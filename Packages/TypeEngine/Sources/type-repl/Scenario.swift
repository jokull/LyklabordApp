import Foundation
import TypeEngine

/// Batch mode: replay line-based scenario files through the proxy + session
/// and check expectations. See Scenarios/core.scenarios for the format.
///
/// Format cheatsheet (one directive per line, `#` comments, blank lines ok):
///
///   SCENARIO <name>          start a scenario (fresh proxy, session, posterior)
///   LIMIT <n>                suggestion bar size for following scenarios (default 5)
///   T <text>                 type text char-by-char; quote to keep spaces: T "hestur "
///   LONGPRESS <text>         type text as long-press CALLOUT selections
///                            (deliberateness veto on lane-relaxation folding)
///   BACKSPACE [n]            press backspace n times (default 1)
///   CURSOR_MOVE <pos>        move caret: +n / -n relative, n absolute, start, end
///   CURSOR_MOVE_SILENT <pos> same, WITHOUT noteExternalTextChange (tests the
///                            session's internal window-change detection)
///   HOST_SET <text>          host app replaces the document (cursor at end)
///   HOST_SET_SILENT <text>   same, WITHOUT noteExternalTextChange
///   NOTE_WINDOW              forward the current window to the session like
///                            the extension's textDidChange/selectionDidChange
///                            (idempotent window-aware note)
///   TRUNCATE_AT <n>          cap the context window at n chars (proxy truncation)
///   STALE_READS on|off       next proxy read after each edit returns pre-edit text
///   SWALLOW_EDITS on|off     host discards keyboard edits before the next
///                            observation read (the ledger's "self-edit
///                            never confirmed" degradation case)
///   PREDICT_SPACE            spacebar mode 2: insert the top bar prediction
///                            then a space (no word may be in progress;
///                            fails when the bar has no prediction)
///   REFRESH                  re-read proxy + re-run autocomplete (no keystroke)
///   FIELD <kind>             field type: standard|url|email|webSearch (layer 2 gate)
///   TAP <text>               tap the bar suggestion with exactly this text
///                            (KeyboardKit tap semantics: replace token + space)
///   TAP <char> <dx> <dy>     type ONE character with its touch point —
///                            within-key normalized offsets from the key
///                            center (−0.5…+0.5 at the cell edges, x right,
///                            y down; PLAN.md "Touch decoding"). Selected
///                            over the suggestion-tap form when the
///                            argument parses as exactly (1 char, number,
///                            number).
///   DOT_APPLY on|off         model STOCK KeyboardKit '.'-autocorrect-apply
///                            (off = our action handler's deferral, the default)
///
///   Personal learning (M2). Seed directives build an in-memory personal
///   snapshot for the CURRENT scenario (replacing any `--personal` baseline
///   until the next SCENARIO resets to it):
///
///   PERSONAL <word> <count>            seed a learned personal word
///                                      (IMPLICIT: organically threshold-
///                                      learned — acute-fold shadows lose
///                                      the autocorrect veto, wave 26)
///   PERSONAL_EXPLICIT <word> [count]   seed a DELIBERATELY learned word
///                                      (dictionary-editor add / verbatim
///                                      tap class: full veto power)
///   PERSONAL_BIGRAM <a> <b> <count>    seed a personal bigram "a b"
///   TOMBSTONE <word>                   seed a deleted (tombstoned) word
///   LEARN <word>                       session-immediate explicit learn
///                                      (same path as a verbatim tap /
///                                      KeyboardKit learnWord forward)
///   PERSONAL_TOUCH <char> <count> <meanDx> <meanDy> <sigmaX> <sigmaY> [cov]
///                                      seed per-key adaptive touch stats
///                                      (stage 2 personal Gaussians; units =
///                                      key pitch, sigmas are STANDARD
///                                      DEVIATIONS, cov defaults to 0);
///                                      replaces any `--personal` touch
///                                      baseline until the next SCENARIO
///
///   NOTE: the verbatim escape-hatch slot (the literal typed token, quoted
///   on device) always leads a non-empty bar; EXPECT_TOP and
///   EXPECT_AUTOCORRECT therefore judge the top NON-verbatim suggestion,
///   while EXPECT_VERBATIM checks the escape-hatch slot itself.
///
///   EXPECT_TOP <word>              top non-verbatim suggestion is exactly <word>
///   EXPECT_AUTOCORRECT <word>      top non-verbatim suggestion is <word> AND flagged autocorrect
///   EXPECT_NO_AUTOCORRECT [word]   no suggestion is flagged autocorrect
///   EXPECT_VERBATIM <word>         bar leads with the verbatim slot <word>
///   EXPECT_ONLY_VERBATIM <word>    bar is exactly the verbatim slot <word>
///   EXPECT_CONTAINS <word>         <word> appears in the bar
///   EXPECT_NOT_CONTAINS <word>     <word> does not appear in the bar
///   EXPECT_NO_SPLIT                no suggestion text contains a space
///                                  (space-miss splits must not be offered)
///   EXPECT_EMPTY                   bar is empty
///   EXPECT_NONEMPTY                bar is not empty
///   EXPECT_POSTERIOR_GT <x>        P(Icelandic) > x
///   EXPECT_POSTERIOR_LT <x>        P(Icelandic) < x
///   EXPECT_COMMITS <n>             exactly n words committed so far
///   EXPECT_LAST_COMMIT <word>      most recent committed word (post-autocorrect)
///   EXPECT_EVENTS <n>              exactly n learning events emitted so far
///                                  (privacy test hook: URL/email/webSearch/
///                                  secure fields must show 0)
///   EXPECT_BUFFER <text>           full proxy document equals <text> (quote for spaces)
///   EXPECT_CONTEXT <text>          window the session last saw equals <text>
struct ScenarioRunner {

    struct Failure {
        let scenario: String
        let line: Int
        let message: String
    }

    let engine: TypeEngine
    var defaultLimit = 5
    /// The `--personal` baseline snapshot, restored at each SCENARIO start.
    var basePersonal: PersonalVocabulary?
    /// The `--personal` baseline TOUCH snapshot, same restore rule.
    var basePersonalTouch: PersonalTouchSnapshot?

    func run(fileAt path: String) -> Int {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            warn("cannot read scenario file: \(path)")
            return 2
        }

        var failures: [Failure] = []
        var scenarioCount = 0
        var passedCount = 0
        var currentName = "(preamble)"
        var currentFailed = false
        var limit = defaultLimit
        var typist = Typist(engine: engine, limit: limit)
        var seeds = SeededPersonalVocabulary()
        var touchSeeds: [Character: PersonalTouchSnapshot.KeyStats] = [:]

        func applySeeds() {
            engine.setPersonalVocabulary(seeds.isEmpty ? basePersonal : seeds)
            engine.setPersonalTouch(
                touchSeeds.isEmpty
                    ? basePersonalTouch
                    : PersonalTouchSnapshot(keys: touchSeeds)
            )
        }

        func finishScenario() {
            guard scenarioCount > 0 else { return }
            print("  \(currentFailed ? "FAIL" : "ok  ")  \(currentName)")
            if !currentFailed { passedCount += 1 }
        }

        let lines = raw.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, argument) = Self.split(line)

            func fail(_ message: String) {
                failures.append(Failure(scenario: currentName, line: lineNo, message: message))
                currentFailed = true
            }

            func expectBar(_ check: ([Suggestion]) -> String?) {
                if let message = check(typist.lastSuggestions) { fail(message) }
            }

            switch keyword {
            case "SCENARIO":
                finishScenario()
                scenarioCount += 1
                currentName = argument
                currentFailed = false
                seeds = SeededPersonalVocabulary()
                touchSeeds = [:]
                applySeeds()  // back to the --personal baseline (or none)
                typist = Typist(engine: engine, limit: limit)
                typist.reset()  // also clears the session-learned overlay

            case "LIMIT":
                limit = Int(argument) ?? limit
                typist.limit = limit

            case "T":
                typist.type(Self.unquote(argument))

            case "LONGPRESS":
                // Type the characters as long-press callout selections
                // (deliberateness signal: lane-relaxation folding vetoed
                // for the pending word).
                typist.longPress(Self.unquote(argument))

            case "BACKSPACE":
                typist.pressBackspace(Int(argument) ?? 1)

            case "CURSOR_MOVE", "CURSOR_MOVE_SILENT":
                switch argument {
                case "start": typist.proxy.moveCursor(to: 0)
                case "end": typist.proxy.moveCursor(to: typist.proxy.document.count)
                default:
                    if argument.hasPrefix("+") || argument.hasPrefix("-") {
                        typist.proxy.moveCursor(by: Int(argument) ?? 0)
                    } else if let absolute = Int(argument) {
                        typist.proxy.moveCursor(to: absolute)
                    } else {
                        fail("bad \(keyword) argument: \(argument)")
                    }
                }
                // SILENT = no noteExternalTextChange: exercises the
                // session's internal cursor-jump detection.
                if keyword == "CURSOR_MOVE" {
                    typist.externalChange()
                } else {
                    typist.silentExternalChange()
                }

            case "HOST_SET", "HOST_SET_SILENT":
                typist.proxy.hostReplaceText(Self.unquote(argument))
                if keyword == "HOST_SET" {
                    typist.externalChange()
                } else {
                    typist.silentExternalChange()
                }

            case "NOTE_WINDOW":
                // The extension's textDidChange/selectionDidChange
                // forwarding (idempotent window-aware note), which also
                // fires after our own insertions on device.
                typist.forwardWindowNote()

            case "TRUNCATE_AT":
                if let n = Int(argument) {
                    typist.proxy.truncation.maxBeforeLength = n
                } else {
                    fail("bad TRUNCATE_AT argument: \(argument)")
                }

            case "STALE_READS":
                typist.proxy.staleReads = (argument == "on")

            case "SWALLOW_EDITS":
                typist.proxy.swallowEdits = (argument == "on")

            case "PREDICT_SPACE":
                // Spacebar mode 2 ("always insert a prediction"): top bar
                // prediction + space, ledger-recorded like every self-edit.
                if !typist.predictSpace() {
                    fail(
                        "PREDICT_SPACE needs no word in progress and a prediction in the bar: \(Self.describe(typist.lastSuggestions))"
                    )
                }

            case "REFRESH":
                typist.refresh()

            case "FIELD":
                if let kind = FieldKind(rawValue: argument) {
                    typist.session.fieldKind = kind
                } else {
                    fail("bad FIELD argument: \(argument)")
                }

            case "DOT_APPLY":
                typist.appliesAutocorrectOnDot = (argument == "on")

            case "TAP":
                // Touch-tap form: TAP <char> <dx> <dy> (see cheatsheet).
                let parts = argument.split(separator: " ").map(String.init)
                if parts.count == 3, parts[0].count == 1,
                    let character = parts[0].first,
                    let dx = Double(parts[1]), let dy = Double(parts[2])
                {
                    typist.tapCharacter(character, dx: dx, dy: dy)
                } else if !typist.tapSuggestion(Self.unquote(argument)) {
                    fail("no suggestion \"\(argument)\" to tap, bar: \(Self.describe(typist.lastSuggestions))")
                }

            case "PERSONAL":
                let parts = argument.split(separator: " ").map(String.init)
                if parts.count == 2, let count = UInt32(parts[1]) {
                    seeds.words[parts[0]] = count
                    applySeeds()
                } else {
                    fail("usage: PERSONAL <word> <count>")
                }

            case "PERSONAL_EXPLICIT":
                let parts = argument.split(separator: " ").map(String.init)
                if parts.count == 1, !parts[0].isEmpty {
                    seeds.words[parts[0]] = max(seeds.words[parts[0]] ?? 0, 1)
                    seeds.explicit.insert(parts[0])
                    applySeeds()
                } else if parts.count == 2, let count = UInt32(parts[1]) {
                    seeds.words[parts[0]] = count
                    seeds.explicit.insert(parts[0])
                    applySeeds()
                } else {
                    fail("usage: PERSONAL_EXPLICIT <word> [count]")
                }

            case "PERSONAL_BIGRAM":
                let parts = argument.split(separator: " ").map(String.init)
                if parts.count == 3, let count = UInt32(parts[2]) {
                    seeds.bigrams["\(parts[0]) \(parts[1])"] = count
                    applySeeds()
                } else {
                    fail("usage: PERSONAL_BIGRAM <first> <second> <count>")
                }

            case "PERSONAL_TOUCH":
                // <char> <count> <meanDx> <meanDy> <sigmaX> <sigmaY> [cov]
                // — sigmas are standard deviations (squared into the
                // snapshot's variances), cov is the covariance itself.
                let parts = argument.split(separator: " ").map(String.init)
                if parts.count >= 6, parts.count <= 7, parts[0].count == 1,
                    let char = parts[0].first,
                    let count = Double(parts[1]),
                    let meanDx = Double(parts[2]), let meanDy = Double(parts[3]),
                    let sigmaX = Double(parts[4]), let sigmaY = Double(parts[5]),
                    let cov = parts.count == 7 ? Double(parts[6]) : 0
                {
                    touchSeeds[char] = PersonalTouchSnapshot.KeyStats(
                        meanDX: meanDx,
                        meanDY: meanDy,
                        varianceX: sigmaX * sigmaX,
                        varianceY: sigmaY * sigmaY,
                        covarianceXY: cov,
                        count: count
                    )
                    applySeeds()
                } else {
                    fail(
                        "usage: PERSONAL_TOUCH <char> <count> <meanDx> <meanDy> <sigmaX> <sigmaY> [cov]"
                    )
                }

            case "TOMBSTONE":
                if argument.isEmpty {
                    fail("usage: TOMBSTONE <word>")
                } else {
                    seeds.tombstones.insert(argument)
                    applySeeds()
                }

            case "LEARN":
                if argument.isEmpty {
                    fail("usage: LEARN <word>")
                } else {
                    typist.learnWord(argument)
                }

            case "EXPECT_EVENTS":
                typist.collectPendingEvents()
                let n = typist.collectedEvents.count
                if n != Int(argument) {
                    fail("expected \(argument) learning events, got \(n): \(typist.collectedEvents)")
                }

            case "EXPECT_TOP":
                expectBar { bar in
                    bar.first(where: { !$0.isVerbatim })?.text == argument
                        ? nil
                        : "expected top \"\(argument)\", bar: \(Self.describe(bar))"
                }

            case "EXPECT_AUTOCORRECT":
                expectBar { bar in
                    guard let top = bar.first(where: { !$0.isVerbatim }) else {
                        return "expected autocorrect \"\(argument)\", bar: \(Self.describe(bar))"
                    }
                    if top.text != argument {
                        return "expected autocorrect \"\(argument)\", top is \"\(top.text)\"\(top.isAutocorrect ? "*" : "")"
                    }
                    if !top.isAutocorrect {
                        return "top is \"\(top.text)\" but NOT flagged autocorrect"
                    }
                    return nil
                }

            case "EXPECT_VERBATIM":
                expectBar { bar in
                    guard let first = bar.first else {
                        return "expected verbatim \"\(argument)\", bar empty"
                    }
                    if !first.isVerbatim {
                        return "expected verbatim slot first, bar: \(Self.describe(bar))"
                    }
                    if first.text != argument {
                        return "expected verbatim \"\(argument)\", got \"\(first.text)\""
                    }
                    return nil
                }

            case "EXPECT_ONLY_VERBATIM":
                expectBar { bar in
                    guard bar.count == 1, let only = bar.first, only.isVerbatim else {
                        return "expected only the verbatim slot, bar: \(Self.describe(bar))"
                    }
                    if only.text != argument {
                        return "expected verbatim \"\(argument)\", got \"\(only.text)\""
                    }
                    return nil
                }

            case "EXPECT_NO_AUTOCORRECT":
                expectBar { bar in
                    if let flagged = bar.first(where: { $0.isAutocorrect }) {
                        return "autocorrect fired: \"\(flagged.text)\" (bar: \(Self.describe(bar)))"
                    }
                    return nil
                }

            case "EXPECT_CONTAINS":
                expectBar { bar in
                    bar.contains(where: { $0.text == argument })
                        ? nil
                        : "expected \"\(argument)\" in bar: \(Self.describe(bar))"
                }

            case "EXPECT_NOT_CONTAINS":
                expectBar { bar in
                    bar.contains(where: { $0.text == argument })
                        ? "did not expect \"\(argument)\" in bar: \(Self.describe(bar))"
                        : nil
                }

            case "EXPECT_NO_SPLIT":
                expectBar { bar in
                    if let split = bar.first(where: { $0.text.contains(" ") }) {
                        return "split suggestion offered: \"\(split.text)\" (bar: \(Self.describe(bar)))"
                    }
                    return nil
                }

            case "EXPECT_EMPTY":
                expectBar { bar in
                    bar.isEmpty ? nil : "expected empty bar, got: \(Self.describe(bar))"
                }

            case "EXPECT_NONEMPTY":
                expectBar { bar in
                    bar.isEmpty ? "expected non-empty bar" : nil
                }

            case "EXPECT_POSTERIOR_GT":
                let p = typist.session.probabilityIcelandic
                if !(p > (Double(argument) ?? .infinity)) {
                    fail("expected P(IS) > \(argument), got \(String(format: "%.3f", p))")
                }

            case "EXPECT_POSTERIOR_LT":
                let p = typist.session.probabilityIcelandic
                if !(p < (Double(argument) ?? -.infinity)) {
                    fail("expected P(IS) < \(argument), got \(String(format: "%.3f", p))")
                }

            case "EXPECT_COMMITS":
                let n = typist.session.committedWordCount
                if n != Int(argument) {
                    fail("expected \(argument) commits, got \(n)")
                }

            case "EXPECT_LAST_COMMIT":
                let last = typist.session.lastCommittedWord
                if last != argument {
                    fail("expected last commit \"\(argument)\", got \(last.map { "\"\($0)\"" } ?? "none")")
                }

            case "EXPECT_BUFFER":
                let expected = Self.unquote(argument)
                if typist.proxy.document != expected {
                    fail("expected buffer \"\(expected)\", got \"\(typist.proxy.document)\"")
                }

            case "EXPECT_CONTEXT":
                let expected = Self.unquote(argument)
                if typist.lastContextBefore != expected {
                    fail("expected context \"\(expected)\", got \"\(typist.lastContextBefore)\"")
                }

            default:
                fail("unknown directive: \(keyword)")
            }
        }
        finishScenario()

        print("")
        print("\(passedCount)/\(scenarioCount) scenarios passed")
        if !failures.isEmpty {
            print("\nfailures:")
            for f in failures {
                print("  [\(f.scenario)] line \(f.line): \(f.message)")
            }
        }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Parsing helpers

    /// Split "KEYWORD rest of line" into (keyword, argument).
    static func split(_ line: String) -> (keyword: String, argument: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        let keyword = String(line[..<space])
        let argument = String(line[line.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        return (keyword, argument)
    }

    /// Strip surrounding double quotes (used to protect leading/trailing
    /// spaces from editors); non-quoted arguments pass through verbatim.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    static func describe(_ bar: [Suggestion]) -> String {
        bar.isEmpty
            ? "(empty)"
            : bar.map {
                let text = $0.isVerbatim ? "\u{201C}\($0.text)\u{201D}" : $0.text
                return "\(text)\($0.isAutocorrect ? "*" : "")"
            }.joined(separator: ", ")
    }
}
