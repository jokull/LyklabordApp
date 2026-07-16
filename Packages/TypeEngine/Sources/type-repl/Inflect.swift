import Foundation
import LemmaCore
import TypeEngine

/// `type-repl inflect` — the auto-harvested inflection eval (PLAN.md
/// "Inflection intelligence", testability: "harvest (context, lemma,
/// expected form) triples from held-out Wikipedia sentences — find noun
/// after a known governor, mask it, ask the engine to complete from its
/// first 3-4 chars; measure form-accuracy vs the frequency-only baseline").
///
/// Zero hand labeling: every case is (governor token, attested noun form)
/// pulled straight from `data/eval/sentences.is.txt`.
///
/// **Held-out region (dev/heldout discipline)**: this eval reads sentences
/// from line 5001 to the end of `sentences.is.txt` (1-based; 7,183 lines in
/// the shipped file, so the region is lines 5001–7183). Lines 1–5000 are
/// the DEV region — tuning of the morph tunables may only ever look at
/// `--dev` runs; the held-out region is report-only, per the eval-studio
/// rule in data/eval/README.md.
///
/// For each harvested case the expected form is masked to its first 3
/// (5-letter words) or 4 (longer) characters and both engines complete it
/// with the governor as bigram context inside a primed Icelandic lane:
///
///   * morph engine    — full artifacts + Stage-B inflection model
///   * baseline engine — identical, inflection off (frequency-only ranking)
///
/// Flags: --dev (harvest from the dev region instead), --cases <n>
/// (default 60), --per-governor <n> (default 6), --min-dominance <p>
/// (harvest only governors whose dominant case reaches p; default 0.55),
/// --weight <λ> (morphBackoffWeight override for dev tuning sweeps),
/// --verbose (list case flips and shared misses).
struct InflectEval {
    let paths: Artifacts.Paths
    let arguments: [String]

    struct Case {
        let governor: String
        let expected: String
        let prefix: String
        let line: Int
    }

    func run() -> Int {
        var arguments = self.arguments
        func takeFlag(_ name: String) -> Bool {
            guard let index = arguments.firstIndex(of: name) else { return false }
            arguments.remove(at: index)
            return true
        }
        func takeOption(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count
            else { return nil }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
            return value
        }
        let useDevRegion = takeFlag("--dev")
        let verbose = takeFlag("--verbose")
        let maxCases = takeOption("--cases").flatMap(Int.init) ?? 60
        let perGovernorCap = takeOption("--per-governor").flatMap(Int.init) ?? 6
        // Governors with a STRONG case signature only (PLAN Stage B #3
        // wording): weak/agreement-shaped governors ("hefur", "sem", …)
        // pass the artifact's entropy filter but carry no per-case signal
        // worth evaluating a FORM choice against.
        let minDominance = takeOption("--min-dominance").flatMap(Double.init) ?? 0.55
        // λ_morph override for dev-region tuning sweeps.
        let weightOverride = takeOption("--weight").flatMap(Double.init)

        guard let root = Artifacts.repoRoot() else {
            warn("inflect: could not locate repo root")
            return 2
        }
        let sentencesURL = root.appendingPathComponent("data/eval/sentences.is.txt")
        guard let raw = try? String(contentsOf: sentencesURL, encoding: .utf8) else {
            warn("inflect: cannot read \(sentencesURL.path)")
            return 2
        }
        guard let paradigmsURL = paths.paradigms, let governorsURL = paths.governors,
            let paradigms = try? ParadigmsReader(contentsOf: paradigmsURL),
            let governors = try? GovernorsModel(gzippedJSONContentsOf: governorsURL)
        else {
            warn("inflect: inflection artifacts missing (data/is/paradigms.bin + governors.json.gz)")
            return 2
        }

        var config = EngineConfig()
        if let weightOverride { config.morphBackoffWeight = weightOverride }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        // 1-based line ranges; see the type doc for the region rule.
        let devBoundary = 5000
        let region: Range<Int> =
            useDevRegion
            ? 0..<min(devBoundary, lines.count)
            : min(devBoundary, lines.count)..<lines.count
        print(
            "inflect eval — sentences.is.txt lines \(region.lowerBound + 1)–\(region.upperBound) "
                + "(\(useDevRegion ? "DEV region (tuning allowed)" : "HELD-OUT region (report-only)"))"
        )

        // ---- Harvest -------------------------------------------------------
        var cases: [Case] = []
        var perGovernor: [String: Int] = [:]
        var seen = Set<String>()
        harvest: for lineIndex in region {
            let tokens = Self.wordTokens(of: String(lines[lineIndex]))
            guard tokens.count >= 2 else { continue }
            for i in 0..<(tokens.count - 1) {
                let governor = tokens[i].lowercased()
                let expected = tokens[i + 1].lowercased()
                guard
                    let entry = governors.governor(of: governor),
                    entry.mass >= config.morphMinGovernorMass,
                    entry.caseProbabilities.max() ?? 0 >= minDominance
                else { continue }
                let expectedChars = Array(expected)
                guard expectedChars.count >= 5 else { continue }
                // Noun after a known governor (the spec's shape); adjectives
                // are harvested separately in a later wave.
                guard paradigms.analyses(ofForm: expected).contains(where: { $0.pos == .noun })
                else { continue }
                guard perGovernor[governor, default: 0] < perGovernorCap else { continue }
                guard seen.insert("\(governor) \(expected)").inserted else { continue }
                let prefixLength = expectedChars.count >= 6 ? 4 : 3
                cases.append(
                    Case(
                        governor: governor,
                        expected: expected,
                        prefix: String(expectedChars.prefix(prefixLength)),
                        line: lineIndex + 1
                    )
                )
                perGovernor[governor, default: 0] += 1
                if cases.count >= maxCases { break harvest }
            }
        }
        print("harvested \(cases.count) (governor, noun) cases across \(perGovernor.count) governors")
        guard !cases.isEmpty else { return 2 }

        // ---- Engines -------------------------------------------------------
        let morphEngine: TypeEngine
        let baselineEngine: TypeEngine
        do {
            morphEngine = try Artifacts.loadEngine(
                paths: paths, morphologyEnabled: true, inflectionEnabled: true, config: config)
            baselineEngine = try Artifacts.loadEngine(
                paths: paths, morphologyEnabled: true, inflectionEnabled: false, config: config)
        } catch {
            warn("inflect: failed to load engines: \(error)")
            return 2
        }

        struct Tally {
            var top1 = 0
            var top3 = 0
        }
        func evaluate(_ engine: TypeEngine, _ c: Case) -> (top1: Bool, top3: Bool, texts: [String]) {
            engine.resetLanguagePosterior()
            // Saturate the Icelandic lane (the harness twin of "was already
            // typing an Icelandic sentence") — same priming as type-eval's
            // accent categories.
            for word in ["og", "að", "er", "og", "að"] { engine.confirmWord(word) }
            let texts = engine.suggestions(
                context: c.governor + " ",
                currentWord: c.prefix,
                limit: 3
            ).map { $0.text.lowercased() }
            return (texts.first == c.expected, texts.contains(c.expected), texts)
        }

        var morphTally = Tally()
        var baseTally = Tally()
        var morphWins = 0
        var morphLosses = 0
        var misses: [String] = []
        for c in cases {
            let morph = evaluate(morphEngine, c)
            let base = evaluate(baselineEngine, c)
            if morph.top1 { morphTally.top1 += 1 }
            if morph.top3 { morphTally.top3 += 1 }
            if base.top1 { baseTally.top1 += 1 }
            if base.top3 { baseTally.top3 += 1 }
            if morph.top1, !base.top1 { morphWins += 1 }
            if base.top1, !morph.top1 { morphLosses += 1 }
            if verbose, morph.top1 != base.top1 {
                misses.append(
                    "  [\(morph.top1 ? "WIN " : "LOSS")] line \(c.line): \(c.governor) \(c.prefix)| -> expected \(c.expected), "
                        + "morph [\(morph.texts.joined(separator: ", "))], "
                        + "baseline [\(base.texts.joined(separator: ", "))]"
                )
            } else if verbose, !morph.top1 {
                misses.append(
                    "  [both] line \(c.line): \(c.governor) \(c.prefix)| -> expected \(c.expected), "
                        + "morph [\(morph.texts.joined(separator: ", "))], "
                        + "baseline [\(base.texts.joined(separator: ", "))]"
                )
            }
        }

        func pct(_ n: Int) -> String {
            String(format: "%5.1f%%", 100.0 * Double(n) / Double(cases.count))
        }
        let n = cases.count
        print("")
        print("engine      n   top-1(form-accuracy)  top-3")
        print("morph    \(String(format: "%4d", n))   \(pct(morphTally.top1))               \(pct(morphTally.top3))")
        print("baseline \(String(format: "%4d", n))   \(pct(baseTally.top1))               \(pct(baseTally.top3))")
        let delta = 100.0 * Double(morphTally.top1 - baseTally.top1) / Double(n)
        print(String(format: "top-1 delta (morph − baseline): %+.1f points", delta))
        print("top-1 breakdown: morph wins \(morphWins), morph losses \(morphLosses)")
        if verbose, !misses.isEmpty {
            print("\ncase detail (flips + shared misses):")
            misses.forEach { print($0) }
        }
        return 0
    }

    /// Letter-run tokens of a sentence (punctuation/digits are boundaries).
    static func wordTokens(of line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in line {
            if character.isLetter {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
