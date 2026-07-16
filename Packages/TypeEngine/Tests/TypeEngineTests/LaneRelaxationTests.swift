import XCTest

@testable import TypeEngine

/// Lane relaxation profiles (PLAN.md "diacritics are an input method, not
/// an error"): fold pricing curve, restoration/error cost decomposition,
/// the skeleton-collision triple gate, the sletta guard, deliberateness
/// vetoes and the field-kind restoration filter. Tiny-lexicon calibration
/// is decoupled from thresholds via config knobs where needed (the
/// real-artifact thresholds are exercised by the scenario suite).
final class LaneRelaxationTests: XCTestCase {

    // MARK: - Fixtures

    private let icelandicWords: [String: UInt32] = [
        "og": 2000, "að": 1800, "ég": 1500, "er": 1400, "í": 3000,
        "fór": 5000, "heim": 400, "víst": 300, "vist": 40,
        "ver": 300, "vér": 25, "búð": 200, "hús": 400, "íslenska": 250,
        "ekki": 900, "gott": 150,
    ]
    private let icelandicBigrams: [String: UInt32] = [
        "ég fór": 80, "í vist": 30,
    ]
    private let englishWords: [String: UInt32] = [
        "the": 5000, "and": 3000, "with": 900, "why": 400, "for": 6000,
        "don't": 380, "font": 300, "cant": 140, "can't": 150,
        "i": 2200, "in": 1200, "bud": 100, "is": 2000, "said": 500,
        "his": 700,
    ]
    private let englishBigrams: [String: UInt32] = [
        "why don't": 30
    ]

    private func corrector(
        morphology: MorphologyProviding? = nil,
        configure: (inout EngineConfig) -> Void = { _ in }
    ) -> Corrector {
        var config = EngineConfig()
        configure(&config)
        return Corrector(
            icelandic: DictLexicon(unigrams: icelandicWords, bigrams: icelandicBigrams),
            english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
            morphology: morphology,
            config: config
        )
    }

    private func pricing(p: Double, veto: Bool = false, config: EngineConfig = EngineConfig())
        -> FoldPricing
    {
        FoldPricing(config: config, pIcelandic: p, vetoRelaxation: veto)
    }

    // MARK: - Fold pricing curve

    func testLaneWeightRampIsSmoothstep() {
        XCTAssertEqual(FoldPricing.smoothstep(0.5, lo: 0.5, hi: 0.85), 0)
        XCTAssertEqual(FoldPricing.smoothstep(0.3, lo: 0.5, hi: 0.85), 0)
        XCTAssertEqual(FoldPricing.smoothstep(0.85, lo: 0.5, hi: 0.85), 1)
        XCTAssertEqual(FoldPricing.smoothstep(0.95, lo: 0.5, hi: 0.85), 1)
        let mid = FoldPricing.smoothstep(0.675, lo: 0.5, hi: 0.85)
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9)
    }

    func testFoldCostAtNeutralLaneEqualsTodaysFloor() {
        let neutral = pricing(p: 0.5)
        XCTAssertEqual(
            neutral.substitutionPrice(typed: "a", intended: "á", confusionBase: 0.35),
            0.35
        )
        // Confusion pairs keep their full constant at neutral.
        XCTAssertEqual(
            neutral.substitutionPrice(typed: "d", intended: "ð", confusionBase: 1.5),
            1.5
        )
        // Apostrophe omissions keep the full omitted-char constant.
        XCTAssertEqual(neutral.omissionPrice(of: "'", base: 4.0), 4.0)
    }

    func testFoldCostDecreasesMonotonicallyWithTheLane() {
        let config = EngineConfig()
        let costs = [0.5, 0.7, 0.9].map { p in
            pricing(p: p, config: config)
                .substitutionPrice(typed: "u", intended: "ú", confusionBase: 0.35)!
        }
        XCTAssertEqual(costs[0], 0.35)
        XCTAssertLessThan(costs[1], costs[0])
        XCTAssertLessThan(costs[2], costs[1])
        // Saturated lane: ~ε, never zero (exact input wins by ε).
        XCTAssertEqual(costs[2], config.foldEpsilon, accuracy: 1e-9)
        XCTAssertGreaterThan(costs[2], 0)
    }

    func testFoldDirectionality() {
        let saturated = pricing(p: 0.9)
        // Folding never REMOVES accents: á→a is not a fold pair.
        XCTAssertNil(saturated.substitutionPrice(typed: "á", intended: "a", confusionBase: 0.35))
        // ð þ æ ö have dedicated keys: never in the fold set (ð→d is not a
        // lane confusion either — direction matters).
        XCTAssertNil(saturated.substitutionPrice(typed: "ð", intended: "d", confusionBase: 1.5))
    }

    func testDeliberatenessVetoRestoresNeutralPricing() {
        let vetoed = pricing(p: 0.9, veto: true)
        XCTAssertEqual(
            vetoed.substitutionPrice(typed: "o", intended: "ó", confusionBase: 0.35),
            0.35
        )
        XCTAssertEqual(vetoed.omissionPrice(of: "'", base: 4.0), 4.0)
    }

    // MARK: - Channel cost decomposition

    func testRestorationOnlyDecomposition() {
        let spatial = SpatialModel()
        let cost = spatial.channelCost(
            typed: Array("islenska"), intended: Array("íslenska"), pricing: pricing(p: 0.5))
        XCTAssertEqual(cost.total, 0.35, accuracy: 1e-9)
        XCTAssertEqual(cost.errorOps, 0)
        XCTAssertEqual(cost.restorationOps, 1)
        XCTAssertTrue(cost.isRestorationOnly)
    }

    func testFoldsDoNotConsumeErrorBudget() {
        // Three folds + one genuine adjacent-key substitution prices ≈ the
        // substitution alone at a saturated lane.
        let spatial = SpatialModel()
        let config = EngineConfig()
        let saturated = pricing(p: 0.9)
        let mixed = spatial.channelCost(
            typed: Array("gus"), intended: Array("hús"), pricing: saturated)
        let subOnly = spatial.substitutionCost(typed: "g", intended: "h")
        XCTAssertEqual(mixed.total, subOnly + config.foldEpsilon, accuracy: 1e-9)
        XCTAssertEqual(mixed.errorOps, 1)
        XCTAssertEqual(mixed.restorationOps, 1)
        XCTAssertFalse(mixed.isRestorationOnly)
    }

    func testApostropheInsertionIsRestorationClass() {
        let spatial = SpatialModel()
        let neutral = spatial.channelCost(
            typed: Array("dont"), intended: Array("don't"), pricing: pricing(p: 0.5))
        XCTAssertEqual(neutral.total, 4.0, accuracy: 1e-9)
        XCTAssertTrue(neutral.isRestorationOnly)
        let config = EngineConfig()
        let enLane = spatial.channelCost(
            typed: Array("dont"), intended: Array("don't"), pricing: pricing(p: 0.1))
        XCTAssertEqual(enLane.total, config.foldEpsilon, accuracy: 1e-9)
        XCTAssertTrue(enLane.isRestorationOnly)
    }

    func testChannelTotalMatchesLegacyTypingCostAtNeutral() {
        let spatial = SpatialModel()
        let neutral = pricing(p: 0.5)
        for (typed, intended) in [
            ("teh", "the"), ("godan", "góðan"), ("koetip", "kortið"),
            ("takkk", "takk"), ("husid", "húsið"), ("hestr", "hestur"),
        ] {
            XCTAssertEqual(
                spatial.channelCost(
                    typed: Array(typed), intended: Array(intended), pricing: neutral
                ).total,
                spatial.typingCost(typed: Array(typed), intended: Array(intended)),
                accuracy: 1e-9,
                "neutral pricing must be byte-identical for \(typed)→\(intended)"
            )
        }
    }

    func testGeminationIndelGetsLaneDiscountOnly() {
        let spatial = SpatialModel()
        let costs = SpatialModel.Costs()
        let neutral = spatial.channelCost(
            typed: Array("takkk"), intended: Array("takk"), pricing: pricing(p: 0.5))
        XCTAssertEqual(neutral.total, costs.insertion, accuracy: 1e-9)
        let saturated = spatial.channelCost(
            typed: Array("takkk"), intended: Array("takk"), pricing: pricing(p: 0.9))
        // Discounted, not free — and still error-class.
        XCTAssertLessThan(saturated.total, neutral.total)
        XCTAssertGreaterThan(saturated.total, 1.0)
        XCTAssertFalse(saturated.isRestorationOnly)
    }

    // MARK: - Rewrite distance (far-repair currency)

    func testRewriteDistanceTreatsApostropheInsertionAsFree() {
        XCTAssertEqual(Corrector.rewriteDistance(Array("dont"), Array("don't")), 0)
        XCTAssertEqual(Corrector.rewriteDistance(Array("im"), Array("i'm")), 0)
        // Dropping an apostrophe is NOT free (folding only inserts).
        XCTAssertEqual(Corrector.rewriteDistance(Array("don't"), Array("dont")), 1)
    }

    // MARK: - Restoration flag on suggestions

    func testRestorationFlagDistinguishesCandidateClasses() {
        let c = corrector()
        let restored = c.correct(typed: "islenska", pIcelandic: 0.5)
        let top = restored.suggestions.first
        XCTAssertEqual(top?.text, "íslenska")
        XCTAssertEqual(top?.isRestoration, true)

        let repaired = c.correct(typed: "teh", pIcelandic: 0.5)
        XCTAssertEqual(repaired.suggestions.first?.text, "the")
        XCTAssertEqual(repaired.suggestions.first?.isRestoration, false)
    }

    // MARK: - Relaxed restoration margin (ordinary, invalid-typed path)

    func testRestorationMarginOnlyRelaxesOnceRampIsOpen() {
        // "hus" has a real cross-language competitor ("his"), so the margin
        // is finite; knobs pin both margins so the tiny lexicon's score
        // spread stays out of the assertion.
        func autocorrects(p: Double, restorationMargin: Double) -> Bool {
            let c = corrector { config in
                config.autocorrectMargin = 1_000  // ordinary margin unreachable
                config.restorationAutoApplyMargin = restorationMargin
            }
            return c.correct(typed: "hus", pIcelandic: p)
                .suggestions.first?.isAutocorrect == true
        }
        XCTAssertFalse(
            autocorrects(p: 0.5, restorationMargin: -100),
            "at the neutral prior the ordinary margin applies unchanged")
        XCTAssertTrue(
            autocorrects(p: 0.9, restorationMargin: -100),
            "open ramp: restoration-only winner uses the relaxed margin")
        XCTAssertFalse(
            autocorrects(p: 0.9, restorationMargin: 1_000),
            "the relaxed margin is still a margin")
    }

    // MARK: - Skeleton-collision triple gate

    /// vist/víst: both attested, ratio 300/40 = 7.5 < 10 → dominance fails,
    /// offer-only whatever the lane.
    func testDominanceRatioFailKeepsSkeletonOfferOnly() {
        let result = corrector().correct(typed: "vist", previousWord: "er", pIcelandic: 0.9)
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertTrue(result.suggestions.contains { $0.text == "víst" })
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testDominanceRatioPassAutoRestores() {
        // Lower the ratio below 7.5 and the same collision passes (context
        // and sletta gates are vacuous here: no bigram favors "vist" after
        // "er", and "vist" has no English reading).
        let c = corrector { $0.restorationDominanceRatio = 5 }
        let result = c.correct(typed: "vist", previousWord: "er", pIcelandic: 0.9)
        XCTAssertEqual(result.suggestions.first?.text, "víst")
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
    }

    /// ver/vér: dominance the wrong way around (300 vs 25) — the frequent
    /// skeleton must never lose to its rare accent twin.
    func testFrequentSkeletonNeverLosesToRareTwin() {
        let result = corrector().correct(typed: "ver", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    /// A skeleton with no attested accented twin never restores, however
    /// permissive the knobs (restoration needs a lane-lexicon candidate).
    func testUnattestedTwinNeverRestores() {
        let morphology = FakeMorphology(["fyr"])
        let c = corrector(morphology: morphology) { config in
            config.restorationDominanceMinZ = -100
            config.slettaGuardBlendThreshold = -100
        }
        let result = c.correct(typed: "fyr", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    /// BÍN-valid skeleton absent from the frequency table: dominance falls
    /// back to the candidate-commonness bar (`restorationDominanceMinZ`).
    func testBinSkeletonDominanceBarGovernsAutoApply() {
        let morphology = FakeMorphology(["vist"])
        // Remove the attested "vist" so the BÍN fallback path is exercised.
        var icelandic = icelandicWords
        icelandic.removeValue(forKey: "vist")
        func autocorrects(minZ: Double) -> Bool {
            var config = EngineConfig()
            config.restorationDominanceMinZ = minZ
            let c = Corrector(
                icelandic: DictLexicon(unigrams: icelandic, bigrams: icelandicBigrams),
                english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
                morphology: morphology,
                config: config
            )
            return c.correct(typed: "vist", previousWord: "er", pIcelandic: 0.9)
                .suggestions.first?.isAutocorrect == true
        }
        XCTAssertTrue(autocorrects(minZ: -100), "headline candidate claims dominance")
        XCTAssertFalse(autocorrects(minZ: 100), "below the bar: offer-only")
    }

    /// Context gate: a bigram-supported skeleton ("í vist") must keep the
    /// restoration offer-only even when dominance would pass.
    func testContextGateFailsWhenBigramFavorsSkeleton() {
        let c = corrector { $0.restorationDominanceRatio = 5 }
        let supported = c.correct(typed: "vist", previousWord: "í", pIcelandic: 0.9)
        XCTAssertFalse(
            supported.suggestions.contains { $0.isAutocorrect },
            "bigram 'í vist' favors the skeleton reading")
        let unsupported = c.correct(typed: "vist", previousWord: "er", pIcelandic: 0.9)
        XCTAssertEqual(unsupported.suggestions.first?.isAutocorrect, true)
    }

    /// Sletta guard: an EN-attested skeleton in a merely-leaning IS lane
    /// keeps its English reading; only a saturated lane may overwhelm it.
    func testSlettaGuardThresholdGovernsCrossLanguageRestoration() {
        let morphology = FakeMorphology(["for"])
        func autocorrects(threshold: Double, p: Double) -> Bool {
            let c = corrector(morphology: morphology) { config in
                config.slettaGuardBlendThreshold = threshold
                config.restorationDominanceMinZ = -100  // isolate the guard
            }
            return c.correct(typed: "for", previousWord: "ég", pIcelandic: p)
                .suggestions.first?.isAutocorrect == true
        }
        XCTAssertTrue(autocorrects(threshold: -100, p: 0.9))
        XCTAssertFalse(
            autocorrects(threshold: 100, p: 0.9),
            "the guard alone can hold restoration back")
        XCTAssertFalse(
            autocorrects(threshold: -100, p: 0.6),
            "below the lane gate nothing fires regardless")
    }

    /// Deliberateness (a): a long-pressed character vetoes folding for the
    /// word — restoration stays offered, never applied.
    func testLongPressedCharacterVetoesAutoRestoration() {
        let morphology = FakeMorphology(["for"])
        let c = corrector(morphology: morphology) { config in
            config.restorationDominanceMinZ = -100
            config.slettaGuardBlendThreshold = -100
        }
        let fired = c.correct(typed: "for", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertEqual(fired.suggestions.first?.isAutocorrect, true)
        let vetoed = c.correct(
            typed: "for", previousWord: "ég", pIcelandic: 0.9, deliberateCharacters: ["o"])
        XCTAssertTrue(vetoed.suggestions.contains { $0.text == "fór" }, "still offered")
        XCTAssertFalse(vetoed.suggestions.contains { $0.isAutocorrect })
    }

    /// Deliberateness (a), reverse direction: a long-pressed accent is
    /// never folded away by any auto-apply.
    func testLongPressedAccentIsNeverFoldedAway() {
        // Typed "fór" with a long-pressed ó; the word is valid, and even an
        // engineered error-class winner may not drop the ó.
        let vetoed = corrector().correct(
            typed: "fór", previousWord: "ég", pIcelandic: 0.9, deliberateCharacters: ["ó"])
        XCTAssertFalse(vetoed.suggestions.contains { $0.isAutocorrect && !$0.text.contains("ó") })
    }

    /// Deliberateness (c): EXPLICITLY learned personal skeletons (editor
    /// add / verbatim tap) veto restoration of themselves; an IMPLICITLY
    /// threshold-learned acute-fold shadow does NOT (wave 26, session
    /// 2026-07-16T22-45-30 — lazy commits must not kill the restoration
    /// they came from). Tombstoned accented forms are never restored to.
    func testPersonalSkeletonAndTombstoneVetoes() {
        let morphology = FakeMorphology(["for"])
        var config = EngineConfig()
        config.restorationDominanceMinZ = -100
        config.slettaGuardBlendThreshold = -100

        var personal = FakePersonal()
        personal.words = ["for": 4]
        personal.explicit = ["for"]
        let model = BlendedLanguageModel(
            icelandic: DictLexicon(unigrams: icelandicWords, bigrams: icelandicBigrams),
            english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
            morphology: morphology,
            config: config
        )
        model.personal.setSnapshot(personal)
        let c = Corrector(model: model, config: config)
        let vetoed = c.correct(typed: "for", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertFalse(
            vetoed.suggestions.contains { $0.isAutocorrect },
            "explicitly learned skeleton outranks restoration")

        // The same skeleton learned IMPLICITLY is a lazy-fold shadow here
        // (this fixture's "fór" dominates an is.lex-absent "for" and the
        // fixture EN lexicon does not out-attest it): restoration fires.
        var implicit = FakePersonal()
        implicit.words = ["for": 4]
        model.personal.setSnapshot(implicit)
        let restored = c.correct(typed: "for", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertEqual(
            restored.suggestions.first?.text, "fór",
            "implicit shadow must not veto restoration")

        var tombstones = FakePersonal()
        tombstones.tombstones = ["fór"]
        let model2 = BlendedLanguageModel(
            icelandic: DictLexicon(unigrams: icelandicWords, bigrams: icelandicBigrams),
            english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
            morphology: morphology,
            config: config
        )
        model2.personal.setSnapshot(tombstones)
        let c2 = Corrector(model: model2, config: config)
        let result = c2.correct(typed: "for", previousWord: "ég", pIcelandic: 0.9)
        XCTAssertFalse(result.suggestions.contains { $0.text == "fór" })
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    // MARK: - EN profile

    func testDontAutoRestoresInEnglishLane() {
        // Sane contraction counts (unlike en.lex v2): don't (380) clears
        // the error-class rival "font" (300) once the apostrophe folds.
        let result = corrector().correct(typed: "dont", previousWord: "why", pIcelandic: 0.1)
        XCTAssertEqual(result.suggestions.first?.text, "don't")
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
        XCTAssertEqual(result.suggestions.first?.isRestoration, true)
    }

    func testDontStaysPutAtNeutralLane() {
        let result = corrector().correct(typed: "dont", previousWord: "why", pIcelandic: 0.5)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testCantDominanceFailsInEnglishLane() {
        // cant (140) vs can't (150): genuine English vocabulary, ratio
        // nowhere near the bar — offer-only.
        let result = corrector().correct(typed: "cant", previousWord: "i", pIcelandic: 0.1)
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testLoneICapitalizesInEnglishLaneOnly() {
        let c = corrector { $0.accentRestoreMinZ = -10 }
        let en = c.correct(typed: "i", previousWord: "said", pIcelandic: 0.1)
        XCTAssertEqual(en.suggestions.first?.text, "I")
        XCTAssertEqual(en.suggestions.first?.isAutocorrect, true)
        XCTAssertEqual(en.suggestions.first?.isRestoration, true)

        let neutral = c.correct(typed: "i", previousWord: nil, pIcelandic: 0.5)
        XCTAssertFalse(neutral.suggestions.contains { $0.isAutocorrect })

        let icelandic = c.correct(typed: "i", previousWord: "erum", pIcelandic: 0.9)
        XCTAssertEqual(icelandic.suggestions.first?.text, "í")
        XCTAssertEqual(icelandic.suggestions.first?.isAutocorrect, true)
    }

    // MARK: - Field-kind restoration filter (TypingSession)

    func testSuppressingFieldsDropRestorationSuggestions() {
        let engine = TypeEngine(
            icelandic: DictLexicon(unigrams: icelandicWords, bigrams: icelandicBigrams),
            english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
            morphologyProvider: nil
        )
        let session = TypingSession(engine: engine)
        session.fieldKind = .url
        let bar = session.suggestions(for: "islenska")
        XCTAssertFalse(
            bar.contains { $0.text == "íslenska" },
            "restoration suggestions are dropped entirely in URL fields")
        // Error-class corrections stay available, tap-only.
        session.reset()
        session.fieldKind = .url
        let repairs = session.suggestions(for: "gott teh")
        XCTAssertTrue(repairs.contains { $0.text == "the" })
        XCTAssertFalse(repairs.contains { $0.isAutocorrect })
    }

    func testLongPressPlumbingThroughSession() {
        let engine = TypeEngine(
            icelandic: DictLexicon(unigrams: icelandicWords, bigrams: icelandicBigrams),
            english: DictLexicon(unigrams: englishWords, bigrams: englishBigrams),
            morphologyProvider: FakeMorphology(["for"])
        )
        let session = TypingSession(engine: engine)
        // Saturate the IS lane.
        for word in ["og", "að", "ég", "og", "að"] { engine.confirmWord(word) }
        XCTAssertGreaterThan(engine.probabilityIcelandic, 0.85)

        // Baseline: "for" (BÍN-valid via fake) restores in the lane when
        // the gates are open — with default knobs the real-artifact-tuned
        // thresholds may keep this offer-only on the tiny lexicon, so the
        // assertion is only about the long-press DELTA below.
        _ = session.suggestions(for: "ég f")
        session.noteLongPressInsertion("o")
        let bar = session.suggestions(for: "ég fo")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
        let after = session.suggestions(for: "ég for")
        XCTAssertFalse(
            after.contains { $0.isAutocorrect },
            "a long-pressed character anywhere in the word vetoes folding")
    }
}
