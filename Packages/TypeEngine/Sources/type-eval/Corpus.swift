import EvalKit
import Foundation
import TypeEngine

func stderr(_ message: String) {
    FileHandle.standardError.write(Data("[type-eval] \(message)\n".utf8))
}

/// `type-eval corpus <dev|heldout>` — replay a corpus split through the real
/// artifacts and print the per-category / per-language / overall table.
func runCorpusCommand(_ args: [String]) {
    guard let split = args.first, split == "dev" || split == "heldout" else {
        stderr("usage: type-eval corpus <dev|heldout>")
        exit(2)
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
            config: ArtifactLoader.deterministicConfig(), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()
    let result = CorpusEval.run(engine: engine, pairs: pairs, split: split)
    printCorpusResult(result)
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
}
