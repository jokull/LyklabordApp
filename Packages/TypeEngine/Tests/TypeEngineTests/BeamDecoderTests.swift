import XCTest
import Lexicon

@testable import TypeEngine

/// Beam-decoder wave: prefix-cursor navigation on the DictLexicon test
/// double, the far-repair auto-apply discipline, the saturated-lane split
/// gate, and the PositionCostProvider seam.
final class BeamDecoderTests: XCTestCase {

    // MARK: - DictLexicon prefix cursors (PrefixSearchableLexicon)

    func testDictLexiconCursorWalk() {
        let lexicon = DictLexicon(unigrams: ["hestur": 500, "hestar": 100, "hús": 400, "og": 2000])
        var cursor = lexicon.prefixRootCursor()
        XCTAssertEqual(cursor.count, 4)
        for ch in "hest" { cursor = lexicon.descend(cursor, appending: ch) }
        XCTAssertEqual(cursor.count, 2)  // hestur, hestar
        XCTAssertNil(lexicon.exactEntry(in: cursor))
        for ch in "ur" { cursor = lexicon.descend(cursor, appending: ch) }
        XCTAssertEqual(lexicon.exactEntry(in: cursor)?.word, "hestur")
        XCTAssertEqual(lexicon.exactEntry(in: cursor)?.frequency, 500)
    }

    func testDictLexiconCursorByteOrderSeparatesAccents() {
        // "hús" must not sit inside the ASCII "hu" range (ú is 2-byte UTF-8).
        let lexicon = DictLexicon(unigrams: ["hús": 400, "hundur": 90])
        let hu = ["h", "u"].reduce(lexicon.prefixRootCursor()) {
            lexicon.descend($0, appending: Character($1))
        }
        XCTAssertEqual(hu.count, 1)  // only hundur
        let hAccent = lexicon.descend(
            lexicon.descend(lexicon.prefixRootCursor(), appending: "h"), appending: "ú")
        XCTAssertEqual(hAccent.count, 1)  // only hús
    }

    func testDictLexiconChildCursorsMatchDescend() {
        let lexicon = DictLexicon(unigrams: ["hestur": 500, "hestar": 100, "hús": 400, "og": 2000])
        let h = lexicon.descend(lexicon.prefixRootCursor(), appending: "h")
        let children = lexicon.childCursors(of: h, scanLimit: 64)
        XCTAssertNotNil(children)
        let map = Dictionary(uniqueKeysWithValues: children!.map { ($0.character, $0.cursor) })
        XCTAssertEqual(Set(map.keys), ["e", "ú"])
        XCTAssertEqual(map["e"], lexicon.descend(h, appending: "e"))
        XCTAssertEqual(map["ú"], lexicon.descend(h, appending: "ú"))
        // Over-limit ranges decline the scan.
        XCTAssertNil(lexicon.childCursors(of: lexicon.prefixRootCursor(), scanLimit: 1))
    }

    // MARK: - Far-repair auto-apply discipline (mash → rare word)

    /// Keyboard mash sits within 3 substitutions of some rare word; a
    /// >= autocorrectFarRepairEdits rewrite may only auto-apply when the
    /// winner is COMMON vocabulary.
    func testMashNeverAutoAppliesRareFarWord() {
        let english = DictLexicon(unigrams: [
            "the": 6000, "and": 3000, "of": 3200, "to": 3400, "in": 2200,
            "aegis": 2,  // rare, 3 adjacent-key subs from "awgke"
        ])
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: english)
        let result = corrector.correct(typed: "awgke", pIcelandic: 0.2)
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "aegis" },
            "the rare word may still be OFFERED, got \(result.suggestions.map(\.text))"
        )
        XCTAssertFalse(
            result.suggestions.contains { $0.isAutocorrect },
            "a 3-substitution rewrite to a rare word must never auto-apply"
        )
    }

    func testFarRepairAppliesForCommonWord() {
        // Same 3-substitution shape, but the target is top-of-Zipf common:
        // tonorriw → tomorrow (n→m, i→o twice on the real layout rows).
        let english = DictLexicon(unigrams: [
            "the": 6000, "and": 3000, "of": 3200, "in": 2200, "tomorrow": 4000,
        ])
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: english)
        let result = corrector.correct(typed: "tonirriw", pIcelandic: 0.2)
        XCTAssertEqual(result.suggestions.first?.text, "tomorrow")
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
    }

    func testRewriteDistanceCountsRestorationsFree() {
        func d(_ a: String, _ b: String) -> Int {
            Corrector.rewriteDistance(Array(a), Array(b))
        }
        XCTAssertEqual(d("godann", "góðan"), 1, "accent/orthographic subs are free; the extra n costs 1")
        XCTAssertEqual(d("faralega", "fáránlega"), 1, "two accents free + inserted n")
        XCTAssertEqual(d("awgke", "aegis"), 3, "mash subs all count")
        XCTAssertEqual(d("koetip", "kortið"), 2, "e→r and p→ð are genuine rewrites")
        XCTAssertEqual(d("hus", "hús"), 0)
    }

    // MARK: - Saturated-lane split discipline

    /// In a saturated lane, split halves must clear the calibrated-z bar in
    /// the LANE language — no cherry-picking the other language (the
    /// koetip "joe tip" junk at P(IS) = 0.9).
    func testSaturatedLaneRejectsOtherLanguageSplitHalves() {
        let english = DictLexicon(unigrams: [
            "the": 6000, "and": 3000, "joe": 900, "tip": 800,
        ])
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: english)

        // Neutral lane: the split is available on its ordinary merits.
        let neutral = corrector.correct(typed: "joentip", pIcelandic: 0.5, limit: 8)
        XCTAssertTrue(
            neutral.suggestions.contains { $0.text == "joe tip" },
            "got \(neutral.suggestions.map(\.text))"
        )

        // Saturated Icelandic lane: both halves are English-only, so the
        // split must not be offered at all.
        let saturated = corrector.correct(typed: "joentip", pIcelandic: 0.9, limit: 8)
        XCTAssertFalse(
            saturated.suggestions.contains { $0.text == "joe tip" },
            "got \(saturated.suggestions.map(\.text))"
        )
    }

    func testSaturatedLaneKeepsLaneLanguageSplits() {
        // "hesturer" → "hestur er": both halves genuinely Icelandic; the
        // saturated-IS lane must not lose the honest split.
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: Fixtures.english)
        let result = corrector.correct(typed: "hesturner", pIcelandic: 0.9, limit: 8)
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "hestur er" },
            "got \(result.suggestions.map(\.text))"
        )
    }

    // MARK: - PositionCostProvider seam

    func testStaticProviderDelegatesToSpatialModelWithConstantConfidence() {
        let spatial = SpatialModel()
        let provider = StaticSpatialCostProvider(spatial: spatial)
        for position in [0, 3, 17] {
            XCTAssertEqual(
                provider.substitutionCost(position: position, typed: "e", intended: "r"),
                spatial.substitutionCost(typed: "e", intended: "r"),
                "static provider is position-independent"
            )
            XCTAssertEqual(provider.confidence(position: position), 1.0)
        }
    }

    func testBeamFindsTripleAdjacentNoise() {
        // gsmsm → gaman: a→s, a→s, n→m — three adjacent-key substitutions,
        // beyond the old edits2 entirely.
        let icelandic = DictLexicon(unigrams: [
            "og": 2000, "að": 1800, "er": 1500, "gaman": 700, "gott": 150,
        ])
        let corrector = Corrector(icelandic: icelandic, english: Fixtures.english)
        let result = corrector.correct(typed: "gsmsm", pIcelandic: 0.8)
        XCTAssertEqual(result.suggestions.first?.text, "gaman")
    }
}
