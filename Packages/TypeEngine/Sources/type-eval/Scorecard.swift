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
    // An empty fixture has zero false auto-applies and zero violations — it
    // must not pass the curated-safety gate.
    let microPopulated = micro.overall.total > 0 && micro.safetyChecked > 0
    if !microPopulated { stderr("  curated safety FAIL: micro-eval fixture produced no cases") }

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
    let repl: URL
    switch typeReplBinary(packageDir: packageDir) {
    case let .success(url): repl = url
    case let .failure(error):
        stderr("cannot obtain a fresh type-repl: \(error)")
        exit(2)
    }

    // Fresh-process host proxy for the language stack's open/parse cost and
    // physical footprint. This is a regression alarm, not an iOS jetsam
    // certification (the physical Wave 39 cohort owns device cold-start).
    // No retry: the first process is the number.
    stderr("running process-cold artifact runtime probe…")
    let artifactProbe = runCaptured(
        "/usr/bin/time", ["-l", repl.path, "artifact-probe"], cwd: packageDir)
    let artifactOpenMs = ScorecardParsing.artifactLoadMs(artifactProbe.err) ?? 0
    let artifactPeakBytes = ScorecardParsing.peakFootprintBytes(artifactProbe.err) ?? 0
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

    // Every `Scenarios/*.scenarios` file is a suite — the gate used to name
    // six suites by hand, so a seventh contract file would never have been
    // run. Each suite must run, print a summary, hold ≥1 scenario and pass.
    stderr("running scenario suites via \(repl.lastPathComponent)…")
    let scenariosDir = packageDir.appendingPathComponent("Scenarios")
    let suiteFiles = ((try? FileManager.default.contentsOfDirectory(atPath: scenariosDir.path)) ?? [])
        .filter { $0.hasSuffix(".scenarios") }
        .sorted()
    var suiteOutcomes: [ScenarioSuiteOutcome] = []
    for file in suiteFiles {
        let name = String(file.dropLast(".scenarios".count))
        let result = runCaptured(
            repl.path, ["run", scenariosDir.appendingPathComponent(file).path], cwd: packageDir)
        let totals = ScorecardParsing.scenarioTotals(result.out)
        suiteOutcomes.append(ScenarioSuiteOutcome(name: name, exitCode: result.code, totals: totals))
        let summary = totals.map { "\($0.passed)/\($0.total)" } ?? "no summary"
        stderr("  \(name): \(summary) (exit \(result.code))")
        if result.code != 0 || totals == nil || totals!.passed != totals!.total {
            // Surface the runner's own failure report (stdout tail + stderr)
            // instead of swallowing it — the old gate discarded both.
            for line in result.out.split(separator: "\n").drop(while: { !$0.hasPrefix("failures:") }) {
                stderr("    \(line)")
            }
            for line in result.err.split(separator: "\n") where !line.contains("loaded artifacts") {
                stderr("    \(line)")
            }
        }
    }
    let scenarioGate = ScorecardGates.scenarioGate(suiteOutcomes)
    for failure in scenarioGate.failures { stderr("  scenario gate FAIL: \(failure)") }
    let scenarioPassed = scenarioGate.passed
    let scenarioTotal = scenarioGate.total
    let scenarioPass = scenarioGate.pass

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
    // A bench report missing any gate line yields nil, never 0 — "nothing
    // measured" used to parse as a 0 ms worst keystroke and pass.
    var benchWorst = ScorecardParsing.benchWorstMs(run(repl.path, ["bench"], cwd: packageDir).out)
    if let first = benchWorst, first >= 30 {
        if let retry = ScorecardParsing.benchWorstMs(run(repl.path, ["bench"], cwd: packageDir).out) {
            benchWorst = min(first, retry)
        }
    }
    let benchPass = benchWorst.map { $0 > 0 && $0 < 30 } ?? false
    let benchWorstMs = benchWorst ?? .nan
    stderr(
        benchWorst == nil
            ? "  bench worst keystroke: NOT MEASURED (report missing gate lines) (gate FAIL)"
            : String(
                format: "  bench worst keystroke: %.2f ms (gate %@)", benchWorstMs,
                benchPass ? "pass" : "FAIL"))

    // --- Gates ------------------------------------------------------------
    // The committed `pass` reflects only the DETERMINISTIC gates so the
    // history line is reproducible given the commit. The latency gate is
    // enforced on the EXIT CODE (for CI) but its volatile measurement is not
    // recorded in the line — see scores/README.md.
    let curatedSafetyPass = microPopulated && falseAutocorrect == 0 && validWordSafety
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
                "casesEvaluated": micro.overall.total,
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
    // Drain stderr on its own thread: reading the two pipes in sequence
    // deadlocks once the child fills the stderr pipe buffer while stdout is
    // still open (a clean or failing `swift build` writes plenty).
    var err = Data()
    let errDrained = DispatchGroup()
    errDrained.enter()
    DispatchQueue.global().async {
        err = errPipe.fileHandleForReading.readDataToEndOfFile()
        errDrained.leave()
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    errDrained.wait()
    process.waitUntilExit()
    return (
        String(decoding: out, as: UTF8.self),
        String(decoding: err, as: UTF8.self),
        process.terminationStatus)
}

struct TypeReplBuildError: Error, CustomStringConvertible {
    let description: String
}

/// Build type-repl into the SAME scratch path and configuration as this
/// process (argv[0] is `<scratch>/<config>/type-eval`), then return the
/// sibling binary. Fails closed: the old version ignored `swift build`'s
/// exit status and then located whatever type-repl already existed in the
/// default `.build` — on a build failure the scenario suites and the bench
/// silently ran against a STALE binary, and the build itself contended for
/// the shared `.build` lock regardless of the scratch path in use.
func typeReplBinary(packageDir: URL) -> Result<URL, TypeReplBuildError> {
    // argv[0] is used UNRESOLVED: `<scratch>/release` is a symlink into
    // `<scratch>/out/Products/Release`, and a resolved path derives the wrong
    // scratch root (see BuildLayout.scratchRoot).
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let binDir = selfURL.deletingLastPathComponent()
    let config = BuildLayout.configuration(forBinaryAt: selfURL)
    guard let scratch = BuildLayout.scratchRoot(forBinaryAt: selfURL) else {
        return .failure(
            TypeReplBuildError(
                description: "cannot find the SwiftPM scratch root above \(selfURL.path)"))
    }
    let build = runCaptured(
        "/usr/bin/env",
        ["swift", "build", "-c", config, "--product", "type-repl", "--scratch-path", scratch.path],
        cwd: packageDir)
    guard build.code == 0 else {
        let tail = build.err.split(separator: "\n").suffix(15).joined(separator: "\n")
        return .failure(
            TypeReplBuildError(
                description: "swift build --product type-repl exited \(build.code)\n\(tail)"))
    }
    // Cross-check: the directory swift just built into must be the directory
    // we are about to run from — otherwise we would be gating a stale binary.
    let shown = runCaptured(
        "/usr/bin/env",
        ["swift", "build", "-c", config, "--show-bin-path", "--scratch-path", scratch.path],
        cwd: packageDir)
    let shownPath = shown.out.trimmingCharacters(in: .whitespacesAndNewlines)
    let builtDir = URL(fileURLWithPath: shownPath).resolvingSymlinksInPath().path
    let runDir = binDir.resolvingSymlinksInPath().path
    guard shown.code == 0, !shownPath.isEmpty, builtDir == runDir else {
        return .failure(
            TypeReplBuildError(
                description:
                    "swift build wrote to \(shownPath) but this process runs from \(binDir.path); "
                    + "refusing to gate a possibly stale type-repl"))
    }
    let candidate = binDir.appendingPathComponent("type-repl")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
        return .failure(
            TypeReplBuildError(description: "built type-repl not found at \(candidate.path)"))
    }
    return .success(candidate)
}

// Bench / artifact-probe / scenario-summary parsers live in
// `EvalKit.ScorecardParsing` (unit-tested; nil on a missing report, never 0).

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
