import Foundation
import LemmaCore
import Lexicon
import TypeEngine

/// Loads the REAL language artifacts (the same `data/` files the extension
/// bundles) and builds a production-shaped `TypeEngine` — no DictLexicon
/// doubles. The corpus eval and the scorecard replay pairs through this
/// engine so the numbers describe the shipping stack, not the micro-eval's
/// hand-assembled fixture vocabulary. Parallels `type-repl`'s Artifacts,
/// factored into EvalKit so type-eval can reuse it.
public enum ArtifactLoader {

    public struct Paths: Sendable {
        public var english: URL
        public var icelandic: URL
        public var morphology: URL?
        public var paradigms: URL?
        public var governors: URL?
    }

    /// Walk up from the current directory (then from this file's compile-time
    /// location) looking for `data/is/is.lex` — the repo-root marker.
    public static func repoRoot() -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<12 {
            if fm.fileExists(atPath: dir.appendingPathComponent("data/is/is.lex").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        // Packages/TypeEngine/Sources/EvalKit/ArtifactLoader.swift → 5 up.
        var compiled = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { compiled = compiled.deletingLastPathComponent() }
        if fm.fileExists(atPath: compiled.appendingPathComponent("data/is/is.lex").path) {
            return compiled
        }
        return nil
    }

    /// The corpus-eval config: the shipping defaults with the two wall-clock
    /// decode budgets (`beamTimeBudget`, `splitTimeBudget`) lifted so the
    /// deterministic expansion/position caps (`beamMaxExpansions`,
    /// `splitMaxPositions`) are the SOLE limiter. Without this, a handful of
    /// hard pairs per 3,000 flip between runs purely on decode timing (a
    /// ~1-pair jitter in space_miss), which would make the committed scorecard
    /// line non-reproducible. Accuracy is what the corpus eval measures;
    /// latency-under-budget is measured separately by the bench. `overrides`
    /// (A/B) apply on top, so an A/B run can still probe the budgets if it
    /// wants. Runtime is barely affected — the caps already bound the work.
    public static func deterministicConfig(base: EngineConfig = EngineConfig()) -> EngineConfig {
        var config = base
        config.beamTimeBudget = 3600
        config.splitTimeBudget = 3600
        return config
    }

    public static func defaultPaths() -> Paths? {
        guard let root = repoRoot() else { return nil }
        return Paths(
            english: root.appendingPathComponent("data/en/en.lex"),
            icelandic: root.appendingPathComponent("data/is/is.lex"),
            morphology: root.appendingPathComponent("data/is/lemma-is.bin"),
            paradigms: root.appendingPathComponent("data/is/paradigms.bin"),
            governors: root.appendingPathComponent("data/is/governors.json.gz")
        )
    }

    /// URL of a corpus split file (`data/eval/dev.jsonl` / `heldout.jsonl`).
    public static func corpusURL(split: String) -> URL? {
        repoRoot()?.appendingPathComponent("data/eval/\(split).jsonl")
    }

    public enum LoadError: Error, CustomStringConvertible {
        case noRepoRoot
        public var description: String {
            "could not locate repo root (data/is/is.lex) — run from inside the repo"
        }
    }

    /// Build the production-shaped engine with `config`. Morphology and the
    /// Stage-B inflection artifacts are loaded when present (matching the
    /// extension + type-repl defaults). `log` receives a one-line summary.
    public static func loadEngine(
        config: EngineConfig = EngineConfig(),
        log: (String) -> Void = { _ in }
    ) throws -> TypeEngine {
        guard let paths = defaultPaths() else { throw LoadError.noRepoRoot }
        return try loadEngine(paths: paths, config: config, log: log)
    }

    public static func loadEngine(
        paths: Paths,
        config: EngineConfig = EngineConfig(),
        log: (String) -> Void = { _ in }
    ) throws -> TypeEngine {
        let start = ContinuousClock.now
        let english = try FrequencyLexicon(contentsOf: paths.english)
        let icelandic = try FrequencyLexicon(contentsOf: paths.icelandic)

        var morphology: BinaryLemmatizer?
        if let url = paths.morphology {
            morphology = try? BinaryLemmatizer(contentsOf: url)
        }

        let engine = TypeEngine(
            icelandic: icelandic, english: english, morphology: morphology, config: config)

        var inflectionSummary = "off"
        if let paradigmsURL = paths.paradigms, let governorsURL = paths.governors {
            if let paradigms = try? ParadigmsReader(contentsOf: paradigmsURL),
                let governors = try? GovernorsModel(gzippedJSONContentsOf: governorsURL)
            {
                engine.setInflection(InflectionModel(paradigms: paradigms, governors: governors))
                inflectionSummary = "on (\(governors.governorCount) governors)"
            }
        }

        let ms = start.duration(to: .now).evalMilliseconds
        log(
            "loaded artifacts in \(String(format: "%.0f", ms)) ms "
                + "(is \(icelandic.unigramCount) / en \(english.unigramCount) unigrams, "
                + "morphology \(morphology == nil ? "off" : "on"), inflection \(inflectionSummary))"
        )
        return engine
    }
}

extension Duration {
    var evalMilliseconds: Double {
        (Double(components.seconds) * 1e6 + Double(components.attoseconds) / 1e12) / 1000
    }
}
