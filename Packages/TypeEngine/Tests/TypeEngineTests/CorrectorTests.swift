import XCTest

@testable import TypeEngine

final class CorrectorTests: XCTestCase {

    func makeCorrector(morphology: MorphologyProviding? = nil) -> Corrector {
        Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            morphology: morphology
        )
    }

    // MARK: Icelandic corrections

    func testHestrOffersHestur() {
        let result = makeCorrector().correct(typed: "hestr")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "hestur" },
            "dropped-letter typo should surface hestur, got \(result.suggestions.map(\.text))"
        )
        XCTAssertFalse(result.typedWordIsValid)
        // hestur (freq 500) should also outrank hestar (freq 100).
        let texts = result.suggestions.map(\.text)
        if let hestur = texts.firstIndex(of: "hestur"), let hestar = texts.firstIndex(of: "hestar") {
            XCTAssertLessThan(hestur, hestar)
        }
    }

    func testValidIcelandicWordIsNeverAutoReplaced() {
        // "borða" is in the IS lexicon: alternatives only.
        let result = makeCorrector().correct(typed: "borða")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testBinValidWordIsNeverAutoReplaced() {
        // Not in any frequency table, but morphologically valid (BÍN).
        let morphology = FakeMorphology(["hestunum"])
        let result = makeCorrector(morphology: morphology).correct(typed: "hestunum")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testBinFloorFrequencyMakesFormSuggestible() {
        // "hestinum" is absent from the IS frequency table but BÍN-valid;
        // a near-miss typo should still surface it via the floor frequency.
        let morphology = FakeMorphology(["hestinum"])
        let result = makeCorrector(morphology: morphology).correct(typed: "hestinun")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "hestinum" },
            "BÍN-valid form should be reachable, got \(result.suggestions.map(\.text))"
        )
    }

    // MARK: English corrections

    func testTehAutocorrectsToThe() {
        let result = makeCorrector().correct(typed: "teh")
        XCTAssertEqual(result.suggestions.first?.text, "the")
        XCTAssertEqual(
            result.suggestions.first?.isAutocorrect, true,
            "unknown-everywhere typo with a high-margin winner must auto-replace"
        )
        XCTAssertFalse(result.typedWordIsValid)
    }

    func testValidEnglishWordIsNeverAutoReplaced() {
        let result = makeCorrector().correct(typed: "with")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    // MARK: Completion-as-suggestion

    func testPrefixCompletionIsOfferedForPartialWord() {
        let result = makeCorrector().correct(typed: "hest")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "hestur" },
            "prefix completions should be offered, got \(result.suggestions.map(\.text))"
        )
    }

    // MARK: Ranking / conservatism internals

    func testBigramContextFlipsCorrectionRanking() {
        let corrector = makeCorrector()
        // Typo "vexur" is spatially equidistant from "vetur" (300) and
        // "veður" (200): without context the more frequent "vetur" wins...
        let noContext = corrector.correct(typed: "vexur", limit: 3)
        XCTAssertEqual(noContext.suggestions.first?.text, "vetur")
        // ...but after "gott" the bigram "gott veður" flips the ranking.
        let withContext = corrector.correct(typed: "vexur", previousWord: "gott", limit: 3)
        XCTAssertEqual(withContext.suggestions.first?.text, "veður")
    }

    func testConfidencesAreProbabilities() {
        let result = makeCorrector().correct(typed: "teh", limit: 3)
        for s in result.suggestions {
            XCTAssertGreaterThan(s.confidence, 0)
            XCTAssertLessThanOrEqual(s.confidence, 1)
        }
        let total = result.suggestions.reduce(0) { $0 + $1.confidence }
        XCTAssertLessThanOrEqual(total, 1.0001)
    }

    func testEmptyInputYieldsNothing() {
        let result = makeCorrector().correct(typed: "")
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testShortInputNeverAutocorrects() {
        // Below minAutocorrectLength (3) nothing may auto-replace.
        let result = makeCorrector().correct(typed: "te")
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    // MARK: Apostrophe conservatism

    /// Lexicons modeling the old en.lex (apostrophe forms stripped at build
    /// time, apostrophe-less twins attested): the guard must hold even then.
    private func apostropheHostileCorrector() -> Corrector {
        Corrector(
            icelandic: Fixtures.icelandic,
            english: DictLexicon(unigrams: [
                "dont": 800, "ibm": 400, "the": 2000, "im": 300,
            ])
        )
    }

    func testApostropheDeletionNeverAutocorrects() {
        // "don't" unknown, "dont" attested: may be suggested, but never
        // auto-applied (never delete the user's apostrophe).
        let result = apostropheHostileCorrector().correct(typed: "don't")
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testApostropheSubstitutionNeverAutocorrects() {
        // "i'm" unknown; "ibm"/"im" attested — neither preserves the
        // apostrophe, so no auto-replace ("I'm" -> "Ibm" harness quirk).
        let result = apostropheHostileCorrector().correct(typed: "i'm")
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testTypographicApostropheGetsTheSameGuard() {
        let result = apostropheHostileCorrector().correct(typed: "don’t")
        XCTAssertFalse(result.suggestions.contains { $0.isAutocorrect })
    }

    func testApostrophePreservingCorrectionMayStillAutocorrect() {
        // The guard only blocks apostrophe-losing replacements: a slipped
        // contraction may still be repaired to another contraction.
        let english = DictLexicon(unigrams: ["don't": 800, "the": 2000])
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: english)
        let result = corrector.correct(typed: "don'r")
        XCTAssertEqual(result.suggestions.first?.text, "don't")
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
    }

    // MARK: Hyphenated compounds

    func testHyphenatedCompoundWithValidPartsIsValidAndUncorrected() {
        let result = makeCorrector().correct(typed: "gott-veður")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    func testHyphenatedCompoundHonorsMorphology() {
        let morphology = FakeMorphology(["hestunum"])
        let result = makeCorrector(morphology: morphology).correct(typed: "gott-hestunum")
        XCTAssertTrue(result.typedWordIsValid)
    }

    func testHyphenatedTokenWithInvalidPartIsNotValid() {
        let result = makeCorrector().correct(typed: "gott-zzqqx")
        XCTAssertFalse(result.typedWordIsValid)
    }

    // MARK: Targeted distance-2 passes

    func testDiacriticRestorationReachesDistanceTwo() {
        // "godan" -> "góðan" needs two substitutions (o→ó, d→ð): outside
        // edits1, found by the diacritic-restoration pass.
        let result = makeCorrector().correct(typed: "godan")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "góðan" },
            "expected góðan, got \(result.suggestions.map(\.text))"
        )
    }

    func testGeminationRepairReachesDistanceTwo() {
        let english = DictLexicon(unigrams: ["tomorrow": 500, "the": 2000])
        let corrector = Corrector(icelandic: Fixtures.icelandic, english: english)
        let result = corrector.correct(typed: "tommorow")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "tomorrow" },
            "expected tomorrow, got \(result.suggestions.map(\.text))"
        )
    }

    // MARK: Space-miss splits

    func testSpaceSubstitutionSplitIsOffered() {
        // "gottnveður" = "gott veður" with the spacebar tap landing on n
        // (directly above the space): the interior n is consumed as the
        // missed space and both halves are exact-valid.
        let result = makeCorrector().correct(typed: "gottnveður")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "gott veður" },
            "expected gott veður, got \(result.suggestions.map(\.text))"
        )
    }

    func testSpaceInsertionSplitIsOffered() {
        // No mis-tapped letter, just a skipped spacebar keystroke.
        let result = makeCorrector().correct(typed: "gottveður")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "gott veður" },
            "expected gott veður, got \(result.suggestions.map(\.text))"
        )
    }

    func testSubstitutionSplitOutranksInsertionRepairPath() {
        // Both classes can reach "gott veður" from "gottnveður" (insertion
        // split "gottn"+"veður" would need an edits1 repair of the left
        // half); the substitution split's smaller penalty must win, making
        // the split the top suggestion here (typed unknown, halves exact,
        // strong bigram).
        let result = makeCorrector().correct(typed: "gottnveður")
        XCTAssertEqual(result.suggestions.first?.text, "gott veður")
    }

    func testSplitHalvesMayBeCheaplyRepaired() {
        // "godandag" = "góðan dag" with a skipped space AND missing
        // diacritics: the left half is repaired by the diacritic-
        // restoration pass before scoring.
        let result = makeCorrector().correct(typed: "godandag")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "góðan dag" },
            "expected góðan dag, got \(result.suggestions.map(\.text))"
        )
    }

    func testValidWordIsNeverSplit() {
        // "íslenska" is attested: valid words are never split, whatever
        // their halves might score.
        let result = makeCorrector().correct(typed: "íslenska")
        XCTAssertFalse(
            result.suggestions.contains { $0.text.contains(" ") },
            "valid word must not be split, got \(result.suggestions.map(\.text))"
        )
    }

    func testMorphologyValidWordIsNeverSplit() {
        // BÍN-valid compounds (unknown to the frequency tables) are valid
        // tokens: never split (PLAN.md: never auto-insert spaces into
        // compounds).
        let morphology = FakeMorphology(["gottveður"])
        let result = makeCorrector(morphology: morphology).correct(typed: "gottveður")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(result.suggestions.contains { $0.text.contains(" ") })
    }

    func testCloseSingleWordFixSuppressesSplits() {
        // "hestr" has a one-edit fix (hest/hestur) below the split gate:
        // the split pass must not even run (no spaced candidates).
        let result = makeCorrector().correct(typed: "hestr")
        XCTAssertFalse(
            result.suggestions.contains { $0.text.contains(" ") },
            "cheap single-word fix must suppress splits, got \(result.suggestions.map(\.text))"
        )
    }

    func testShortTokensAreNeverSplit() {
        // Below splitMinLength nothing is split ("ogað" = "og að" would be
        // plausible, but 4 chars is too little evidence).
        let result = makeCorrector().correct(typed: "ogað")
        XCTAssertFalse(result.suggestions.contains { $0.text.contains(" ") })
    }

    func testSplitScoreRewardsBigramCoherence() {
        // The second half is scored conditioned on the first: the same
        // split scores strictly higher when the (first, second) bigram is
        // attested than when it is not.
        let unigrams: [String: UInt32] = ["gott": 150, "veður": 200, "og": 2000]
        let withBigram = Corrector(
            icelandic: DictLexicon(unigrams: unigrams, bigrams: ["gott veður": 30]),
            english: Fixtures.english
        )
        let withoutBigram = Corrector(
            icelandic: DictLexicon(unigrams: unigrams, bigrams: [:]),
            english: Fixtures.english
        )
        func score(_ corrector: Corrector) -> Double? {
            corrector.splitCandidates(
                typedChars: Array("gottnveður"), previousWord: nil, pIcelandic: 0.5
            ).first(where: { $0.word == "gott veður" })?.score
        }
        guard let coherent = score(withBigram), let incoherent = score(withoutBigram) else {
            return XCTFail("split candidate missing")
        }
        XCTAssertGreaterThan(coherent, incoherent)
    }

    // MARK: edits2 budgets

    func testEdits2ExpansionCapFallsBackGracefully() {
        var config = EngineConfig()
        config.maxEdits2Expansions = 0  // edits2 fully disabled
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: Fixtures.english, config: config
        )
        // Still produces edits1/completion candidates without crashing.
        let result = corrector.correct(typed: "hestr")
        XCTAssertTrue(result.suggestions.contains { $0.text == "hestur" })
    }

    func testEdits2TimeBudgetFallsBackGracefully() {
        var config = EngineConfig()
        config.edits2TimeBudget = 0  // immediate wall-clock abort
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: Fixtures.english, config: config
        )
        let result = corrector.correct(typed: "qqqqqzz")
        XCTAssertFalse(result.typedWordIsValid)  // and no hang / crash
    }
}
