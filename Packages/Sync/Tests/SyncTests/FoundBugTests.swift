import XCTest
import Learning
@testable import Sync

/// Regressions for real defects found by the Sync harness. Each started
/// life as a strict `XCTExpectFailure` repro; the wrapper was removed when
/// the defect was fixed and the assertions kept (and sharpened — the
/// original asserted on a merged payload that the fixed path never
/// produces, so it would have passed vacuously).
final class FoundBugTests: XCTestCase {

    private var store: InMemoryCloudStore!
    private var keyStore: InMemoryKeyStore!
    private var key: Data!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = InMemoryCloudStore()
        key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncFoundBug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine(_ device: String) -> SyncEngine {
        SyncEngine(store: store, keyStore: keyStore, isEnabled: { true }, deviceIdentifier: device)
    }

    /// The remote snapshot, decrypted — what every OTHER device will pull.
    private func remotePayload() async throws -> SyncPayload {
        let stored = await store.record
        let record = try XCTUnwrap(stored)
        return try SyncPayload.decode(try SyncCrypto.open(record.sealedBlob, keyData: key))
    }

    /// One simulated device: a real `PersonalModel` file plus an event log
    /// for implicit learning; `sync` writes back exactly as the app does.
    private final class Device {
        var model: PersonalModel
        let url: URL
        let log: EventLog
        init(_ name: String, in directory: URL) throws {
            url = directory.appendingPathComponent("\(name).json")
            model = PersonalModel()
            log = EventLog(url: directory.appendingPathComponent("\(name).log"), dayProvider: { 20_000 })
            try model.save(to: url)
        }
        func reload() throws -> PersonalModel { try PersonalModel(contentsOf: url) }
    }

    /// Mirrors the app: the model FILE is the source of truth (editor
    /// mutations are saved immediately), so reload it, compact pending log
    /// events into it, sync, write back, reload.
    @discardableResult
    private func sync(_ device: Device, as name: String) async throws -> (SyncOutcome, PersonalModel) {
        device.model = try device.reload()
        try device.model.compactAndSave(applying: device.log, to: device.url)
        let outcome = await engine(name).sync(localModelData: try Data(contentsOf: device.url))
        switch outcome {
        case .pulled(let data), .merged(let data), .failed(_, let data?):
            try data.write(to: device.url, options: .atomic)
        case .failed(let reason, nil):
            XCTFail("sync failed: \(reason)")
        default:
            break
        }
        device.model = try device.reload()
        return (outcome, device.model)
    }

    // MARK: - Bug: an explicit re-add could never survive sync

    /// `merge` was tombstone union, so the device that re-added a word
    /// (`addUserWord`, behind the dictionary editor's "Afturkalla" undo) had
    /// its own next sync re-tombstone it — the re-add never reached the
    /// remote from ANY device. Now the re-add bumps the word's tombstone
    /// epoch and the merge lets the higher epoch win.
    func testExplicitReAddOnTheSameDeviceSurvivesItsOwnNextSync() async throws {
        let modelURL = directory.appendingPathComponent("A.json")

        // One device, real PersonalModel: learn, delete (tombstone), sync.
        let model = PersonalModel()
        _ = model.importLearnedWords(["Jökull"])
        model.remove(word: "Jökull")
        try model.save(to: modelURL)
        var outcome = await engine("A").sync(localModelData: try Data(contentsOf: modelURL))
        XCTAssertEqual(outcome, .pushed)
        let afterDelete = try await remotePayload()
        XCTAssertTrue(afterDelete.tombstones.contains("Jökull"))

        // The user taps "Afturkalla" (undo) → addUserWord clears the local
        // tombstone and makes the word valid again.
        try model.addUserWord("Jökull")
        XCTAssertTrue(model.isLearned("Jökull"))
        XCTAssertFalse(model.isTombstoned("Jökull"))
        XCTAssertEqual(model.tombstoneEpoch(of: "Jökull"), 2)
        try model.save(to: modelURL)

        // Next scheduled sync of the SAME device: local wins (epoch 2 > 1),
        // so nothing comes back and the remote now carries the re-add.
        outcome = await engine("A").sync(localModelData: try Data(contentsOf: modelURL))
        XCTAssertEqual(outcome, .pushed, "the local re-add must not be reverted")
        let remote = try await remotePayload()
        XCTAssertTrue(remote.userAdded.contains("Jökull"), "re-added word must reach the remote as user-added")
        XCTAssertFalse(remote.tombstones.contains("Jökull"), "re-add must clear the synced tombstone")
        XCTAssertEqual(remote.tombstoneEpoch(of: "Jökull"), 2)

        // Stable: a third sync is a no-op.
        outcome = await engine("A").sync(localModelData: try Data(contentsOf: modelURL))
        XCTAssertEqual(outcome, .upToDate)
    }

    /// Two devices: the re-add propagates to the other device, a LATER
    /// explicit delete there beats it, and that in turn propagates back.
    func testReAddPropagatesAndLaterDeleteBeatsIt() async throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        try a.model.addUserWord("Þórsmörk")
        try a.model.save(to: a.url)
        try await sync(a, as: "A"); try await sync(b, as: "B")
        XCTAssertTrue(try b.reload().isLearned("Þórsmörk"))

        // B deletes; A pulls the deletion.
        var bModel = try b.reload(); bModel.remove(word: "Þórsmörk"); try bModel.save(to: b.url)
        try await sync(b, as: "B")
        var (_, aModel) = try await sync(a, as: "A")
        XCTAssertFalse(aModel.isLearned("Þórsmörk")); XCTAssertTrue(aModel.isTombstoned("Þórsmörk"))

        // A undoes (explicit re-add) → B must see the word again.
        try aModel.addUserWord("Þórsmörk"); try aModel.save(to: a.url)
        try await sync(a, as: "A")
        (_, bModel) = try await sync(b, as: "B")
        XCTAssertTrue(bModel.isLearned("Þórsmörk"), "re-add must propagate")
        XCTAssertTrue(bModel.isUserAdded("Þórsmörk"))
        XCTAssertFalse(bModel.isTombstoned("Þórsmörk"))

        // B deletes again, later → beats the earlier re-add everywhere.
        bModel.remove(word: "Þórsmörk"); try bModel.save(to: b.url)
        try await sync(b, as: "B")
        (_, aModel) = try await sync(a, as: "A")
        XCTAssertFalse(aModel.isLearned("Þórsmörk"), "later explicit delete must win")
        XCTAssertTrue(aModel.isTombstoned("Þórsmörk"))
        XCTAssertEqual(aModel.tombstoneEpoch(of: "Þórsmörk"), 3)

        // Converged and stable.
        let (again, _) = try await sync(b, as: "B")
        XCTAssertEqual(again, .upToDate)
    }

    /// Deletions still stick against IMPLICIT relearning: after the synced
    /// deletion, typing the word again (commits, even a verbatim tap) on
    /// either device must not resurrect it anywhere — only the editor can.
    func testImplicitRelearningStillCannotResurrectASyncedDeletion() async throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        try a.log.append(.wordTapped(word: "leyndarmál"))
        try await sync(a, as: "A"); try await sync(b, as: "B")
        let bModel = try b.reload()
        XCTAssertTrue(bModel.isLearned("leyndarmál"))
        bModel.remove(word: "leyndarmál"); try bModel.save(to: b.url)
        try await sync(b, as: "B")
        let (_, aModel) = try await sync(a, as: "A")
        XCTAssertTrue(aModel.isTombstoned("leyndarmál"))

        // Both devices keep typing it.
        try a.log.append(.wordTapped(word: "leyndarmál"))
        try a.log.append(.wordCommitted(word: "leyndarmál", previousWord: nil, languageHint: .icelandic))
        try b.log.append(.wordTapped(word: "leyndarmál"))
        for _ in 0..<2 {
            let (_, am) = try await sync(a, as: "A")
            let (_, bm) = try await sync(b, as: "B")
            XCTAssertFalse(am.isLearned("leyndarmál")); XCTAssertFalse(bm.isLearned("leyndarmál"))
            XCTAssertEqual(am.tombstoneEpoch(of: "leyndarmál"), 1, "implicit learning never touches the epoch")
        }
        let remote = try await remotePayload()
        XCTAssertTrue(remote.tombstones.contains("leyndarmál"))
        XCTAssertNil(remote.words["leyndarmál"])
    }

    /// Concurrent, unsynced editor actions on two devices. The epoch counts
    /// flips, so the side that changed its mind MORE often wins; equal flip
    /// counts (both acted once from the same base) tie, and a tie goes to
    /// the tombstone. Walked through with real devices:
    ///
    /// 1. B deletes (1) while A deletes-then-undoes (2) → A wins, re-add.
    /// 2. From that base both delete concurrently (3 vs 3) → tombstone.
    /// 3. From that base both re-add concurrently (4 vs 4) → user-added.
    /// 4. From that base B deletes (5) and syncs, while A — without pulling
    ///    — deletes and undoes (6) → A's deliberate re-add wins (6 > 5).
    func testConcurrentEditorActionsResolveByFlipCountThenTombstone() async throws {
        let a = try Device("A", in: directory), b = try Device("B", in: directory)
        try a.model.addUserWord("hestur"); try a.model.save(to: a.url)
        try await sync(a, as: "A"); try await sync(b, as: "B")

        func converge() async throws -> (PersonalModel, PersonalModel) {
            try await sync(a, as: "A"); try await sync(b, as: "B")
            let (_, am) = try await sync(a, as: "A")
            let (outcome, bm) = try await sync(b, as: "B")
            XCTAssertEqual(outcome, .upToDate)
            return (am, bm)
        }

        // 1.
        var bModel = try b.reload(); bModel.remove(word: "hestur"); try bModel.save(to: b.url)
        var aModel = try a.reload(); aModel.remove(word: "hestur"); try aModel.addUserWord("hestur"); try aModel.save(to: a.url)
        (aModel, bModel) = try await converge()
        XCTAssertTrue(bModel.isLearned("hestur"), "A flipped twice (2) against B's once (1)")
        XCTAssertEqual(bModel.tombstoneEpoch(of: "hestur"), 2)

        // 2.
        aModel.remove(word: "hestur"); try aModel.save(to: a.url)
        bModel.remove(word: "hestur"); try bModel.save(to: b.url)
        (aModel, bModel) = try await converge()
        XCTAssertTrue(aModel.isTombstoned("hestur")); XCTAssertTrue(bModel.isTombstoned("hestur"))
        XCTAssertEqual(aModel.tombstoneEpoch(of: "hestur"), 3)

        // 3.
        try aModel.addUserWord("hestur"); try aModel.save(to: a.url)
        try bModel.addUserWord("hestur"); try bModel.save(to: b.url)
        (aModel, bModel) = try await converge()
        XCTAssertTrue(aModel.isLearned("hestur")); XCTAssertTrue(bModel.isLearned("hestur"))
        XCTAssertEqual(aModel.tombstoneEpoch(of: "hestur"), 4)

        // 4.
        bModel.remove(word: "hestur"); try bModel.save(to: b.url)
        try await sync(b, as: "B")                                       // B's delete (5) is on the remote
        aModel.remove(word: "hestur"); try aModel.addUserWord("hestur")  // A, unsynced: 4 → 5 → 6
        try aModel.save(to: a.url)
        XCTAssertEqual(aModel.tombstoneEpoch(of: "hestur"), 6, "A flipped twice from the same base")
        (aModel, bModel) = try await converge()
        XCTAssertTrue(bModel.isLearned("hestur"), "6 > 5: A's deliberate re-add wins")

        // A delete-vs-re-add TIE cannot arise between real devices: a re-add
        // is always one flip past the deletion it undoes, so the re-adding
        // side is ahead of anyone who only deleted from the same base. The
        // tie rule (tombstone wins) is exercised at the merge level in
        // `MergeTests.testEqualEpochTieGoesToTheTombstone`.
    }
}
