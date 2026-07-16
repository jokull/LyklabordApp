import XCTest

@testable import Lexicon

final class FrequencyLexiconTests: XCTestCase {

    static var lexicon: FrequencyLexicon!

    override class func setUp() {
        super.setUp()
        let url = Bundle.module.url(forResource: "fixture.lex", withExtension: nil)!
        lexicon = try! FrequencyLexicon(contentsOf: url)
    }

    var lexicon: FrequencyLexicon { Self.lexicon }

    // MARK: - Header / metadata

    func testHeaderMetadata() {
        XCTAssertEqual(lexicon.version, 1)
        XCTAssertEqual(lexicon.unigramCount, 20)
        XCTAssertEqual(lexicon.bigramCount, 10)
        XCTAssertEqual(lexicon.totalUnigramTokens, 12660)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try FrequencyLexicon(data: Data(repeating: 0xAB, count: 64)))
        XCTAssertThrowsError(try FrequencyLexicon(data: Data()))
    }

    // MARK: - frequency(of:)

    func testKnownWordFrequencies() {
        XCTAssertEqual(lexicon.frequency(of: "the"), 5000)
        XCTAssertEqual(lexicon.frequency(of: "quick"), 300)
        XCTAssertEqual(lexicon.frequency(of: "dog"), 350)
        XCTAssertEqual(lexicon.frequency(of: "og"), 1200)
    }

    func testUnknownWordReturnsNil() {
        XCTAssertNil(lexicon.frequency(of: "xyzzyquux"))
        // "það" was dropped from the fixture bigram source because it never
        // appears in the unigram list — confirms bigrams never grow the
        // unigram vocabulary.
        XCTAssertNil(lexicon.frequency(of: "það"))
    }

    func testCaseInsensitiveLookup() {
        XCTAssertEqual(lexicon.frequency(of: "THE"), lexicon.frequency(of: "the"))
        XCTAssertEqual(lexicon.frequency(of: "ÞETTA"), lexicon.frequency(of: "þetta"))
    }

    func testEmptyStringIsUnknown() {
        XCTAssertNil(lexicon.frequency(of: ""))
    }

    // MARK: - Icelandic non-ASCII round-trip

    func testIcelandicNonASCIIWords() {
        XCTAssertEqual(lexicon.frequency(of: "börnin"), 42)
        XCTAssertEqual(lexicon.frequency(of: "þetta"), 900)
        XCTAssertEqual(lexicon.frequency(of: "þeirra"), 87)
        XCTAssertEqual(lexicon.frequency(of: "æðislegur"), 12)
        XCTAssertEqual(lexicon.frequency(of: "öðruvísi"), 9)
        XCTAssertEqual(lexicon.frequency(of: "ánægður"), 33)
        XCTAssertEqual(lexicon.frequency(of: "morguninn"), 77)
    }

    // MARK: - bigramFrequency

    func testKnownBigramFrequencies() {
        XCTAssertEqual(lexicon.bigramFrequency("the", "quick"), 40)
        XCTAssertEqual(lexicon.bigramFrequency("quick", "brown"), 35)
        XCTAssertEqual(lexicon.bigramFrequency("þetta", "er"), 60)
        XCTAssertEqual(lexicon.bigramFrequency("og", "þetta"), 8)
    }

    func testUnseenBigramReturnsNil() {
        // Both words known, pair never co-occurred in the fixture.
        XCTAssertNil(lexicon.bigramFrequency("the", "dog"))
    }

    func testBigramWithUnknownWordReturnsNil() {
        // "það" never made it into the unigram table, so the bigram "það og"
        // (present in the raw fixture bigram source) was dropped by the
        // builder; both directions must be nil.
        XCTAssertNil(lexicon.bigramFrequency("það", "og"))
        XCTAssertNil(lexicon.bigramFrequency("og", "það"))
    }

    // MARK: - completions(of:)

    func testCompletionsOrderedByDescendingFrequency() {
        let results = lexicon.completions(of: "þ", limit: 10)
        XCTAssertEqual(results.map(\.word), ["þetta", "þeirra"])
        XCTAssertEqual(results.map(\.frequency), [900, 87])
    }

    func testCompletionsRespectsLimit() {
        let results = lexicon.completions(of: "þ", limit: 1)
        XCTAssertEqual(results.map(\.word), ["þetta"])
    }

    func testCompletionsUnknownPrefixIsEmpty() {
        XCTAssertEqual(lexicon.completions(of: "zzz", limit: 10).count, 0)
    }

    func testCompletionsExactWordIncluded() {
        // "og" is itself a complete word and a prefix of nothing else.
        let results = lexicon.completions(of: "og", limit: 10)
        XCTAssertEqual(results.map(\.word), ["og"])
    }

    func testCompletionsZeroLimitIsEmpty() {
        XCTAssertTrue(lexicon.completions(of: "þ", limit: 0).isEmpty)
    }

    func testCompletionsAsciiPrefixExcludesAccentedLookalikes() {
        // "á" (U+00E1) is a different byte sequence than ASCII "a" (U+0061),
        // so prefix "a" must match only "að", not "á"/"ánægður"/"æðislegur".
        let results = lexicon.completions(of: "a", limit: 10)
        XCTAssertEqual(results.map(\.word), ["að"])
    }

    // MARK: - continuations(of:limit:)

    func testContinuationsOrderedByDescendingFrequency() {
        // Fixture bigrams starting with "the": "the quick" (40), "the lazy" (15).
        let results = lexicon.continuations(of: "the", limit: 10)
        XCTAssertEqual(results.map(\.word), ["quick", "lazy"])
        XCTAssertEqual(results.map(\.frequency), [40, 15])
    }

    func testContinuationsRespectsLimit() {
        let results = lexicon.continuations(of: "the", limit: 1)
        XCTAssertEqual(results.map(\.word), ["quick"])
    }

    func testContinuationsSingleMatch() {
        let results = lexicon.continuations(of: "fox", limit: 10)
        XCTAssertEqual(results.map(\.word), ["jumps"])
        XCTAssertEqual(results.map(\.frequency), [25])
    }

    func testContinuationsUnknownWordIsEmpty() {
        XCTAssertEqual(lexicon.continuations(of: "xyzzyquux", limit: 10).count, 0)
    }

    func testContinuationsWordWithNoOutgoingBigramIsEmpty() {
        // "dog" is a known unigram but never appears as a bigram's first word
        // in the fixture (only as "lazy dog"'s second word).
        XCTAssertEqual(lexicon.continuations(of: "dog", limit: 10).count, 0)
    }

    func testContinuationsZeroLimitIsEmpty() {
        XCTAssertTrue(lexicon.continuations(of: "the", limit: 0).isEmpty)
    }

    func testContinuationsNonASCIIWord() {
        // "þetta er" (60) is the fixture's only bigram starting with "þetta".
        let results = lexicon.continuations(of: "þetta", limit: 10)
        XCTAssertEqual(results.map(\.word), ["er"])
        XCTAssertEqual(results.map(\.frequency), [60])
    }

    func testContinuationsNonASCIISecondWord() {
        // "og þetta" (8): first word ASCII-looking ("og"), continuation is
        // the non-ASCII word "þetta".
        let results = lexicon.continuations(of: "og", limit: 10)
        XCTAssertEqual(results.map(\.word), ["þetta"])
        XCTAssertEqual(results.map(\.frequency), [8])
    }

    func testContinuationsCaseInsensitiveLookup() {
        XCTAssertEqual(
            lexicon.continuations(of: "THE", limit: 10).map(\.word),
            lexicon.continuations(of: "the", limit: 10).map(\.word)
        )
    }

    func testDefaultLexiconExtensionReturnsEmpty() {
        struct MinimalLexicon: Lexicon {
            var totalUnigramTokens: UInt64 { 0 }
            func frequency(of word: String) -> UInt32? { nil }
            func bigramFrequency(_ first: String, _ second: String) -> UInt32? { nil }
            func completions(of prefix: String, limit: Int) -> [(word: String, frequency: UInt32)] { [] }
        }
        let minimal = MinimalLexicon()
        XCTAssertTrue(minimal.continuations(of: "anything", limit: 10).isEmpty)
    }

    // MARK: - Cross-check against real built artifacts

    /// Climbs from this test file up to the repo root
    /// (Packages/Lexicon/Tests/LexiconTests/<file> -> repo root).
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func testCrossCheckEnglishArtifact() throws {
        let url = Self.repoRoot().appendingPathComponent("data/en/en.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/en/en.lex not built — run scripts/build-lexicon.py")
        let en = try FrequencyLexicon(contentsOf: url)

        // 20 random words sampled from data/en/en-80k.txt (seed 42), with
        // frequency scaled by the same divisor build-lexicon.py computed
        // for this artifact (divisor=7 at build time — see build log).
        let samples: [(String, UInt32)] = [
            ("fabulous", 210_486),
            ("volumes", 1_715_321),
            ("veined", 36_016),
            ("honorably", 47_578),
            ("malfunction", 58_482),
            ("filler", 143_517),
            ("benson", 240_022),
            ("countersinking", 1_984),
            ("originality", 310_966),
            ("largehearted", 874),
            ("agitates", 9_019),
            ("designated", 1_261_664),
            ("muslim", 1_371_270),
            ("devout", 276_872),
            ("turnaround", 61_244),
            ("croats", 53_420),
            ("polymerizes", 3_510),
            ("underachieves", 662),
            ("stomach", 1_596_984),
            ("soporifics", 1_537),
        ]
        for (word, expected) in samples {
            XCTAssertEqual(en.frequency(of: word), expected, "mismatch for \(word)")
        }
    }

    func testCrossCheckIcelandicArtifact() throws {
        let url = Self.repoRoot().appendingPathComponent("data/is/is.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/is/is.lex not built — run scripts/build-lexicon.py")
        let is_ = try FrequencyLexicon(contentsOf: url)

        // 20 random words sampled from the pruned data/is/is.lex word list
        // (seed 42, rebuilt 2026-07-15 with --bin-lookup/--bin-lemmas
        // pruning — see data/README.md "## .lex artifacts"). Icelandic
        // counts fit UInt32 directly (scale divisor=1), so these are exact
        // source counts.
        let samples: [(String, UInt32)] = [
            ("skrílslæti", 13),
            ("dómsmálagjöld", 12),
            ("atvinnuhjólreiðamaður", 6),
            ("tollafgreiðslunnar", 27),
            ("heildarkvótanum", 188),
            ("grenjandi", 201),
            ("garðaskóli", 6),
            ("ergo", 181),
            ("tildur", 15),
            ("djúpsævi", 16),
            ("stelpna", 287),
            ("tjónabætur", 35),
            ("öryrkjabandalag", 777),
            ("pisa", 258),
            ("bókmenntaborgarinnar", 5),
            ("sakbitinn", 10),
            ("leiguíbúðalán", 27),
            ("aznar", 185),
            ("austurrískum", 73),
            ("clásico", 106),
        ]
        for (word, expected) in samples {
            XCTAssertEqual(is_.frequency(of: word), expected, "mismatch for \(word)")
        }
    }

    // MARK: - is.lex ranking-noise pruning (harness quirk fix)

    func testIcelandicArtifactPruningRemovesNoise() throws {
        let url = Self.repoRoot().appendingPathComponent("data/is/is.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/is/is.lex not built — run scripts/build-lexicon.py")
        let is_ = try FrequencyLexicon(contentsOf: url)

        // "islenskar"/"islensk" (unaccented) are gone: not BÍN forms, and
        // their accented counterparts ("íslenskar"/"íslensk") dominate by
        // >1000x — the accent-dominance filter drops them regardless of the
        // BÍN-membership escape hatch.
        XCTAssertNil(is_.frequency(of: "islenskar"), "unaccented noise 'islenskar' should be pruned")
        XCTAssertNil(is_.frequency(of: "islensk"), "unaccented noise 'islensk' should be pruned")

        // "hester" is neither a BÍN surface form nor a lemma, and its
        // frequency (57) falls well outside the top-10000-by-frequency
        // non-BÍN escape hatch — pure junk, pruned.
        XCTAssertNil(is_.frequency(of: "hester"), "junk form 'hester' should be pruned")
    }

    func testIcelandicArtifactPruningKeepsLegitimateWords() throws {
        let url = Self.repoRoot().appendingPathComponent("data/is/is.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/is/is.lex not built — run scripts/build-lexicon.py")
        let is_ = try FrequencyLexicon(contentsOf: url)

        // The accented forms that dominate their pruned unaccented
        // lookalikes must themselves survive with their real frequencies.
        XCTAssertEqual(is_.frequency(of: "íslenskar"), 15_388)
        XCTAssertEqual(is_.frequency(of: "íslensk"), 37_988)

        // "hestur" (horse, nom. sg.) — a basic word that is its own BÍN
        // lemma and therefore (surprisingly) absent from lemma-is's
        // lookup.tsv.gz alone (see load_bin_forms() docstring); it must
        // still survive because it's present in lemmas.txt.gz.
        XCTAssertEqual(is_.frequency(of: "hestur"), 422)

        // Common closed-class words ("hann"=he, "ég"=I) are also their own
        // lemma and would be wrongly flagged as "non-BÍN noise" if
        // lookup.tsv.gz were used without unioning lemmas.txt.gz.
        XCTAssertEqual(is_.frequency(of: "hann"), 3_772_234)
        XCTAssertEqual(is_.frequency(of: "ég"), 1_907_515)

        // A high-frequency non-BÍN word (foreign proper noun/loanword a
        // news corpus is full of) must survive via the top-K escape hatch.
        XCTAssertNotNil(is_.frequency(of: "reykjavík"))
    }

    // MARK: - en.lex contraction presence (harness quirk fix)

    func testEnglishArtifactContractionsPresent() throws {
        let url = Self.repoRoot().appendingPathComponent("data/en/en.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/en/en.lex not built — run scripts/build-lexicon.py")
        let en = try FrequencyLexicon(contentsOf: url)

        // Previously destroyed by the apostrophe-stripping WORD_RE filter
        // (harness symptom: "don't" -> "dont" -> autocorrected to "Ibm").
        // Real per-artifact counts (scale divisor=7, see build log).
        let contractions: [(String, UInt32)] = [
            ("don't", 26_863),
            ("i'm", 13_381),
            ("it's", 4_399),
            ("can't", 7_536),
            ("won't", 2_493),
            ("isn't", 2_630),
            ("you're", 7_021),
            ("we're", 3_007),
            ("they're", 3_909),
            ("i've", 4_272),
            ("i'll", 5_874),
            ("didn't", 5_396),
            ("doesn't", 2_043),
            ("wasn't", 1_927),
            ("aren't", 966),
            ("couldn't", 2_509),
            ("wouldn't", 2_000),
            ("shouldn't", 727),
            ("that's", 1_662),
            ("there's", 551),
            ("what's", 7_854),
            ("let's", 2_590),
        ]
        for (word, expected) in contractions {
            XCTAssertEqual(en.frequency(of: word), expected, "mismatch for \(word)")
        }

        // Curly apostrophe (U+2019) must normalize to the same token as the
        // straight ASCII apostrophe.
        XCTAssertEqual(en.frequency(of: "don\u{2019}t"), en.frequency(of: "don't"))
    }

    // MARK: - Prefix cursors (PrefixSearchableLexicon)

    func testPrefixRootCursorSpansWholeTable() {
        let root = lexicon.prefixRootCursor()
        XCTAssertEqual(root.lowerBound, 0)
        XCTAssertEqual(root.upperBound, lexicon.unigramCount)
        XCTAssertEqual(root.byteDepth, 0)
        XCTAssertNil(lexicon.exactEntry(in: root), "empty prefix is never a word")
    }

    func testDescendMatchesCompletionsRange() {
        // Walking þ (2-byte UTF-8) narrows to exactly the words completions
        // enumerates for that prefix.
        let root = lexicon.prefixRootCursor()
        let cursor = lexicon.descend(root, appending: "þ")
        XCTAssertEqual(cursor.count, 2)  // þetta, þeirra
        XCTAssertEqual(cursor.byteDepth, 2)
        XCTAssertNil(lexicon.exactEntry(in: cursor), "þ alone is not a fixture word")
    }

    func testDescendToExactWord() {
        var cursor = lexicon.prefixRootCursor()
        for ch in "þetta" { cursor = lexicon.descend(cursor, appending: ch) }
        let entry = lexicon.exactEntry(in: cursor)
        XCTAssertEqual(entry?.word, "þetta")
        XCTAssertEqual(entry?.frequency, 900)
    }

    func testDescendExactWordThatIsAlsoAPrefix() {
        // "the" is a word AND a prefix of "they"/"there"-class fixture words;
        // exactEntry must find it at the head of the range.
        var cursor = lexicon.prefixRootCursor()
        for ch in "the" { cursor = lexicon.descend(cursor, appending: ch) }
        XCTAssertEqual(lexicon.exactEntry(in: cursor)?.word, "the")
        XCTAssertGreaterThanOrEqual(cursor.count, 1)
    }

    func testDescendUnknownBranchIsEmptyAndSticky() {
        var cursor = lexicon.prefixRootCursor()
        cursor = lexicon.descend(cursor, appending: "z")
        XCTAssertTrue(cursor.isEmpty)
        // Descending an empty cursor stays empty (and never traps).
        let deeper = lexicon.descend(cursor, appending: "z")
        XCTAssertTrue(deeper.isEmpty)
        XCTAssertEqual(deeper.byteDepth, 2)
        XCTAssertNil(lexicon.exactEntry(in: deeper))
    }

    func testDescendAsciiPrefixExcludesAccentedLookalikes() {
        // Byte-order discipline: "a" (0x61) must not swallow "á" (0xC3 0xA1).
        let a = lexicon.descend(lexicon.prefixRootCursor(), appending: "a")
        XCTAssertEqual(a.count, 1)  // only "að"
        let accented = lexicon.descend(lexicon.prefixRootCursor(), appending: "á")
        XCTAssertGreaterThanOrEqual(accented.count, 1)  // ánægður
        XCTAssertEqual(accented.byteDepth, 2)
    }

    func testCursorWalkAgreesWithCompletionsOnRealArtifact() throws {
        let url = Self.repoRoot().appendingPathComponent("data/is/is.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/is/is.lex not built — run scripts/build-lexicon.py")
        let is_ = try FrequencyLexicon(contentsOf: url)

        // For a spread of prefixes: the cursor's exact entry must agree with
        // frequency(of:), and the cursor count must cover every completion.
        for prefix in ["hest", "kort", "ís", "þor", "already", "a"] {
            var cursor = is_.prefixRootCursor()
            for ch in prefix { cursor = is_.descend(cursor, appending: ch) }
            let exact = is_.exactEntry(in: cursor)
            XCTAssertEqual(exact?.frequency, is_.frequency(of: prefix), "prefix \(prefix)")
            if let exact { XCTAssertEqual(exact.word, prefix) }
            let completions = is_.completions(of: prefix, limit: 50)
            XCTAssertGreaterThanOrEqual(
                cursor.count, completions.count, "range must cover completions for \(prefix)")
            for entry in completions where entry.word == prefix {
                XCTAssertNotNil(exact)
            }
        }
    }
}
