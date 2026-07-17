//
//  SyncCoordinator.swift
//  BetterKeyboard
//
//  M2 wave 3: app-side owner of the CloudKit sync loop. Bridges `AppModel`
//  (which owns the personal-model FILE) to `Sync.SyncEngine` (which is
//  stateless per call and never touches disk). The keyboard extension has
//  no counterpart to this type BY DESIGN — sync is app-only, always
//  (architecture invariant: the extension ships zero network code and is
//  untouched by Full Access denial).
//

import Foundation
import Observation
import Sync

@MainActor
@Observable
final class SyncCoordinator {

    // MARK: - Keys

    /// Opt-out flag in the App Group `UserDefaults` suite (same suite as
    /// the spacebar mode, so a later extension wave could show a subtle
    /// sync indicator if ever wanted). Default ON per PLAN decision #5
    /// ("sync transparently, zero-config") — absent key means enabled.
    static let syncEnabledDefaultsKey = "is.solberg.lyklabord.settings.icloudSyncEnabled"

    /// Random per-install identifier for the record's `deviceLastWriter`
    /// diagnostics field. Deliberately NOT the user-visible device name
    /// (no PII in record metadata) and deliberately in the app's OWN
    /// standard defaults (device-local by definition).
    private static let deviceIdentifierDefaultsKey = "is.solberg.lyklabord.sync.deviceIdentifier"

    /// How long dictionary-editor mutations / compactions coalesce before
    /// one sync round runs (rapid-fire edits become a single round-trip).
    static let coalescingDelay: Duration = .seconds(5)

    // MARK: - Display state

    /// What the settings screen shows. Lightweight mirror of `SyncOutcome`
    /// (the outcome's merged-model payload bytes are applied immediately,
    /// never retained here).
    enum DisplayState: Equatable {
        case never
        case syncing
        case disabled
        case success(Kind, Date)
        case failure(SyncFailureReason, Date)
        case deleted(Date)

        enum Kind: Equatable {
            case upToDate, pushed, pulled, merged
        }
    }

    private(set) var displayState: DisplayState = .never

    /// Set by `AppModel` — invoked after a pulled/merged model has been
    /// written to the model file, so the in-memory model and listings
    /// reload from disk.
    var onModelDataReplaced: (() -> Void)?

    // MARK: - Wiring

    private let engine: SyncEngine
    private let modelURL: URL?
    private var pendingSync: Task<Void, Never>?
    /// Serializes overlapping `syncNow` calls (scheduled + manual).
    private var activeSync: Task<Void, Never>?

    static func isSyncEnabled() -> Bool {
        guard let defaults = UserDefaults(suiteName: AppModel.appGroupIdentifier) else { return true }
        return defaults.object(forKey: syncEnabledDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: syncEnabledDefaultsKey)
    }

    init(modelURL: URL?) {
        self.modelURL = modelURL
        // TODO(provisioning): when `SyncActivation.isCloudKitProvisioned`
        // flips (paid team + container "iCloud.is.solberg.lyklabord" + app-target
        // entitlement — see SyncActivation docs), this line starts
        // constructing the real store; nothing else changes.
        let store: CloudRecordStore = SyncActivation.isCloudKitProvisioned
            ? CloudKitRecordStore(containerIdentifier: SyncActivation.containerIdentifier)
            : UnactivatedCloudStore()
        engine = SyncEngine(
            store: store,
            keyStore: ICloudKeychainStore(),
            // Lyklaborð+ gate: iCloud sync of the personal model is part of
            // the subscription. Checked per sync round (like the opt-out
            // toggle) so an entitlement change takes effect on the next
            // round without restarting anything. Unentitled ⇒ the engine
            // reports `.disabled` — sync is PAUSED, local data untouched.
            // Delete-remote is NOT gated (`deleteRemote` ignores
            // `isEnabled` by design): data-deletion rights are never
            // paywalled.
            isEnabled: { SyncCoordinator.isSyncEnabled() && PlusGate.isEntitled() },
            deviceIdentifier: Self.deviceIdentifier()
        )
    }

    private static func deviceIdentifier() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdentifierDefaultsKey) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdentifierDefaultsKey)
        return fresh
    }

    // MARK: - Triggers

    /// Coalescing trigger: called after every compaction (launch /
    /// foreground) and after every dictionary-editor mutation. Restarts
    /// the ~5s timer; a burst of edits produces one sync round. The engine
    /// itself is stateless per call — this is the documented caller-side
    /// debounce.
    func noteLocalChange() {
        guard modelURL != nil else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// One immediate sync round (settings toggle-on, pull-to-refresh
    /// style affordances). Overlapping calls queue behind the active one.
    func syncNow() async {
        if let activeSync {
            await activeSync.value
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
        }
        activeSync = task
        await task.value
        activeSync = nil
    }

    private func performSync() async {
        guard let modelURL,
              FileManager.default.fileExists(atPath: modelURL.path),
              let localData = try? Data(contentsOf: modelURL) else {
            return  // nothing to sync yet (first launch before any compaction)
        }
        displayState = .syncing
        let outcome = await engine.sync(localModelData: localData)
        apply(outcome, basedOn: localData)
    }

    private func apply(_ outcome: SyncOutcome, basedOn readData: Data) {
        let now = Date()
        switch outcome {
        case .disabled:
            displayState = .disabled
        case .upToDate:
            displayState = .success(.upToDate, now)
        case .pushed:
            displayState = .success(.pushed, now)
        case .pulled(let newData):
            displayState = writeBack(newData, basedOn: readData) ? .success(.pulled, now) : displayState
        case .merged(let newData):
            displayState = writeBack(newData, basedOn: readData) ? .success(.merged, now) : displayState
        case .failed(let reason, let newData):
            if let newData {
                _ = writeBack(newData, basedOn: readData)
            }
            displayState = .failure(reason, now)
        }
    }

    /// Applies a pulled/merged model file. Guard against a local mutation
    /// that landed while the engine was in flight: if the file on disk no
    /// longer matches the bytes the sync round was based on, the merge
    /// result is stale — skip the write and re-schedule so the next round
    /// folds both changes in.
    private func writeBack(_ newData: Data, basedOn readData: Data) -> Bool {
        guard let modelURL else { return false }
        guard let current = try? Data(contentsOf: modelURL), current == readData else {
            noteLocalChange()
            return false
        }
        do {
            try newData.write(to: modelURL, options: .atomic)
        } catch {
            return false
        }
        onModelDataReplaced?()
        return true
    }

    // MARK: - Delete-all (v1-blocker: iCloud opt-out + delete-all)

    /// Removes the snapshot record from the user's private database. The
    /// envelope key stays in the iCloud Keychain — deleting it would
    /// strand other devices that have not pulled yet, and a kept key is
    /// harmless once the ciphertext is gone. Works while sync is disabled
    /// (opting out and then deleting is the expected order).
    /// Returns true on success.
    ///
    /// `alsoRemoveKey` defaults to false for the standalone "Eyða gögnum úr
    /// iCloud" action (a kept key is harmless once the ciphertext is gone,
    /// and dropping it would strand other devices that have not pulled). The
    /// app's total "delete all data" flow passes `true` — a full "never
    /// again" wipe removes the envelope key from the iCloud Keychain too.
    @discardableResult
    func deleteRemoteData(alsoRemoveKey: Bool = false) async -> Bool {
        pendingSync?.cancel()
        let outcome = await engine.deleteRemote(alsoRemoveKey: alsoRemoveKey)
        switch outcome {
        case .deleted:
            displayState = .deleted(Date())
            return true
        case .failed(let reason):
            displayState = .failure(reason, Date())
            return false
        }
    }

    // MARK: - Presentation

    /// Icelandic status line for the settings screen (all copy in
    /// `Strings`; the Sync package is presentation-free).
    var statusText: String {
        switch displayState {
        case .never:
            return SyncActivation.isCloudKitProvisioned
                ? Strings.Settings.syncStatusNever
                : Strings.Settings.syncStatusNotActivated
        case .syncing:
            return Strings.Settings.syncStatusSyncing
        case .disabled:
            return Strings.Settings.syncStatusDisabled
        case .success(let kind, _):
            switch kind {
            case .upToDate: return Strings.Settings.syncOutcomeUpToDate
            case .pushed: return Strings.Settings.syncOutcomePushed
            case .pulled: return Strings.Settings.syncOutcomePulled
            case .merged: return Strings.Settings.syncOutcomeMerged
            }
        case .failure(let reason, _):
            switch reason {
            case .noAccount: return Strings.Settings.syncErrorNoAccount
            case .networkUnavailable: return Strings.Settings.syncErrorNetwork
            case .quotaExceeded: return Strings.Settings.syncErrorQuota
            case .conflict: return Strings.Settings.syncErrorConflict
            case .keyUnavailable: return Strings.Settings.syncErrorKeyUnavailable
            case .cannotDecryptRemote: return Strings.Settings.syncErrorCannotDecrypt
            case .newerRemoteSchema: return Strings.Settings.syncErrorNewerSchema
            case .notActivated: return Strings.Settings.syncStatusNotActivated
            case .keychainFailure, .localModelUnreadable, .storeFailure:
                return Strings.Settings.syncErrorGeneric
            }
        case .deleted:
            return Strings.Settings.syncDeleteDone
        }
    }

    /// Timestamp accompanying the status line, when one applies.
    var statusDate: Date? {
        switch displayState {
        case .never, .syncing, .disabled:
            return nil
        case .success(_, let date), .failure(_, let date), .deleted(let date):
            return date
        }
    }
}
