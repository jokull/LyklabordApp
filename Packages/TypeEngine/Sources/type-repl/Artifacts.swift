import Foundation
import LemmaCore
import Lexicon
import TypeEngine

/// Loads the REAL language artifacts (same files the extension bundles) and
/// builds a production-shaped TypeEngine. No fixtures, no doubles.
enum Artifacts {

    struct Paths {
        var english: URL
        var icelandic: URL
        var morphology: URL?
        /// Stage-B inflection artifacts (PLAN.md "Inflection intelligence");
        /// either missing → engine runs without inflection.
        var paradigms: URL?
        var governors: URL?
    }

    /// Locate the repo root: walk up from the current directory looking for
    /// `data/is/is.lex`; fall back to the compile-time location of this file
    /// (Packages/TypeEngine/Sources/type-repl/Artifacts.swift → 5 up).
    static func repoRoot() -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("data/is/is.lex").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        var compiled = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { compiled = compiled.deletingLastPathComponent() }
        if fm.fileExists(atPath: compiled.appendingPathComponent("data/is/is.lex").path) {
            return compiled
        }
        return nil
    }

    static func defaultPaths() -> Paths? {
        guard let root = repoRoot() else { return nil }
        return Paths(
            english: root.appendingPathComponent("data/en/en.lex"),
            icelandic: root.appendingPathComponent("data/is/is.lex"),
            morphology: root.appendingPathComponent("data/is/lemma-is.bin"),
            paradigms: root.appendingPathComponent("data/is/paradigms.bin"),
            governors: root.appendingPathComponent("data/is/governors.json.gz")
        )
    }

    /// Load the artifacts and build the engine. Prints a one-line summary to
    /// stderr so stdout stays clean for the REPL/batch output.
    static func loadEngine(
        paths: Paths,
        morphologyEnabled: Bool,
        inflectionEnabled: Bool = true,
        config: EngineConfig = EngineConfig()
    ) throws -> TypeEngine {
        let start = ContinuousClock.now
        let english = try FrequencyLexicon(contentsOf: paths.english)
        let icelandic = try FrequencyLexicon(contentsOf: paths.icelandic)

        var morphology: BinaryLemmatizer?
        if morphologyEnabled, let url = paths.morphology {
            do {
                morphology = try BinaryLemmatizer(contentsOf: url)
            } catch {
                warn("lemma-is.bin failed to load (\(error)); continuing without morphology")
            }
        }

        let engine = TypeEngine(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config
        )

        // Stage-B inflection artifacts (paradigms.bin is mmap-only —
        // resident cost is the touched pages; the governors table is the
        // one-time gunzip+parse, timed separately below).
        var inflectionSummary = "off"
        if inflectionEnabled, let paradigmsURL = paths.paradigms, let governorsURL = paths.governors {
            do {
                let paradigms = try ParadigmsReader(contentsOf: paradigmsURL)
                let governorsStart = ContinuousClock.now
                let governors = try GovernorsModel(gzippedJSONContentsOf: governorsURL)
                let governorsMs = governorsStart.duration(to: .now).milliseconds
                engine.setInflection(
                    InflectionModel(paradigms: paradigms, governors: governors))
                inflectionSummary =
                    "on (\(governors.governorCount) governors, "
                    + "\(governorsMs.formatted(.number.precision(.fractionLength(0)))) ms parse)"
            } catch {
                warn("inflection artifacts failed to load (\(error)); continuing without")
            }
        }

        let elapsed = start.duration(to: .now)
        warn(
            "loaded artifacts in \(elapsed.milliseconds.formatted(.number.precision(.fractionLength(1)))) ms "
                + "(is: \(icelandic.unigramCount) unigrams, en: \(english.unigramCount) unigrams, "
                + "morphology: \(morphology == nil ? "off" : "on"), inflection: \(inflectionSummary))"
        )
        return engine
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[type-repl] \(message)\n".utf8))
}

extension Duration {
    var microseconds: Double {
        Double(components.seconds) * 1e6 + Double(components.attoseconds) / 1e12
    }
    var milliseconds: Double { microseconds / 1000 }
}
