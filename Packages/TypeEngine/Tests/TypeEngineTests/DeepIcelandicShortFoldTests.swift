import XCTest

@testable import TypeEngine

/// Deep-Icelandic short folds are deliberately narrower than ordinary
/// autocorrect: exact acute restoration may arm on a lower margin only after
/// it wins naturally; every existing intent/skeleton/lane guard remains
/// authoritative.
final class DeepIcelandicShortFoldTests: XCTestCase {
    private func corrector(
        enabled: Bool = true,
        configure: (inout EngineConfig) -> Void = { _ in }
    ) -> Corrector {
        var config = EngineConfig()
        config.deepShortFoldEnabled = enabled
        // Decouple the structural policy from this tiny lexicon's calibration.
        config.deepShortFoldMinZ = -100
        config.restorationDominanceMinZ = -100
        config.slettaGuardBlendThreshold = -100
        config.restorationAutoApplyMargin = 100
        configure(&config)
        return Corrector(
            icelandic: DictLexicon(
                unigrams: [
                    "og": 10_000, "að": 9_000, "sem": 2_000,
                    "sé": 8_000,
                    "ja": 1_000, "já": 2_000,
                ]
            ),
            english: DictLexicon(
                unigrams: ["the": 10_000, "se": 2_000]
            ),
            config: config
        )
    }

    func testDeepLaneArmsNaturallyWinningExactFoldOnRelaxedMargin() {
        let baseline = corrector(enabled: false).correct(typed: "se", pIcelandic: 0.9)
        XCTAssertEqual(baseline.suggestions.first?.text, "sé")
        XCTAssertFalse(baseline.suggestions.contains(where: \.isAutocorrect))

        let deep = corrector().correct(typed: "se", pIcelandic: 0.9)
        XCTAssertEqual(deep.suggestions.first?.text, "sé")
        XCTAssertEqual(deep.suggestions.first?.isAutocorrect, true)
        XCTAssertEqual(deep.suggestions.first?.isRestoration, true)
    }

    func testMerelyLeaningIcelandicLaneKeepsOldBehavior() {
        let result = corrector().correct(typed: "se", pIcelandic: 0.8)
        XCTAssertEqual(result.suggestions.first?.text, "sé")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    func testGenuineIcelandicSkeletonStillNeedsDominance() {
        // ja is genuine IS vocabulary and já is only 2x as frequent, below
        // the existing 10x collision threshold. Deep mode may lead with the
        // useful offer, but it must not arm the spacebar.
        let result = corrector { $0.restorationAutoApplyMargin = 0 }
            .correct(typed: "ja", pIcelandic: 0.9)
        XCTAssertEqual(result.suggestions.first?.text, "já")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    func testLongPressDeliberatenessVetoesDeepPolicy() {
        let result = corrector().correct(
            typed: "se",
            pIcelandic: 0.9,
            deliberateCharacters: ["e"]
        )
        XCTAssertEqual(result.suggestions.first?.text, "sé")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    func testTargetTypicalityFloorStillApplies() {
        let result = corrector { $0.deepShortFoldMinZ = 100 }
            .correct(typed: "se", pIcelandic: 0.9)
        XCTAssertEqual(result.suggestions.first?.text, "sé")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }
}
