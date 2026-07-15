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
        try await ensureZone()
        let record: CKRecord
        if basedOnDigest != nil, let last = lastServerRecord {
            record = last
        } else {
            record = CKRecord(recordType: SyncActivation.recordType, recordID: recordID)
        }
        try Self.apply(snapshot, to: record)
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

    static func apply(_ snapshot: SnapshotRecord, to record: CKRecord) throws {
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
        } else {
            record[SyncActivation.Field.sealedBlob] = snapshot.sealedBlob as NSData
            record[SyncActivation.Field.sealedBlobAsset] = nil
        }
        record[SyncActivation.Field.schemaVersion] = snapshot.schemaVersion as NSNumber
        record[SyncActivation.Field.modelDigest] = snapshot.modelDigest as NSString
        record[SyncActivation.Field.deviceLastWriter] = snapshot.deviceLastWriter as NSString
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
