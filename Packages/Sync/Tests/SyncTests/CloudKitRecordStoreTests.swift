import CloudKit
import XCTest
@testable import Sync

/// Exercises the CKAsset staging helpers directly (no `CKContainer`, no
/// entitlements, no network — `apply`/`sweepStaleStagingFiles` are pure
/// file-system + `CKRecord` field manipulation). See `CloudKitRecordStore`'s
/// doc comment: the actor itself isn't exercised by unit tests, but these
/// static helpers are the ones responsible for not leaking staging files.
final class CloudKitRecordStoreTests: XCTestCase {

    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitRecordStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        scratchDir = nil
        super.tearDown()
    }

    private func makeRecord() -> CKRecord {
        CKRecord(recordType: SyncActivation.recordType, recordID: CKRecord.ID(recordName: "test"))
    }

    // MARK: - apply()

    func testApplyStagesLargeBlobAndReturnsItsURL() throws {
        let bigBlob = Data(repeating: 0x42, count: 1_000_000)
        let snapshot = SnapshotRecord(
            sealedBlob: bigBlob,
            schemaVersion: 1,
            modelDigest: "deadbeef",
            deviceLastWriter: "device-a"
        )
        let record = makeRecord()
        let stagedURL = try CloudKitRecordStore.apply(snapshot, to: record)

        let url = try XCTUnwrap(stagedURL, "a blob over the asset threshold must be staged to disk")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("lyklabord-sync-"))
        XCTAssertEqual(url.pathExtension, "bin")
        XCTAssertEqual(try Data(contentsOf: url), bigBlob)
        XCTAssertNotNil(record[SyncActivation.Field.sealedBlobAsset] as? CKAsset)
        XCTAssertNil(record[SyncActivation.Field.sealedBlob])

        // Cleanup mirrors what `saveSnapshot`'s `defer` does in production.
        try? FileManager.default.removeItem(at: url)
    }

    func testApplySmallBlobStaysInlineAndStagesNoFile() throws {
        let smallBlob = Data(repeating: 0x11, count: 128)
        let snapshot = SnapshotRecord(
            sealedBlob: smallBlob,
            schemaVersion: 1,
            modelDigest: "cafebabe",
            deviceLastWriter: "device-a"
        )
        let record = makeRecord()
        let stagedURL = try CloudKitRecordStore.apply(snapshot, to: record)

        XCTAssertNil(stagedURL, "a small blob must not be staged to a loose file")
        XCTAssertEqual(record[SyncActivation.Field.sealedBlob] as? Data, smallBlob)
        XCTAssertNil(record[SyncActivation.Field.sealedBlobAsset])
    }

    // MARK: - sweepStaleStagingFiles()

    func testSweepRemovesOnlyStaleStagingFiles() throws {
        let fm = FileManager.default
        let stale = scratchDir.appendingPathComponent("lyklabord-sync-\(UUID().uuidString).bin")
        let fresh = scratchDir.appendingPathComponent("lyklabord-sync-\(UUID().uuidString).bin")
        let unrelated = scratchDir.appendingPathComponent("some-other-file.bin")

        try Data([0x01]).write(to: stale)
        try Data([0x02]).write(to: fresh)
        try Data([0x03]).write(to: unrelated)

        // Back-date only the stale file's modification time by two days.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stale.path)

        CloudKitRecordStore.sweepStaleStagingFiles(olderThan: 86_400, in: scratchDir)

        XCTAssertFalse(fm.fileExists(atPath: stale.path), "stale staging file must be removed")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "fresh staging file must be left alone (save may be in flight)")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "non-matching files must never be touched")
    }

    func testSweepToleratesMissingDirectory() {
        let missing = scratchDir.appendingPathComponent("does-not-exist")
        // Must not throw or crash; just a no-op.
        CloudKitRecordStore.sweepStaleStagingFiles(olderThan: 86_400, in: missing)
    }
}
