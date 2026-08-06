import EvalKit
import Foundation
import TypeEngine

// `type-eval scorecard [--heldout]` — the unified per-commit scorecard.
//
// Runs: micro-eval + corpus dev (+ REPORT-ONLY heldout with --heldout) +
// the scenario suites + timed last-mile embedder replay + latency bench (via
// type-repl), assembles ONE deterministic JSON (timestamp = git HEAD commit
// time, commit = HEAD hash — no Date.now, so re-running on the same commit
// reproduces the line byte-for-byte), appends it to scores/history.jsonl,
// prints it to stdout, and exits non-zero if any hard gate fails.
//
// Hard gates (PLAN.md eval studio):
//   curatedSafety      micro false-autocorrect == 0 + valid-word safety
//   corpusRegression   dev+safety top-1/top-3 floors and false-ac ceilings
//   languageArtifacts  generation freshness/cohort/bytes/SHA-256 manifest
//   artifactRuntime    fresh-process load < 500 ms, peak footprint < 50 MiB
//   benchWorstLineMs   type-repl bench worst keystroke < 30 ms
//   scenarioPass       every scenario in every suite passes (100%)
//   lastMileReplay     final-text cases + host request/action latency budgets

func runScorecardCommand(_ args: [String]) {
    let includeHeldout = args.contains("--heldout")
    let updateCorpusBaseline = args.contains("--update-corpus-baseline")
    let recordHistory = !args.contains("--no-history")
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
    let referenceDate = ISO8601DateFormatter().date(from: timestamp) ?? .distantPast

    // --- Shipping artifact cohort ---------------------------------------
    stderr("auditing language artifact manifests…")
    let artifactAudit = LanguageArtifactAudit.run(
        repoRoot: repoRoot, referenceDate: referenceDate)
    for failure in artifactAudit.failures { stderr("  FAIL \(failure)") }
    if artifactAudit.passed {
        stderr(
            "  \(artifactAudit.verifiedFileCount) files verified; generations "
                + artifactAudit.generations.keys.sorted().map {
                    "\($0)=\(artifactAudit.generations[$0]!)"
                }.joined(separator: ", "))
    }

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
    stderr("running corpus safety…")
    let safety = CorpusEval.run(
        engine: engine, pairs: loadSplit("safety", repoRoot), split: "safety")
    print("")
    printCorpusResult(safety, label: "corpus safety")
    // Compounds slice (wave 31): real iceErrorCorpus compound errors —
    // tracked in the scorecard line (not a hard gate) so the structural
    // gaps (missing-hyphen, cross-token joins) stay visible per commit.
    stderr("running corpus compounds…")
    let compounds = CorpusEval.run(
        engine: engine, pairs: loadSplit("compounds", repoRoot), split: "compounds")
    print("")
    printCorpusResult(compounds, label: "corpus compounds")
    var heldout: CorpusResult?
    if includeHeldout {
        stderr("running corpus heldout (REPORT-ONLY)…")
        heldout = CorpusEval.run(
            engine: engine, pairs: loadSplit("heldout", repoRoot), split: "heldout")
        print("")
        printCorpusResult(heldout!, label: "corpus heldout [REPORT-ONLY]")
    }

    // --- Baseline-relative real-artifact gate ---------------------------
    let currentSuites = [
        "dev": CorpusSuiteSnapshot(dev),
        "safety": CorpusSuiteSnapshot(safety),
    ]
    let corpusBaselineURL = repoRoot.appendingPathComponent("scores/corpus-baseline-v1.json")
    if updateCorpusBaseline {
        do {
            try writeCorpusBaseline(currentSuites, to: corpusBaselineURL)
            stderr("updated corpus baseline at \(corpusBaselineURL.path)")
        } catch {
            stderr("cannot update corpus baseline: \(error)")
            exit(2)
        }
    }
    let corpusFailures: [String]
    do {
        let baseline = try JSONDecoder().decode(
            CorpusBaselineDocument.self, from: Data(contentsOf: corpusBaselineURL))
        corpusFailures = CorpusBaselineGate.failures(
            current: currentSuites, baseline: baseline)
    } catch {
        corpusFailures = ["cannot load scores/corpus-baseline-v1.json: \(error)"]
    }
    for failure in corpusFailures { stderr("  corpus gate FAIL: \(failure)") }

    // --- Scenario suites + bench (type-repl) ------------------------------
    let repl = typeReplBinary(packageDir: packageDir)

    // Fresh-process host proxy for the language stack's open/parse cost and
    // physical footprint. This is a regression alarm, not an iOS jetsam
    // certification (the physical Wave 39 cohort owns device cold-start).
    // No retry: the first process is the number.
    stderr("running process-cold artifact runtime probe…")
    let artifactProbe = runCaptured(
        "/usr/bin/time", ["-l", repl.path, "artifact-probe"], cwd: packageDir)
    let artifactOpenMs = parseArtifactLoadMs(artifactProbe.err)
    let artifactPeakBytes = parsePeakFootprintBytes(artifactProbe.err)
    let artifactOpenThresholdMs = 500.0
    let artifactPeakThresholdBytes = 50 * 1024 * 1024
    let artifactRuntimePass = artifactProbe.code == 0
        && artifactOpenMs > 0 && artifactOpenMs < artifactOpenThresholdMs
        && artifactPeakBytes > 0 && artifactPeakBytes < artifactPeakThresholdBytes
    stderr(
        String(
            format: "  load %.1f ms; peak footprint %.1f MiB (gate %@)",
            artifactOpenMs, Double(artifactPeakBytes) / 1_048_576,
            artifactRuntimePass ? "pass" : "FAIL"))

    stderr("running scenario suites via \(repl.lastPathComponent)…")
    var scenarioPassed = 0
    var scenarioTotal = 0
    var scenarioOK = true
    for suite in ["core", "dogfood", "inflect", "touch", "compounds", "folded"] {
        let file = packageDir.appendingPathComponent("Scenarios/\(suite).scenarios").path
        let (out, code) = run(repl.path, ["run", file], cwd: packageDir)
        let (passed, total) = parseScenarioTotals(out)
        scenarioPassed += passed
        scenarioTotal += total
        if code != 0 || passed != total { scenarioOK = false }
        stderr("  \(suite): \(passed)/\(total) (exit \(code))")
    }
    let scenarioPass = scenarioOK && scenarioTotal > 0 && scenarioPassed == scenarioTotal

    // Timed last-mile replay: unlike stateless corpus evaluation and the
    // synchronous scenarios, this drives a separately published bar over a
    // real serial session queue. It gates final proxy text for delimiter
    // apply, stale delivery, fast queueing, and backspace/revert. Behavior is
    // deterministic and belongs in the committed scorecard; volatile host
    // timings are enforced on the exit code but omitted from the JSON line.
    stderr("running timed last-mile replay…")
    let (lastMileOut, lastMileCode) = run(
        repl.path, ["last-mile"], cwd: packageDir)
    let lastMile = parseLastMileReport(lastMileOut)
    let lastMileBehaviorPass = lastMile?.behaviorPass == true
        && lastMile!.passedCases == lastMile!.totalCases
        && lastMile!.totalCases > 0
    let lastMilePerformancePass = lastMile?.performancePass == true
        && lastMileCode == 0
    stderr(String(
        format: "  last-mile: %d/%d; request p95 %.2f ms; fast drain %.2f ms; gate %@",
        lastMile?.passedCases ?? 0, lastMile?.totalCases ?? 0,
        lastMile?.requestP95Ms ?? 0, lastMile?.backlogDrainMs ?? 0,
        lastMileBehaviorPass && lastMilePerformancePass ? "pass" : "FAIL"))

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
    let curatedSafetyPass = falseAutocorrect == 0 && validWordSafety
    let corpusRegressionPass = corpusFailures.isEmpty
    let deterministicPass = curatedSafetyPass && corpusRegressionPass
        && artifactAudit.passed && scenarioPass && lastMileBehaviorPass
    let exitPass = deterministicPass && artifactRuntimePass && benchPass
        && lastMilePerformancePass

    // --- JSON (deterministic given the commit) ----------------------------
    var json: [String: Any] = [
        "version": "v1",
        "commit": commit,
        "timestamp": timestamp,
        "corpus": corpusJSON(dev),
        "safety": corpusJSON(safety),
        "compounds": corpusJSON(compounds),
        "microEval": [
            "n": micro.overall.total,
            "top1": micro.overall.top1,
            "top3": micro.overall.top3,
            "curatedSafety": [
                "falseAutoApplies": falseAutocorrect,
                "validWordSafety": validWordSafety,
            ] as [String: Any],
        ] as [String: Any],
        "hardGates": [
            "curatedSafety": [
                "requiredFalseAutoApplies": 0,
                "actualFalseAutoApplies": falseAutocorrect,
                "validWordSafety": validWordSafety,
                "pass": curatedSafetyPass,
            ] as [String: Any],
            "corpusRegression": [
                "baseline": "scores/corpus-baseline-v1.json",
                "failures": corpusFailures,
                "pass": corpusRegressionPass,
            ] as [String: Any],
            "languageArtifacts": [
                "failures": artifactAudit.failures,
                "generations": artifactAudit.generations,
                "sourceAgeDays": artifactAudit.sourceAgeDays,
                "verifiedFiles": artifactAudit.verifiedFileCount,
                "pass": artifactAudit.passed,
            ] as [String: Any],
            // Threshold specs only. Fresh-process timing/footprint are host-
            // volatile and enforced on the exit code, like the bench below.
            "artifactRuntime": [
                "loadThresholdMs": artifactOpenThresholdMs,
                "peakFootprintThresholdBytes": artifactPeakThresholdBytes,
            ] as [String: Any],
            // Threshold spec only — the measured value is wall-clock volatile
            // and enforced on the exit code, kept out of the committed line.
            "benchWorstLineMs": ["threshold": 30],
            "scenarioPass": [
                "required": "100%", "passed": scenarioPassed, "total": scenarioTotal,
                "pass": scenarioPass,
            ],
            "lastMileReplay": [
                "required": "100% final-text cases",
                "passed": lastMile?.passedCases ?? 0,
                "total": lastMile?.totalCases ?? 0,
                "sessionProxyFailures": max(
                    (lastMile?.totalCases ?? 0) - (lastMile?.passedCases ?? 0), 0),
                "behaviorPass": lastMileBehaviorPass,
                // Threshold specs only; measurements are host-volatile and
                // enforced on the scorecard exit code.
                "requestP95ThresholdMs": 60.0,
                "requestMaxThresholdMs": 120.0,
                "backlogDrainThresholdMs": 100.0,
                "actionP95ThresholdMs": 5.0,
            ] as [String: Any],
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
    if recordHistory {
        appendHistory(line: line, repoRoot: repoRoot)
    } else {
        stderr("history append skipped (--no-history)")
    }

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
    func stagesJSON(_ tally: CorpusStageTally) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: CorpusOutcomeStage.allCases.map { ($0.rawValue, tally[$0]) })
    }
    var stageCategories: [String: Any] = [:]
    for (name, tally) in result.stagesByCategory {
        stageCategories[name] = stagesJSON(tally)
    }
    var stageLangs: [String: Any] = [:]
    for (name, tally) in result.stagesByLang { stageLangs[name] = stagesJSON(tally) }
    return [
        "split": result.split,
        "overall": tallyJSON(result.overall),
        "categories": categories,
        "byLang": langs,
        "stages": [
            "overall": stagesJSON(result.stagesOverall),
            "categories": stageCategories,
            "byLang": stageLangs,
        ] as [String: Any],
    ]
}

func writeCorpusBaseline(
    _ suites: [String: CorpusSuiteSnapshot], to url: URL
) throws {
    let document = CorpusBaselineDocument(suites: suites)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(document)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
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

func runCaptured(
    _ launchPath: String, _ args: [String], cwd: URL?
) -> (out: String, err: String, code: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = cwd }
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return ("", "\(error)", -1)
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        String(decoding: out, as: UTF8.self),
        String(decoding: err, as: UTF8.self),
        process.terminationStatus)
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

struct LastMileReport {
    let passedCases: Int
    let totalCases: Int
    let behaviorPass: Bool
    let performancePass: Bool
    let requestP95Ms: Double
    let backlogDrainMs: Double
}

func parseLastMileReport(_ output: String) -> LastMileReport? {
    for line in output.split(separator: "\n").reversed() {
        guard line.first == "{",
            let data = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let metrics = object["metrics"] as? [String: Any],
            let passed = (object["passedCases"] as? NSNumber)?.intValue,
            let total = (object["totalCases"] as? NSNumber)?.intValue,
            let behavior = (object["behaviorPass"] as? NSNumber)?.boolValue,
            let performance = (object["performancePass"] as? NSNumber)?.boolValue,
            let requestP95 = (metrics["requestP95Ms"] as? NSNumber)?.doubleValue,
            let drain = (metrics["backlogDrainMs"] as? NSNumber)?.doubleValue
        else { continue }
        return LastMileReport(
            passedCases: passed, totalCases: total,
            behaviorPass: behavior, performancePass: performance,
            requestP95Ms: requestP95, backlogDrainMs: drain)
    }
    return nil
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

func parseArtifactLoadMs(_ stderr: String) -> Double {
    guard let line = stderr.split(separator: "\n").first(where: {
        $0.contains("loaded artifacts in")
    }), let marker = line.range(of: "loaded artifacts in ")
    else { return 0 }
    let tail = line[marker.upperBound...]
    guard let token = tail.split(separator: " ").first else { return 0 }
    return Double(token.replacingOccurrences(of: ",", with: ".")) ?? 0
}

func parsePeakFootprintBytes(_ stderr: String) -> Int {
    for line in stderr.split(separator: "\n") where line.contains("peak memory footprint") {
        if let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
            let bytes = Int(token)
        {
            return bytes
        }
    }
    return 0
}
