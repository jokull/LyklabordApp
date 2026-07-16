import XCTest

@testable import TypeEngine

/// Engine-side personal-learning semantics (M2): validity/protection,
/// suggestibility, ranking boost, tombstones, session-immediate overlay,
/// snapshot swaps and canonical-casing restoration.
final class PersonalVocabularyTests: XCTestCase {

    /// "kubbur"/"Miðeind" are OOV in the fixtures and in the fake BÍN.
    private func engine(
        personal: FakePersonal? = nil,
        config: EngineConfig = EngineConfig()
    ) -> TypeEngine {
        let engine = Fixtures.engine(config: config)
        if let personal {
            engine.setPersonalVocabulary(personal)
        }
        return engine
    }

    // MARK: - Validity / protection

    func testLearnedWordIsNeverAutocorrected() {
        let e = engine(personal: FakePersonal(words: ["kubbur": 8]))
        let bar = e.suggestions(context: "", currentWord: "kubbur")
        XCTAssertFalse(bar.contains { $0.isAutocorrect }, "learned word must stay untouched")
    }

    func testUserAddedWordWithCountOneIsProtected() {
        // User-added words surface with the count floor of 1.
        let e = engine(personal: FakePersonal(words: ["kubbur": 1]))
        let bar = e.suggestions(context: "", currentWord: "kubbur")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    func testWithoutPersonalSnapshotTheSameWordMayBeCorrected() {
        // Sanity: the protection really comes from the snapshot.
        let e = engine()
        XCTAssertFalse(e.isPersonalWord("kubbur"))
    }

    // MARK: - Suggestibility

    func testLearnedWordCompletesFromPrefix() {
        let e = engine(personal: FakePersonal(words: ["kubbur": 8]))
        let bar = e.suggestions(context: "", currentWord: "kubbu")
        XCTAssertTrue(bar.contains { $0.text == "kubbur" }, "bar: \(bar.map(\.text))")
    }

    func testTypoOfLearnedWordCorrectsToIt() {
        let e = engine(personal: FakePersonal(words: ["kubbur": 8]))
        // One substitution away (r→t on the last letter).
        let bar = e.suggestions(context: "", currentWord: "kubbut")
        XCTAssertEqual(bar.first?.text, "kubbur", "bar: \(bar.map(\.text))")
    }

    func testCanonicalCasingIsRestored() {
        // Surface forms are byte-exact in the store; the pipeline matches
        // case-insensitively and the bar shows the canonical surface when
        // correcting a typo ("mideind": accent-dropped d for ð).
        let e = engine(personal: FakePersonal(words: ["Miðeind": 6]))
        let bar = e.suggestions(context: "", currentWord: "mideind")
        XCTAssertTrue(bar.contains { $0.text == "Miðeind" }, "bar: \(bar.map(\.text))")
    }

    func testExactLowercaseOfPersonalWordIsSimplyValid() {
        // Typing the personal word in lowercase is typing a valid word: no
        // correction, no autocorrect — the engine offers nothing to change.
        let e = engine(personal: FakePersonal(words: ["Miðeind": 6]))
        let bar = e.suggestions(context: "", currentWord: "miðeind")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    // MARK: - Ranking boost

    func testHigherPersonalCountRanksHigher() {
        let low = engine(personal: FakePersonal(words: ["kubbur": 1]))
        let high = engine(personal: FakePersonal(words: ["kubbur": 200]))
        func rank(_ e: TypeEngine) -> Int? {
            e.suggestions(context: "", currentWord: "kubbu", limit: 5)
                .firstIndex { $0.text == "kubbur" }
        }
        let lowRank = rank(low)
        let highRank = rank(high)
        XCTAssertNotNil(lowRank)
        XCTAssertNotNil(highRank)
        XCTAssertLessThanOrEqual(highRank!, lowRank!)
    }

    func testPersonalBoostIsCapped() {
        var config = EngineConfig()
        config.personalBoostCap = 3.0
        let e = engine(personal: FakePersonal(words: ["kubbur": 1_000_000]), config: config)
        // Just exercises the cap path; the word must still be suggestible.
        let bar = e.suggestions(context: "", currentWord: "kubbu")
        XCTAssertTrue(bar.contains { $0.text == "kubbur" })
    }

    // MARK: - Prediction

    func testPersonalBigramContinuationOutranksBaseContinuation() {
        // Base fixture has "góðan dag" (50); the user's own habit is
        // "góðan kubbur" (10). The personal follower must rank ahead —
        // blended via the bigram boost, not hard-prepended.
        let e = engine(
            personal: FakePersonal(
                words: ["kubbur": 10],
                bigrams: ["góðan kubbur": 10]
            )
        )
        let bar = e.suggestions(context: "góðan ", currentWord: "")
        XCTAssertEqual(bar.first?.text, "kubbur", "bar: \(bar.map(\.text))")
        XCTAssertTrue(bar.contains { $0.text == "dag" }, "base continuation must remain")
    }

    func testUnlearnedPersonalBigramFollowerIsStillPredicted() {
        // Bigram evidence is pair-level: the follower need not be learned.
        let e = engine(personal: FakePersonal(bigrams: ["góðan kubbur": 10]))
        let bar = e.suggestions(context: "góðan ", currentWord: "", limit: 5)
        XCTAssertTrue(bar.contains { $0.text == "kubbur" }, "bar: \(bar.map(\.text))")
    }

    // MARK: - Tombstones

    func testTombstonedBaseWordIsNeverSuggested() {
        let e = engine(personal: FakePersonal(tombstones: ["hestur"]))
        let bar = e.suggestions(context: "", currentWord: "hestu", limit: 5)
        XCTAssertFalse(bar.contains { $0.text == "hestur" }, "bar: \(bar.map(\.text))")
    }

    func testTombstonedWordIsNeverPredicted() {
        // "dag" follows "góðan" in the base bigrams; tombstoning it must
        // remove it from prediction despite base-lexicon presence.
        let e = engine(personal: FakePersonal(tombstones: ["dag"]))
        let bar = e.suggestions(context: "góðan ", currentWord: "", limit: 5)
        XCTAssertFalse(bar.contains { $0.text == "dag" }, "bar: \(bar.map(\.text))")
    }

    func testTombstonedWordTypedVerbatimIsNotCorrected() {
        // "grenn" would otherwise be a correction target (near "green");
        // tombstoned it is still never suggested — but typing it must not
        // trigger an auto-replacement either (deletion ≠ punishment).
        let e = engine(personal: FakePersonal(tombstones: ["grenn"]))
        let bar = e.suggestions(context: "", currentWord: "grenn")
        XCTAssertFalse(bar.contains { $0.isAutocorrect }, "bar: \(bar.map(\.text))")
        XCTAssertFalse(bar.contains { $0.text == "grenn" })
    }

    // MARK: - Session-immediate overlay

    func testSessionLearnedWordIsImmediatelyValidAndSuggestible() {
        let e = engine()
        e.learnSessionWord("kubbur")
        XCTAssertTrue(e.isPersonalWord("kubbur"))
        XCTAssertEqual(e.sessionLearnedWords, ["kubbur"])
        let typed = e.suggestions(context: "", currentWord: "kubbur")
        XCTAssertFalse(typed.contains { $0.isAutocorrect })
        let completed = e.suggestions(context: "", currentWord: "kubbu")
        XCTAssertTrue(completed.contains { $0.text == "kubbur" })
    }

    func testClearSessionVocabularyDropsTheOverlay() {
        let e = engine()
        e.learnSessionWord("kubbur")
        e.clearSessionVocabulary()
        XCTAssertFalse(e.isPersonalWord("kubbur"))
        XCTAssertTrue(e.sessionLearnedWords.isEmpty)
    }

    func testSessionOverlaySurvivesSnapshotSwap() {
        let e = engine()
        e.learnSessionWord("kubbur")
        e.setPersonalVocabulary(FakePersonal(words: ["annar": 3]))
        XCTAssertTrue(e.isPersonalWord("kubbur"))
        XCTAssertTrue(e.isPersonalWord("annar"))
    }

    // MARK: - Snapshot swap

    func testSnapshotSwapToNilRemovesPersonalWords() {
        let e = engine(personal: FakePersonal(words: ["kubbur": 8]))
        XCTAssertTrue(e.isPersonalWord("kubbur"))
        e.setPersonalVocabulary(nil)
        XCTAssertFalse(e.isPersonalWord("kubbur"))
        let bar = e.suggestions(context: "", currentWord: "kubbu", limit: 5)
        XCTAssertFalse(bar.contains { $0.text == "kubbur" })
    }

    func testSnapshotSwapReplacesWholesale() {
        let e = engine(personal: FakePersonal(words: ["kubbur": 8]))
        e.setPersonalVocabulary(FakePersonal(words: ["annar": 3]))
        XCTAssertFalse(e.isPersonalWord("kubbur"))
        XCTAssertTrue(e.isPersonalWord("annar"))
        XCTAssertEqual(e.personalSnapshotWords, ["annar"])
    }

    // MARK: - Lazy-fold shadows (wave 26, session 2026-07-16T22-45-30)

    /// Model-level harness: the fixtures' "hús" (400) is the dominant
    /// acute-restoration twin of the is.lex-absent skeleton "hus".
    private func blended(
        personal: FakePersonal?,
        config: EngineConfig = EngineConfig()
    ) -> BlendedLanguageModel {
        let store = PersonalStore()
        if let personal { store.setSnapshot(personal) }
        return BlendedLanguageModel(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            morphology: nil,
            config: config,
            personal: store
        )
    }

    func testImplicitAcuteFoldShadowLosesTheAutocorrectVeto() {
        let m = blended(personal: FakePersonal(words: ["hus": 3]))
        XCTAssertEqual(m.acuteFoldShadowTwin(of: "hus"), "hús")
        XCTAssertTrue(m.isPersonalValid("hus"), "shadows stay valid vocabulary")
        XCTAssertFalse(m.isPersonalProtected("hus"), "…but must not veto restoration")
        XCTAssertFalse(m.isValidTypedWord("hus"))
    }

    func testExplicitlyAddedShadowKeepsFullVeto() {
        let m = blended(personal: FakePersonal(words: ["hus": 3], explicit: ["hus"]))
        XCTAssertTrue(m.isPersonalProtected("hus"))
        XCTAssertTrue(m.isValidTypedWord("hus"))
    }

    func testSessionLearnedShadowKeepsFullVeto() {
        // The session overlay is the verbatim-tap / explicit-learn path —
        // a verbatim tap rejecting this very restoration must stick.
        let m = blended(personal: nil)
        m.personal.learnSession("hus")
        XCTAssertTrue(m.isPersonalProtected("hus"))
        XCTAssertTrue(m.isValidTypedWord("hus"))
    }

    func testShadowCountsBoostTheRestoredTwin() {
        // The lazy commits were commits OF the twin: their evidence rides
        // on "hús" (implicit skeleton only — explicit adds mean the user
        // wants the skeleton itself).
        let implicit = blended(personal: FakePersonal(words: ["hus": 3]))
        XCTAssertGreaterThan(implicit.personalBoost(of: "hús", previous: nil), 0)
        let explicitAdd = blended(
            personal: FakePersonal(words: ["hus": 3], explicit: ["hus"]))
        XCTAssertEqual(explicitAdd.personalBoost(of: "hús", previous: nil), 0)
    }

    func testTombstonedTwinGetsNoRedirectedBoost() {
        let m = blended(
            personal: FakePersonal(words: ["hus": 3], tombstones: ["hús"]))
        XCTAssertEqual(m.personalBoost(of: "hús", previous: nil), 0)
    }

    func testNonDominantTwinLeavesProtectionIntact() {
        // Both forms honestly attested at comparable frequency (the
        // vist/víst shape): no 10x dominance, no shadow, full protection.
        let icelandic = DictLexicon(
            unigrams: ["og": 2000, "að": 1800, "vist": 300, "víst": 900],
            bigrams: [:]
        )
        let store = PersonalStore()
        store.setSnapshot(FakePersonal(words: ["vist": 3]))
        let m = BlendedLanguageModel(
            icelandic: icelandic,
            english: Fixtures.english,
            morphology: nil,
            config: EngineConfig(),
            personal: store
        )
        XCTAssertNil(m.acuteFoldShadowTwin(of: "vist"))
        XCTAssertTrue(m.isPersonalProtected("vist"))
    }

    func testEnglishAttestedSkeletonStaysProtected() {
        // "for" is headline English; its commits were plausibly English —
        // the IS twin ("fór", middling) must not strip protection.
        let icelandic = DictLexicon(
            unigrams: ["og": 100_000, "að": 50_000, "fór": 500, "hús": 400],
            bigrams: [:]
        )
        let english = DictLexicon(
            unigrams: ["for": 100_000, "the": 90_000, "and": 50_000],
            bigrams: [:]
        )
        let store = PersonalStore()
        store.setSnapshot(FakePersonal(words: ["for": 5]))
        let m = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: nil,
            config: EngineConfig(),
            personal: store
        )
        XCTAssertNil(m.acuteFoldShadowTwin(of: "for"))
        XCTAssertTrue(m.isPersonalProtected("for"))
    }

    // MARK: - Autocap artifacts (wave 26, session 2026-07-16T22-45-30)

    func testLeadingCapSurfaceOfCommonWordKeepsPipelineCasing() {
        // "Hestur" learned via sentence-start autocaps must not title-case
        // the mid-word completion of lowercase typing.
        let e = engine(personal: FakePersonal(words: ["Hestur": 5]))
        let bar = e.suggestions(context: "og er", currentWord: "hestu", limit: 5)
        XCTAssertTrue(bar.contains { $0.text == "hestur" }, "bar: \(bar.map(\.text))")
        XCTAssertFalse(bar.contains { $0.text == "Hestur" }, "bar: \(bar.map(\.text))")
    }

    func testLeadingCapSurfaceOfRareWordIsStillRestored() {
        // Genuine proper nouns ("Miðeind": lowercase OOV in the fixtures)
        // keep their learned capitalization.
        let e = engine(personal: FakePersonal(words: ["Miðeind": 6]))
        let bar = e.suggestions(context: "og er", currentWord: "miðein", limit: 5)
        XCTAssertTrue(bar.contains { $0.text == "Miðeind" }, "bar: \(bar.map(\.text))")
    }

    func testAutocapArtifactLowercasedJudgments() {
        let e = engine()
        XCTAssertEqual(e.autocapArtifactLowercased("Hestur"), "hestur")
        XCTAssertNil(e.autocapArtifactLowercased("Miðeind"), "rare/OOV lowercase")
        XCTAssertNil(e.autocapArtifactLowercased("hestur"), "already lowercase")
        XCTAssertNil(e.autocapArtifactLowercased("HESTUR"), "not leading-cap-only")
        XCTAssertNil(e.autocapArtifactLowercased("I"), "single letters excluded")
    }

    // MARK: - Lane posterior isolation

    func testPersonalWordsContributeNoLaneEvidence() {
        // Deliberate v1 decision (see PersonalVocabulary docs): personal
        // attestation never moves the lane — evidence stays base-corpus-only.
        let e = engine(personal: FakePersonal(words: ["kubbur": 500]))
        XCTAssertEqual(e.laneDiagnostics(for: "kubbur").evidence, 0)
        let before = e.probabilityIcelandic
        e.confirmWord("kubbur")
        XCTAssertEqual(e.probabilityIcelandic, before, accuracy: 1e-9)
    }
}
