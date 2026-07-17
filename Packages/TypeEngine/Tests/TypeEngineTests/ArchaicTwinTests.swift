import XCTest

@testable import TypeEngine

/// Wave 32 — archaic-twin restoration (the eg/þu dogfood class): a
/// RESTORATION-ONLY winner that is the typed skeleton's DOMINANT acute-fold
/// twin (the wave-26 `acuteFoldShadowTwin` probe) clears the relaxed
/// `archaicTwinShortMinZ` floor instead of the headline
/// `autocorrectShortMinZ` bar — plus the wave-26 parity fix in the
/// single-letter path (a→á consults PROTECTED personal validity, not raw).
final class ArchaicTwinTests: XCTestCase {

    /// IS unigrams with a nowhere-attested 2-char skeleton "þu" whose twin
    /// "þú" dominates (the skeleton is absent, so the wave-26 dominance
    /// denominator is 1), plus IS-only priming words for the lane.
    private static let icelandicUnigrams: [String: UInt32] = [
        "og": 2000,
        "að": 1800,
        "er": 1500,
        "ekki": 900,
        "þú": 600,
        "þar": 300,
        "á": 1900,
        "árum": 100,
    ]

    private static let icelandic = DictLexicon(
        unigrams: icelandicUnigrams, bigrams: [:])

    private static let english = DictLexicon(
        unigrams: [
            "the": 2000,
            "and": 1500,
            "with": 900,
        ],
        bigrams: [:]
    )

    private func engine(
        icelandic: DictLexicon = ArchaicTwinTests.icelandic,
        personal: FakePersonal? = nil,
        config: EngineConfig = EngineConfig()
    ) -> TypeEngine {
        let e = TypeEngine(
            icelandic: icelandic,
            english: Self.english,
            morphologyProvider: nil,
            config: config
        )
        if let personal { e.setPersonalVocabulary(personal) }
        return e
    }

    /// Saturate the IS lane the way the evals prime context.
    private func primeIcelandic(_ e: TypeEngine) {
        for word in ["og", "að", "er", "ekki"] { e.confirmWord(word) }
    }

    // MARK: - The archaic-twin short floor (Corrector auto-apply)

    /// The class contract, independent of where the small fixture places
    /// þú's calibrated z: with the headline short floor pushed out of
    /// reach, ONLY the archaic-twin floor can admit a 2-char fire — and it
    /// does, exactly for the dominant-twin restoration winner.
    private func shortFloorOutOfReachConfig() -> EngineConfig {
        var config = EngineConfig()
        config.autocorrectShortMinZ = 99
        config.archaicTwinShortMinZ = -99
        return config
    }

    func testDominantTwinRestorationClearsTheArchaicFloor() {
        let e = engine(config: shortFloorOutOfReachConfig())
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "þu", limit: 5)
        XCTAssertEqual(bar.first { !$0.isVerbatim }?.text, "þú", "bar: \(bar.map(\.text))")
        XCTAssertTrue(
            bar.contains { $0.isAutocorrect && $0.text == "þú" },
            "dominant-twin restoration must auto-apply through the archaic floor")
    }

    func testToggleOffRestoresTheHeadlineShortFloor() {
        var config = shortFloorOutOfReachConfig()
        config.archaicTwinRestorationEnabled = false
        let e = engine(config: config)
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "þu", limit: 5)
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "with the wave-32 toggle off the 99-z short floor must block the fire")
    }

    func testAttestedSkeletonNeverUsesTheArchaicFloor() {
        // Same shape, but the skeleton is honestly attested at comparable
        // frequency (the ja/já, vist/víst shape): no 10x dominance, no
        // shadow twin — the token is a VALID word and the auto-apply
        // machinery never rewrites it at all.
        var unigrams = Self.icelandicUnigrams
        unigrams["þu"] = 400
        let e = engine(
            icelandic: DictLexicon(unigrams: unigrams, bigrams: [:]),
            config: shortFloorOutOfReachConfig()
        )
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "þu", limit: 5)
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "an attested skeleton is a valid word — dominance protection stands")
    }

    func testArchaicFloorStillFloorsJunkTwins() {
        // The archaic floor is a RELAXATION, not a bypass: leave it at a
        // value the fixture twin cannot reach and the fire must stay dead.
        var config = EngineConfig()
        config.autocorrectShortMinZ = 99
        config.archaicTwinShortMinZ = 99
        let e = engine(config: config)
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "þu", limit: 5)
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    // MARK: - Single-letter parity (wave-26 demotion reaches a→á)

    /// The tiny fixture cannot place "á" 1.5σ over its own mean, so the
    /// accent-offer floor is lowered for these tests; the property under
    /// test is the personal gate, not the calibration.
    private func singleLetterConfig() -> EngineConfig {
        var config = EngineConfig()
        config.accentRestoreMinZ = 0.0
        return config
    }

    func testImplicitlyLearnedBareVowelDoesNotKillAccentAutoApply() {
        // The dogfood "horfa a mynd" shape: a habitual lazy-"a" typist has
        // implicitly learned "a"; the shadow demotion (ratio, noise-tier
        // and English-reading gates all pass for á) must free the
        // single-letter restoration exactly like it frees eg→ég.
        let e = engine(
            personal: FakePersonal(words: ["a": 12]), config: singleLetterConfig())
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "a", limit: 5)
        XCTAssertTrue(
            bar.contains { $0.isAutocorrect && $0.text == "á" },
            "implicit personal 'a' must not veto a→á, bar: \(bar.map(\.text))")
    }

    func testExplicitlyLearnedBareVowelKeepsTheVeto() {
        let e = engine(
            personal: FakePersonal(words: ["a": 3], explicit: ["a"]),
            config: singleLetterConfig())
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "a", limit: 5)
        XCTAssertTrue(
            bar.contains { $0.text == "á" },
            "the offer survives an explicit add, bar: \(bar.map(\.text))")
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "an explicit add is the user pointing at the word — full veto")
    }

    func testTombstonedBareVowelKeepsTheVeto() {
        // Deletion means "stop suggesting", never "start correcting what I
        // type" — the tombstone leg of the bare-letter gate is untouched.
        let e = engine(
            personal: FakePersonal(tombstones: ["a"]), config: singleLetterConfig())
        primeIcelandic(e)
        let bar = e.suggestions(context: "og er", currentWord: "a", limit: 5)
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }
}
