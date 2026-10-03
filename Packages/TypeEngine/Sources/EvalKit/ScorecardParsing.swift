import Foundation

/// Pure parsers for the sub-process reports `type-eval scorecard` consumes
/// from `type-repl`, plus the scenario-suite gate. Every parser returns nil
/// when the expected report shape is absent: the scorecard used to coerce a
/// missing report to `0`, which for the bench made "no latency measured"
/// read as "0 ms worst keystroke" (a pass), and for a scenario suite made
/// "no summary line" read as `0/0` (a pass once the other suites supplied a
/// non-zero total).
public enum ScorecardParsing {

    /// "<passed>/<total> scenarios passed" — the runner's summary line.
    public static func scenarioTotals(_ output: String) -> (passed: Int, total: Int)? {
        for line in output.split(separator: "\n") {
            guard line.contains("scenarios passed") else { continue }
            let head = line.split(separator: " ").first.map(String.init) ?? ""
            let parts = head.split(separator: "/").map(String.init)
            if parts.count == 2, let passed = Int(parts[0]), let total = Int(parts[1]) {
                return (passed, total)
            }
        }
        return nil
    }

    /// The bench's per-line gate labels. The worst keystroke is the max over
    /// ALL of them; a report missing any one of them is not a bench report
    /// and must not produce a number.
    public static let benchGateLabels = [
        "max", "first-5 max", "edits2 worst case", "beam worst case", "accent-naked IS",
        "governor-context",
    ]

    /// Worst keystroke in milliseconds across every "<label> <n> us" gate
    /// line, or nil when any gate label is missing or unparseable.
    public static func benchWorstMs(_ output: String) -> Double? {
        var found: [String: Double] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: " us") else { continue }
            let head = line[..<range.lowerBound]
            guard let token = head.split(whereSeparator: { $0 == " " }).last,
                let value = Double(token)
            else { continue }
            for label in benchGateLabels where line.hasPrefix(label + " ") {
                found[label] = value
            }
        }
        guard benchGateLabels.allSatisfy({ found[$0] != nil }) else { return nil }
        return found.values.max()! / 1000
    }

    /// "loaded artifacts in <ms> ms" from type-repl's stderr (decimal comma
    /// tolerated — the lab prints with the user locale).
    public static func artifactLoadMs(_ stderr: String) -> Double? {
        guard
            let line = stderr.split(separator: "\n").first(where: {
                $0.contains("loaded artifacts in")
            }), let marker = line.range(of: "loaded artifacts in ")
        else { return nil }
        let tail = line[marker.upperBound...]
        guard let token = tail.split(separator: " ").first else { return nil }
        return Double(token.replacingOccurrences(of: ",", with: "."))
    }

    /// "<bytes>  peak memory footprint" from `/usr/bin/time -l`.
    public static func peakFootprintBytes(_ stderr: String) -> Int? {
        for line in stderr.split(separator: "\n") where line.contains("peak memory footprint") {
            if let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                let bytes = Int(token)
            {
                return bytes
            }
        }
        return nil
    }
}

/// One scenario suite's run, as the scorecard observed it.
public struct ScenarioSuiteOutcome: Equatable, Sendable {
    public let name: String
    public let exitCode: Int32
    /// nil when the runner printed no summary line (crash, unreadable file).
    public let totals: (passed: Int, total: Int)?

    public init(name: String, exitCode: Int32, totals: (passed: Int, total: Int)?) {
        self.name = name
        self.exitCode = exitCode
        self.totals = totals
    }

    public static func == (lhs: ScenarioSuiteOutcome, rhs: ScenarioSuiteOutcome) -> Bool {
        lhs.name == rhs.name && lhs.exitCode == rhs.exitCode
            && lhs.totals?.passed == rhs.totals?.passed && lhs.totals?.total == rhs.totals?.total
    }
}

public struct ScenarioGateResult: Equatable, Sendable {
    public let pass: Bool
    public let passed: Int
    public let total: Int
    public let failures: [String]
}

public enum ScorecardGates {
    /// `scenarioPass`: EVERY suite must exist, run to exit 0, print a summary,
    /// contain at least one scenario, and pass all of them. The old gate
    /// summed totals across suites and only required the SUM to be positive,
    /// so one suite reporting `0/0` (empty or comment-only file) passed.
    public static func scenarioGate(_ suites: [ScenarioSuiteOutcome]) -> ScenarioGateResult {
        var failures: [String] = []
        var passed = 0
        var total = 0
        if suites.isEmpty {
            failures.append("no scenario suites found")
        }
        for suite in suites {
            guard let totals = suite.totals else {
                failures.append("\(suite.name): runner printed no summary (exit \(suite.exitCode))")
                continue
            }
            passed += totals.passed
            total += totals.total
            if totals.total == 0 {
                failures.append("\(suite.name): suite contains no scenarios")
            }
            if suite.exitCode != 0 {
                failures.append("\(suite.name): runner exit \(suite.exitCode)")
            }
            if totals.passed != totals.total {
                failures.append("\(suite.name): \(totals.passed)/\(totals.total) passed")
            }
        }
        return ScenarioGateResult(
            pass: failures.isEmpty && total > 0, passed: passed, total: total, failures: failures)
    }
}

/// Where `swift build` puts things, derived from a built executable's path.
public enum BuildLayout {
    /// The SwiftPM scratch root that owns a binary at `<scratch>/<config>/x`:
    /// the nearest ancestor containing `workspace-state.json`. The path must
    /// be used UNRESOLVED — `<scratch>/release` is a symlink into
    /// `<scratch>/out/Products/Release` (or `<scratch>/<triple>/release`),
    /// and resolving it first lands on a nested directory that also carries a
    /// workspace-state.json, so a `--scratch-path` derived from it builds
    /// into the wrong tree while the caller keeps running the old binary.
    public static func scratchRoot(
        forBinaryAt binary: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        var dir = binary.deletingLastPathComponent()
        for _ in 0..<8 {
            if fileExists(dir.appendingPathComponent("workspace-state.json").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// `release` or `debug` from the binary's (unresolved) directory name,
    /// case-insensitively — SwiftBuild spells the resolved target `Release`.
    public static func configuration(forBinaryAt binary: URL) -> String {
        binary.deletingLastPathComponent().lastPathComponent.lowercased() == "release"
            ? "release" : "debug"
    }
}
