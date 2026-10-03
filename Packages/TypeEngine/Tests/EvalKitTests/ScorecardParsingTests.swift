import XCTest

@testable import EvalKit

/// The scorecard's sub-process parsers and the scenario-suite gate. The
/// pre-audit versions coerced a missing report to 0 and summed suite totals,
/// so an unparseable bench report or an empty suite could pass.
final class ScorecardParsingTests: XCTestCase {

    // MARK: - Scenario summary

    func testScenarioTotalsParsesSummaryLine() {
        let out = "  ok    x\n\n161/161 scenarios passed\n"
        XCTAssertEqual(ScorecardParsing.scenarioTotals(out)?.passed, 161)
        XCTAssertEqual(ScorecardParsing.scenarioTotals(out)?.total, 161)
    }

    func testScenarioTotalsIsNilWithoutSummary() {
        XCTAssertNil(ScorecardParsing.scenarioTotals(""))
        XCTAssertNil(ScorecardParsing.scenarioTotals("Fatal error: boom\n"))
        XCTAssertNil(ScorecardParsing.scenarioTotals("x/y scenarios passed\n"))
    }

    // MARK: - Bench

    private let benchReport = """
        type-repl bench — 251 keystrokes, limit 3
          warmUp()           4.2 ms
          p50                    1123 us
          p95                    3004 us
          max                    3997 us
          first-5 max            1328 us
          edits2 worst case      6798 us  (slowest keystroke while typing "brgha-þwkkt")
          beam worst case        9352 us  (slowest keystroke while typing "…á koetip")
          accent-naked IS        4739 us  (slowest; p50 1143 us while typing "flytjum i bud …")
          governor-context       3573 us  (slowest; p50 1451 us while typing after frá/til/um governors)
          phys_footprint         11.4 MB  (resident 107.5 MB after bench, all artifacts loaded)
        """

    func testBenchWorstIsTheMaxOverEveryGateLine() throws {
        XCTAssertEqual(try XCTUnwrap(ScorecardParsing.benchWorstMs(benchReport)), 9.352, accuracy: 1e-9)
    }

    func testBenchWorstIsNilWhenAGateLineIsMissing() {
        let withoutBeam = benchReport.split(separator: "\n")
            .filter { !$0.contains("beam worst case") }.joined(separator: "\n")
        XCTAssertNil(ScorecardParsing.benchWorstMs(withoutBeam))
        XCTAssertNil(ScorecardParsing.benchWorstMs(""))
        XCTAssertNil(ScorecardParsing.benchWorstMs("no keystrokes measured\n"))
    }

    func testBenchWorstIsNilWhenUnitsChange() {
        // A report that switched to milliseconds must not parse as 0 us.
        let ms = benchReport.replacingOccurrences(of: " us", with: " ms")
        XCTAssertNil(ScorecardParsing.benchWorstMs(ms))
    }

    func testBenchFirstFiveLineIsIncludedInTheGate() throws {
        // The cold-after-warmUp keystrokes are part of the worst-line gate.
        let cold = benchReport.replacingOccurrences(
            of: "first-5 max            1328 us", with: "first-5 max           41000 us")
        XCTAssertEqual(try XCTUnwrap(ScorecardParsing.benchWorstMs(cold)), 41.0, accuracy: 1e-9)
    }

    // MARK: - Artifact probe

    func testArtifactLoadMsAcceptsDecimalComma() throws {
        let err = "[type-repl] loaded artifacts in 146,9 ms (is: 242882 unigrams)\n"
        XCTAssertEqual(try XCTUnwrap(ScorecardParsing.artifactLoadMs(err)), 146.9, accuracy: 1e-9)
        XCTAssertNil(ScorecardParsing.artifactLoadMs("artifact-probe ready\n"))
    }

    func testPeakFootprintBytes() {
        let err = "        0.31 real         0.22 user         0.05 sys\n"
            + "            45678912  maximum resident set size\n"
            + "            41234567  peak memory footprint\n"
        XCTAssertEqual(ScorecardParsing.peakFootprintBytes(err), 41_234_567)
        XCTAssertNil(ScorecardParsing.peakFootprintBytes(""))
    }

    // MARK: - Scenario gate

    private func suite(_ name: String, _ passed: Int, _ total: Int, exit: Int32 = 0) -> ScenarioSuiteOutcome {
        ScenarioSuiteOutcome(name: name, exitCode: exit, totals: (passed, total))
    }

    func testAllSuitesPassing() {
        let gate = ScorecardGates.scenarioGate([suite("core", 161, 161), suite("touch", 11, 11)])
        XCTAssertTrue(gate.pass)
        XCTAssertEqual(gate.passed, 172)
        XCTAssertEqual(gate.total, 172)
        XCTAssertEqual(gate.failures, [])
    }

    func testEmptySuiteFailsEvenWhenOthersSupplyATotal() {
        // The old gate only required the SUM of totals to be positive.
        let gate = ScorecardGates.scenarioGate([suite("core", 161, 161), suite("ghost", 0, 0)])
        XCTAssertFalse(gate.pass)
        XCTAssertEqual(gate.failures, ["ghost: suite contains no scenarios"])
    }

    func testMissingSummaryFails() {
        let crashed = ScenarioSuiteOutcome(name: "core", exitCode: 139, totals: nil)
        let gate = ScorecardGates.scenarioGate([crashed])
        XCTAssertFalse(gate.pass)
        XCTAssertEqual(gate.failures, ["core: runner printed no summary (exit 139)"])
    }

    func testNonZeroExitFailsEvenWithMatchingTotals() {
        let gate = ScorecardGates.scenarioGate([suite("core", 161, 161, exit: 2)])
        XCTAssertFalse(gate.pass)
        XCTAssertEqual(gate.failures, ["core: runner exit 2"])
    }

    func testOneFailingScenarioFailsTheGate() {
        let gate = ScorecardGates.scenarioGate([suite("compounds", 21, 22, exit: 1)])
        XCTAssertFalse(gate.pass)
        XCTAssertEqual(gate.failures, ["compounds: runner exit 1", "compounds: 21/22 passed"])
    }

    func testNoSuitesFails() {
        let gate = ScorecardGates.scenarioGate([])
        XCTAssertFalse(gate.pass)
        XCTAssertEqual(gate.failures, ["no scenario suites found"])
    }
}

final class BuildLayoutTests: XCTestCase {
    func testScratchRootIsNearestAncestorWithWorkspaceState() {
        let present: Set<String> = [
            "/s/workspace-state.json", "/s/out/Products/workspace-state.json",
        ]
        let root = BuildLayout.scratchRoot(
            forBinaryAt: URL(fileURLWithPath: "/s/release/type-eval"),
            fileExists: { present.contains($0) })
        XCTAssertEqual(root?.path, "/s")
        // A RESOLVED path lands on the nested product directory — the bug.
        let nested = BuildLayout.scratchRoot(
            forBinaryAt: URL(fileURLWithPath: "/s/out/Products/Release/type-eval"),
            fileExists: { present.contains($0) })
        XCTAssertEqual(nested?.path, "/s/out/Products")
        XCTAssertNil(
            BuildLayout.scratchRoot(
                forBinaryAt: URL(fileURLWithPath: "/elsewhere/bin/type-eval"),
                fileExists: { _ in false }))
    }

    func testConfigurationIsCaseInsensitive() {
        XCTAssertEqual(BuildLayout.configuration(forBinaryAt: URL(fileURLWithPath: "/s/release/type-eval")), "release")
        XCTAssertEqual(BuildLayout.configuration(forBinaryAt: URL(fileURLWithPath: "/s/out/Products/Release/type-eval")), "release")
        XCTAssertEqual(BuildLayout.configuration(forBinaryAt: URL(fileURLWithPath: "/s/debug/type-eval")), "debug")
    }
}
