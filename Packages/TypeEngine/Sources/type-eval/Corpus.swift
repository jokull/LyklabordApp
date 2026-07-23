import EvalKit
import Foundation
import TypeEngine

func stderr(_ message: String) {
    FileHandle.standardError.write(Data("[type-eval] \(message)\n".utf8))
}

/// `type-eval corpus <dev|heldout|compounds|safety>` — replay a corpus split
/// through the real artifacts and print the per-category / per-language /
/// overall table. `compounds` is the wave-31 iceErrorCorpus compound slice
/// (data/eval/compounds.jsonl — real error→correction pairs; several of its
/// categories track structural gaps and protection assertions, see
/// data/eval/README.md).
///
/// Debug flags (dev-iteration tooling, no effect on the table):
///   --dump <failures|false-ac>   per-pair dump instead of the table
///   --category <name>            restrict the dump to one category
func runCorpusCommand(_ args: [String]) {
    guard let split = args.first, ["dev", "heldout", "compounds", "safety"].contains(split) else {
        stderr(
            "usage: type-eval corpus <dev|heldout|compounds|safety> [--dump failures|false-ac] [--category c]"
        )
        exit(2)
    }
    var dumpMode: String?
    var dumpCategory: String?
    var baseConfig = EngineConfig()
    var rest = Array(args.dropFirst())
    while let flag = rest.first {
        rest.removeFirst()
        switch flag {
        case "--dump": dumpMode = rest.isEmpty ? "failures" : rest.removeFirst()
        case "--category": dumpCategory = rest.isEmpty ? nil : rest.removeFirst()
        case "--config":
            guard !rest.isEmpty else {
                stderr("--config requires a path")
                exit(2)
            }
            do {
                (baseConfig, _) = try ConfigOverrides.load(
                    from: URL(fileURLWithPath: rest.removeFirst()))
            } catch {
                stderr("config error: \(error)")
                exit(2)
            }
        default:
            stderr("unknown flag \(flag)")
            exit(2)
        }
    }
    if split == "heldout" {
        stderr(
            "REPORT-ONLY: heldout.jsonl must never be tuned against — only reported "
                + "(see scores/README.md).")
    }
    guard let url = ArtifactLoader.corpusURL(split: split) else {
        stderr("cannot locate repo root (data/eval/\(split).jsonl)")
        exit(2)
    }
    let pairs: [CorpusPair]
    do {
        pairs = try Corpus.loadCorpus(at: url)
    } catch {
        stderr("\(error)")
        exit(2)
    }
    let engine: TypeEngine
    do {
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(base: baseConfig), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()
    if let dumpMode {
        dumpCorpusPairs(engine: engine, pairs: pairs, mode: dumpMode, category: dumpCategory)
        return
    }
    let result = CorpusEval.run(engine: engine, pairs: pairs, split: split)
    printCorpusResult(result)
}

/// `type-eval export-candidates <dev|safety>` — emit one JSON object per row
/// with the real corrector's scored candidate pool. This is deliberately
/// limited to tuning/protection data: offline ranker studies may consume it,
/// while heldout remains report-only and cannot accidentally become training
/// data.
func runExportCandidatesCommand(_ args: [String]) {
    guard args.count == 1, ["dev", "safety"].contains(args[0]) else {
        stderr("usage: type-eval export-candidates <dev|safety>")
        exit(2)
    }
    let split = args[0]
    guard let url = ArtifactLoader.corpusURL(split: split) else {
        stderr("cannot locate repo root (data/eval/\(split).jsonl)")
        exit(2)
    }
    let pairs: [CorpusPair]
    let engine: TypeEngine
    do {
        pairs = try Corpus.loadCorpus(at: url)
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(base: EngineConfig()),
            log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    for (index, pair) in pairs.enumerated() {
        engine.resetLanguagePosterior()
        for word in pair.context { engine.confirmWord(word) }
        let trace = CorrectionTrace()
        let suggestions = engine.suggestions(
            context: pair.context.joined(separator: " "),
            currentWord: pair.typo,
            // Match the keyboard/corpus production surface. CorrectionTrace
            // still captures up to eight internal candidates for offline
            // pairwise analysis without widening bounded discovery work.
            limit: 3,
            trace: trace)
        let record = CandidateExportRecord(
            row: index + 1,
            typo: pair.typo,
            intended: pair.intended,
            context: pair.context,
            lang: pair.lang,
            category: pair.category,
            expectation: pair.expectation.rawValue,
            pIcelandic: trace.pIcelandic,
            autocorrect: suggestions.first?.isAutocorrect == true,
            suggestions: suggestions.map(\.text),
            candidates: trace.candidates.map {
                CandidateExportRecord.Candidate(
                    word: $0.word,
                    score: $0.score,
                    languageScore: $0.languageScore,
                    contextEvidence: $0.contextEvidence)
            })
        do {
            FileHandle.standardOutput.write(try encoder.encode(record))
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            stderr("cannot encode row \(index + 1): \(error)")
            exit(2)
        }
    }
}

private struct CandidateExportRecord: Encodable {
    struct Candidate: Encodable {
        let word: String
        let score: Double
        let languageScore: Double
        let contextEvidence: Double?
    }

    let row: Int
    let typo: String
    let intended: String
    let context: [String]
    let lang: String
    let category: String
    let expectation: String
    let pIcelandic: Double
    let autocorrect: Bool
    let suggestions: [String]
    let candidates: [Candidate]
}

/// Per-pair debug dump (mirrors CorpusEval.run's replay exactly): one line
/// per selected pair with the typo, intended, tail context and the top
/// suggestions (with autocorrect flags). `mode` selects which pairs print:
///   failures  — top-1 misses
///   false-ac  — auto-apply fired on a wrong top candidate
func dumpCorpusPairs(engine: TypeEngine, pairs: [CorpusPair], mode: String, category: String?) {
    for pair in pairs {
        if let category, pair.category != category { continue }
        engine.resetLanguagePosterior()
        for word in pair.context { engine.confirmWord(word) }
        let context = pair.context.joined(separator: " ")
        let suggestions = engine.suggestions(context: context, currentWord: pair.typo, limit: 3)
        let texts = suggestions.map(\.text)
        let fired = suggestions.first?.isAutocorrect == true
        let target = pair.expectation == .preserve ? pair.typo : pair.intended
        let top1 = texts.first == target
        switch mode {
        case "failures": if top1 { continue }
        case "false-ac": if !(fired && !top1) { continue }
        default:
            stderr("unknown dump mode \(mode)")
            exit(2)
        }
        let rendered = suggestions.map { s in
            "\(s.text)\(s.isAutocorrect ? "*" : "")\(s.isRestoration ? "~" : "")"
        }.joined(separator: " | ")
        let tail = pair.context.suffix(3).joined(separator: " ")
        print(
            "[\(pair.category)/\(pair.lang)]\(fired ? " AC" : "") "
                + "typo=\(pair.typo) target=\(target) source-intended=\(pair.intended) "
                + "ctx=…\(tail) -> \(rendered)")
    }
}

func pct(_ tally: CorpusTally, _ n: Int) -> String {
    tally.total == 0 ? "  n/a" : String(format: "%5.1f%%", tally.percent(n))
}

func printCorpusResult(_ result: CorpusResult, label: String? = nil) {
    let header = label ?? "corpus \(result.split)"
    print(
        "\(header) — \(result.overall.total) pairs, "
            + "\(String(format: "%.1f", result.runtimeSeconds)) s "
            + "(\(String(format: "%.2f", result.runtimeSeconds * 1000 / Double(max(result.overall.total, 1)))) ms/pair)")
    print("")
    print("category              n   top-1    top-3   ac-fired  false-ac")
    for category in result.byCategory.keys.sorted() {
        let t = result.byCategory[category]!
        print(
            "\(category.padding(toLength: 18, withPad: " ", startingAt: 0))"
                + String(format: "%5d", t.total)
                + "  \(pct(t, t.top1))  \(pct(t, t.top3))"
                + "   \(pct(t, t.autocorrectFired))   \(pct(t, t.falseAutocorrect))")
    }
    print(String(repeating: "-", count: 60))
    for lang in result.byLang.keys.sorted() {
        let t = result.byLang[lang]!
        print(
            "lang \(lang.padding(toLength: 13, withPad: " ", startingAt: 0))"
                + String(format: "%5d", t.total)
                + "  \(pct(t, t.top1))  \(pct(t, t.top3))"
                + "   \(pct(t, t.autocorrectFired))   \(pct(t, t.falseAutocorrect))")
    }
    let o = result.overall
    print(
        "all               "
            + String(format: "%5d", o.total)
            + "  \(pct(o, o.top1))  \(pct(o, o.top3))"
            + "   \(pct(o, o.autocorrectFired))   \(pct(o, o.falseAutocorrect))")
    let stageText = CorpusOutcomeStage.allCases.map {
        "\($0.rawValue)=\(result.stagesOverall[$0])"
    }.joined(separator: " ")
    print("stages: \(stageText)")
}
