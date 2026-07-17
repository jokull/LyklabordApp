import XCTest

@testable import TypeEngine

/// Wave 30 — deep-decode mash recovery (the eotthbap→eitthvað class):
/// the near-miss enabling cap on per-tap substitution pricing, the
/// edge-key undershoot carve-out, the widened mash-recovery beam cone,
/// and its offer-only fire suppression.
final class MashRecoveryTests: XCTestCase {

    let config = EngineConfig()
    var spatial: SpatialModel { SpatialModel(costs: config.spatialCosts) }

    func provider(
        _ taps: [TapSample?], config: EngineConfig? = nil
    ) -> PerTapCostProvider {
        PerTapCostProvider(taps: taps, spatial: spatial, config: config ?? self.config)
    }

    // MARK: - Near-miss enabling cap

    func testNearMissLeanCapsPerTapCostAtStatic() {
        // The recorded eotthbap "o" tap: dx −0.388 (78% of the way to the
        // i boundary). The raw LLR taxes o→i ABOVE the static ~1.02 price;
        // the near-miss cap restores the static geometry cost — a tap
        // leaning toward the intended key never prices worse than no tap.
        let perTap = provider([TapSample(char: "o", dxNorm: -0.388, dyNorm: -0.351)])
        let staticCost = spatial.substitutionCost(typed: "o", intended: "i")
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "o", intended: "i"),
            staticCost,
            accuracy: 1e-9
        )
        var off = config
        off.tapNearMissCapEnabled = false
        let uncapped = provider(
            [TapSample(char: "o", dxNorm: -0.388, dyNorm: -0.351)], config: off)
        XCTAssertGreaterThan(
            uncapped.substitutionCost(position: 0, typed: "o", intended: "i"),
            staticCost,
            "without the cap the tight-σ LLR taxes even a strong near-miss"
        )
    }

    func testBelowThresholdLeanKeepsTheLikelihoodRatio() {
        // A tap barely leaning (0.1 < tapNearMissMinLean 0.25) keeps the
        // full LLR — the veto half is untouched near the key center.
        let perTap = provider([TapSample(char: "o", dxNorm: -0.1, dyNorm: 0)])
        XCTAssertGreaterThan(
            perTap.substitutionCost(position: 0, typed: "o", intended: "i"),
            spatial.substitutionCost(typed: "o", intended: "i")
        )
    }

    func testWrongDirectionLeanKeepsTheVeto() {
        // Tap leaning AWAY from the intended key (toward p, asking for i):
        // full veto pricing stands.
        let perTap = provider([TapSample(char: "o", dxNorm: 0.4, dyNorm: 0)])
        XCTAssertGreaterThan(
            perTap.substitutionCost(position: 0, typed: "o", intended: "i"),
            6.0
        )
    }

    // MARK: - Edge-key undershoot carve-out

    func testEdgeUndershootPairPricesStaticRegardlessOfTap() {
        // Dead-center p tap, intended ð (the heipina→heiðina evidence):
        // an aim error carries no tap information — static price.
        let perTap = provider([TapSample(char: "p", dxNorm: 0, dyNorm: 0)])
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "p", intended: "ð"),
            spatial.substitutionCost(typed: "p", intended: "ð"),
            accuracy: 1e-9
        )
    }

    func testEdgeUndershootIsDirectional() {
        // ð→p is NOT an undershoot (nobody reaches past ð for p): a
        // dead-center ð tap keeps its full veto against the p reading.
        let perTap = provider([TapSample(char: "ð", dxNorm: 0, dyNorm: 0)])
        XCTAssertGreaterThan(
            perTap.substitutionCost(position: 0, typed: "ð", intended: "p"),
            6.0
        )
    }

    func testEdgeUndershootDisabledKeepsTheVeto() {
        var off = config
        off.edgeUndershootEnabled = false
        let perTap = provider([TapSample(char: "p", dxNorm: 0, dyNorm: 0)], config: off)
        XCTAssertGreaterThan(
            perTap.substitutionCost(position: 0, typed: "p", intended: "ð"),
            6.0
        )
    }

    // MARK: - tapSupports (the margin-veto exemption predicate)

    func testTapSupportsLeanAndEdgePairsOnly() {
        let perTap = provider([
            TapSample(char: "o", dxNorm: -0.388, dyNorm: 0),  // leans toward i
            TapSample(char: "p", dxNorm: 0, dyNorm: 0),  // edge pair for ð
            TapSample(char: "a", dxNorm: 0, dyNorm: 0),  // dead center
        ])
        XCTAssertTrue(perTap.tapSupports(position: 0, typed: "o", intended: "i"))
        XCTAssertFalse(perTap.tapSupports(position: 0, typed: "o", intended: "p"))
        XCTAssertTrue(perTap.tapSupports(position: 1, typed: "p", intended: "ð"))
        XCTAssertFalse(perTap.tapSupports(position: 2, typed: "a", intended: "s"))
        XCTAssertFalse(perTap.tapSupports(position: 2, typed: "a", intended: "a"))
    }

    func testVetoFactorSkipsSupportedPositions() {
        // Same-length rewrite whose every substituted position is
        // tap-supported: nothing contradicts the rewrite, factor 1. The
        // dead-center matching position ("o") never counts either way.
        let corrector = Corrector(
            icelandic: DictLexicon(unigrams: ["og": 100]),
            english: DictLexicon(unigrams: ["the": 100])
        )
        let perTap = provider([
            TapSample(char: "o", dxNorm: 0, dyNorm: 0),
            TapSample(char: "k", dxNorm: 0.4, dyNorm: 0),  // leans toward l
        ])
        XCTAssertEqual(
            corrector.tapVetoFactor(
                typedChars: ["o", "k"], candidate: "ol", perTap: perTap),
            1.0
        )
        // The same rewrite against a dead-center tap keeps the veto.
        let deadCenter = provider([
            TapSample(char: "o", dxNorm: 0, dyNorm: 0),
            TapSample(char: "k", dxNorm: 0, dyNorm: 0),
        ])
        XCTAssertGreaterThan(
            corrector.tapVetoFactor(
                typedChars: ["o", "k"], candidate: "ol", perTap: deadCenter),
            1.0
        )
    }

    // MARK: - Mash-recovery widened beam cone

    /// Fixture: "bestxur" → "hestur" needs b→h (~1.59) + an extra-x
    /// deletion (4.0) ≈ 5.59 nats over 2 edits — inside the widened 6.5
    /// cap, outside the ordinary 5.0 multi-edit cap, and unreachable by
    /// every targeted pass (the typo in the first letter keeps hestur out
    /// of the prefix-completion pools).
    private func mashCorrector(_ config: EngineConfig = EngineConfig()) -> Corrector {
        Corrector(
            icelandic: DictLexicon(unigrams: ["hestur": 5000, "og": 1000, "að": 900]),
            english: DictLexicon(unigrams: ["the": 2000, "and": 1000]),
            config: config
        )
    }

    func testMashRecoveryOffersTheWidenedConeCandidate() {
        let result = mashCorrector().correct(typed: "bestxur")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "hestur" },
            "recovery cone should offer hestur, got \(result.suggestions.map(\.text))"
        )
    }

    func testMashRecoveryWinnerAboveOrdinaryCapNeverAutoApplies() {
        // hestur costs 5.59 — under autocorrectMaxSpatialCost (6.0) with
        // an infinite margin, so WITHOUT the offer-only rule it would
        // fire. A winner only the widened cone could pool must not widen
        // the calibrated set of auto-applies (the dev-A/B ráðherra leak).
        let result = mashCorrector().correct(typed: "bestxur")
        XCTAssertFalse(
            result.suggestions.contains { $0.isAutocorrect },
            "widened-cone winner must stay offer-only"
        )
    }

    func testMashRecoveryDisabledLeavesTheBarEmpty() {
        var off = EngineConfig()
        off.mashRecoveryEnabled = false
        let result = mashCorrector(off).correct(typed: "bestxur")
        XCTAssertFalse(result.suggestions.contains { $0.text == "hestur" })
    }

    func testMashRecoveryRespectsTheMinLength() {
        var config = EngineConfig()
        config.mashRecoveryMinLength = 8
        let result = mashCorrector(config).correct(typed: "bestxur")
        XCTAssertFalse(result.suggestions.contains { $0.text == "hestur" })
    }

    func testMashRecoverySkippedWhenAnAttestedRepairExists() {
        // One cheap edit away from attested vocabulary ("hestur" via a
        // single deleted x): the pool holds a close attested candidate, so
        // the deep gate never opens and no recovery note applies — the
        // ordinary machinery both offers AND may fire it.
        let trace = CorrectionTrace()
        let result = mashCorrector().correct(typed: "hestxur", trace: trace)
        XCTAssertTrue(result.suggestions.contains { $0.text == "hestur" })
        XCTAssertFalse(
            trace.notes.contains { $0.contains("mash recovery") },
            "a close attested repair must keep the widened cone shut"
        )
    }
}
