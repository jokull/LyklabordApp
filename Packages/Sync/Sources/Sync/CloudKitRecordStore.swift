#if canImport(CloudKit)
import CloudKit
import Foundation

/// Real `CKContainer`-backed `CloudRecordStore`.
///
/// NOT exercised by unit tests (no entitlements in SPM) and NOT
/// instantiated by the app until `SyncActivation.isCloudKitProvisioned`
/// is flipped — creating a `CKContainer` for an identifier absent from the
/// entitlements raises an Objective-C exception. TODO(provisioning): once
/// the container exists, the app's `SyncCoordinator` constructs this with
/// `SyncActivation.containerIdentifier` and the whole path goes live; no
/// other code changes needed.
///
/// Layout: one record (`SyncActivation.recordType` / `.recordName`) in the
/// custom zone `SyncActivation.zoneName` of the user's PRIVATE database.
/// Optimistic concurrency: saves go through `.ifServerRecordUnchanged`
/// against the last-fetched `CKRecord`; a `serverRecordChanged` error is
/// surfaced as `CloudStoreError.conflict(server:)` with the server-side
/// record parsed, so `SyncEngine` can run its fetch-merge-retry loop
/// without an extra round-trip.
public actor CloudKitRecordStore: CloudRecordStore {

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let recordID: CKRecord.ID
    /// The CKRecord (with its server change tag) that `basedOnDigest`-style
    /// saves are built on. Refreshed by every fetch and every successful
    /// save/conflict.
    private var lastServerRecord: CKRecord?
    private var zoneEnsured = false
    /// Guards the one-time stale-staging sweep per store instance (the
    /// store lives for the app's process lifetime — see `SyncCoordinator`).
    private var didSweepStaleStaging = false

    /// Blobs above this go into a `CKAsset` instead of an inline `Data`
    /// field (CKRecord values are budgeted at ~1MB total).
    private static let assetThresholdBytes = 900_000

    public init(containerIdentifier: String = SyncActivation.containerIdentifier) {
        let container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: SyncActivation.zoneName, ownerName: CKCurrentUserDefaultName)
        recordID = CKRecord.ID(recordName: SyncActivation.recordName, zoneID: zoneID)
    }

    // MARK: - CloudRecordStore

    public func fetchSnapshot() async throws -> SnapshotRecord? {
        do {
            let record = try await database.record(for: recordID)
            lastServerRecord = record
            return try Self.snapshot(from: record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            lastServerRecord = nil
            return nil
        } catch {
            throw mapError(error)
        }
    }

    public func saveSnapshot(_ snapshot: SnapshotRecord, basedOnDigest: String?) async throws {
        if !didSweepStaleStaging {
            didSweepStaleStaging = true
            Self.sweepStaleStagingFiles()
        }
        try await ensureZone()
        let record: CKRecord
        if basedOnDigest != nil, let last = lastServerRecord {
            record = last
        } else {
            record = CKRecord(recordType: SyncActivation.recordType, recordID: recordID)
        }
        // `apply` may stage the sealed blob as a loose file on disk for the
        // CKAsset to point at (CloudKit reads it directly during upload).
        // Whether the upload below succeeds or throws, the staging file
        // must not outlive this call — otherwise every save leaks a
        // ~1.6MB file into the container's tmp/ directory forever.
        let stagedFileURL = try Self.apply(snapshot, to: record)
        defer {
            if let stagedFileURL {
                try? FileManager.default.removeItem(at: stagedFileURL)
            }
        }
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            for (_, result) in saveResults {
                switch result {
                case .success(let saved):
                    lastServerRecord = saved
                case .failure(let error):
                    throw mapError(error)
                }
            }
        } catch let error as CloudStoreError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    public func deleteSnapshot() async throws {
        do {
            try await database.deleteRecord(withID: recordID)
            lastServerRecord = nil
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            lastServerRecord = nil  // nothing to delete — idempotent success
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Zone bootstrap

    /// Custom zones must exist before the first record save. Saving an
    /// existing zone is an idempotent update, so no existence check needed;
    /// remembered per instance to avoid a round-trip per save.
    private func ensureZone() async throws {
        guard !zoneEnsured else { return }
        do {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
            zoneEnsured = true
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Record <-> snapshot mapping

    static func snapshot(from record: CKRecord) throws -> SnapshotRecord {
        let blob: Data
        if let data = record[SyncActivation.Field.sealedBlob] as? Data {
            blob = data
        } else if let asset = record[SyncActivation.Field.sealedBlobAsset] as? CKAsset,
                  let fileURL = asset.fileURL,
                  let data = try? Data(contentsOf: fileURL) {
            blob = data
        } else {
            throw CloudStoreError.other("snapshot record has no sealed blob")
        }
        return SnapshotRecord(
            sealedBlob: blob,
            schemaVersion: record[SyncActivation.Field.schemaVersion] as? Int ?? 0,
            modelDigest: record[SyncActivation.Field.modelDigest] as? String ?? "",
            deviceLastWriter: record[SyncActivation.Field.deviceLastWriter] as? String ?? ""
        )
    }

    /// Applies `snapshot` onto `record`, staging the sealed blob as a loose
    /// file when it is large enough to need a `CKAsset`. Returns the staged
    /// file's URL so the caller can delete it once the upload that reads it
    /// has finished (success or failure) — the file must survive until then
    /// but not a moment longer. Returns `nil` when the blob was small enough
    /// to go inline (no file staged).
    @discardableResult
    static func apply(_ snapshot: SnapshotRecord, to record: CKRecord) throws -> URL? {
        if snapshot.sealedBlob.count > assetThresholdBytes {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyklabord-sync-\(UUID().uuidString).bin")
            do {
                try snapshot.sealedBlob.write(to: tempURL, options: .atomic)
            } catch {
                throw CloudStoreError.other("asset staging failed: \(error.localizedDescription)")
            }
            record[SyncActivation.Field.sealedBlobAsset] = CKAsset(fileURL: tempURL)
            record[SyncActivation.Field.sealedBlob] = nil
            record[SyncActivation.Field.schemaVersion] = snapshot.schemaVersion as NSNumber
            record[SyncActivation.Field.modelDigest] = snapshot.modelDigest as NSString
            record[SyncActivation.Field.deviceLastWriter] = snapshot.deviceLastWriter as NSString
            return tempURL
        } else {
            record[SyncActivation.Field.sealedBlob] = snapshot.sealedBlob as NSData
            record[SyncActivation.Field.sealedBlobAsset] = nil
            record[SyncActivation.Field.schemaVersion] = snapshot.schemaVersion as NSNumber
            record[SyncActivation.Field.modelDigest] = snapshot.modelDigest as NSString
            record[SyncActivation.Field.deviceLastWriter] = snapshot.deviceLastWriter as NSString
            return nil
        }
    }

    // MARK: - Staging cleanup

    /// Removes leftover `lyklabord-sync-*.bin` staging files older than
    /// `maxAge`. Normal operation cleans these up itself (see `saveSnapshot`'s
    /// `defer`), but a process kill mid-upload (crash, force-quit, jetsam)
    /// can strand one — this sweep is the crash-resilience backstop, run
    /// once per store instance before the first save. Only touches files
    /// older than a day so a save currently in flight is never raced.
    static func sweepStaleStagingFiles(
        olderThan maxAge: TimeInterval = 86_400,
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in contents {
            guard url.lastPathComponent.hasPrefix("lyklabord-sync-"), url.pathExtension == "bin" else {
                continue
            }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modDate, modDate < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Error mapping

    private func mapError(_ error: Error) -> CloudStoreError {
        guard let ckError = error as? CKError else {
            return .other(error.localizedDescription)
        }
        // Batch APIs wrap per-item failures; unwrap the one that matters.
        if ckError.code == .partialFailure,
           let partial = ckError.partialErrorsByItemID?.values.first as? CKError {
            return mapCKError(partial)
        }
        return mapCKError(ckError)
    }

    private func mapCKError(_ ckError: CKError) -> CloudStoreError {
        switch ckError.code {
        case .notAuthenticated:
            return .noAccount
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // All transient-transport shaped: retry later.
            return .networkUnavailable
        case .quotaExceeded:
            return .quotaExceeded
        case .serverRecordChanged:
            if let server = ckError.serverRecord {
                lastServerRecord = server
                return .conflict(server: try? Self.snapshot(from: server))
            }
            return .conflict(server: nil)
        default:
            return .other("CKError \(ckError.code.rawValue): \(ckError.localizedDescription)")
        }
    }
}
#endif
