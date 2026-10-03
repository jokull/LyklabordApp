import XCTest
@testable import Learning

/// Hostile / odd-but-plausible `vocabulary.txt` inputs and the export ⇄
/// import relationship. Anything here must parse without crashing and
/// without letting junk into the model.
final class SwiftKeyImportHostileTests: LearningTestCase {

    func testCROnlyAndMixedLineEndingsImportEveryWord() {
        // CR-only (classic Mac), CRLF (Windows) and a mix all split per
        // line — `Character.isNewline`, not `"\n"`, since Swift treats
        // "\r\n" as ONE Character (see FoundBugTests for the CRLF repro).
        let (crWords, _) = SwiftKeyImport.parseVocabulary("Jökull\rhestur\r")
        XCTAssertEqual(crWords, ["Jökull", "hestur"])
        let (mixed, _) = SwiftKeyImport.parseVocabulary("Jökull\nhestur\r\nþú\n")
        XCTAssertEqual(mixed, ["Jökull", "hestur", "þú"])
        // Other Unicode line breaks (NEL, LS, PS) are line breaks too.
        let (exotic, _) = SwiftKeyImport.parseVocabulary("Jökull\u{85}hestur\u{2028}þú\u{2029}orð")
        XCTAssertEqual(exotic, ["Jökull", "hestur", "þú", "orð"])
    }

    func testUTF8BOMBeforeFirstLineOnlyAffectsThatLine() throws {
        let (words, _) = SwiftKeyImport.parseVocabulary("\u{FEFF}# header\nJökull\n")
        XCTAssertEqual(words, ["Jökull"])
        // BOM glued to a word: rejected (control/format scalar), never crashes.
        let (bomWord, skipped) = SwiftKeyImport.parseVocabulary("\u{FEFF}Jökull\nhestur\n")
        XCTAssertEqual(bomWord, ["hestur"])
        XCTAssertEqual(skipped, 1)
    }

    func testInvisibleAndFormatCharactersAreRejected() {
        let hostile = [
            "zero\u{200D}joiner",   // ZWJ
            "zero\u{200B}width",    // ZWSP
            "soft\u{00AD}hyphen",   // SHY (format char)
            "rtl\u{202E}override",  // bidi override
            "nul\u{0000}byte",
            "tab\there",
            "nbsp\u{00A0}here",
        ]
        for word in hostile {
            XCTAssertFalse(SwiftKeyImport.isImportableWord(word), "accepted \(word.debugDescription)")
        }
        let (words, skipped) = SwiftKeyImport.parseVocabulary(hostile.joined(separator: "\n"))
        XCTAssertTrue(words.isEmpty)
        XCTAssertEqual(skipped, hostile.count)
    }

    func testCombiningMarksOnlyAndSymbolsAreRejected() {
        XCTAssertFalse(SwiftKeyImport.isImportableWord("\u{0301}\u{0308}"))
        XCTAssertFalse(SwiftKeyImport.isImportableWord("--"))
        XCTAssertFalse(SwiftKeyImport.isImportableWord("''"))
        XCTAssertFalse(SwiftKeyImport.isImportableWord("-orð"))
        XCTAssertFalse(SwiftKeyImport.isImportableWord("orð-"))
        XCTAssertTrue(SwiftKeyImport.isImportableWord("vestur-þýskur"))
        XCTAssertTrue(SwiftKeyImport.isImportableWord("o'clock"))
    }

    func testNFDInputIsNormalizedToNFCBeforeImport() throws {
        let nfd = "Jo\u{308}kull"
        let (words, _) = SwiftKeyImport.parseVocabulary(nfd)
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(Array(words[0].unicodeScalars).count, 6, "parser emits NFC")
        let model = PersonalModel()
        _ = model.importLearnedWords(words)
        XCTAssertTrue(model.isLearned("Jökull"))
    }

    func testOverlongLinesAndHugeFilesStayFastAndBounded() {
        let longWord = String(repeating: "a", count: 10_000)
        let (long, skipped) = SwiftKeyImport.parseVocabulary(longWord + "\n" + String(repeating: "ö", count: 64) + "\n")
        XCTAssertEqual(long.count, 1, "64-char word is the cap; 10k is rejected")
        XCTAssertEqual(skipped, 1)

        var lines: [String] = []
        lines.reserveCapacity(100_000)
        let letters = Array("aábdðeéfghiíjklmnoóprstuúvxyýþæö")
        for i in 0..<100_000 {
            // Letters only (digits are rejected by design): 5000 distinct words.
            var n = i % 5000
            var suffix = ""
            repeat { suffix.append(letters[n % letters.count]); n /= letters.count } while n > 0
            lines.append("orð" + suffix)
        }
        let text = lines.joined(separator: "\n")
        let start = Date()
        let (words, _) = SwiftKeyImport.parseVocabulary(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(words.count, 5000, "dedupe")
        XCTAssertLessThan(elapsed, 5, "100k-line import took \(elapsed)s")
    }

    func testInvalidUTF8FileThrowsInsteadOfCrashing() throws {
        let url = directory.appendingPathComponent("vocabulary.txt")
        try Data([0x4A, 0xC3, 0x28, 0xA0, 0xA1, 0x0A]).write(to: url)
        XCTAssertThrowsError(try SwiftKeyImport.parseVocabulary(at: url))
    }

    func testImportNeverResurrectsTombstonesEvenWithCaseVariants() {
        let model = PersonalModel()
        model.remove(word: "Jökull")
        let summary = model.importLearnedWords(["Jökull", "jökull", "JÖKULL"])
        XCTAssertEqual(summary.skippedTombstoned, 1, "exact surface form only — case variants are different words")
        XCTAssertEqual(summary.imported, 2)
        XCTAssertFalse(model.isLearned("Jökull"))
        XCTAssertTrue(model.isLearned("jökull"))
    }

    // MARK: - Export ⇄ import

    /// There is no importer for the export format, but a user *can* paste
    /// the exported word list into a vocabulary.txt. Every exported learned
    /// word that passes the (stricter) import validation must come back
    /// learned; tombstones in the export must still block.
    func testExportedLearnedWordsReimportAsLearned() throws {
        let (model, log) = try makeModelAndLog()
        for word in ["hestur", "Þórsmörk", "vestur-þýskur", "A4", "orð."] {
            try learnWord(word, model: model, log: log)
        }
        try model.addUserWord("Jökull")
        model.remove(word: "óvinur")
        let doc = model.exportDocument()

        let fresh = PersonalModel()
        for tomb in doc.tombstones { fresh.remove(word: tomb) }
        let candidates = doc.learnedWords.map(\.word)
        let summary = fresh.importLearnedWords(candidates)
        // "A4" (digit) and "orð." (trailing punctuation) are learnable
        // tokenizer output but not importable vocabulary — documented
        // asymmetry, so they are the only expected losses.
        XCTAssertEqual(summary.skippedInvalid, 2, "\(candidates)")
        for word in ["hestur", "Þórsmörk", "vestur-þýskur", "Jökull"] {
            XCTAssertTrue(fresh.isLearned(word), word)
            XCTAssertTrue(fresh.isExplicit(word), "imports are explicit")
        }
        XCTAssertTrue(fresh.isTombstoned("óvinur"))

        // And the re-exported document is a superset of the original words.
        let again = fresh.exportDocument()
        XCTAssertTrue(Set(again.learnedWords.map(\.word)).isSuperset(of: ["hestur", "Þórsmörk", "vestur-þýskur", "Jökull"]))
        XCTAssertEqual(again.tombstones, doc.tombstones)
    }

    func testExportJSONRoundTripsThroughCodableLosslessly() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("Jökull", model: model, log: log)
        try log.append(.wordCommitted(word: "bráðnar", previousWord: "Jökull", languageHint: .icelandic))
        try log.append(.touchSample(keyChar: "ð", dx: 0.25, dy: -0.125))
        try model.compact(applying: log)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try model.exportedJSONData(exportedAt: date)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersonalModelExport.self, from: data)
        XCTAssertEqual(decoded, model.exportDocument(exportedAt: date))
    }
}
