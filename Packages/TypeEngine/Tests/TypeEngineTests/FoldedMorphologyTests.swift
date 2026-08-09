import XCTest

@testable import TypeEngine

final class FoldedMorphologyTests: XCTestCase {
    private struct Repair {
        let typed: String
        let foldedKey: String
        let target: String
    }

    private let repairs = [
        Repair(
            typed: "afmælisosjir", foldedKey: "afmælisoskir", target: "afmælisóskir"),
        Repair(
            typed: "andlitsgarum", foldedKey: "andlitsharum", target: "andlitshárum"),
        Repair(
            typed: "annalatitarinn", foldedKey: "annalaritarinn", target: "annálaritarinn"),
        Repair(
            typed: "alnugavæða", foldedKey: "almugavæða", target: "almúgavæða"),
        Repair(
            typed: "afbrotanal", foldedKey: "afbrotamal", target: "afbrotamál"),
        Repair(
            typed: "andofshopyrinn", foldedKey: "andofshopurinn", target: "andófshópurinn"),
        Repair(
            typed: "felagsfunsur", foldedKey: "felagsfundur", target: "félagsfundur"),
    ]

    private func makeCorrector(
        repairs selected: [Repair]? = nil,
        configure: (inout EngineConfig) -> Void = { _ in }
    ) -> Corrector {
        let selected = selected ?? repairs
        let morphology = FakeMorphology(Set(selected.map(\.target)))
        for repair in selected {
            morphology.foldedForms[repair.foldedKey, default: []].append(repair.target)
        }
        var config = EngineConfig()
        // Isolate this provider: the production beam/repair passes must not
        // accidentally make these acceptance tests pass.
        config.disabledCandidateProviders = .all.subtracting([.foldedMorphology])
        configure(&config)
        return Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            morphology: morphology,
            config: config)
    }

    func testFoldedBinOneKeyRepairsAllArmSpacebarAtNeutralLane() {
        let corrector = makeCorrector()

        for repair in repairs {
            let result = corrector.correct(typed: repair.typed, pIcelandic: 0.5, limit: 8)
            XCTAssertEqual(
                result.suggestions.first?.text, repair.target,
                "wrong winner for \(repair.typed): \(result.suggestions.map(\.text))")
            XCTAssertEqual(
                result.suggestions.first?.isAutocorrect, true,
                "\(repair.typed) should arm spacebar for \(repair.target)")
            XCTAssertEqual(result.suggestions.first?.isRestoration, false)
        }
    }

    func testFoldedIntentBeatsPlainBinNeighborsAndArmsOnItsStructuredMargin() {
        let repair = repairs.first { $0.typed == "afbrotanal" }!
        let plainNeighbors = ["afbrotamal", "afbrotahal"]
        let morphology = FakeMorphology(Set([repair.target] + plainNeighbors))
        morphology.foldedForms[repair.foldedKey] = [repair.target]
        var config = EngineConfig()
        config.disabledCandidateProviders = .all.subtracting([
            .edits1Residue, .foldedMorphology,
        ])
        let corrector = Corrector(
            // A slight corpus advantage models the real artifact's
            // afbrotamál > BÍN-floor compound-neighbor separation: enough
            // to disambiguate the folded hit, deliberately below the generic
            // 1.15-nat error margin.
            icelandic: DictLexicon(unigrams: ["og": 2_000, repair.target: 3]),
            english: Fixtures.english,
            morphology: morphology,
            config: config)

        let result = corrector.correct(typed: repair.typed, pIcelandic: 0.5, limit: 8)
        XCTAssertEqual(
            result.suggestions.first?.text, repair.target,
            "folded intent should beat plain BÍN neighbors: \(result.suggestions.map(\.text))")
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
    }

    func testExactFoldedBinInputArmsWithoutAKeyboardError() {
        let repair = Repair(
            typed: "afmælisoskir", foldedKey: "afmælisoskir", target: "afmælisóskir")
        let result = makeCorrector(repairs: [repair]).correct(
            typed: repair.typed, pIcelandic: 0.5)

        XCTAssertEqual(result.suggestions.first?.text, repair.target)
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
        XCTAssertEqual(result.suggestions.first?.isRestoration, true)
    }

    func testUserCandidateFelagsfundurArmsSpacebar() {
        let repair = Repair(
            typed: "felagsfundur", foldedKey: "felagsfundur", target: "félagsfundur")
        let result = makeCorrector(repairs: [repair]).correct(
            typed: repair.typed, pIcelandic: 0.5)

        XCTAssertEqual(result.suggestions.first?.text, repair.target)
        XCTAssertEqual(result.suggestions.first?.isAutocorrect, true)
        XCTAssertEqual(result.suggestions.first?.isRestoration, true)
    }

    func testProviderCanBeAblatedIndependently() {
        let repair = repairs[0]
        let result = makeCorrector { config in
            config.disabledCandidateProviders = .all
        }.correct(typed: repair.typed, pIcelandic: 0.5, limit: 8)

        XCTAssertFalse(result.suggestions.contains { $0.text == repair.target })
    }

    func testLowIcelandicPosteriorOffersButDoesNotArm() {
        let repair = repairs[0]
        let result = makeCorrector(repairs: [repair]).correct(
            typed: repair.typed, pIcelandic: 0.49, limit: 8)

        XCTAssertEqual(result.suggestions.first?.text, repair.target)
        XCTAssertFalse(result.suggestions.first?.isAutocorrect ?? true)
    }

    func testActionSwitchOffersButDoesNotArm() {
        let repair = repairs[0]
        let result = makeCorrector(repairs: [repair]) { config in
            config.foldedMorphologyAutocorrectEnabled = false
        }.correct(typed: repair.typed, pIcelandic: 0.9, limit: 8)

        XCTAssertEqual(result.suggestions.first?.text, repair.target)
        XCTAssertFalse(result.suggestions.first?.isAutocorrect ?? true)
    }

    func testTwoKeyboardErrorsAreOutsideTheProviderCone() {
        let repair = Repair(
            typed: "afmælisodjir", foldedKey: "afmælisoskir", target: "afmælisóskir")
        let result = makeCorrector(repairs: [repair]).correct(
            typed: repair.typed, pIcelandic: 0.9, limit: 8)

        XCTAssertFalse(result.suggestions.contains { $0.text == repair.target })
    }

    func testValidSkeletonMayBeDisambiguatedButNeverBlindlyReplaced() {
        let target = "fór"
        let morphology = FakeMorphology([target])
        morphology.foldedForms["for"] = [target]
        var config = EngineConfig()
        config.foldedMorphologyMinLength = 3
        config.disabledCandidateProviders = .all.subtracting([.foldedMorphology])
        let corrector = Corrector(
            icelandic: DictLexicon(unigrams: ["for": 100]),
            english: Fixtures.english,
            morphology: morphology,
            config: config)

        let result = corrector.correct(typed: "for", pIcelandic: 0.5)
        XCTAssertTrue(result.typedWordIsValid)
        XCTAssertEqual(result.suggestions.first?.text, target)
        XCTAssertFalse(result.suggestions.first?.isAutocorrect ?? true)
    }

    func testTraceIdentifiesFoldedMorphologyEvidence() throws {
        let repair = repairs[0]
        let trace = CorrectionTrace()
        _ = makeCorrector(repairs: [repair]).correct(
            typed: repair.typed, pIcelandic: 0.5, limit: 8, trace: trace)

        let candidate = try XCTUnwrap(trace.candidates.first { $0.word == repair.target })
        XCTAssertTrue(candidate.providers.contains(.foldedMorphology))
        XCTAssertEqual(candidate.errorOps, 1)
        XCTAssertGreaterThanOrEqual(candidate.restorationOps, 1)
        XCTAssertTrue(trace.report.contains("folded-morphology-arming"))
    }
}
