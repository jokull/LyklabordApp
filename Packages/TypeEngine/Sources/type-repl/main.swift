import EvalKit
import Foundation
import Learning
import TypeEngine

// type-repl: headless macOS harness for the TypeEngine typing pipeline,
// running the REAL data artifacts through the exact same TypingSession the
// keyboard extension uses (via a simulated UITextDocumentProxy window).
//
//   swift run -c release type-repl                       interactive REPL
//   swift run -c release type-repl run <file.scenarios>  batch expectations
//   swift run -c release type-repl bench                 latency percentiles
//   swift run -c release type-repl last-mile             timed embedder replay
//   swift run -c release type-repl artifact-probe        process-cold load probe
//   swift run -c release type-repl calibration-profile   print build-time values
//
// Flags (all modes):
//   --en <path>      en.lex override        (default <repo>/data/en/en.lex)
//   --is <path>      is.lex override        (default <repo>/data/is/is.lex)
//   --lemma <path>   bin-morph.bin override  (default <repo>/data/is/bin-morph.bin)
//   --no-morph       skip BÍN morphology
//   --no-inflect     skip the Stage-B inflection artifacts (paradigms.bin +
//                    governors.json.gz) — the frequency-only baseline engine
//   --limit <n>      suggestion bar size    (default 5; bench default 3 = extension)
//   --config <p>     EngineConfig overrides JSON (same keys as
//                    `type-eval ab --config`) — A/B a scenario suite or a
//                    REPL session against a knob
//   --deterministic  lift the wall-clock decode budgets outside `run` too
//                    (piped REPL replays stay reproducible under load)
//   --personal <p>   personal-model JSON (Learning.PersonalModel file, the
//                    same personal-model.json the app writes to the App
//                    Group container) injected as the engine's personal
//                    vocabulary snapshot
//
// Subcommand `inflect`: the auto-harvested inflection eval (PLAN.md
// "Inflection intelligence" testability) — see Inflect.swift.

var arguments = Array(CommandLine.arguments.dropFirst())

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let enOverride = takeOption("--en")
let isOverride = takeOption("--is")
let lemmaOverride = takeOption("--lemma")
let noMorph = takeFlag("--no-morph")
let noInflect = takeFlag("--no-inflect")
let limitOverride = takeOption("--limit").flatMap(Int.init)
let personalOverride = takeOption("--personal")
let configOverride = takeOption("--config")
let deterministicBudgets = takeFlag("--deterministic")
// The `inflect` subcommand builds its own engine pair (morph vs baseline)
// from `paths`, so peek before the engine below is constructed.
let isInflectEval = arguments.first == "inflect"

var resolvedPaths = Artifacts.defaultPaths()
if resolvedPaths == nil, let en = enOverride, let is_ = isOverride {
    // No repo root found: explicit overrides for both lexicons still work.
    resolvedPaths = Artifacts.Paths(
        english: URL(fileURLWithPath: en),
        icelandic: URL(fileURLWithPath: is_),
        englishCalibration: nil,
        icelandicCalibration: nil,
        morphology: lemmaOverride.map(URL.init(fileURLWithPath:))
    )
}
guard var paths = resolvedPaths else {
    warn("could not locate repo root (data/is/is.lex); pass --en and --is explicitly")
    exit(2)
}

if let en = enOverride { paths.english = URL(fileURLWithPath: en) }
if let is_ = isOverride { paths.icelandic = URL(fileURLWithPath: is_) }
if let lemma = lemmaOverride { paths.morphology = URL(fileURLWithPath: lemma) }

if isInflectEval {
    // Dedicated eval mode: loads its own engine pair, never the shared one.
    exit(Int32(InflectEval(paths: paths, arguments: Array(arguments.dropFirst())).run()))
}

// Scenario runs are behavioral contracts and must be DETERMINISTIC: lift
// the two wall-clock decode budgets exactly like the corpus/micro evals do
// (scores/README "Reproducibility & determinism") so the deterministic
// expansion/position caps are the sole limiter — otherwise budget-edge
// scenarios ("merged pair keeps interior capitalization": the split pass
// spends its 6 ms on the first center-out hypothesis's edits1 probes under
// load) flip on machine timing alone. Latency stays the bench's job — the
// `bench` subcommand keeps the shipping budgets.
var engineConfig = EngineConfig()
if arguments.first == "run" || deterministicBudgets {
    engineConfig.beamTimeBudget = 3600
    engineConfig.splitTimeBudget = 3600
}

if let configOverride {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: configOverride))
        guard let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigOverrideError.wrongType(key: "<root>", expected: "JSON object")
        }
        try ConfigOverrides.apply(overrides, to: &engineConfig)
    } catch {
        warn("bad --config: \(error)")
        exit(2)
    }
}

let engine: TypeEngine
do {
    engine = try Artifacts.loadEngine(
        paths: paths, morphologyEnabled: !noMorph, inflectionEnabled: !noInflect,
        config: engineConfig)
} catch {
    warn("failed to load artifacts: \(error)")
    exit(2)
}

// Personal-learning snapshot (M2): same injection path as the extension —
// ONE model load feeds both the vocabulary snapshot and the stage-2
// personal touch snapshot.
var basePersonal: PersonalVocabulary?
var basePersonalTouch: PersonalTouchSnapshot?
if let personalOverride {
    do {
        let model = try PersonalModel(contentsOf: URL(fileURLWithPath: personalOverride))
        let snapshot = PersonalSnapshot(model: model)
        basePersonal = snapshot
        engine.setPersonalVocabulary(snapshot)
        let touch = PersonalTouchSnapshot(model: model)
        basePersonalTouch = touch.isEmpty ? nil : touch
        engine.setPersonalTouch(basePersonalTouch)
        warn(
            "personal model loaded: \(engine.personalSnapshotWords.count) words, "
                + "\(touch.keys.count) touch keys (:touchstats)")
    } catch {
        warn("failed to load personal model: \(error)")
        exit(2)
    }
}

switch arguments.first {
case "run":
    guard arguments.count >= 2 else {
        warn("usage: type-repl run <file.scenarios>")
        exit(2)
    }
    let runner = ScenarioRunner(
        engine: engine,
        defaultLimit: limitOverride ?? 5,
        basePersonal: basePersonal,
        basePersonalTouch: basePersonalTouch
    )
    exit(Int32(runner.run(fileAt: arguments[1])))

case "bench":
    // Default limit 3 = what the extension requests per keystroke.
    Bench(engine: engine).run(limit: limitOverride ?? 3)

case "last-mile":
    exit(Int32(TimedLastMileRunner(engine: engine).run()))

case "artifact-probe":
    // Intentionally do nothing after the production-shaped artifact load.
    // `type-eval scorecard` launches this in a fresh process under
    // `/usr/bin/time -l` and gates load latency + peak physical footprint.
    print("artifact-probe ready")

case "calibration-profile":
    let d = engine.calibrationDiagnostics
    let object: [String: Any] = [
        "is": [
            "mean": d.icelandicMean,
            "sigma": d.icelandicSigma,
            "warmupWords": Array(d.icelandicWarmupWords.prefix(64)),
        ],
        "en": [
            "mean": d.englishMean,
            "sigma": d.englishSigma,
            "warmupWords": Array(d.englishWarmupWords.prefix(64)),
        ],
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case nil:
    Repl(engine: engine).run(limit: limitOverride ?? 5)

case let .some(unknown):
    warn("unknown subcommand: \(unknown) (expected: run, bench, last-mile, artifact-probe, calibration-profile, or none for REPL)")
    exit(2)
}
