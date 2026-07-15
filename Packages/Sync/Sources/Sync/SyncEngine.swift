import Foundation
import Learning

/// Machine-readable failure reason. The APP maps these to user-presentable
/// Icelandic strings (all UI copy lives in the app's `Strings` enum) — the
/// package stays presentation-free.
public enum SyncFailureReason: Equatable, Sendable {
    /// No iCloud account on this device.
    case noAccount
    /// Offline / CloudKit transient failure — retry later.
    case networkUnavailable
    /// iCloud storage full.
    case quotaExceeded
    /// Conflicted twice in one sync (fetch → merge → save → conflict →
    /// re-merge → save → conflict). Extremely busy multi-device moment;
    /// the next scheduled sync resolves it.
    case conflict
    /// A remote snapshot exists but this device has no envelope key yet —
    /// normal on a freshly restored device while iCloud Keychain is still
    /// syncing. NO new key is minted in this state (that would strand the
    /// existing remote data); just retry later.
    case keyUnavailable
    /// The Keychain itself errored (locked, entitlement issue).
    case keychainFailure
    /// The remote blob would not decrypt/decode (tampered, truncated, or
    /// encrypted with a key this device does not have). Local state is
    /// never clobbered and remote is never overwritten in this state; the
    /// user-level remedy is "Eyða gögnum úr iCloud" + fresh sync.
    case cannotDecryptRemote
    /// The remote snapshot was written by a NEWER app version (schema
    /// ahead of ours). Refuse to touch it; user updates the app.
    case newerRemoteSchema
    /// The local model file bytes did not decode — sync refuses to run
    /// rather than risk pushing garbage.
    case localModelUnreadable
    /// CloudKit not provisioned in this build (`SyncActivation`).
    case notActivated
    /// Anything else, stringly.
    case storeFailure(String)
}

/// Result of one `SyncEngine.sync` call.
///
/// `newLocalModelData` (on `.pulled`/`.merged`, and best-effort on
/// `.failed`) is a complete serialized `PersonalModel` file — merged
/// payload plus this device's own `consumedLogMarker` — that the caller
/// writes back to the model file and reloads. The engine NEVER touches
/// disk itself.
public enum SyncOutcome: Equatable, Sendable {
    /// Sync is switched off (opt-out flag) — nothing was fetched or sent.
    case disabled
    /// Local and remote digests already matched.
    case upToDate
    /// Remote updated; local unchanged.
    case pushed
    /// Local needs updating; remote already contained a superset.
    case pulled(newLocalModelData: Data)
    /// Both sides changed: merged state pushed, and local needs updating.
    case merged(newLocalModelData: Data)
    /// Sync did not complete. `newLocalModelData` is non-nil when a merge
    /// had already produced a better local state before the failure (e.g.
    /// push conflicted twice) — the caller should still apply it.
    case failed(SyncFailureReason, newLocalModelData: Data?)
}

/// Result of `SyncEngine.deleteRemote`.
public enum SyncDeleteOutcome: Equatable, Sendable {
    case deleted
    case failed(SyncFailureReason)
}

/// Orchestrates one sync round: fetch remote → decrypt → merge → save back
/// if needed (retry once on conflict, with re-merge).
///
/// ## Statelessness & scheduling
///
/// The engine keeps NO state between `sync` calls (the actor only
/// serializes overlapping calls; the real CloudKit store carries the CK
/// change tag). Debounce/coalescing is the CALLER's job: the app's
/// `SyncCoordinator` coalesces triggers (post-compaction, dictionary-editor
/// mutations) into one call ~5s after the last trigger. Calling `sync`
/// twice in a row is always safe — the second call short-circuits at
/// `.upToDate`.
///
/// ## Key bootstrap rules (order matters)
///
/// 1. Remote fetched FIRST. If a remote snapshot exists but no key is in
///    the Keychain, fail with `.keyUnavailable` — never mint a second key,
///    which would make the existing snapshot permanently undecryptable and
///    fork the devices.
/// 2. Only when BOTH remote and key are absent is a fresh key generated
///    and stored (add-if-absent; the stored winner is re-loaded in case
///    another device raced us).
///
/// ## Opt-out (v1-blocker: iCloud opt-out + delete-all)
///
/// `sync` short-circuits to `.disabled` when `isEnabled()` is false.
/// `deleteRemote` deliberately IGNORES the flag — deleting remote data
/// after opting out is exactly the expected order of operations.
public actor SyncEngine {

    public static let supportedSchemaVersion = PersonalModel.schemaVersion

    private let store: CloudRecordStore
    private let keyStore: SyncKeyStore
    private let isEnabled: () -> Bool
    private let deviceIdentifier: String

    /// - Parameters:
    ///   - store: CloudKit seam (`CloudKitRecordStore` once provisioned,
    ///     `UnactivatedCloudStore` until then, `InMemoryCloudStore` in
    ///     tests).
    ///   - keyStore: envelope-key storage (`ICloudKeychainStore` in the
    ///     app, `InMemoryKeyStore` in tests).
    ///   - isEnabled: read the user's opt-out flag at call time (so a
    ///     toggle flipped mid-flight is respected on the next call).
    ///   - deviceIdentifier: opaque per-device tag for the record's
    ///     `deviceLastWriter` field. Diagnostics only — pass a random
    ///     per-install UUID, not the user-visible device name.
    public init(
        store: CloudRecordStore,
        keyStore: SyncKeyStore,
        isEnabled: @escaping () -> Bool,
        deviceIdentifier: String
    ) {
        self.store = store
        self.keyStore = keyStore
        self.isEnabled = isEnabled
        self.deviceIdentifier = deviceIdentifier
    }

    // MARK: - Sync

    /// One full sync round over the serialized local model file bytes.
    /// Never throws and never crashes on bad input — every failure mode is
    /// a `SyncOutcome.failed` with local state untouched.
    public func sync(localModelData: Data) async -> SyncOutcome {
        guard isEnabled() else { return .disabled }

        // Parse local state. Refuse to sync anything we can't read.
        guard let localDoc = try? PersonalModelDocument(decoding: localModelData),
              let localDigest = try? localDoc.payload.digestHex() else {
            return .failed(.localModelUnreadable, newLocalModelData: nil)
        }
        let localPayload = localDoc.payload

        // Fetch remote BEFORE any key work (see key bootstrap rules).
        let remote: SnapshotRecord?
        do {
            remote = try await store.fetchSnapshot()
        } catch {
            return .failed(Self.reason(for: error), newLocalModelData: nil)
        }

        // Envelope key: load, or bootstrap only when no remote exists.
        let keyData: Data
        do {
            if let existing = try keyStore.loadKeyData() {
                keyData = existing
            } else if remote == nil {
                let candidate = SyncCrypto.generateKey()
                try keyStore.saveKeyData(candidate)
                // add-if-absent: another device may have won the race —
                // whatever is stored now is THE key.
                keyData = try keyStore.loadKeyData() ?? candidate
            } else {
                return .failed(.keyUnavailable, newLocalModelData: nil)
            }
        } catch {
            return .failed(.keychainFailure, newLocalModelData: nil)
        }

        // Decrypt + gate the remote payload.
        var basedOnDigest: String?
        var remotePayload: SyncPayload?
        if let remote {
            guard remote.schemaVersion <= Self.supportedSchemaVersion else {
                return .failed(.newerRemoteSchema, newLocalModelData: nil)
            }
            if remote.modelDigest == localDigest {
                return .upToDate  // digest match — no decryption needed
            }
            guard let decoded = Self.decodePayload(from: remote, keyData: keyData) else {
                return .failed(.cannotDecryptRemote, newLocalModelData: nil)
            }
            remotePayload = decoded
            basedOnDigest = remote.modelDigest
        }

        // Merge (or plain first push when no remote exists).
        var merged = remotePayload.map { PersonalModelMerge.merge(localPayload, $0) } ?? localPayload
        var localChanged = merged != localPayload
        var remoteChanged = remotePayload.map { merged != $0 } ?? true

        func newLocalData() -> Data? {
            guard localChanged else { return nil }
            // Re-attach the DEVICE-LOCAL log marker — never synced.
            return try? PersonalModelDocument(
                payload: merged,
                consumedLogMarker: localDoc.consumedLogMarker
            ).encoded()
        }

        if remoteChanged {
            do {
                try await store.saveSnapshot(
                    try makeRecord(payload: merged, keyData: keyData),
                    basedOnDigest: basedOnDigest
                )
            } catch CloudStoreError.conflict(let server) {
                // Server-wins fetch-merge-retry, exactly once: fold the
                // server's newer state into our merge and save on top of it.
                guard let server,
                      server.schemaVersion <= Self.supportedSchemaVersion,
                      let serverPayload = Self.decodePayload(from: server, keyData: keyData) else {
                    return .failed(.conflict, newLocalModelData: newLocalData())
                }
                merged = PersonalModelMerge.merge(merged, serverPayload)
                localChanged = merged != localPayload
                remoteChanged = merged != serverPayload
                if remoteChanged {
                    do {
                        try await store.saveSnapshot(
                            try makeRecord(payload: merged, keyData: keyData),
                            basedOnDigest: server.modelDigest
                        )
                    } catch {
                        return .failed(Self.reason(for: error), newLocalModelData: newLocalData())
                    }
                }
            } catch {
                return .failed(Self.reason(for: error), newLocalModelData: newLocalData())
            }
        }

        switch (localChanged, remoteChanged) {
        case (false, false):
            return .upToDate
        case (false, true):
            return .pushed
        case (true, _):
            guard let data = newLocalData() else {
                return .failed(.localModelUnreadable, newLocalModelData: nil)
            }
            return remoteChanged ? .merged(newLocalModelData: data) : .pulled(newLocalModelData: data)
        }
    }

    // MARK: - Delete-all (v1-blocker)

    /// Removes the snapshot record from the user's private database.
    /// Works regardless of the opt-out flag (see actor docs). Pass
    /// `alsoRemoveKey: true` only for a full "never again" wipe — removing
    /// the key from the iCloud Keychain strands any OTHER device that has
    /// not yet pulled, so the app's default delete flow keeps the key.
    public func deleteRemote(alsoRemoveKey: Bool = false) async -> SyncDeleteOutcome {
        do {
            try await store.deleteSnapshot()
        } catch {
            return .failed(Self.reason(for: error))
        }
        if alsoRemoveKey {
            do {
                try keyStore.deleteKeyData()
            } catch {
                return .failed(.keychainFailure)
            }
        }
        return .deleted
    }

    // MARK: - Helpers

    private func makeRecord(payload: SyncPayload, keyData: Data) throws -> SnapshotRecord {
        let plaintext = try payload.canonicalData()
        return SnapshotRecord(
            sealedBlob: try SyncCrypto.seal(plaintext, keyData: keyData),
            schemaVersion: payload.schemaVersion,
            modelDigest: SyncCrypto.digestHex(plaintext),
            deviceLastWriter: deviceIdentifier
        )
    }

    /// Decrypt + decode, collapsing every failure into nil (corrupted blob
    /// → safe error at the call site; never crashes, never clobbers).
    private static func decodePayload(from record: SnapshotRecord, keyData: Data) -> SyncPayload? {
        guard let plaintext = try? SyncCrypto.open(record.sealedBlob, keyData: keyData) else {
            return nil
        }
        return try? SyncPayload.decode(plaintext)
    }

    private static func reason(for error: Error) -> SyncFailureReason {
        switch error {
        case CloudStoreError.noAccount: return .noAccount
        case CloudStoreError.networkUnavailable: return .networkUnavailable
        case CloudStoreError.quotaExceeded: return .quotaExceeded
        case CloudStoreError.conflict: return .conflict
        case CloudStoreError.notActivated: return .notActivated
        case CloudStoreError.other(let message): return .storeFailure(message)
        default: return .storeFailure(String(describing: error))
        }
    }
}
