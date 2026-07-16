import Foundation
import XCTest

@testable import EvalKit

final class CorpusPairTests: XCTestCase {

    func testParsesAccentDropRecord() throws {
        let line =
            #"{"typo": "fra", "intended": "frá", "context": ["Þessi", "rúnaröð"], "lang": "is", "category": "accent_drop", "seed": 20260715}"#
        let pair = try XCTUnwrap(Corpus.parseLine(line))
        XCTAssertEqual(pair.typo, "fra")
        XCTAssertEqual(pair.intended, "frá")
        XCTAssertEqual(pair.context, ["Þessi", "rúnaröð"])
        XCTAssertEqual(pair.lang, "is")
        XCTAssertEqual(pair.category, "accent_drop")
    }

    func testSpaceMissIntendedIsTwoWords() throws {
        let line =
            #"{"typo": "hlutiHvalfjarðar", "intended": "hluti Hvalfjarðar", "context": ["Frá"], "lang": "is", "category": "space_miss", "seed": 1}"#
        let pair = try XCTUnwrap(Corpus.parseLine(line))
        XCTAssertEqual(pair.intended, "hluti Hvalfjarðar")
        XCTAssertTrue(pair.intended.contains(" "))
    }

    func testEmptyContextArray() throws {
        let line =
            #"{"typo": "Arið", "intended": "Árið", "context": [], "lang": "is", "category": "accent_drop"}"#
        let pair = try XCTUnwrap(Corpus.parseLine(line))
        XCTAssertTrue(pair.context.isEmpty)
    }

    func testUnknownKeysAreIgnored() throws {
        let line =
            #"{"typo": "dont", "intended": "don't", "context": [], "lang": "en", "category": "contraction_damage", "seed": 42, "extra": "x"}"#
        let pair = try XCTUnwrap(Corpus.parseLine(line))
        XCTAssertEqual(pair.intended, "don't")
    }

    func testBlankLineReturnsNil() throws {
        XCTAssertNil(try Corpus.parseLine(""))
        XCTAssertNil(try Corpus.parseLine("   \t "))
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try Corpus.parseLine("{not json", lineNumber: 7)) { error in
            guard case let CorpusParseError.malformedJSON(line, _) = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertEqual(line, 7)
        }
    }

    func testMissingRequiredFieldThrows() {
        // Missing "category".
        let line = #"{"typo": "a", "intended": "á", "context": [], "lang": "is"}"#
        XCTAssertThrowsError(try Corpus.parseLine(line))
    }

    func testLoadCorpusSkipsBlankLinesAndParsesAll() throws {
        let body = [
            #"{"typo": "a", "intended": "á", "context": [], "lang": "is", "category": "accent_drop"}"#,
            "",
            #"{"typo": "teh", "intended": "the", "context": ["and"], "lang": "en", "category": "transposition"}"#,
            "",
        ].joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-\(UUID().uuidString).jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let pairs = try Corpus.loadCorpus(at: url)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].intended, "á")
        XCTAssertEqual(pairs[1].intended, "the")
        XCTAssertEqual(pairs[1].context, ["and"])
    }

    func testRealDevCorpusLoadsWhenPresent() throws {
        guard let url = ArtifactLoader.corpusURL(split: "dev"),
            FileManager.default.fileExists(atPath: url.path)
        else {
            throw XCTSkip("dev.jsonl not found from test cwd")
        }
        let pairs = try Corpus.loadCorpus(at: url)
        XCTAssertEqual(pairs.count, 3000)
        XCTAssertTrue(pairs.allSatisfy { $0.typo != $0.intended })
        XCTAssertTrue(pairs.allSatisfy { $0.lang == "is" || $0.lang == "en" })
    }
}
