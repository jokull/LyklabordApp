import Foundation
import TypeEngine

/// One directive line of a `.scenarios` file, lexed but not yet executed.
public struct ScenarioDirective: Equatable, Sendable {
    public let line: Int
    public let keyword: String
    /// Trimmed argument text, quotes intact (`ScenarioScript.unquote` strips
    /// them where a directive takes free text).
    public let argument: String
    /// The physical line (without the newline) — kept so authoring hazards
    /// that trimming hides (an unquoted trailing space) can be diagnosed.
    public let rawLine: String
}

/// A static defect in a scenario file: something the runner must never
/// silently accept. `scenario` is the enclosing SCENARIO name (nil in the
/// preamble); `line` 0 means the file as a whole.
public struct ScenarioDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let scenario: String?
    public let message: String

    public var description: String {
        "[\(scenario ?? "(file)")] line \(line): \(message)"
    }
}

/// Lexer + static validator for the `type-repl run` scenario format (the
/// cheatsheet lives at the top of `type-repl/Scenario.swift`).
///
/// The runner used to parse directives inline and tolerate every authoring
/// mistake it did not have a `case` for: `LIMIT five` kept the old limit,
/// `STALE_READS yes` turned stale reads OFF, `BACKSPACE two` pressed once, an
/// unquoted `T teh ` lost its delimiter, a SCENARIO with no EXPECT lines
/// counted as passing, and an empty file reported `0/0 scenarios passed` with
/// exit 0. Scenario files are behavioural contracts derived from real bug
/// reports, so every one of those is a contract that could not fail.
///
/// `parse` returns the directive stream plus a list of diagnostics. The
/// runner treats each diagnostic as a failure of the enclosing scenario and
/// refuses to execute the offending directive; a file with zero scenarios is
/// rejected outright.
public struct ScenarioScript: Sendable {
    public let directives: [ScenarioDirective]
    public let scenarioCount: Int
    public let diagnostics: [ScenarioDiagnostic]

    /// Diagnostics keyed by line, for the runner's per-directive lookup.
    public var diagnosticsByLine: [Int: [ScenarioDiagnostic]] {
        Dictionary(grouping: diagnostics, by: \.line)
    }

    // MARK: - Directive vocabulary

    /// Directives that drive the proxy/session (no assertion).
    public static let actionDirectives: Set<String> = [
        "SCENARIO", "LIMIT", "T", "LONGPRESS", "BACKSPACE", "CURSOR_MOVE",
        "CURSOR_MOVE_SILENT", "HOST_SET", "HOST_SET_SILENT", "NOTE_WINDOW", "TRUNCATE_AT",
        "STALE_READS", "SWALLOW_EDITS", "PREDICT_SPACE", "REFRESH", "FIELD", "TAP", "DOT_APPLY",
        "PERSONAL", "PERSONAL_EXPLICIT", "PERSONAL_BIGRAM", "PERSONAL_TOUCH", "TOMBSTONE",
        "LEARN", "EJECT",
    ]

    /// Directives that assert; a scenario needs at least one of these.
    public static let assertionDirectives: Set<String> = [
        "EXPECT_PERSONAL_LEARNED", "EXPECT_NOT_PERSONAL_LEARNED", "EXPECT_TOP",
        "EXPECT_AUTOCORRECT", "EXPECT_NO_AUTOCORRECT", "EXPECT_VERBATIM", "EXPECT_ONLY_VERBATIM",
        "EXPECT_CONTAINS", "EXPECT_NOT_CONTAINS", "EXPECT_NO_SPLIT", "EXPECT_EMPTY",
        "EXPECT_NONEMPTY", "EXPECT_POSTERIOR_GT", "EXPECT_POSTERIOR_LT", "EXPECT_COMMITS",
        "EXPECT_LAST_COMMIT", "EXPECT_EVENTS", "EXPECT_BUFFER", "EXPECT_CONTEXT",
    ]

    public static var knownDirectives: Set<String> {
        actionDirectives.union(assertionDirectives)
    }

    /// Directives whose execution re-reads the proxy and re-runs
    /// autocomplete (`Typist.refresh()`), i.e. produce a bar to assert on.
    /// NOTE_WINDOW and LEARN deliberately do not.
    public static let barProducingDirectives: Set<String> = [
        "T", "LONGPRESS", "TAP", "BACKSPACE", "REFRESH", "PREDICT_SPACE", "CURSOR_MOVE",
        "CURSOR_MOVE_SILENT", "HOST_SET", "HOST_SET_SILENT", "EJECT",
    ]

    /// Negative bar assertions: trivially true against the empty bar a fresh
    /// scenario starts with, so they are vacuous until a bar-producing
    /// directive has run.
    public static let negativeBarAssertions: Set<String> = [
        "EXPECT_NOT_CONTAINS", "EXPECT_NO_AUTOCORRECT", "EXPECT_NO_SPLIT", "EXPECT_EMPTY",
    ]

    /// Directives whose argument is free text where a trailing space is
    /// meaningful (a delimiter keystroke, a document suffix) and therefore
    /// MUST be quoted — the lexer trims, so an unquoted trailing space is
    /// silently lost.
    public static let freeTextDirectives: Set<String> = [
        "T", "LONGPRESS", "TAP", "HOST_SET", "HOST_SET_SILENT", "EXPECT_BUFFER", "EXPECT_CONTEXT",
    ]

    /// Directives that take no argument at all.
    public static let bareDirectives: Set<String> = [
        "NOTE_WINDOW", "PREDICT_SPACE", "REFRESH", "EXPECT_NO_SPLIT", "EXPECT_EMPTY",
        "EXPECT_NONEMPTY",
    ]

    // MARK: - Parsing

    public static func parse(_ text: String) -> ScenarioScript {
        var directives: [ScenarioDirective] = []
        var diagnostics: [ScenarioDiagnostic] = []
        var scenarioCount = 0
        var currentName: String?
        var currentLine = 0
        var assertionsInCurrent = 0
        var barProducedInCurrent = false
        var seenNames: Set<String> = []

        func closeScenario() {
            guard let name = currentName else { return }
            if assertionsInCurrent == 0 {
                diagnostics.append(
                    ScenarioDiagnostic(
                        line: currentLine, scenario: name,
                        message: "scenario has no EXPECT_* assertion — it cannot fail"))
            }
        }

        let lines = text.components(separatedBy: "\n")
        for (index, physical) in lines.enumerated() {
            let lineNo = index + 1
            let rawLine = physical.hasSuffix("\r") ? String(physical.dropLast()) : physical
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let (keyword, argument) = split(line)
            directives.append(
                ScenarioDirective(line: lineNo, keyword: keyword, argument: argument, rawLine: rawLine))

            func diagnose(_ message: String) {
                diagnostics.append(
                    ScenarioDiagnostic(line: lineNo, scenario: currentName, message: message))
            }

            guard knownDirectives.contains(keyword) else {
                diagnose("unknown directive: \(keyword)")
                continue
            }

            if keyword == "SCENARIO" {
                closeScenario()
                scenarioCount += 1
                currentName = argument
                currentLine = lineNo
                assertionsInCurrent = 0
                barProducedInCurrent = false
                if argument.isEmpty {
                    diagnose("SCENARIO needs a name")
                } else if !seenNames.insert(argument).inserted {
                    diagnose("duplicate SCENARIO name \"\(argument)\" (failure reports would be ambiguous)")
                }
                continue
            }

            if currentName == nil, keyword != "LIMIT" {
                diagnose("directive before the first SCENARIO is never asserted on (only LIMIT may precede it)")
                continue
            }

            if let problem = validateArgument(keyword: keyword, argument: argument) {
                diagnose(problem)
                continue
            }

            if freeTextDirectives.contains(keyword), !argument.isEmpty,
                !isQuoted(argument), rawLine.last.map({ $0 == " " || $0 == "\t" }) == true
            {
                diagnose(
                    "\(keyword) argument has unquoted trailing whitespace — the lexer trims it, "
                        + "so the delimiter is silently lost; quote the argument (\(keyword) \"…\")")
                continue
            }

            if assertionDirectives.contains(keyword) {
                assertionsInCurrent += 1
                if negativeBarAssertions.contains(keyword), !barProducedInCurrent {
                    diagnose(
                        "\(keyword) before any bar-producing directive is vacuous "
                            + "(a fresh scenario's bar is always empty)")
                }
            }
            if barProducingDirectives.contains(keyword) {
                barProducedInCurrent = true
            }
        }
        closeScenario()

        if scenarioCount == 0 {
            diagnostics.append(
                ScenarioDiagnostic(line: 0, scenario: nil, message: "file contains no SCENARIO"))
        }

        return ScenarioScript(
            directives: directives, scenarioCount: scenarioCount,
            diagnostics: diagnostics.sorted { ($0.line, $0.message) < ($1.line, $1.message) })
    }

    /// Argument validation for one directive. Returns a message when the
    /// argument is malformed — every branch here used to be a silent
    /// default (`Int(x) ?? 1`, `argument == "on"`, ...).
    public static func validateArgument(keyword: String, argument: String) -> String? {
        func parts() -> [String] { argument.split(separator: " ").map(String.init) }
        switch keyword {
        case _ where bareDirectives.contains(keyword):
            return argument.isEmpty ? nil : "\(keyword) takes no argument (got \"\(argument)\")"

        case "T", "LONGPRESS":
            return unquote(argument).isEmpty ? "\(keyword) needs text to type" : nil

        case "TAP":
            if argument.isEmpty { return "TAP needs a suggestion text or <char> <dx> <dy>" }
            let p = parts()
            // Three tokens with a one-character head is the touch form; it
            // must then parse fully — a half-numeric line is a typo, not a
            // suggestion tap.
            if p.count == 3, p[0].count == 1, Double(p[1]) != nil || Double(p[2]) != nil {
                if Double(p[1]) == nil || Double(p[2]) == nil {
                    return "TAP <char> <dx> <dy>: offsets must be numbers (got \"\(argument)\")"
                }
            }
            return nil

        case "BACKSPACE":
            if argument.isEmpty { return nil }
            guard let n = Int(argument), n >= 1 else {
                return "BACKSPACE [n]: n must be a positive integer (got \"\(argument)\")"
            }
            return nil

        case "LIMIT", "TRUNCATE_AT":
            guard let n = Int(argument), n >= 1 else {
                return "\(keyword) <n>: n must be a positive integer (got \"\(argument)\")"
            }
            return nil

        case "CURSOR_MOVE", "CURSOR_MOVE_SILENT":
            if argument == "start" || argument == "end" { return nil }
            if Int(argument) != nil { return nil }
            return "\(keyword) <pos>: expected start|end|+n|-n|n (got \"\(argument)\")"

        case "STALE_READS", "SWALLOW_EDITS", "DOT_APPLY":
            return argument == "on" || argument == "off"
                ? nil : "\(keyword) on|off (got \"\(argument)\")"

        case "FIELD":
            return FieldKind(rawValue: argument) == nil
                ? "bad FIELD argument: \(argument) (expected standard|url|email|webSearch|secure)"
                : nil

        case "PERSONAL":
            let p = parts()
            return p.count == 2 && UInt32(p[1]) != nil ? nil : "usage: PERSONAL <word> <count>"

        case "PERSONAL_EXPLICIT":
            let p = parts()
            if p.count == 1, !p[0].isEmpty { return nil }
            if p.count == 2, UInt32(p[1]) != nil { return nil }
            return "usage: PERSONAL_EXPLICIT <word> [count]"

        case "PERSONAL_BIGRAM":
            let p = parts()
            return p.count == 3 && UInt32(p[2]) != nil
                ? nil : "usage: PERSONAL_BIGRAM <first> <second> <count>"

        case "PERSONAL_TOUCH":
            let p = parts()
            guard p.count >= 6, p.count <= 7, p[0].count == 1,
                p.dropFirst().allSatisfy({ Double($0) != nil })
            else {
                return "usage: PERSONAL_TOUCH <char> <count> <meanDx> <meanDy> <sigmaX> <sigmaY> [cov]"
            }
            return nil

        case "TOMBSTONE", "LEARN", "EJECT":
            return argument.isEmpty ? "usage: \(keyword) <word>" : nil

        case "HOST_SET", "HOST_SET_SILENT", "EXPECT_BUFFER", "EXPECT_CONTEXT":
            return nil  // empty is a legitimate document/window

        case "EXPECT_NO_AUTOCORRECT":
            return nil  // optional, documentary word argument

        case "EXPECT_POSTERIOR_GT", "EXPECT_POSTERIOR_LT":
            return Double(argument) == nil
                ? "\(keyword) <x>: x must be a number (got \"\(argument)\")" : nil

        case "EXPECT_COMMITS", "EXPECT_EVENTS":
            guard let n = Int(argument), n >= 0 else {
                return "\(keyword) <n>: n must be a non-negative integer (got \"\(argument)\")"
            }
            return nil

        case "EXPECT_TOP", "EXPECT_AUTOCORRECT", "EXPECT_VERBATIM", "EXPECT_ONLY_VERBATIM",
            "EXPECT_CONTAINS", "EXPECT_NOT_CONTAINS", "EXPECT_PERSONAL_LEARNED",
            "EXPECT_NOT_PERSONAL_LEARNED", "EXPECT_LAST_COMMIT":
            return argument.isEmpty ? "\(keyword) <word>: needs a word" : nil

        default:
            return nil
        }
    }

    // MARK: - Lexing helpers

    /// Split "KEYWORD rest of line" into (keyword, argument).
    public static func split(_ line: String) -> (keyword: String, argument: String) {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (line, "")
        }
        let keyword = String(line[..<space])
        let argument = String(line[line.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        return (keyword, argument)
    }

    /// Strip surrounding double quotes (used to protect leading/trailing
    /// spaces from editors); non-quoted arguments pass through verbatim.
    public static func unquote(_ text: String) -> String {
        guard isQuoted(text) else { return text }
        return String(text.dropFirst().dropLast())
    }

    public static func isQuoted(_ text: String) -> Bool {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"")
    }
}
