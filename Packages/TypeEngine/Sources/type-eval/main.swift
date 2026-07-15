import Foundation
import TypeEngine

// type-eval: micro-evaluation harness for the TypeEngine corrector.
//
// Reads a TSV of (typo, expected, lang) rows — bundled fixture by default,
// or a path passed as argv[1] — runs each typo through a TypeEngine seeded
// with small realistic DictLexicon doubles, and reports:
//   * top-1 / top-3 accuracy (per language and overall)
//   * autocorrect firing rate and false-autocorrect rate
//     (autocorrect fired but the replacement is not the expected word)
//   * valid-word safety: every *expected* word typed verbatim must produce
//     zero isAutocorrect=true suggestions (the conservatism invariant)
//
// This harness grows with the project; nothing here touches real .lex files.

struct EvalCase {
    let typo: String
    let expected: String
    let lang: String
}

func loadCases() -> [EvalCase] {
    let url: URL
    if CommandLine.arguments.count > 1 {
        url = URL(fileURLWithPath: CommandLine.arguments[1])
    } else if let bundled = Bundle.module.url(forResource: "eval-fixture", withExtension: "tsv") {
        url = bundled
    } else {
        FileHandle.standardError.write(Data("error: bundled eval-fixture.tsv not found\n".utf8))
        exit(1)
    }
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: cannot read \(url.path)\n".utf8))
        exit(1)
    }
    var cases: [EvalCase] = []
    for line in raw.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let cols = trimmed.split(separator: "\t").map(String.init)
        guard cols.count == 3 else {
            FileHandle.standardError.write(Data("warning: skipping malformed line: \(trimmed)\n".utf8))
            continue
        }
        cases.append(EvalCase(typo: cols[0], expected: cols[1], lang: cols[2]))
    }
    return cases
}

struct Tally {
    var total = 0
    var top1 = 0
    var top3 = 0
    var autocorrectFired = 0
    var falseAutocorrect = 0

    func pct(_ n: Int) -> String {
        total == 0 ? "  n/a" : String(format: "%5.1f%%", 100.0 * Double(n) / Double(total))
    }
}

let cases = loadCases()
let icelandic = DictLexicon(
    unigrams: EvalWordlists.icelandic,
    bigrams: EvalWordlists.icelandicBigrams
)
let english = DictLexicon(
    unigrams: EvalWordlists.english,
    bigrams: EvalWordlists.englishBigrams
)
// Neutral posterior throughout: no confirmWord calls, each row is judged
// language-blind exactly like the first word in a fresh text field.
let engine = TypeEngine(
    icelandic: icelandic,
    english: english,
    morphologyProvider: nil
)

var perLang: [String: Tally] = [:]
var failures: [(EvalCase, [String])] = []

let clock = ContinuousClock()
let elapsed = clock.measure {
    for c in cases {
        let suggestions = engine.suggestions(context: "", currentWord: c.typo, limit: 3)
        var tally = perLang[c.lang, default: Tally()]
        tally.total += 1
        let texts = suggestions.map(\.text)
        if texts.first == c.expected { tally.top1 += 1 }
        if texts.contains(c.expected) { tally.top3 += 1 }
        if suggestions.first?.isAutocorrect == true {
            tally.autocorrectFired += 1
            if texts.first != c.expected { tally.falseAutocorrect += 1 }
        }
        if texts.first != c.expected {
            failures.append((c, texts))
        }
        perLang[c.lang] = tally
    }
}

// Conservatism control: type every expected word verbatim; none may
// auto-replace (they are all in-lexicon). Multi-word expectations (the
// "split" category: "hello world") are checked word-by-word — each half is
// a valid word the user could type on its own.
let expectedWords = Set(
    cases.flatMap { $0.expected.split(separator: " ").map(String.init) }
)
var validWordViolations: [String] = []
for word in expectedWords {
    let suggestions = engine.suggestions(context: "", currentWord: word, limit: 3)
    if suggestions.contains(where: { $0.isAutocorrect }) {
        validWordViolations.append(word)
    }
}

// ---- Report ----------------------------------------------------------------

var overall = Tally()
for tally in perLang.values {
    overall.total += tally.total
    overall.top1 += tally.top1
    overall.top3 += tally.top3
    overall.autocorrectFired += tally.autocorrectFired
    overall.falseAutocorrect += tally.falseAutocorrect
}

let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
print("type-eval — \(overall.total) cases, \(String(format: "%.1f", ms)) ms total")
print("")
print("lang     n   top-1    top-3   ac-fired  false-ac")
for (lang, tally) in perLang.sorted(by: { $0.key < $1.key }) {
    print(
        "\(lang.padding(toLength: 5, withPad: " ", startingAt: 0)) "
            + String(format: "%4d", tally.total)
            + "  \(tally.pct(tally.top1))  \(tally.pct(tally.top3))"
            + "   \(tally.pct(tally.autocorrectFired))   \(tally.pct(tally.falseAutocorrect))"
    )
}
print(
    "all   "
        + String(format: "%4d", overall.total)
        + "  \(overall.pct(overall.top1))  \(overall.pct(overall.top3))"
        + "   \(overall.pct(overall.autocorrectFired))   \(overall.pct(overall.falseAutocorrect))"
)
print("")
if validWordViolations.isEmpty {
    print(
        "valid-word safety: OK — 0/\(expectedWords.count) expected words auto-replaced when typed verbatim"
    )
} else {
    print("valid-word safety: VIOLATIONS — \(validWordViolations.sorted().joined(separator: ", "))")
}

if !failures.isEmpty {
    print("\ntop-1 misses:")
    for (c, texts) in failures {
        let got = texts.isEmpty ? "(none)" : texts.joined(separator: ", ")
        print("  [\(c.lang)] \(c.typo) -> expected \(c.expected), got \(got)")
    }
}

exit(validWordViolations.isEmpty ? 0 : 1)
