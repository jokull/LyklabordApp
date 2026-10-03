import XCTest
import Learning
@testable import Sync

/// Minimal deterministic repros of real defects found by the Sync harness.
/// Each is wrapped in a strict `XCTExpectFailure` so the suite stays green
/// today and flips red the moment the behaviour changes — then delete the
/// wrapper and keep the test as a plain regression.
final class FoundBugTests: XCTestCase {

    private var store: InMemoryCloudStore!
    private var keyStore: InMemoryKeyStore!

    override func setUp() {
        super.setUp()
        store = InMemoryCloudStore()
        keyStore = InMemoryKeyStore(initialKey: SyncCrypto.generateKey())
    }

    private func engine(_ device: String) -> SyncEngine {
        SyncEngine(store: store, keyStore: keyStore, isEnabled: { true }, deviceIdentifier: device)
    }

    private func payload(of outcome: SyncOutcome) throws -> SyncPayload? {
        switch outcome {
        case .pulled(let data), .merged(let data): return try PersonalModelDocument(decoding: data).payload
        case .failed(_, let data?): return try PersonalModelDocument(decoding: data).payload
        default: return nil
        }
    }

    // MARK: - Bug: an explicit re-add can never survive sync

    /// ADR-0009 ("Tombstones: set union") accepts that a re-add "can lose
    /// to a still-tombstoned state on another device *until that device
    /// also syncs the re-add*". That recovery path does not exist: the
    /// device that re-adds is the one whose own next sync re-tombstones the
    /// word (`merge` = tombstone union, userAdded minus tombstones), so the
    /// re-add never reaches the remote at all, from ANY device, ever. The
    /// only escape is "delete iCloud data" and a fresh first push.
    ///
    /// This is user-visible through `App/AppModel.swift` `undoRemove`
    /// ("Afturkalla" in the dictionary editor), which is built on
    /// `addUserWord`: once the deletion has synced (~5s coalescing window),
    /// pressing undo appears to work and is silently reverted on the next
    /// sync — on a SINGLE device, no second device required.
    ///
    /// Intent is ambiguous: tombstone-wins is deliberate, but the ADR's
    /// description of the consequence is wrong and the editor offers an
    /// undo it cannot honour. A fix needs a monotonic signal (e.g. a
    /// per-word re-add counter / "tombstone epoch") so re-add can win.
    func testExplicitReAddOnTheSameDeviceSurvivesItsOwnNextSync() async throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFoundBug-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: modelURL) }

        // One device, real PersonalModel: learn, delete (tombstone), sync.
        let model = PersonalModel()
        _ = model.importLearnedWords(["Jökull"])
        model.remove(word: "Jökull")
        try model.save(to: modelURL)
        var outcome = await engine("A").sync(localModelData: try Data(contentsOf: modelURL))
        XCTAssertEqual(outcome, .pushed)

        // The user taps "Afturkalla" (undo) → addUserWord clears the local
        // tombstone and makes the word valid again.
        try model.addUserWord("Jökull")
        XCTAssertTrue(model.isLearned("Jökull"))
        XCTAssertFalse(model.isTombstoned("Jökull"))
        try model.save(to: modelURL)

        // Next scheduled sync of the SAME device.
        outcome = await engine("A").sync(localModelData: try Data(contentsOf: modelURL))
        let merged = try payload(of: outcome)

        XCTExpectFailure("Re-add (dictionary-editor undo) is undone by the device's own next sync; remote tombstone is unbeatable", strict: true) {
            XCTAssertTrue(merged?.userAdded.contains("Jökull") ?? true, "re-added word must stay user-added")
            XCTAssertFalse(merged?.tombstones.contains("Jökull") ?? false, "re-add must clear the synced tombstone")
        }
    }
}
