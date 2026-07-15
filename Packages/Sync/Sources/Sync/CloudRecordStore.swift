import Foundation

/// The single snapshot record, as the engine sees it — one per user, living
/// in the private database's custom zone (see `SyncActivation` for record
/// type/field documentation).
public struct SnapshotRecord: Equatable, Sendable {
    /// AES-GCM sealed canonical `SyncPayload` bytes.
    public var sealedBlob: Data
    /// Plaintext schema version (pre-decryption gating).
    public var schemaVersion: Int
    /// Lowercase hex SHA-256 of the plaintext payload — change detection
    /// without decryption, and the optimistic-concurrency token at this
    /// protocol's level.
    public var modelDigest: String
    /// Opaque identifier of the device that last wrote the record
    /// (diagnostics only).
    public var deviceLastWriter: String

    public init(sealedBlob: Data, schemaVersion: Int, modelDigest: String, deviceLastWriter: String) {
        self.sealedBlob = sealedBlob
        self.schemaVersion = schemaVersion
        self.modelDigest = modelDigest
        self.deviceLastWriter = deviceLastWriter
    }
}

public enum CloudStoreError: Error, Equatable {
    /// No iCloud account signed in on this device.
    case noAccount
    /// Transient transport failure (offline, CloudKit unavailable,
    /// rate-limited) — safe to retry later.
    case networkUnavailable
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// Optimistic-concurrency failure: another device wrote the record
    /// after this client's fetch. Carries the current server record when
    /// available so the caller can re-merge and retry without a round-trip.
    case conflict(server: SnapshotRecord?)
    /// CloudKit is not provisioned in this build (see `SyncActivation`).
    case notActivated
    /// Anything else, stringly (CKError descriptions vary).
    case other(String)
}

/// Protocol seam over CloudKit so the engine unit-tests without a container
/// (and without entitlements — see `SyncActivation`).
///
/// Concurrency contract: `saveSnapshot`'s `basedOnDigest` is the
/// `modelDigest` of the record version the save is based on (`nil` = "I
/// expect no record to exist"). Implementations must reject a save whose
/// basis no longer matches the server state with
/// `CloudStoreError.conflict` — the CloudKit implementation gets this from
/// `.ifServerRecordUnchanged` + `serverRecordChanged`, the in-memory fake
/// compares digests directly.
public protocol CloudRecordStore {
    /// The current snapshot, or nil when none exists yet (first sync, or
    /// after `deleteSnapshot`).
    func fetchSnapshot() async throws -> SnapshotRecord?
    /// Save, guarded by `basedOnDigest` (see above).
    func saveSnapshot(_ record: SnapshotRecord, basedOnDigest: String?) async throws
    /// Remove the record. Missing record is not an error (idempotent —
    /// "delete my iCloud data" must always succeed when there is nothing
    /// left to delete).
    func deleteSnapshot() async throws
}

/// Stand-in store for builds where the CloudKit container is not yet
/// provisioned (`SyncActivation.isCloudKitProvisioned == false`). Every
/// operation fails with `.notActivated`, which the app presents as a
/// neutral "not active in this build yet" status — never as a crash.
public struct UnactivatedCloudStore: CloudRecordStore {
    public init() {}

    public func fetchSnapshot() async throws -> SnapshotRecord? {
        throw CloudStoreError.notActivated
    }

    public func saveSnapshot(_ record: SnapshotRecord, basedOnDigest: String?) async throws {
        throw CloudStoreError.notActivated
    }

    public func deleteSnapshot() async throws {
        throw CloudStoreError.notActivated
    }
}

/// In-memory fake for tests: scripted one-shot errors, a concurrent-writer
/// queue for conflict simulation, and call counters for interaction
/// assertions.
public actor InMemoryCloudStore: CloudRecordStore {
    public private(set) var record: SnapshotRecord?
    public private(set) var fetchCount = 0
    public private(set) var saveCount = 0
    public private(set) var deleteCount = 0

    private var fetchErrors: [CloudStoreError] = []
    private var saveErrors: [CloudStoreError] = []
    private var deleteErrors: [CloudStoreError] = []
    /// Records that "another device" writes immediately before each
    /// subsequent save attempt's conflict check — consumed one per save.
    private var concurrentWrites: [SnapshotRecord] = []

    public init(record: SnapshotRecord? = nil) {
        self.record = record
    }

    // MARK: - Test scripting

    public func seed(_ record: SnapshotRecord?) {
        self.record = record
    }

    public func failNextFetch(_ error: CloudStoreError) {
        fetchErrors.append(error)
    }

    public func failNextSave(_ error: CloudStoreError) {
        saveErrors.append(error)
    }

    public func failNextDelete(_ error: CloudStoreError) {
        deleteErrors.append(error)
    }

    public func queueConcurrentWrite(_ record: SnapshotRecord) {
        concurrentWrites.append(record)
    }

    // MARK: - CloudRecordStore

    public func fetchSnapshot() async throws -> SnapshotRecord? {
        fetchCount += 1
        if !fetchErrors.isEmpty { throw fetchErrors.removeFirst() }
        return record
    }

    public func saveSnapshot(_ new: SnapshotRecord, basedOnDigest: String?) async throws {
        saveCount += 1
        if !concurrentWrites.isEmpty {
            record = concurrentWrites.removeFirst()
        }
        if !saveErrors.isEmpty { throw saveErrors.removeFirst() }
        guard record?.modelDigest == basedOnDigest else {
            throw CloudStoreError.conflict(server: record)
        }
        record = new
    }

    public func deleteSnapshot() async throws {
        deleteCount += 1
        if !deleteErrors.isEmpty { throw deleteErrors.removeFirst() }
        record = nil
    }
}
