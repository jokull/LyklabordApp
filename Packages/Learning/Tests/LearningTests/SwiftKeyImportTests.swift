import XCTest

@testable import Learning

final class SwiftKeyImportTests: XCTestCase {

    private let sampleExport = """
        # Your SwiftKey vocabulary
        #\u{20}
        # This is a list of words that SwiftKey has learned from your typing.

        !
        \u{22}
        #startup
        #VIBfundur
        '70
        Jökull
        doesn\u{2019}t
        doesn't
        dokobit
        matvöruverslunum
        a
        Jökull
        """

    func testParseVocabularySkipsCommentsAndJunk() {
        let (words, skipped) = SwiftKeyImport.parseVocabulary(sampleExport)
        XCTAssertEqual(
            words,
            ["startup", "VIBfundur", "Jökull", "doesn't", "dokobit", "matvöruverslunum"]
        )
        // "!", quote, "'70" (digits), "a" (single char); curly-apostrophe
        // duplicate of doesn't and second Jökull dedupe silently.
        XCTAssertEqual(skipped, 4)
    }

    func testHashtagStrippedCommentsKept() {
        let (words, _) = SwiftKeyImport.parseVocabulary("# comment line\n#orð\n")
        XCTAssertEqual(words, ["orð"])
    }

    func testImportMarksExplicitAndSkipsTombstones() throws {
        let model = PersonalModel()
        model.remove(word: "banned")
        let summary = model.importLearnedWords(["Jökull", "banned", "ok'word", "x!"])
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.skippedTombstoned, 1)
        XCTAssertEqual(summary.skippedInvalid, 1)
        XCTAssertTrue(model.isLearned("Jökull"))
        XCTAssertTrue(model.isTombstoned("banned"))
        XCTAssertFalse(model.isLearned("banned"))
        XCTAssertEqual(model.frequency(of: "Jökull"), 3)
    }

    func testImportKeepsHigherOrganicCounts() throws {
        let model = PersonalModel()
        let summary1 = model.importLearnedWords(["orð"], seedCount: 3)
        XCTAssertEqual(summary1.imported, 1)
        // Re-import with lower seed must not clobber.
        let summary2 = model.importLearnedWords(["orð"], seedCount: 1)
        XCTAssertEqual(summary2.imported, 1)
        XCTAssertEqual(model.frequency(of: "orð"), 3)
    }

    func testImportPersistsAcrossSaveLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.json")

        let model = PersonalModel()
        _ = model.importLearnedWords(["matvöruverslunum"])
        try model.save(to: url)
        let reloaded = try PersonalModel(contentsOf: url)
        XCTAssertTrue(reloaded.isLearned("matvöruverslunum"))
    }
}
