import EvalKit
import Foundation
import TypeEngine

// `type-eval ab [--config <overrides.json>] [--disable-family <name>]`
// — baseline vs override/provider-family ablation diff.
//
// Applies an EngineConfig override set (explicit key→setter map, see
// EvalKit/ConfigOverrides + scores/README.md) and runs corpus dev + the
// micro-eval for the baseline config and the override config, printing a diff
// table. Only DEV corpus is used — A/B tuning must never touch heldout.

func runABCommand(_ args: [String]) {
    var overrideConfig = EngineConfig()
    var requestedDisabled: CandidateProviderSet = []
    var appliedKeys: [String] = []
    var labels: [String] = []
    var index = 0
    while index < args.count {
        let flag = args[index]
        guard index + 1 < args.count else {
            stderr("missing value after \(flag)")
            printABUsageAndExit()
        }
        let value = args[index + 1]
        switch flag {
        case "--config":
            do {
                let loaded = try ConfigOverrides.load(from: URL(fileURLWithPath: value))
                overrideConfig = loaded.config
                appliedKeys = loaded.keys
                labels.append("config \(value)")
            } catch {
                stderr("config error: \(error)")
                stderr("supported keys: \(ConfigOverrides.supportedKeys.joined(separator: ", "))")
                exit(2)
            }
        case "--disable-family":
            guard let family = CandidateProviderFamily(rawValue: value) else {
                stderr("unknown provider family: \(value)")
                stderr(
                    "families: "
                        + CandidateProviderFamily.allCases.map(\.rawValue).joined(separator: ", "))
                exit(2)
            }
            requestedDisabled.formUnion(family.providers)
            labels.append("disable-family \(family.rawValue)")
        case "--disable-provider":
            guard let provider = CandidateProvider(rawValue: value) else {
                stderr("unknown candidate provider: \(value)")
                stderr(
                    "providers: "
                        + CandidateProvider.allCases.map(\.rawValue).joined(separator: ", "))
                exit(2)
            }
            requestedDisabled.insert(CandidateProviderSet(provider))
            labels.append("disable-provider \(provider.rawValue)")
        default:
            stderr("unknown A/B option: \(flag)")
            printABUsageAndExit()
        }
        index += 2
    }
    guard !labels.isEmpty else {
        printABUsageAndExit()
    }
    overrideConfig.disabledCandidateProviders.formUnion(requestedDisabled)

    guard let repoRoot = ArtifactLoader.repoRoot() else {
        stderr("cannot locate repo root")
        exit(2)
    }
    let pairs = loadSplit("dev", repoRoot)

    // Micro-eval, both configs.
    let cases = loadCases()
    let microBase = runMicroEval(cases: cases, config: ArtifactLoader.deterministicConfig())
    let microOver = runMicroEval(
        cases: cases, config: ArtifactLoader.deterministicConfig(base: overrideConfig))

    // Corpus dev, both configs (two real-artifact engines). Both run with
    // the deterministic decode budgets so the diff is signal, not timing.
    stderr("loading baseline engine…")
    let baseEngine = loadABEngine(config: ArtifactLoader.deterministicConfig())
    baseEngine.warmUp()
    let corpusBase = CorpusEval.run(engine: baseEngine, pairs: pairs, split: "dev")

    stderr("loading override engine…")
    let overEngine = loadABEngine(config: ArtifactLoader.deterministicConfig(base: overrideConfig))
    overEngine.warmUp()
    let corpusOver = CorpusEval.run(engine: overEngine, pairs: pairs, split: "dev")

    // --- Report -----------------------------------------------------------
    print("A/B — \(labels.joined(separator: "; "))")
    if !appliedKeys.isEmpty {
        print("overrides applied (\(appliedKeys.count)): \(appliedKeys.joined(separator: ", "))")
    }
    let disabled = overrideConfig.disabledCandidateProviders.providers
    if !disabled.isEmpty {
        print("providers disabled (\(disabled.count)): \(disabled.map(\.rawValue).joined(separator: ", "))")
    }
    print("")
    print("metric                     baseline   override      delta")
    func row(_ name: String, _ base: Double, _ over: Double, _ suffix: String = "%") {
        let delta = over - base
        print(
            "\(name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                + String(format: "%8.2f%@", base, suffix)
                + String(format: "  %8.2f%@", over, suffix)
                + String(format: "  %+8.2f%@", delta, suffix))
    }
    print("[corpus dev, \(corpusBase.overall.total) pairs]")
    row("corpus top-1", pctOf(corpusBase.overall, \.top1), pctOf(corpusOver.overall, \.top1))
    row("corpus top-3", pctOf(corpusBase.overall, \.top3), pctOf(corpusOver.overall, \.top3))
    row("corpus ac-fired",
        pctOf(corpusBase.overall, \.autocorrectFired), pctOf(corpusOver.overall, \.autocorrectFired))
    row("corpus false-ac",
        pctOf(corpusBase.overall, \.falseAutocorrect), pctOf(corpusOver.overall, \.falseAutocorrect))
    print("[micro-eval, \(microBase.overall.total) cases]")
    row("micro top-1",
        microPct(microBase.overall, microBase.overall.top1),
        microPct(microOver.overall, microOver.overall.top1))
    row("micro false-ac",
        microPct(microBase.overall, microBase.overall.falseAutocorrect),
        microPct(microOver.overall, microOver.overall.falseAutocorrect))

    print("")
    print("[corpus dev top-1 by category]")
    print("category              baseline   override      delta")
    for category in corpusBase.byCategory.keys.sorted() {
        let base = corpusBase.byCategory[category]!
        let over = corpusOver.byCategory[category] ?? CorpusTally()
        let b = pctOf(base, \.top1)
        let o = pctOf(over, \.top1)
        print(
            "\(category.padding(toLength: 18, withPad: " ", startingAt: 0))"
                + String(format: "%8.2f%%", b)
                + String(format: "  %8.2f%%", o)
                + String(format: "  %+8.2f%%", o - b))
    }
}

private func printABUsageAndExit() -> Never {
    stderr(
        "usage: type-eval ab [--config <overrides.json>]"
            + " [--disable-family <family>] [--disable-provider <provider>]")
    exit(2)
}

func loadABEngine(config: EngineConfig) -> TypeEngine {
    do {
        return try ArtifactLoader.loadEngine(config: config, log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
}

func pctOf(_ tally: CorpusTally, _ key: KeyPath<CorpusTally, Int>) -> Double {
    tally.percent(tally[keyPath: key])
}

func microPct(_ tally: Tally, _ n: Int) -> Double {
    tally.total == 0 ? 0 : 100.0 * Double(n) / Double(tally.total)
}
