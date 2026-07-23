import XCTest

@testable import TypeEngine

/// Wave 22 — productive compound acceptance (Compounds.swift): the
/// modifier/head legality rules ported from Miðeind's compound analyzer,
/// the autocorrect-protection wiring, and the compound-head repair pass.
final class CompoundTests: XCTestCase {

    /// Paradigm fixture: the linking forms the modifier rule reads.
    private func makeParadigms() -> FakeParadigms {
        let paradigms = FakeParadigms()
        // Neuter "stökk": nf/þf.et indefinite = the stem slots.
        paradigms.addNoun(
            lemma: "stökk", genderCode: 2,
            forms: [
                ("stökk", 0, false, false),  // nf et
                ("stökk", 1, false, false),  // þf et
                ("stökki", 2, false, false),  // þgf et
                ("stökks", 3, false, false),  // ef et
            ])
        // Feminine "vinna": "vinnu" covers þf/þgf/ef.et — the ef reading
        // is the genitive linking form (vinnu-).
        paradigms.addNoun(
            lemma: "vinna", genderCode: 1,
            forms: [
                ("vinna", 0, false, false),
                ("vinnu", 1, false, false),
                ("vinnu", 2, false, false),
                ("vinnu", 3, false, false),
            ])
        // Masculine "hestur": nominative is NOT a linking form, dative is
        // not, accusative ("hest") and genitives ("hests"/"hesta") are;
        // the definite genitive ("hestsins") never is.
        paradigms.addNoun(
            lemma: "hestur", genderCode: 0,
            forms: [
                ("hestur", 0, false, false),
                ("hest", 1, false, false),
                ("hesti", 2, false, false),
                ("hests", 3, false, false),
                ("hestsins", 3, false, true),
                ("hesta", 3, true, false),
            ])
        // Genitive-plural linking forms for the 3-part compound test.
        paradigms.addNoun(
            lemma: "skaði", genderCode: 0, forms: [("skaða", 3, false, false)])
        paradigms.addNoun(
            lemma: "bót", genderCode: 1, forms: [("bóta", 3, true, false)])
        return paradigms
    }

    private func makeCorrector(
        morphology: FakeMorphology,
        paradigms: FakeParadigms,
        config: EngineConfig = EngineConfig()
    ) -> Corrector {
        let inflection = InflectionStore()
        inflection.setModel(
            InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: [:])))
        let model = BlendedLanguageModel(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            morphology: morphology,
            config: config,
            inflection: inflection
        )
        return Corrector(model: model, config: config)
    }

    // MARK: Modifier legality

    func testGenitiveModifierPlusKnownHeadIsProtected() {
        let corrector = makeCorrector(
            morphology: FakeMorphology(["fundinum"]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "vinnufundinum")
        XCTAssertTrue(result.typedWordIsValid, "vinnu(ef)+fundinum must be accepted")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    func testNeuterStemModifierIsProtected() {
        let corrector = makeCorrector(
            morphology: FakeMorphology(["húsinu"]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "stökkhúsinu")
        XCTAssertTrue(result.typedWordIsValid, "stökk(stem)+húsinu must be accepted")
    }

    func testMasculineAccusativeStemAndGenitivesLink() {
        let morphology = FakeMorphology(["skúrinn"])
        let corrector = makeCorrector(morphology: morphology, paradigms: makeParadigms())
        XCTAssertTrue(corrector.correct(typed: "hestskúrinn").typedWordIsValid)  // hest- þf.et
        XCTAssertTrue(corrector.correct(typed: "hestsskúrinn").typedWordIsValid)  // hests- ef.et
        XCTAssertTrue(corrector.correct(typed: "hestaskúrinn").typedWordIsValid)  // hesta- ef.ft
    }

    func testNominativeAndDativeAndDefiniteFormsNeverLink() {
        let morphology = FakeMorphology(["skúrinn"])
        let corrector = makeCorrector(morphology: morphology, paradigms: makeParadigms())
        XCTAssertFalse(
            corrector.correct(typed: "hesturskúrinn").typedWordIsValid,
            "masc nominative is not a linking form")
        XCTAssertFalse(
            corrector.correct(typed: "hestiskúrinn").typedWordIsValid,
            "dative is not a linking form")
        XCTAssertFalse(
            corrector.correct(typed: "hestsinsskúrinn").typedWordIsValid,
            "definite (article-suffixed) genitive is not a linking form")
    }

    // MARK: Head legality

    func testBoundSuffixFormIsALegalHead() {
        // "leikanum" exists only in BÍN's ord.suffix.csv (utg=-1) — absent
        // from the morphology fake on purpose.
        let corrector = makeCorrector(
            morphology: FakeMorphology([]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "stökkleikanum")
        XCTAssertTrue(result.typedWordIsValid, "bound suffix -leikanum must head a compound")
        XCTAssertFalse(result.suggestions.contains(where: \.isAutocorrect))
    }

    func testClosedClassHeadIsRejected() {
        // "hverjum" known but flagged closed-class: no compound reading.
        let morphology = FakeMorphology(["hverjum"])
        morphology.openClass = []
        let corrector = makeCorrector(morphology: morphology, paradigms: makeParadigms())
        XCTAssertFalse(corrector.correct(typed: "stökkhverjum").typedWordIsValid)
    }

    // MARK: Structure

    func testTwoModifierCompoundIsAccepted() {
        let corrector = makeCorrector(
            morphology: FakeMorphology(["reglan"]), paradigms: makeParadigms())
        XCTAssertTrue(
            corrector.correct(typed: "skaðabótareglan").typedWordIsValid,
            "skaða+bóta+reglan: every non-final part a legal modifier")
    }

    func testThreeCharacterHeadIsAcceptedByDefault() {
        var config = EngineConfig()
        XCTAssertEqual(config.compoundMinHeadLength, 3)
        let corrector = makeCorrector(
            morphology: FakeMorphology(["hús"]), paradigms: makeParadigms(), config: config)
        XCTAssertTrue(corrector.correct(typed: "stökkhús").typedWordIsValid)

        config.compoundMinHeadLength = 4
        let strict = makeCorrector(
            morphology: FakeMorphology(["hús"]), paradigms: makeParadigms(), config: config)
        XCTAssertFalse(strict.correct(typed: "stökkhús").typedWordIsValid)
    }

    func testHagfraedibokIsNeverAutoSplit() {
        let paradigms = makeParadigms()
        paradigms.addNoun(
            lemma: "hagfræði", genderCode: 2,
            forms: [
                ("hagfræði", 0, false, false),
                ("hagfræði", 1, false, false),
            ])
        let morphology = FakeMorphology(["bók", "ók"])
        let inflection = InflectionStore()
        inflection.setModel(
            InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: [:])))
        let model = BlendedLanguageModel(
            icelandic: DictLexicon(
                unigrams: ["hagfræði": 1_000, "ók": 800, "bók": 600],
                bigrams: ["hagfræði ók": 500]),
            english: Fixtures.english,
            morphology: morphology,
            config: EngineConfig(),
            inflection: inflection)
        let result = Corrector(model: model, config: EngineConfig()).correct(
            typed: "hagfræðibók", pIcelandic: 0.9)

        XCTAssertTrue(result.typedWordIsValid, "hagfræði+bók must be compound-protected")
        XCTAssertFalse(
            result.suggestions.contains(where: \.isAutocorrect),
            "valid compound must never auto-split, got \(result.suggestions)")
    }

    func testGarbageStaysInvalid() {
        let corrector = makeCorrector(
            morphology: FakeMorphology(["fundinum", "húsinu"]), paradigms: makeParadigms())
        for junk in ["dlmk", "habb", "eotthbap", "stökklrikanum"] {
            XCTAssertFalse(
                corrector.correct(typed: junk).typedWordIsValid,
                "\(junk) must stay invalid")
        }
    }

    func testDisabledKnobTurnsAcceptanceOff() {
        var config = EngineConfig()
        config.compoundValidityEnabled = false
        let corrector = makeCorrector(
            morphology: FakeMorphology(["fundinum"]), paradigms: makeParadigms(),
            config: config)
        XCTAssertFalse(corrector.correct(typed: "vinnufundinum").typedWordIsValid)
    }

    func testNoParadigmsMeansNoAcceptance() {
        // Without an inflection model the modifier rule has no
        // definiteness-aware source — the machinery must stay inert.
        let corrector = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            morphology: FakeMorphology(["fundinum"])
        )
        XCTAssertFalse(corrector.correct(typed: "vinnufundinum").typedWordIsValid)
    }

    // MARK: Wave 31 — never-a-compound deny set

    func testDenySetWordNeverDecomposes() {
        // Fixture makes margs+konar a perfectly legal join (genitive
        // modifier + open-class head) — the deny set must refuse it
        // anyway, while the same modifier keeps linking elsewhere.
        let paradigms = makeParadigms()
        paradigms.addNoun(
            lemma: "margur", genderCode: 0, forms: [("margs", 3, false, false)])
        let morphology = FakeMorphology(["konar", "skúrinn"])
        let inflection = InflectionStore()
        inflection.setModel(
            InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: [:])))
        let model = BlendedLanguageModel(
            icelandic: Fixtures.icelandic, english: Fixtures.english,
            morphology: morphology, config: EngineConfig(), inflection: inflection)
        let corrector = Corrector(model: model, config: EngineConfig())
        XCTAssertTrue(
            corrector.correct(typed: "margsskúrinn").typedWordIsValid,
            "control: margs- links as an ordinary genitive modifier")
        XCTAssertFalse(
            corrector.correct(typed: "margskonar").typedWordIsValid,
            "deny-set word must never earn compound protection")
    }

    func testDenySetOffersCanonicalSplit() {
        let corrector = makeCorrector(
            morphology: FakeMorphology([]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "margskonar")
        let offer = result.suggestions.first { $0.text == "margs konar" }
        XCTAssertNotNil(offer, "deny-set words offer their canonical split")
        XCTAssertFalse(offer?.isAutocorrect ?? true, "offer-only, never auto-applied")
    }

    func testDenyMapCoversTheHarvestedC002Set() {
        XCTAssertEqual(CompoundAnalyzer.neverCompounds.count, 10)
        XCTAssertEqual(CompoundAnalyzer.neverCompounds["margskonar"], "margs konar")
        XCTAssertEqual(CompoundAnalyzer.neverCompounds["annarstaðar"], "annars staðar")
        XCTAssertEqual(CompoundAnalyzer.neverCompounds["niðrá"], "niður á")
    }

    // MARK: Wave 31 — modifier-chain depth knob

    func testThreeModifierChainNeedsTheRelaxedKnob() {
        // vinnu+vinnu+vinnu+fundinum: three modifiers — refused at the
        // shipped cap of 2, accepted at 3.
        let word = "vinnuvinnuvinnufundinum"
        let morphology = FakeMorphology(["fundinum"])
        XCTAssertFalse(
            makeCorrector(morphology: morphology, paradigms: makeParadigms())
                .correct(typed: word).typedWordIsValid,
            "default compoundMaxModifiers == 2 refuses a 3-modifier chain")
        var config = EngineConfig()
        config.compoundMaxModifiers = 3
        XCTAssertTrue(
            makeCorrector(morphology: morphology, paradigms: makeParadigms(), config: config)
                .correct(typed: word).typedWordIsValid,
            "compoundMaxModifiers = 3 accepts the 3-modifier chain")
    }

    // MARK: Wave 31 — linking-letter yield

    func testLinkingLetterRepairShapes() {
        // Insertion at the boundary (framhald|skóla + s).
        XCTAssertTrue(
            Corrector.isLinkingLetterRepair(
                typedChars: Array("framhaldskóla"), candidate: "framhaldsskóla",
                split: CompoundSplit(modifiers: ["framhald"], head: "skóla")))
        // Removal of the boundary-final letter (samferðar|fólki − r).
        XCTAssertTrue(
            Corrector.isLinkingLetterRepair(
                typedChars: Array("samferðarfólki"), candidate: "samferðafólki",
                split: CompoundSplit(modifiers: ["samferðar"], head: "fólki")))
        // Boundary-strict: kaffispjallið inserts -l- at position 10, not
        // at the accidental decomposition boundary (kaffis|pjalið).
        XCTAssertFalse(
            Corrector.isLinkingLetterRepair(
                typedChars: Array("kaffispjalið"), candidate: "kaffispjallið",
                split: CompoundSplit(modifiers: ["kaffis"], head: "pjalið")))
        // Letter-strict: only the bandstafir count.
        XCTAssertFalse(
            Corrector.isLinkingLetterRepair(
                typedChars: Array("framhaldskóla"), candidate: "framhaldxskóla",
                split: CompoundSplit(modifiers: ["framhald"], head: "skóla")))
    }

    func testLinkingYieldLetsTheAttestedRepairFire() {
        // framhald(neuter stem)+skóla decomposes -> protected; the is.lex-
        // attested "framhaldsskóla" is one boundary -s- away. With the
        // yield the ordinary rules fire; without it wave 22's protection
        // keeps the repair offer-only.
        func build(_ yieldEnabled: Bool) -> Corrector {
            var config = EngineConfig()
            config.compoundLinkingRepairYieldEnabled = yieldEnabled
            let paradigms = FakeParadigms()
            paradigms.addNoun(
                lemma: "framhald", genderCode: 2,
                forms: [("framhald", 0, false, false), ("framhald", 1, false, false)])
            let icelandic = DictLexicon(
                unigrams: [
                    "og": 2000, "að": 1800, "er": 1500,
                    "framhaldsskóla": 500,
                ])
            let inflection = InflectionStore()
            inflection.setModel(
                InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: [:])))
            let model = BlendedLanguageModel(
                icelandic: icelandic, english: Fixtures.english,
                morphology: FakeMorphology(["skóla"]), config: config,
                inflection: inflection)
            return Corrector(model: model, config: config)
        }
        let yielded = build(true).correct(typed: "framhaldskóla", pIcelandic: 0.9)
        XCTAssertTrue(
            yielded.suggestions.first?.text == "framhaldsskóla"
                && yielded.suggestions.first?.isAutocorrect == true,
            "yield fires the attested boundary repair, got \(yielded.suggestions)")
        let protected_ = build(false).correct(typed: "framhaldskóla", pIcelandic: 0.9)
        XCTAssertTrue(
            protected_.suggestions.contains { $0.text == "framhaldsskóla" },
            "repair stays offered with the yield off")
        XCTAssertFalse(
            protected_.suggestions.contains(where: \.isAutocorrect),
            "wave-22 protection stands with the yield off")
    }

    // MARK: Compound-head repair (Corrector step 5b)

    func testHeadRepairOffersTheCompound() {
        // "stökkleikanun" (m→n at the last key) is no compound — but with
        // the modifier "stökk" held fixed, edits1 of "leikanun" reaches the
        // bound suffix head "leikanum".
        let corrector = makeCorrector(
            morphology: FakeMorphology([]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "stökkleikanun")
        XCTAssertTrue(
            result.suggestions.contains { $0.text == "stökkleikanum" },
            "head repair must surface stökkleikanum, got \(result.suggestions.map(\.text))")
        XCTAssertFalse(
            result.suggestions.first(where: { $0.text == "stökkleikanum" })?.isAutocorrect
                ?? false,
            "unattested compound winners never auto-apply")
    }

    func testHeadRepairRespectsTheKnob() {
        var config = EngineConfig()
        config.compoundRepairEnabled = false
        config.compoundCompletionEnabled = false
        let corrector = makeCorrector(
            morphology: FakeMorphology([]), paradigms: makeParadigms(), config: config)
        let result = corrector.correct(typed: "stökkleikanun")
        XCTAssertFalse(result.suggestions.contains { $0.text == "stökkleikanum" })
    }

    // MARK: Protection semantics (the conservatism invariant)

    func testValidCompoundIsNeverAutoReplacedByAnAttestedRival() {
        // "stökkhesti" is a legal compound (stökk+hesti); "hesti" the
        // standalone is.lex word is one deletion away and attested — the
        // sacred rule (widened by wave 22) forbids the auto-replace.
        let corrector = makeCorrector(
            morphology: FakeMorphology(["hesti"]), paradigms: makeParadigms())
        let result = corrector.correct(typed: "stökkhesti")
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertFalse(
            result.suggestions.contains(where: \.isAutocorrect),
            "valid compound must never be auto-replaced, got \(result.suggestions)")
    }
}
