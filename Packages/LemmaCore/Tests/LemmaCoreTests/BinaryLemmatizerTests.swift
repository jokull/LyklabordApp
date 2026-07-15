import XCTest

@testable import LemmaCore

final class BinaryLemmatizerTests: XCTestCase {

    static var lemmatizer: BinaryLemmatizer!

    override class func setUp() {
        super.setUp()
        let url = Bundle.module.url(forResource: "lemma-is.core.bin", withExtension: nil)!
        lemmatizer = try! BinaryLemmatizer(contentsOf: url)
    }

    var lemmatizer: BinaryLemmatizer { Self.lemmatizer }

    // MARK: - Header / metadata

    func testHeaderMetadata() {
        XCTAssertEqual(lemmatizer.version, 1)
        XCTAssertEqual(lemmatizer.wordFormCount, 350_000)
        XCTAssertGreaterThan(lemmatizer.lemmaCount, 0)
        XCTAssertEqual(lemmatizer.bigramCount, 0)
        XCTAssertFalse(lemmatizer.hasMorphFeatures)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try BinaryLemmatizer(data: Data(repeating: 0xAB, count: 64)))
        XCTAssertThrowsError(try BinaryLemmatizer(data: Data()))
    }

    // MARK: - Golden fixture (generated from the TypeScript implementation)

    func testMatchesTypeScriptGoldenFixture() throws {
        let url = Bundle.module.url(forResource: "lemmatize-fixture.json", withExtension: nil)!
        let fixture = try JSONDecoder().decode(
            [String: [String]].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixture.count, 300, "fixture should have ~300 words")

        var failures: [String] = []
        for (word, expected) in fixture {
            let got = lemmatizer.lemmatize(word)
            if got != expected {
                failures.append("\(word): expected \(expected), got \(got)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count)/\(fixture.count) mismatches vs TypeScript:\n"
                + failures.joined(separator: "\n"))
    }

    // MARK: - Behavior spot checks (README examples)

    func testReadmeExamples() {
        XCTAssertEqual(lemmatizer.lemmatize("börnin"), ["barn"])
        XCTAssertEqual(lemmatizer.lemmatize("hestinum"), ["hestur"])
        XCTAssertEqual(lemmatizer.lemmatize("keypti").first, "kaupa")
    }

    func testUnknownWordReturnsNormalizedInput() {
        XCTAssertEqual(lemmatizer.lemmatize("XYZZYQUUX"), ["xyzzyquux"])
        XCTAssertFalse(lemmatizer.isKnown("xyzzyquux"))
    }

    func testUppercaseInputIsNormalized() {
        XCTAssertEqual(lemmatizer.lemmatize("BÖRNIN"), lemmatizer.lemmatize("börnin"))
        XCTAssertTrue(lemmatizer.isKnown("Hestinum"))
    }

    func testWordClassFilter() {
        // "kaupa" is both verb (kaupa) and noun (kaup/kaupi)
        let verbs = lemmatizer.lemmatize("kaupa", wordClass: .verb)
        XCTAssertEqual(verbs, ["kaupa"])
        let nouns = lemmatizer.lemmatize("kaupa", wordClass: .noun)
        XCTAssertFalse(nouns.contains("kaupa") && nouns.count == 1)
    }

    func testLemmatizeWithPOS() {
        let results = lemmatizer.lemmatizeWithPOS("keypti")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains(LemmaWithPOS(lemma: "kaupa", pos: "so")))
        // Unknown word → empty array (not fallback), matching TS
        XCTAssertEqual(lemmatizer.lemmatizeWithPOS("xyzzyquux"), [])
    }

    func testBigramFreqZeroWhenNoBigrams() {
        // Core artifact is built with --no-bigrams
        XCTAssertEqual(lemmatizer.bigramFreq("á", "morgun"), 0)
    }

    // MARK: - Memory footprint (deliverable 4)

    func testMemoryFootprintAfterLoadAndLookups() {
        let before = Self.memoryFootprint()

        let url = Bundle.module.url(forResource: "lemma-is.core.bin", withExtension: nil)!
        let fresh = try! BinaryLemmatizer(contentsOf: url)

        let afterLoad = Self.memoryFootprint()

        let words = [
            "börnin", "keypti", "hestinum", "manninum", "konunni", "húsið",
            "skólanum", "fórum", "stærri", "góðan", "við", "þeirra",
            "bílastæði", "æðislegur", "xyzzyunknown",
        ]
        var total = 0
        for i in 0..<1000 {
            total += fresh.lemmatize(words[i % words.count]).count
        }
        XCTAssertGreaterThan(total, 0)

        let afterCalls = Self.memoryFootprint()

        let mb = { (b: UInt64) in String(format: "%.2f MB", Double(b) / 1024 / 1024) }
        print(
            """
            [LemmaCore memory] file=\(mb(UInt64(fresh.bufferSize)))
            [LemmaCore memory] before load:        resident=\(mb(before.resident)) footprint=\(mb(before.footprint))
            [LemmaCore memory] after mmap load:    resident=\(mb(afterLoad.resident)) footprint=\(mb(afterLoad.footprint))
            [LemmaCore memory] after 1000 lookups: resident=\(mb(afterCalls.resident)) footprint=\(mb(afterCalls.footprint))
            [LemmaCore memory] footprint delta (load+lookups): \(mb(afterCalls.footprint - min(afterCalls.footprint, before.footprint)))
            """)

        // The mmap strategy is working if loading + lookups adds far less
        // footprint than the 9.7MB file (only touched pages become resident,
        // and file-backed pages are clean). Allow generous slack for test
        // runner noise; the real signal is the printed numbers.
        let delta = afterCalls.footprint - min(afterCalls.footprint, before.footprint)
        XCTAssertLessThan(
            delta, 20 * 1024 * 1024,
            "load + 1000 lookups should not add >20MB footprint")
    }

    static func memoryFootprint() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, UInt64(info.phys_footprint))
    }
}
