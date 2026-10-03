import EvalKit
import Foundation
import TypeEngine

/// Interactive mode: whatever you type on a line is appended to the document
/// character-by-character through the proxy (trailing spaces survive, so
/// "hestur " commits the word). Lines starting with ':' are commands.
struct Repl {
    let engine: TypeEngine

    func run(limit: Int) {
        let typist = Typist(engine: engine, limit: limit)
        var showPerCharTiming = false

        print(
            """
            type-repl — interactive TypeEngine session (real artifacts)
            Input is appended to the document verbatim, one character at a
            time through the proxy window; end a line with a space (or type
            punctuation) to commit the word. Commands:
              :reset            fresh field (document, session, posterior)
              :posterior        print P(Icelandic)
              :word <w>         per-lexicon attestation, calibrated z, lane evidence
              :bigram <p> <w>   per-lexicon bigram counts + contextual z(w|p)
              :compound <w>     compound-analyzer verdict: validity, protection,
                                decomposition, deny-list membership
              :why              decision trace of the LAST suggestions() pass:
                                per-candidate cost/score, margin vs runner-up,
                                which auto-apply rule ran, every gate's value
              :gov <w>          case-government distribution when <w> is a governor
                                (inflection intelligence: P(case | w) from governors.json.gz)
              :learn <w>        session-immediate explicit learn (verbatim-tap path)
              :longpress <c>    type <c> as LONG-PRESS callout characters
                                (deliberateness signal: folding vetoed for the word)
              :tap <c> <dx> <dy>  type <c> with its touch point (within-key
                                normalized offsets, −0.5…+0.5 at the cell
                                edges, x right / y down — coordinate decoding)
              :learned          list personal snapshot + session-learned words
              :touchstats       per-key personal touch stats (stage 2): count,
                                mean offset, σ, ρ, shrinkage weight, gate status
              :events           list learning events emitted so far
              :timing           toggle per-keystroke latency listing
              :context          show proxy window vs full document
              :cursor <pos>     move caret (+n / -n relative, n absolute, start, end)
              :host <text>      host app replaces the document
              :truncate <n>     cap the context window at n chars
              :stale on|off     stale proxy reads after edits
              :backspace [n]    press backspace n times
              :quit
            """
        )

        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { break }

            if line.hasPrefix(":") {
                if handleCommand(
                    line, typist: typist, showPerCharTiming: &showPerCharTiming
                ) { break }
                continue
            }
            guard !line.isEmpty else {
                report(typist, lineLatencies: [], showPerChar: false)
                continue
            }

            let startIndex = typist.latenciesMicros.count
            typist.type(line)
            let lineLatencies = Array(typist.latenciesMicros[startIndex...])
            report(typist, lineLatencies: lineLatencies, showPerChar: showPerCharTiming)
        }
    }

    /// Returns true when the REPL should exit.
    private func handleCommand(
        _ line: String,
        typist: Typist,
        showPerCharTiming: inout Bool
    ) -> Bool {
        let (command, argument) = ScenarioScript.split(line)
        switch command {
        case ":quit", ":q", ":exit":
            return true
        case ":reset":
            typist.reset()
            print("reset: empty document, P(IS)=0.500")
        case ":posterior":
            print("P(IS) = \(String(format: "%.3f", typist.session.probabilityIcelandic))")
        case ":word":
            guard !argument.isEmpty else {
                print("usage: :word <word>")
                break
            }
            let d = engine.laneDiagnostics(for: argument)
            let fIS = d.frequencyIS.map(String.init) ?? "-"
            let fEN = d.frequencyEN.map(String.init) ?? "-"
            print("  is.lex  f=\(fIS)  z=\(String(format: "%+.2f", d.zIS))")
            print("  en.lex  f=\(fEN)  z=\(String(format: "%+.2f", d.zEN))")
            print(
                "  BÍN     \(d.binKnown ? "known" : "-")"
                    + (d.binCases.isEmpty ? "" : "  cases: \(d.binCases.joined(separator: " "))")
                    + "  lemmas: "
                    + (d.binLemmas.isEmpty ? "-" : d.binLemmas.joined(separator: ",")))
            print(
                "  lane evidence log(e_IS/e_EN) = \(String(format: "%+.3f", d.evidence)) nats"
                    + (d.evidence == 0 ? " (uniform — does not move the lane)" : "")
            )
        case ":compound":
            guard !argument.isEmpty else {
                print("usage: :compound <word>")
                break
            }
            let d = engine.compoundDiagnostics(for: argument)
            print(
                "  valid=\(d.typedValid)  protected=\(d.protected)"
                    + "  split=\(d.parts.map { $0.joined(separator: "+") } ?? "-")"
                    + (d.deniedSplit.map { "  DENY -> \"\($0)\"" } ?? ""))
        case ":bigram":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 2 else {
                print("usage: :bigram <previous> <word>")
                break
            }
            let d = engine.bigramDiagnostics(previous: parts[0], word: parts[1])
            let bIS = d.bigramIS.map(String.init) ?? "-"
            let bEN = d.bigramEN.map(String.init) ?? "-"
            let pIS = d.previousIS.map(String.init) ?? "-"
            let pEN = d.previousEN.map(String.init) ?? "-"
            print("  is.lex  bigram=\(bIS)  f(prev)=\(pIS)  z(w|prev)=\(String(format: "%+.2f", d.zIS))")
            print("  en.lex  bigram=\(bEN)  f(prev)=\(pEN)  z(w|prev)=\(String(format: "%+.2f", d.zEN))")
        case ":why":
            if let trace = typist.lastTrace {
                print(trace.report)
            } else {
                print("  (no suggestions() pass recorded yet)")
            }
        case ":gov":
            guard !argument.isEmpty else {
                print("usage: :gov <word>")
                break
            }
            if let d = engine.governorDiagnostics(for: argument) {
                let distribution = d.cases
                    .map { "\($0.name)=\(String(format: "%.3f", $0.p))" }
                    .joined(separator: "  ")
                print(
                    "  governor \"\(argument)\": mass=\(String(format: "%.0f", d.mass))"
                        + "  entropy_ratio=\(String(format: "%.3f", d.entropyRatio))"
                )
                print("  P(case | \(argument)): \(distribution)")
            } else {
                print(
                    "  \"\(argument)\" is not a known governor"
                        + " (no inflection model loaded, or below the artifact's mass/entropy filters)"
                )
            }
        case ":longpress":
            guard !argument.isEmpty else {
                print("usage: :longpress <characters>")
                break
            }
            typist.longPress(ScenarioScript.unquote(argument))
            report(typist, lineLatencies: [], showPerChar: false)
        case ":tap":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0].count == 1,
                let character = parts[0].first,
                let dx = Double(parts[1]), let dy = Double(parts[2])
            else {
                print("usage: :tap <char> <dx> <dy>   (offsets in −0.5…+0.5)")
                break
            }
            typist.tapCharacter(character, dx: dx, dy: dy)
            report(typist, lineLatencies: [typist.lastLatencyMicros], showPerChar: false)
        case ":learn":
            guard !argument.isEmpty else {
                print("usage: :learn <word>")
                break
            }
            typist.learnWord(argument)
            if engine.isPersonalWord(argument) {
                print("session-learned \"\(argument)\" (valid + suggestible immediately)")
            } else {
                print(
                    "NOT learned: \"\(argument)\" is not a learnable word here "
                        + "(field kind \(typist.session.fieldKind.rawValue), or fails EventLog validation)"
                )
            }
        case ":learned":
            let snapshot = engine.personalSnapshotWords
            let session = engine.sessionLearnedWords
            print("  snapshot (\(snapshot.count)): \(snapshot.isEmpty ? "-" : snapshot.joined(separator: " "))")
            print("  session  (\(session.count)): \(session.isEmpty ? "-" : session.joined(separator: " "))")
        case ":touchstats":
            guard let touch = engine.personalTouchSnapshot, !touch.isEmpty else {
                print("  (no personal touch model loaded — use --personal <model.json>)")
                break
            }
            let config = engine.config
            print(
                "  gate: count >= \(String(format: "%.0f", config.touchPersonalMinSamples))"
                    + "  shrinkage w = n/(n+\(String(format: "%.0f", config.touchPriorStrength)))"
                    + "  prior σ = (\(String(format: "%.3f", config.tapSigmaX)),"
                    + " \(String(format: "%.3f", config.tapSigmaY)))"
            )
            for char in touch.keys {
                guard let stats = touch.stats(for: char) else { continue }
                let weight = stats.count / (stats.count + config.touchPriorStrength)
                let sigmaX = stats.varianceX >= 0 ? stats.varianceX.squareRoot() : .nan
                let sigmaY = stats.varianceY >= 0 ? stats.varianceY.squareRoot() : .nan
                let rho =
                    sigmaX > 0 && sigmaY > 0
                    ? stats.covarianceXY / (sigmaX * sigmaY) : 0
                let active = stats.count >= config.touchPersonalMinSamples
                print(
                    "  \(char)  n=\(String(format: "%7.1f", stats.count))"
                        + "  mean=(\(String(format: "%+.3f", stats.meanDX)),"
                        + " \(String(format: "%+.3f", stats.meanDY)))"
                        + "  σ=(\(String(format: "%.3f", sigmaX)),"
                        + " \(String(format: "%.3f", sigmaY)))"
                        + "  ρ=\(String(format: "%+.2f", rho))"
                        + "  w=\(String(format: "%.2f", weight))"
                        + "  \(active ? "ACTIVE" : "below gate (prior)")"
                )
            }
        case ":events":
            typist.collectPendingEvents()
            if typist.collectedEvents.isEmpty {
                print("  (no learning events)")
            } else {
                for event in typist.collectedEvents {
                    print("  \(event)")
                }
            }
        case ":timing":
            showPerCharTiming.toggle()
            print("per-keystroke timing \(showPerCharTiming ? "on" : "off")")
        case ":context":
            print("window : \"\(typist.lastContextBefore)\"")
            print("document: \"\(typist.proxy.document)\" (cursor at \(typist.proxy.cursor))")
        case ":cursor":
            switch argument {
            case "start": typist.proxy.moveCursor(to: 0)
            case "end": typist.proxy.moveCursor(to: typist.proxy.document.count)
            default:
                if argument.hasPrefix("+") || argument.hasPrefix("-") {
                    typist.proxy.moveCursor(by: Int(argument) ?? 0)
                } else {
                    typist.proxy.moveCursor(to: Int(argument) ?? typist.proxy.cursor)
                }
            }
            typist.externalChange()
            report(typist, lineLatencies: [], showPerChar: false)
        case ":host":
            typist.proxy.hostReplaceText(ScenarioScript.unquote(argument))
            typist.externalChange()
            report(typist, lineLatencies: [], showPerChar: false)
        case ":truncate":
            typist.proxy.truncation.maxBeforeLength = Int(argument) ?? .max
            print("context window capped at \(typist.proxy.truncation.maxBeforeLength) chars")
        case ":stale":
            typist.proxy.staleReads = (argument == "on")
            print("stale reads \(typist.proxy.staleReads ? "on" : "off")")
        case ":backspace":
            typist.pressBackspace(Int(argument) ?? 1)
            report(typist, lineLatencies: [typist.lastLatencyMicros], showPerChar: false)
        default:
            print("unknown command: \(command)")
        }
        return false
    }

    private func report(_ typist: Typist, lineLatencies: [Double], showPerChar: Bool) {
        let window = typist.lastContextBefore
        let tail = window.count > 48 ? "…" + window.suffix(48) : window
        print("  window   \"\(tail)\"")
        if let applied = typist.lastAppliedAutocorrect {
            print("  applied  autocorrect \"\(applied.from)\" -> \"\(applied.to)\"")
        }
        print("  bar      \(typist.barDescription)")
        print("  space    \(typist.spaceCommitDescription)")
        let p = typist.session.probabilityIcelandic
        let last = typist.lastLatencyMicros
        let lineMax = lineLatencies.max() ?? last
        print(
            "  state    P(IS)=\(String(format: "%.3f", p))"
                + "  commits=\(typist.session.committedWordCount)"
                + "  suggestions()=\(String(format: "%.0f", last)) us"
                + (lineLatencies.count > 1
                    ? " (line max \(String(format: "%.0f", lineMax)) us)" : "")
        )
        if showPerChar, !lineLatencies.isEmpty {
            let listing = lineLatencies
                .map { String(format: "%.0f", $0) }
                .joined(separator: " ")
            print("  timing   [\(listing)] us")
        }
    }
}
