import XCTest

@testable import TypeEngine

final class CandidateProviderTests: XCTestCase {

    func testAdmissionPoolKeepsFirstCostAndUnionsProvenance() {
        var pool = CandidateAdmissionPool(captureProvenance: true)
        XCTAssertTrue(
            pool.admit(
                "the",
                cost: ChannelCost(total: 2, errorOps: 1, restorationOps: 0),
                provider: .shortBeam))

        var duplicateCostWasEvaluated = false
        XCTAssertFalse(
            pool.admit(
                "the",
                cost: {
                    duplicateCostWasEvaluated = true
                    return ChannelCost(total: 99, errorOps: 9, restorationOps: 9)
                }(),
                provider: .edits1Residue))

        XCTAssertFalse(duplicateCostWasEvaluated)
        XCTAssertEqual(pool["the"]?.total, 2)
        XCTAssertEqual(pool["the"]?.errorOps, 1)
        XCTAssertTrue(pool.providers(for: "the").contains(.shortBeam))
        XCTAssertTrue(pool.providers(for: "the").contains(.edits1Residue))
    }

    func testTraceNamesProviderAndAdditiveScoreSignals() throws {
        let trace = CorrectionTrace()
        let corrector = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english)

        _ = corrector.correct(typed: "teh", trace: trace)

        let candidate = try XCTUnwrap(trace.candidates.first { $0.word == "the" })
        XCTAssertTrue(candidate.providers.contains(.shortBeam))
        XCTAssertEqual(
            candidate.channelContribution
                + candidate.languageContribution
                + candidate.morphologyContribution
                + candidate.compoundContribution
                + candidate.precedenceContribution,
            candidate.score,
            accuracy: 1e-12)
        XCTAssertNotNil(candidate.unigramLanguageScore)
        XCTAssertNotNil(candidate.contextEvidence)
        XCTAssertTrue(trace.report.contains("via=short-beam"))
        XCTAssertTrue(trace.report.contains("signals channel="))
        XCTAssertGreaterThan(
            trace.providerSummaries.first { $0.provider == .shortBeam }?
                .admittedCandidateCount ?? 0,
            0)
    }

    func testEmptyAblationIsSuggestionIdentical() {
        var explicit = EngineConfig()
        explicit.disabledCandidateProviders = []
        let baseline = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english)
        let explicitEmpty = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            config: explicit)

        for typed in ["teh", "hestr", "hest", "vexur", "islenska"] {
            XCTAssertEqual(
                baseline.correct(typed: typed).suggestions,
                explicitEmpty.correct(typed: typed).suggestions,
                "empty provider mask changed \(typed)")
        }
    }

    func testProviderAblationRemovesOnlyThatCandidateSource() {
        var config = EngineConfig()
        config.disabledCandidateProviders = [.shortBeam]
        let corrector = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            config: config)

        let repair = corrector.correct(typed: "teh")
        XCTAssertFalse(repair.suggestions.contains { $0.text == "the" })

        let completion = corrector.correct(typed: "hest")
        XCTAssertTrue(completion.suggestions.contains { $0.text == "hestur" })
    }

    func testSplitCarriesProvenanceAndCanBeAblated() throws {
        let trace = CorrectionTrace()
        let baseline = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english)
        _ = baseline.correct(typed: "gottnveður", limit: 8, trace: trace)

        let split = try XCTUnwrap(trace.candidates.first { $0.word == "gott veður" })
        XCTAssertEqual(split.providers, [.spaceMissSplit])
        XCTAssertGreaterThan(
            trace.providerSummaries.first { $0.provider == .spaceMissSplit }?
                .admittedCandidateCount ?? 0,
            0)

        var config = EngineConfig()
        config.disabledCandidateProviders = [.spaceMissSplit]
        let ablated = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english,
            config: config)
            .correct(typed: "gottnveður", limit: 8)
        XCTAssertFalse(ablated.suggestions.contains { $0.text.contains(" ") })
    }

    func testAblationFamiliesAreDisjointAndCoverEveryProvider() {
        var union: CandidateProviderSet = []
        for family in CandidateProviderFamily.allCases {
            XCTAssertTrue(
                union.intersection(family.providers).isEmpty,
                "provider appears in more than one family: \(family.rawValue)")
            union.formUnion(family.providers)
        }
        XCTAssertEqual(union, .all)
    }
}
