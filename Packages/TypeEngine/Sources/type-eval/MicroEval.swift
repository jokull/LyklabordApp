import Foundation
import TypeEngine

// The micro-evaluation: a small curated TSV fixture of (typo, expected,
// lang[, context]) rows run through TypeEngines seeded with DictLexicon
// doubles (EvalWordlists + the lane-relaxation AccentWordlists pack). See the
// header of the original main.swift for the full category semantics. This
// file factors that logic into callable functions so the scorecard and the
// A/B mode can run it under an arbitrary EngineConfig.

struct EvalCase {
    let typo: String
    let expected: String
    let lang: String
    let context: String
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

/// Load the fixture rows (bundled `eval-fixture.tsv`, or a path override).
func loadCases(path: String? = nil) -> [EvalCase] {
    let url: URL
    if let path {
        url = URL(fileURLWithPath: path)
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
        guard cols.count == 3 || cols.count == 4 else {
            FileHandle.standardError.write(Data("warning: skipping malformed line: \(trimmed)\n".utf8))
            continue
        }
        cases.append(
            EvalCase(
                typo: cols[0], expected: cols[1], lang: cols[2],
                context: cols.count == 4 ? cols[3] : ""))
    }
    return cases
}

enum LanePriming: Equatable {
    case neutral
    case icelandic
    case english
}

struct MicroEvalResult {
    var perLang: [String: Tally]
    var overall: Tally
    var failures: [(EvalCase, [String])]
    var validWordViolations: [String]
    var safetyChecked: Int
    var elapsedMs: Double
}

/// Run the micro-eval under `config`. Builds a fresh engine pair (base +
/// lane-relaxation pack) so an A/B config override is fully applied.
func runMicroEval(cases: [EvalCase], config: EngineConfig = EngineConfig()) -> MicroEvalResult {
    let baseEngine = TypeEngine(
        icelandic: DictLexicon(
            unigrams: EvalWordlists.icelandic, bigrams: EvalWordlists.icelandicBigrams),
        english: DictLexicon(
            unigrams: EvalWordlists.english, bigrams: EvalWordlists.englishBigrams),
        morphologyProvider: nil, config: config)

    let accentEngine = TypeEngine(
        icelandic: DictLexicon(
            unigrams: AccentWordlists.merged(EvalWordlists.icelandic, AccentWordlists.icelandic),
            bigrams: AccentWordlists.merged(
                EvalWordlists.icelandicBigrams, AccentWordlists.icelandicBigrams)),
        english: DictLexicon(
            unigrams: AccentWordlists.merged(EvalWordlists.english, AccentWordlists.english),
            bigrams: AccentWordlists.merged(
                EvalWordlists.englishBigrams, AccentWordlists.englishBigrams)),
        morphologyProvider: nil, config: config)

    func setup(for lang: String) -> (engine: TypeEngine, lane: LanePriming) {
        switch lang {
        case "accentlazy", "accentguard": return (accentEngine, .icelandic)
        case "apos", "aposguard": return (accentEngine, .english)
        default: return (baseEngine, .neutral)
        }
    }

    func prime(_ engine: TypeEngine, lane: LanePriming) {
        engine.resetLanguagePosterior()
        let words: [String]
        switch lane {
        case .neutral: return
        case .icelandic: words = ["og", "að", "er", "og", "að"]
        case .english: words = ["the", "and", "with", "the", "and"]
        }
        for word in words { engine.confirmWord(word) }
    }

    var perLang: [String: Tally] = [:]
    var failures: [(EvalCase, [String])] = []
    var currentSetup: (engine: TypeEngine, lane: LanePriming) = (baseEngine, .neutral)
    prime(baseEngine, lane: .neutral)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for c in cases {
            let wanted = setup(for: c.lang)
            if wanted.engine !== currentSetup.engine || wanted.lane != currentSetup.lane {
                currentSetup = wanted
                prime(wanted.engine, lane: wanted.lane)
            }
            let suggestions = wanted.engine.suggestions(
                context: c.context, currentWord: c.typo, limit: 3)
            var tally = perLang[c.lang, default: Tally()]
            tally.total += 1
            let texts = suggestions.map(\.text)
            let fired = suggestions.first?.isAutocorrect == true
            if c.typo == c.expected {
                if fired {
                    tally.autocorrectFired += 1
                    tally.falseAutocorrect += 1
                    failures.append((c, texts))
                } else {
                    tally.top1 += 1
                    tally.top3 += 1
                }
            } else {
                if texts.first == c.expected { tally.top1 += 1 }
                if texts.contains(c.expected) { tally.top3 += 1 }
                if fired {
                    tally.autocorrectFired += 1
                    if texts.first != c.expected { tally.falseAutocorrect += 1 }
                }
                if texts.first != c.expected { failures.append((c, texts)) }
            }
            perLang[c.lang] = tally
        }
    }

    // Valid-word safety control: type every expected word verbatim; none may
    // auto-replace (they are all in-lexicon), at their category's primed lane.
    var validWordViolations: [String] = []
    var safetyChecked = 0
    var safetySetups: [String: (engine: TypeEngine, lane: LanePriming, words: Set<String>)] = [:]
    for c in cases {
        let key = "\(setup(for: c.lang).lane)"
        let s = setup(for: c.lang)
        var entry = safetySetups[key] ?? (s.engine, s.lane, [])
        for word in c.expected.split(separator: " ").map(String.init) {
            entry.words.insert(word)
        }
        safetySetups[key] = entry
    }
    for (_, entry) in safetySetups.sorted(by: { $0.key < $1.key }) {
        prime(entry.engine, lane: entry.lane)
        for word in entry.words.sorted() {
            safetyChecked += 1
            let suggestions = entry.engine.suggestions(context: "", currentWord: word, limit: 3)
            if suggestions.contains(where: { $0.isAutocorrect }) {
                validWordViolations.append(word)
            }
        }
    }

    var overall = Tally()
    for tally in perLang.values {
        overall.total += tally.total
        overall.top1 += tally.top1
        overall.top3 += tally.top3
        overall.autocorrectFired += tally.autocorrectFired
        overall.falseAutocorrect += tally.falseAutocorrect
    }

    let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return MicroEvalResult(
        perLang: perLang, overall: overall, failures: failures,
        validWordViolations: validWordViolations, safetyChecked: safetyChecked, elapsedMs: ms)
}

/// The human report (unchanged output from the original main.swift).
func printMicroEval(_ r: MicroEvalResult) {
    print("type-eval — \(r.overall.total) cases, \(String(format: "%.1f", r.elapsedMs)) ms total")
    print("")
    print("lang     n   top-1    top-3   ac-fired  false-ac")
    for (lang, tally) in r.perLang.sorted(by: { $0.key < $1.key }) {
        print(
            "\(lang.padding(toLength: 5, withPad: " ", startingAt: 0)) "
                + String(format: "%4d", tally.total)
                + "  \(tally.pct(tally.top1))  \(tally.pct(tally.top3))"
                + "   \(tally.pct(tally.autocorrectFired))   \(tally.pct(tally.falseAutocorrect))")
    }
    print(
        "all   "
            + String(format: "%4d", r.overall.total)
            + "  \(r.overall.pct(r.overall.top1))  \(r.overall.pct(r.overall.top3))"
            + "   \(r.overall.pct(r.overall.autocorrectFired))   \(r.overall.pct(r.overall.falseAutocorrect))")
    print("")
    if let lazy = r.perLang["accentlazy"] {
        let guardTally = r.perLang["accentguard"] ?? Tally()
        print(
            "accent restoration rate \(lazy.pct(lazy.autocorrectFired)) "
                + "(top-1 \(lazy.pct(lazy.top1))); "
                + "false restoration on \(guardTally.total) collision skeletons: "
                + "\(guardTally.pct(guardTally.falseAutocorrect))")
    }
    if r.validWordViolations.isEmpty {
        print(
            "valid-word safety: OK — 0/\(r.safetyChecked) expected words auto-replaced when typed verbatim (incl. at primed lanes)")
    } else {
        print("valid-word safety: VIOLATIONS — \(r.validWordViolations.sorted().joined(separator: ", "))")
    }
    if !r.failures.isEmpty {
        print("\ntop-1 misses:")
        for (c, texts) in r.failures {
            let got = texts.isEmpty ? "(none)" : texts.joined(separator: ", ")
            print("  [\(c.lang)] \(c.typo) -> expected \(c.expected), got \(got)")
        }
    }
}
