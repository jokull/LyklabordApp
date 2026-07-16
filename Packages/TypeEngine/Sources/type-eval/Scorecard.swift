import EvalKit
import Foundation
import TypeEngine

// `type-eval scorecard [--heldout]` — the unified per-commit scorecard.
//
// Runs: micro-eval + corpus dev (+ REPORT-ONLY heldout with --heldout) +
// the scenario suites (via the type-repl binary) + the latency bench (also
// type-repl), assembles ONE deterministic JSON (timestamp = git HEAD commit
// time, commit = HEAD hash — no Date.now, so re-running on the same commit
// reproduces the line byte-for-byte), appends it to scores/history.jsonl,
// prints it to stdout, and exits non-zero if any hard gate fails.
//
// Hard gates (PLAN.md eval studio):
//   falseAutocorrect   micro-eval overall false-autocorrect count == 0
//   validWordSafety    micro-eval valid-word safety passes
//   benchWorstLineMs   type-repl bench worst keystroke < 30 ms
//   scenarioPass       every scenario in every suite passes (100%)

func runScorecardCommand(_ args: [String]) {
    let includeHeldout = args.contains("--heldout")
    // `--note <text>`: a short human annotation carried in the committed
    // history line (e.g. the wave the entry gates). Deterministic — the
    // caller supplies it, nothing wall-clock enters the JSON.
    var note: String?
    if let index = args.firstIndex(of: "--note"), index + 1 < args.count {
        note = args[index + 1]
    }

    guard let repoRoot = ArtifactLoader.repoRoot() else {
        stderr("cannot locate repo root")
        exit(2)
    }
    let packageDir = repoRoot.appendingPathComponent("Packages/TypeEngine")

    // --- Provenance -------------------------------------------------------
    let commit = git(["-C", repoRoot.path, "rev-parse", "HEAD"], default: "unknown")
    let timestamp = git(
        ["-C", repoRoot.path, "show", "-s", "--format=%cI", "HEAD"], default: "unknown")

    // --- Micro-eval -------------------------------------------------------
    stderr("running micro-eval…")
    let micro = runMicroEval(cases: loadCases(), config: ArtifactLoader.deterministicConfig())
    let falseAutocorrect = micro.overall.falseAutocorrect
    let validWordSafety = micro.validWordViolations.isEmpty

    // --- Corpus dev (+ optional heldout) ---------------------------------
    stderr("running corpus dev…")
    let engine: TypeEngine
    do {
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()
    let dev = CorpusEval.run(engine: engine, pairs: loadSplit("dev", repoRoot), split: "dev")
    printCorpusResult(dev)
    var heldout: CorpusResult?
    if includeHeldout {
        stderr("running corpus heldout (REPORT-ONLY)…")
        heldout = CorpusEval.run(
            engine: engine, pairs: loadSplit("heldout", repoRoot), split: "heldout")
        print("")
        printCorpusResult(heldout!, label: "corpus heldout [REPORT-ONLY]")
    }

    // --- Scenario suites + bench (type-repl) ------------------------------
    let repl = typeReplBinary(packageDir: packageDir)
    stderr("running scenario suites via \(repl.lastPathComponent)…")
    var scenarioPassed = 0
    var scenarioTotal = 0
    var scenarioOK = true
    for suite in ["core", "dogfood", "inflect", "touch"] {
        let file = packageDir.appendingPathComponent("Scenarios/\(suite).scenarios").path
        let (out, code) = run(repl.path, ["run", file], cwd: packageDir)
        let (passed, total) = parseScenarioTotals(out)
        scenarioPassed += passed
        scenarioTotal += total
        if code != 0 || passed != total { scenarioOK = false }
        stderr("  \(suite): \(passed)/\(total) (exit \(code))")
    }
    let scenarioPass = scenarioOK && scenarioTotal > 0 && scenarioPassed == scenarioTotal

    // Bench is wall-clock — a cold-cache first run can spike past the
    // ceiling (measured 48 ms once, ~4 ms steady). Retry once and take the
    // min worst so a transient blip doesn't fail the gate; a real regression
    // fails both. The MEASURED value stays out of the committed JSON (see
    // below) so the history line is reproducible.
    stderr("running bench…")
    var benchWorstMs = parseBenchWorstMs(run(repl.path, ["bench"], cwd: packageDir).out)
    if benchWorstMs >= 30 {
        let retry = parseBenchWorstMs(run(repl.path, ["bench"], cwd: packageDir).out)
        benchWorstMs = min(benchWorstMs, retry)
    }
    let benchPass = benchWorstMs < 30
    stderr(String(format: "  bench worst keystroke: %.2f ms (gate %@)", benchWorstMs, benchPass ? "pass" : "FAIL"))

    // --- Gates ------------------------------------------------------------
    // The committed `pass` reflects only the DETERMINISTIC gates so the
    // history line is reproducible given the commit. The latency gate is
    // enforced on the EXIT CODE (for CI) but its volatile measurement is not
    // recorded in the line — see scores/README.md.
    let deterministicPass = (falseAutocorrect == 0) && validWordSafety && scenarioPass
    let exitPass = deterministicPass && benchPass

    // --- JSON (deterministic given the commit) ----------------------------
    var json: [String: Any] = [
        "version": "v0",
        "commit": commit,
        "timestamp": timestamp,
        "corpus": corpusJSON(dev),
        "microEval": [
            "n": micro.overall.total,
            "top1": micro.overall.top1,
            "top3": micro.overall.top3,
            "falseAutocorrect": falseAutocorrect,
            "validWordSafety": validWordSafety,
        ] as [String: Any],
        "hardGates": [
            "falseAutocorrect": ["required": 0, "actual": falseAutocorrect, "pass": falseAutocorrect == 0],
            "validWordSafety": ["pass": validWordSafety],
            // Threshold spec only — the measured value is wall-clock volatile
            // and enforced on the exit code, kept out of the committed line.
            "benchWorstLineMs": ["threshold": 30],
            "scenarioPass": [
                "required": "100%", "passed": scenarioPassed, "total": scenarioTotal,
                "pass": scenarioPass,
            ],
        ] as [String: Any],
        "pass": deterministicPass,
    ]
    if let heldout {
        var h = corpusJSON(heldout)
        h["reportOnly"] = true
        json["heldout"] = h
    }
    if let note {
        json["note"] = note
    }

    let line = canonicalJSON(json)
    print("")
    print(line)

    // --- Append to committed history --------------------------------------
    appendHistory(line: line, repoRoot: repoRoot)

    // Human note: the (non-deterministic) measured worst keystroke, kept OUT
    // of the JSON so the committed history line stays reproducible.
    stderr(String(format: "scorecard %@ — bench worst %.2f ms", exitPass ? "PASS" : "FAIL", benchWorstMs))
    exit(exitPass ? 0 : 1)
}

// MARK: - Corpus → JSON

func corpusJSON(_ result: CorpusResult) -> [String: Any] {
    func tallyJSON(_ t: CorpusTally) -> [String: Any] {
        ["n": t.total, "top1": t.top1, "top3": t.top3, "acFired": t.autocorrectFired,
         "falseAc": t.falseAutocorrect]
    }
    var categories: [String: Any] = [:]
    for (name, tally) in result.byCategory { categories[name] = tallyJSON(tally) }
    var langs: [String: Any] = [:]
    for (name, tally) in result.byLang { langs[name] = tallyJSON(tally) }
    return [
        "split": result.split,
        "overall": tallyJSON(result.overall),
        "categories": categories,
        "byLang": langs,
    ]
}

func loadSplit(_ split: String, _ repoRoot: URL) -> [CorpusPair] {
    let url = repoRoot.appendingPathComponent("data/eval/\(split).jsonl")
    do {
        return try Corpus.loadCorpus(at: url)
    } catch {
        stderr("failed to load \(split): \(error)")
        exit(2)
    }
}

/// Serialize with sorted keys → deterministic byte output for the committed
/// history file.
func canonicalJSON(_ object: [String: Any]) -> String {
    guard
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

func appendHistory(line: String, repoRoot: URL) {
    let dir = repoRoot.appendingPathComponent("scores")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("history.jsonl")
    let payload = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(payload)
        try? handle.close()
    } else {
        try? payload.write(to: file)
    }
}

// MARK: - Subprocess helpers

func git(_ args: [String], default fallback: String) -> String {
    let (out, code) = run("/usr/bin/env", ["git"] + args, cwd: nil)
    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return (code == 0 && !trimmed.isEmpty) ? trimmed : fallback
}

@discardableResult
func run(_ launchPath: String, _ args: [String], cwd: URL?) -> (out: String, code: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = cwd }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return ("", -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

/// Build (if needed) and locate the type-repl binary in the same build
/// configuration as this process — simplest reliable way to drive the
/// scenario runner + bench without an in-process port.
func typeReplBinary(packageDir: URL) -> URL {
    let config = CommandLine.arguments[0].contains("/release/") ? "release" : "debug"
    run("/usr/bin/env", ["swift", "build", "-c", config, "--product", "type-repl"], cwd: packageDir)
    let (binPath, code) = run(
        "/usr/bin/env", ["swift", "build", "-c", config, "--show-bin-path"], cwd: packageDir)
    let dir = code == 0 ? binPath.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if !dir.isEmpty {
        let candidate = URL(fileURLWithPath: dir).appendingPathComponent("type-repl")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    // Fallback: sibling of this executable.
    return URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("type-repl")
}

func parseScenarioTotals(_ output: String) -> (passed: Int, total: Int) {
    for line in output.split(separator: "\n") {
        // "<passed>/<total> scenarios passed"
        guard line.contains("scenarios passed") else { continue }
        let head = line.split(separator: " ").first.map(String.init) ?? ""
        let parts = head.split(separator: "/").map(String.init)
        if parts.count == 2, let passed = Int(parts[0]), let total = Int(parts[1]) {
            return (passed, total)
        }
    }
    return (0, 0)
}

/// Max "<int> us" over the whole bench report → milliseconds. The bench
/// prints several worst-case keystroke latencies (main text max, edits2,
/// beam, accent-naked, governor-context); the gate is the worst of them all.
func parseBenchWorstMs(_ output: String) -> Double {
    var worstUs = 0.0
    for line in output.split(separator: "\n") {
        guard let range = line.range(of: " us") else { continue }
        let head = line[..<range.lowerBound]
        // last whitespace-separated token before " us" is the number
        if let token = head.split(whereSeparator: { $0 == " " }).last, let value = Double(token) {
            worstUs = max(worstUs, value)
        }
    }
    return worstUs / 1000
}
