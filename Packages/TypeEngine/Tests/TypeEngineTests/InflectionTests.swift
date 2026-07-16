import LemmaCore
import XCTest

@testable import TypeEngine

/// Inflection intelligence, Stage B (PLAN.md "Inflection intelligence"):
/// governors model loading, the λ_morph completion backoff + its exact-bigram
/// override, wrong-form offers (offer-only, HARD), inflection-aware
/// prediction, and the personal lemma lift.
final class InflectionTests: XCTestCase {

    // MARK: - Fixtures

    /// hestur paradigm (singular slice) + competitors, in a small Icelandic
    /// lexicon. Frequencies deliberately favor the nominative so any
    /// dative/genitive win must come from the morph term.
    private func makeFixture(
        bigrams: [String: UInt32] = [:],
        governors: [String: GovernorsModel.Governor]? = nil,
        config: EngineConfig = EngineConfig()
    ) -> (engine: TypeEngine, paradigms: FakeParadigms, morphology: FakeMorphology) {
        let icelandic = DictLexicon(
            unigrams: [
                "og": 2000, "að": 1800, "er": 1500,
                "frá": 900, "til": 900, "um": 900,
                "hestur": 500, "hesti": 150, "hests": 40, "hest": 80,
                "hesturinn": 100, "hestar": 90, "hestum": 30, "hesta": 20,
                "veður": 200,
            ],
            bigrams: bigrams
        )
        let english = DictLexicon(unigrams: [
            "the": 2000, "and": 1500, "with": 900, "weekend": 300, "weekends": 100,
        ])
        let paradigms = FakeParadigms()
        paradigms.addNoun(
            lemma: "hestur",
            forms: [
                ("hestur", 0, false, false),
                ("hest", 1, false, false),
                ("hesti", 2, false, false),
                ("hests", 3, false, false),
                ("hesturinn", 0, false, true),
                ("hestar", 0, true, false),
                ("hesta", 1, true, false),
                ("hesta", 3, true, false),  // þf/ef syncretism, like the real artifact
                ("hestum", 2, true, false),
            ]
        )
        let morphology = FakeMorphology([
            "hestur", "hest", "hesti", "hests", "hesturinn", "hestar", "hesta", "hestum",
        ])
        let engine = TypeEngine(
            icelandic: icelandic,
            english: english,
            morphologyProvider: morphology,
            config: config
        )
        // Noun-slot marginals (caseCode | plural<<2 | definite<<3): the
        // singular-indefinite slot of the dominant case carries most of
        // its mass, like the real artifact ("frá": no:þgf:et:ngr 0.339 of
        // þgf 0.675).
        func slots(_ entries: [Int: Double]) -> [Double] {
            var out = [Double](repeating: 0, count: 16)
            for (slot, p) in entries { out[slot] = p }
            return out
        }
        let table =
            governors
            ?? [
                // frá: dative-dominant (the real artifact: þgf 0.675)
                "frá": .init(
                    mass: 5000,
                    caseProbabilities: [0.10, 0.15, 0.68, 0.07],
                    caseEntropyRatio: 0.7,
                    nounBundleProbabilities: slots([0: 0.10, 1: 0.15, 2: 0.53, 6: 0.15, 3: 0.07])
                ),
                // til: genitive-dominant
                "til": .init(
                    mass: 5000,
                    caseProbabilities: [0.09, 0.14, 0.07, 0.70],
                    caseEntropyRatio: 0.66,
                    nounBundleProbabilities: slots([0: 0.09, 1: 0.14, 2: 0.07, 3: 0.55, 7: 0.15])
                ),
                // um: accusative-dominant
                "um": .init(
                    mass: 5000,
                    caseProbabilities: [0.34, 0.46, 0.14, 0.06],
                    caseEntropyRatio: 0.84,
                    nounBundleProbabilities: slots([0: 0.34, 1: 0.40, 5: 0.06, 2: 0.14, 3: 0.06])
                ),
            ]
        engine.setInflection(
            InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: table))
        )
        return (engine, paradigms, morphology)
    }

    private func topTexts(
        _ engine: TypeEngine, context: String, word: String, limit: Int = 4
    ) -> [String] {
        engine.suggestions(context: context, currentWord: word, limit: limit).map(\.text)
    }

    // MARK: - Completion re-ranking (the headline)

    func testGovernorBackoffReordersCompletions() {
        let (engine, _, _) = makeFixture()
        // "frá hest|": dative "hesti" (freq 150) must outrank nominative
        // "hestur" (freq 500) via the morph backoff.
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hesti")
        // "til hest|": genitive "hests" leads.
        XCTAssertEqual(topTexts(engine, context: "til ", word: "hest").first, "hests")
        // "um hest|": typed "hest" is already the accusative — the corrector
        // never suggests the typed word itself, and the wrong-form offer
        // must not fire; the dative/genitive must not lead either.
        let um = topTexts(engine, context: "um ", word: "hest")
        XCTAssertNotEqual(um.first, "hesti")
        XCTAssertNotEqual(um.first, "hests")
    }

    func testNoGovernorContextIsFrequencyOnly() {
        let (engine, _, _) = makeFixture()
        // "veður hest|": previous word is not a governor — frequency wins.
        XCTAssertEqual(topTexts(engine, context: "veður ", word: "hest").first, "hestur")
        // No context at all.
        XCTAssertEqual(topTexts(engine, context: "", word: "hest").first, "hestur")
    }

    func testWithoutInflectionModelIsFrequencyOnly() {
        let (engine, _, _) = makeFixture()
        engine.setInflection(nil)
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hestur")
    }

    func testExactBigramEvidenceOverridesBackoff() {
        // "frá hestur" attested as a bigram: the attested reading skips the
        // morph term AND carries the bigram MLE — it must beat the
        // backoff-boosted dative.
        let (engine, _, _) = makeFixture(bigrams: ["frá hestur": 400])
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hestur")
    }

    func testMassGateDisablesThinGovernors() {
        var config = EngineConfig()
        config.morphMinGovernorMass = 10_000  // above the fixture's 5000
        let (engine, _, _) = makeFixture(config: config)
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hestur")
    }

    func testLaneGateKeepsEnglishTypingUntouched() {
        let (engine, _, _) = makeFixture()
        // Drive the posterior to the English floor; the IS-lane gate
        // (morphBackoffMinPosterior) must disable the backoff even though
        // "frá" is a governor.
        for _ in 0..<6 { engine.confirmWord("the") }
        XCTAssertLessThan(engine.probabilityIcelandic, 0.5)
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hestur")
    }

    func testEnglishSlettaAfterGovernorUntouched() {
        let (engine, _, _) = makeFixture()
        // "um weekend": the EN word has no noun/adjective analysis — fit 0,
        // no decoration, no correction; typed word stays valid.
        let bar = engine.suggestions(context: "um ", currentWord: "weekend", limit: 4)
        XCTAssertFalse(bar.contains(where: \.isAutocorrect))
        XCTAssertEqual(bar.first?.text, "weekends")  // plain completion, undecorated
    }

    func testMorphologyCaseFallbackWhenParadigmsLacksForm() {
        let (engine, paradigms, morphology) = makeFixture()
        // Simulate a rare form outside the frequency-filtered paradigms:
        // remove hesti's paradigm analyses; lemmatizeWithMorph still knows
        // its case.
        paradigms.analysesByForm["hesti"] = nil
        morphology.cases["hesti"] = ["þgf"]
        XCTAssertEqual(topTexts(engine, context: "frá ", word: "hest").first, "hesti")
    }

    // MARK: - Wrong-form offers (offer-only, HARD)

    func testWrongFormOfferAfterGovernor() {
        let (engine, _, _) = makeFixture()
        // "frá hestur|": typed word VALID; the dative sibling is offered in
        // the bar and nothing may auto-apply — one valid form of a lemma is
        // never auto-replaced by another (absolute rule).
        let bar = engine.suggestions(context: "frá ", currentWord: "hestur", limit: 4)
        XCTAssertTrue(bar.map(\.text).contains("hesti"), "expected hesti offered, got \(bar.map(\.text))")
        XCTAssertFalse(bar.contains(where: \.isAutocorrect))
    }

    func testWrongFormOfferKeepsAgreementAxes() {
        // Plural typed form swaps only the case: "frá hestar" → "hestum"
        // (never the singular "hesti" — number is an agreement axis the
        // offer must hold fixed).
        let (engine, _, _) = makeFixture()
        let bar = engine.suggestions(context: "frá ", currentWord: "hestar", limit: 4)
        XCTAssertEqual(bar.first?.text, "hestum", "got \(bar.map(\.text))")
        XCTAssertFalse(bar.contains(where: \.isAutocorrect))
    }

    func testNoOfferWhenTypedFormFitsGovernor() {
        let (engine, _, _) = makeFixture()
        // "um hest": hest already carries the accusative um wants — no
        // wrong-form offer may lead the bar, and nothing auto-applies.
        // (Oblique forms may still appear as ordinary ranked candidates.)
        let bar = engine.suggestions(context: "um ", currentWord: "hest", limit: 4)
        XCTAssertNotEqual(bar.first?.text, "hesti")
        XCTAssertNotEqual(bar.first?.text, "hests")
        XCTAssertFalse(bar.contains(where: \.isAutocorrect))
    }

    func testNoOfferWhenTypedBigramIsAttested() {
        // Grammar-offer precision: a corpus-attested (governor, word) pair
        // must never trigger a "correction" offer. The typed word has a
        // cheap in-lexicon completion (hesturinn), so "hesti" can only
        // enter this bar through the offer machinery — its absence IS the
        // suppression.
        let (engine, _, _) = makeFixture(bigrams: ["frá hestur": 400])
        let bar = engine.suggestions(context: "frá ", currentWord: "hestur", limit: 4)
        XCTAssertFalse(bar.map(\.text).contains("hesti"), "got \(bar.map(\.text))")
    }

    func testOfferedSiblingRespectsTombstones() {
        let (engine, _, _) = makeFixture()
        var personal = FakePersonal()
        personal.tombstones = ["hesti"]
        engine.setPersonalVocabulary(personal)
        let bar = engine.suggestions(context: "frá ", currentWord: "hestur", limit: 4)
        XCTAssertFalse(bar.map(\.text).contains("hesti"))
    }

    // MARK: - Prediction

    func testPredictionAfterGovernorBoostsExpectedCase() {
        let (engine, _, _) = makeFixture()
        // No bigram followers exist for "frá" — the pool degrades to top
        // unigrams, where the morph term must rank the dative above the
        // (much more frequent) nominative.
        let predictions = engine.suggestions(context: "frá ", currentWord: "", limit: 20)
            .map(\.text)
        let hestiIndex = predictions.firstIndex(of: "hesti")
        let hesturIndex = predictions.firstIndex(of: "hestur")
        XCTAssertNotNil(hestiIndex, "got \(predictions)")
        XCTAssertNotNil(hesturIndex, "got \(predictions)")
        XCTAssertLessThan(hestiIndex!, hesturIndex!)
    }

    func testPredictionBigramFollowersKeepBigramRanking() {
        // An attested follower in a "wrong" case must not be displaced by
        // the backoff (it skips the morph term by the backoff rule).
        let (engine, _, _) = makeFixture(bigrams: ["frá hestur": 400])
        let predictions = engine.suggestions(context: "frá ", currentWord: "", limit: 4)
            .map(\.text)
        XCTAssertEqual(predictions.first, "hestur")
    }

    // MARK: - Personal lemma lift

    /// Fixture where the learned form's siblings compete with a slightly
    /// more frequent unrelated word, so the lift is the deciding factor.
    private func makeLiftFixture() -> (
        engine: TypeEngine, paradigms: FakeParadigms, morphology: FakeMorphology
    ) {
        let icelandic = DictLexicon(unigrams: [
            "og": 2000, "að": 1800, "er": 1500,
            "jökull": 50, "jökuls": 10, "jökli": 8,
            "jökup": 30,  // unrelated competitor, more frequent than the siblings
            "á": 900, "ánni": 40, "ánur": 60,
        ])
        let english = DictLexicon(unigrams: ["the": 2000, "and": 1500])
        let paradigms = FakeParadigms()
        paradigms.addNoun(
            lemma: "jökull",
            forms: [
                ("jökull", 0, false, false),
                ("jökul", 1, false, false),
                ("jökli", 2, false, false),
                ("jökuls", 3, false, false),
            ]
        )
        paradigms.addNoun(
            lemma: "á",
            genderCode: 1,
            forms: [
                ("á", 0, false, false),
                ("ánni", 2, false, true),
            ]
        )
        let morphology = FakeMorphology(["jökull", "jökuls", "jökli", "á", "ánni"])
        morphology.lemmas = [
            "jökull": ["jökull"],  // unambiguous — lifts
            "á": ["á", "eiga"],  // ambiguous — never lifts
        ]
        let engine = TypeEngine(
            icelandic: icelandic, english: english, morphologyProvider: morphology)
        engine.setInflection(
            InflectionModel(paradigms: paradigms, governors: GovernorsModel(table: [:]))
        )
        return (engine, paradigms, morphology)
    }

    func testUnambiguousLearnedFormLiftsParadigmSiblings() {
        let (engine, _, _) = makeLiftFixture()
        // Baseline: the unrelated competitor outranks the rare sibling.
        XCTAssertEqual(topTexts(engine, context: "", word: "jök").first, "jökup")
        engine.learnSessionWord("jökull")
        // Lifted: the genitive sibling now outranks the competitor; the
        // learned form itself (full personal boost) outranks the sibling —
        // the lift is strictly smaller than the learned form's own boost.
        let lifted = topTexts(engine, context: "", word: "jök", limit: 6)
        let jokull = lifted.firstIndex(of: "jökull")
        let jokuls = lifted.firstIndex(of: "jökuls")
        let jokup = lifted.firstIndex(of: "jökup")
        XCTAssertNotNil(jokull)
        XCTAssertNotNil(jokuls)
        XCTAssertLessThan(jokull!, jokuls!, "learned form must outrank its lifted sibling")
        if let jokup {
            XCTAssertLessThan(jokuls!, jokup, "lifted sibling must outrank the competitor")
        }
    }

    func testAmbiguousLearnedFormNeverLifts() {
        let (engine, _, _) = makeLiftFixture()
        func ranks() -> (anur: Int?, anni: Int?) {
            let texts = topTexts(engine, context: "", word: "án", limit: 6)
            return (texts.firstIndex(of: "ánur"), texts.firstIndex(of: "ánni"))
        }
        let before = ranks()
        XCTAssertLessThan(before.anur!, before.anni!)
        engine.learnSessionWord("á")
        // "á" is lemma-ambiguous (á | eiga): its paradigm sibling "ánni"
        // must NOT be lifted past the more frequent unrelated "ánur"
        // (the learned "á" itself may of course enter the bar).
        let after = ranks()
        XCTAssertLessThan(after.anur!, after.anni!)
    }

    func testAmbiguousSiblingNeverLifted() {
        let (engine, paradigms, _) = makeLiftFixture()
        // Make "jökuls" attribute to TWO lemmas: sibling-side ambiguity.
        paradigms.analysesByForm["jökuls", default: []].append(
            ParadigmAnalysis(
                lemma: "jökulsher", pos: .noun, genderCode: 0,
                bundle: .noun(caseCode: 0))
        )
        engine.learnSessionWord("jökull")  // rebuilds the lift
        let lifted = topTexts(engine, context: "", word: "jök", limit: 6)
        let jokuls = lifted.firstIndex(of: "jökuls")
        let jokup = lifted.firstIndex(of: "jökup")
        if let jokuls, let jokup {
            XCTAssertGreaterThan(jokuls, jokup, "ambiguous sibling must not be lifted")
        }
    }

    func testClearingSessionRetiresLift() {
        let (engine, _, _) = makeLiftFixture()
        engine.learnSessionWord("jökull")
        engine.clearSessionVocabulary()
        XCTAssertEqual(topTexts(engine, context: "", word: "jök").first, "jökup")
    }

    // MARK: - GovernorsModel parsing

    func testGovernorsModelParsesFixtureJSON() throws {
        let json = """
            {"meta":{"version":1,"governor_count":2},
             "governors":{
               "frá":{"mass":1000.0,
                      "case_distribution":{"þgf":0.9,"þf":0.05,"nf":0.03,"ef":0.02},
                      "case_entropy_ratio":0.3,
                      "bundle_distribution":{"no:þgf:et:ngr":0.5,"no:þgf:et:gr":0.4}},
               "til":{"mass":500.0,
                      "case_distribution":{"ef":1.0},
                      "case_entropy_ratio":0.0,
                      "bundle_distribution":{}}}}
            """
        let model = try GovernorsModel(jsonData: Data(json.utf8))
        XCTAssertEqual(model.governorCount, 2)
        let fra = try XCTUnwrap(model.governor(of: "frá"))
        XCTAssertEqual(fra.mass, 1000)
        XCTAssertEqual(fra.caseProbabilities[2], 0.9, accuracy: 1e-9)  // þgf
        XCTAssertEqual(fra.caseProbabilities[0], 0.03, accuracy: 1e-9)  // nf
        XCTAssertEqual(fra.caseEntropyRatio, 0.3, accuracy: 1e-9)
        let til = try XCTUnwrap(model.governor(of: "til"))
        XCTAssertEqual(til.caseProbabilities[3], 1.0, accuracy: 1e-9)  // ef
        XCTAssertNil(model.governor(of: "hestur"))
    }

    func testGovernorsModelRejectsGarbage() {
        XCTAssertThrowsError(try GovernorsModel(jsonData: Data("not json".utf8)))
        XCTAssertThrowsError(try GovernorsModel(jsonData: Data("{\"meta\":{}}".utf8)))
        XCTAssertThrowsError(
            try GovernorsModel(gzippedJSONContentsOf: URL(fileURLWithPath: "/nonexistent"))
        )
    }

    // MARK: - Real artifact (skipped when the checkout has no data dir)

    private static func realArtifactURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url.appendingPathComponent("data/is/\(name)")
    }

    private func requireRealGovernors() throws -> GovernorsModel {
        let url = Self.realArtifactURL("governors.json.gz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/is/governors.json.gz not present in this checkout")
        }
        return try GovernorsModel(gzippedJSONContentsOf: url)
    }

    func testRealGovernorsKnownPrepositionSignatures() throws {
        let model = try requireRealGovernors()
        XCTAssertGreaterThan(model.governorCount, 10_000)

        func dominantCase(_ word: String) throws -> (code: Int, p: Double) {
            let governor = try XCTUnwrap(model.governor(of: word), "\(word) missing")
            let best = governor.caseProbabilities.enumerated().max(by: { $0.element < $1.element })!
            return (best.offset, best.element)
        }
        // The Stage-A sanity assertions, now against the loaded Swift model:
        // P(þgf | frá), P(ef | til), P(þf | um) all dominant.
        let fra = try dominantCase("frá")
        XCTAssertEqual(ParadigmBundle.caseNames[fra.code], "þgf")
        XCTAssertGreaterThan(fra.p, 0.5)
        let til = try dominantCase("til")
        XCTAssertEqual(ParadigmBundle.caseNames[til.code], "ef")
        XCTAssertGreaterThan(til.p, 0.5)
        let um = try dominantCase("um")
        XCTAssertEqual(ParadigmBundle.caseNames[um.code], "þf")

        // Split-case governors: á and með keep a real þf/þgf split.
        for word in ["á", "með"] {
            let governor = try XCTUnwrap(model.governor(of: word))
            XCTAssertGreaterThan(governor.caseProbabilities[1], 0.05, "\(word) þf share")
            XCTAssertGreaterThan(governor.caseProbabilities[2], 0.05, "\(word) þgf share")
        }
    }

    func testRealGovernorsLoadFootprintIsCompact() throws {
        let url = Self.realArtifactURL("governors.json.gz")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("data/is/governors.json.gz not present in this checkout")
        }
        let before = Self.memoryFootprint()
        let model = try GovernorsModel(gzippedJSONContentsOf: url)
        XCTAssertGreaterThan(model.governorCount, 10_000)
        let after = Self.memoryFootprint()
        let delta = Double(after - min(after, before)) / 1024 / 1024
        print("[GovernorsModel memory] footprint delta after load: \(String(format: "%.2f", delta)) MB")
        // The retained table is ~2MB; the ~14MB decompression buffer must
        // NOT stay dirty (mmap+munmap discipline — see withGunzipped).
        // Generous slack for allocator noise.
        XCTAssertLessThan(delta, 8, "governors load must not retain the decompression buffer")
    }

    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
