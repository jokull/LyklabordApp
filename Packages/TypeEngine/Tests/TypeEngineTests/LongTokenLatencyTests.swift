import Foundation
import LemmaCore
import Lexicon
import XCTest

@testable import TypeEngine

/// Per-keystroke cost on LONG junk tokens (2026-10 fuzz latency finding).
/// `type-repl bench` types real words and gates the worst keystroke at
/// 30 ms; the fuzzer measured 35–45 ms on 30-character key-mash and
/// concatenated-word tokens, where two unbudgeted/coarsely-budgeted stages
/// dominated: the O(n³) diacritic-variant enumeration (now capped at
/// `restorationVariantCap`, breadth-first by change count) and the split
/// pass checking its 6 ms deadline once per hypothesis (now before each
/// half). The structural tests below are deterministic; the timing test
/// runs only in release builds with the production artifacts present.
final class LongTokenLatencyTests: XCTestCase {

    // MARK: - Structural: the restoration-variant cap

    func testVariantCapKeepsShortWordsByteIdentical() {
        for word in ["islenska", "godan", "veitingahusid", "nattura", "ao", "kartoflunum"] {
            let chars = Array(word)
            XCTAssertEqual(
                Set(Corrector.diacriticVariants(of: chars, maxVariants: 400)),
                Set(Corrector.diacriticVariants(of: chars)),
                word)
        }
    }

    func testVariantCapIsBreadthFirstAndBounded() {
        // 14 restorable positions: ~140 one/two-change variants, ~500 three-
        // change ones — the cap lands inside the three-change tail.
        let chars = Array("aeiouyaeiouyae")
        let capped = Corrector.diacriticVariants(of: chars, maxVariants: 400)
        XCTAssertEqual(capped.count, 400)
        let uncapped = Corrector.diacriticVariants(of: chars)
        XCTAssertGreaterThan(uncapped.count, 400)
        // Every one- and two-change variant survives; only the three-change
        // tail is shed.
        func changes(_ variant: String) -> Int {
            zip(variant, chars).filter { $0 != $1 }.count
        }
        let oneAndTwo = Set(uncapped.filter { changes($0) <= 2 })
        XCTAssertLessThan(oneAndTwo.count, 400, "fixture must leave room for the tail")
        XCTAssertTrue(oneAndTwo.isSubset(of: Set(capped)))
        XCTAssertEqual(Set(capped).count, capped.count, "no duplicates")
    }

    func testVariantCapIsDeterministic() {
        let chars = Array("aeiouyaeiouyae")
        XCTAssertEqual(
            Corrector.diacriticVariants(of: chars, maxVariants: 400),
            Corrector.diacriticVariants(of: chars, maxVariants: 400))
    }

    /// Mash recovery (wave 30) must keep working with the cap: the widened
    /// cone is a beam property, not a variant property.
    func testMashRecoveryUnaffectedByVariantCap() {
        var config = EngineConfig()
        config.restorationVariantCap = 400
        let corrector = Corrector(
            icelandic: DictLexicon(unigrams: ["hestur": 5000, "og": 1000, "að": 900]),
            english: DictLexicon(unigrams: ["the": 2000, "and": 1000]),
            config: config)
        let result = corrector.correct(typed: "bestxur")
        XCTAssertTrue(result.suggestions.contains { $0.text == "hestur" })
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    // MARK: - Structural: the repair length cap

    func testOverLengthTokenGetsOnlyTheVerbatimSlot() {
        let session = TypingSession(engine: Fixtures.engine())
        let long = String(repeating: "hestur", count: 6)  // 36 > 32
        let bar = session.suggestions(for: long, limit: 5)
        XCTAssertEqual(bar.map(\.text), [long])
        XCTAssertTrue(bar[0].isVerbatim)
        // At the cap itself the ordinary pipeline still runs.
        var config = EngineConfig()
        config.repairMaxLength = 7
        let corrector = Corrector(
            icelandic: DictLexicon(unigrams: ["hestur": 5000]),
            english: DictLexicon(unigrams: ["the": 2000]), config: config)
        XCTAssertFalse(corrector.correct(typed: "hestxur").suggestions.isEmpty, "7 chars: repaired")
        XCTAssertTrue(corrector.correct(typed: "hestxurr").suggestions.isEmpty, "8 chars: capped")
    }

    // MARK: - Timing: long tokens through the real artifacts (release only)

    /// Worst keystroke while typing each long token through the production
    /// session path with the SHIPPING budgets. The bench's gate is 30 ms;
    /// one retry absorbs a cold-cache blip, exactly like the scorecard's.
    func testLongJunkTokensStayUnderTheBenchGate() throws {
        #if DEBUG
            throw XCTSkip("timing is meaningful in release builds only")
        #else
            guard let engine = Self.shippingEngine() else {
                throw XCTSkip("production artifacts (data/is/is.lex …) not found")
            }
            let tokens = [
                "asdkfjhgqwpeoirutyzmxncbvlaskdjfhg",  // key mash, no lexicon prefix
                "tgretaHmmmrSouthCarolinathtetaSvo",  // fuzz real seed: concatenated words
                "vantarddundravigervigreindagragnaverin",  // fuzz fixture seed: IS concatenation
                "aeiouyaeiouyaeiouyaeiouyaeiouyaei",  // every position restorable
                "minnveitingahusitkörlumThemMangalorbetrigertthink",  // fuzz real seed: 48-char run-on
            ]
            for token in tokens {
                var worst = Self.worstKeystrokeMilliseconds(engine, token)
                if worst >= 30 { worst = Self.worstKeystrokeMilliseconds(engine, token) }
                print(String(format: "[long-token] worst %.1f ms while typing %@", worst, token.debugDescription as NSString))
                XCTAssertLessThan(worst, 30, "worst keystroke while typing \(token.debugDescription)")
            }
        #endif
    }

    private static func worstKeystrokeMilliseconds(_ engine: TypeEngine, _ token: String) -> Double {
        let session = TypingSession(engine: engine)
        let proxy = ProxySimulator()
        var worst = 0.0
        let clock = ContinuousClock()
        for c in token {
            proxy.insertText(String(c))
            let window = proxy.contextBeforeInput
            let start = clock.now
            _ = session.suggestions(for: window, limit: 3)
            worst = max(worst, start.duration(to: clock.now).fuzzSeconds * 1000)
        }
        return worst
    }

    /// The production artifacts with the SHIPPING config (wall-clock budgets
    /// in force), unlike `FuzzEngines.real` which lifts them.
    private static func shippingEngine() -> TypeEngine? {
        guard let root = FuzzEngines.repoRoot() else { return nil }
        guard
            let english = try? FrequencyLexicon(contentsOf: root.appendingPathComponent("data/en/en.lex")),
            let icelandic = try? FrequencyLexicon(contentsOf: root.appendingPathComponent("data/is/is.lex")),
            let morphology = try? BinaryLemmatizer(
                contentsOf: root.appendingPathComponent("data/is/bin-morph.bin"))
        else { return nil }
        let folded = root.appendingPathComponent("data/is/bin-morph.folded.bin")
        if FileManager.default.fileExists(atPath: folded.path) {
            try? morphology.loadFoldedIndex(contentsOf: folded)
        }
        let engine = TypeEngine(
            icelandic: icelandic, english: english, morphology: morphology,
            config: EngineConfig(),
            icelandicCalibration: try? LexiconCalibrationProfile(
                contentsOf: root.appendingPathComponent("data/is/is-calibration.json")),
            englishCalibration: try? LexiconCalibrationProfile(
                contentsOf: root.appendingPathComponent("data/en/en-calibration.json")))
        if let paradigms = try? ParadigmsReader(
            contentsOf: root.appendingPathComponent("data/is/paradigms.bin")),
            let governors = try? GovernorsModel(
                gzippedJSONContentsOf: root.appendingPathComponent("data/is/governors.json.gz"))
        {
            engine.setInflection(InflectionModel(paradigms: paradigms, governors: governors))
        }
        engine.warmUp()
        return engine
    }
}
