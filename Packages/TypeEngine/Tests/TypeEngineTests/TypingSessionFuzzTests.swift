import Foundation
import Learning
import LemmaCore
import Lexicon
import XCTest

@testable import TypeEngine

// MARK: - Seeded RNG

/// SplitMix64 — tiny, deterministic, platform-independent. `SystemRandom-
/// NumberGenerator` is not seedable, and Foundation's `srand48` is process
/// global; a value-type generator keeps every fuzz case reproducible from
/// its seed alone.
struct FuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
    /// Weighted pick: `weights[i]` is the relative weight of `items[i]`.
    mutating func weighted<T>(_ items: [(weight: Int, value: T)]) -> T {
        let total = items.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total, using: &self)
        for item in items {
            if roll < item.weight { return item.value }
            roll -= item.weight
        }
        return items.last!.value
    }
}

// MARK: - Mode

/// Everything about a fuzz case that is not an action: bar size, proxy
/// shape, embedder dot behavior, field kind. Derived from the seed so one
/// number reproduces the whole case; `swiftLiteral` pastes into a repro.
struct FuzzMode: Equatable, CustomStringConvertible {
    var limit = 5
    /// `ProxySimulator.TruncationPolicy.none` instead of the default
    /// sentence-cut/200-char window.
    var truncationNone = false
    /// Model STOCK KeyboardKit '.'-apply (Typist `appliesAutocorrectOnDot`).
    var dotApply = false
    /// First read after each proxy edit returns the pre-edit window.
    var staleReads = false
    var field: FieldKind = .standard
    /// Metamorphic variants (see `FuzzHarness.metamorphic`): a no-op
    /// `refresh()` after every action, or the extension's window-aware
    /// `noteExternalTextChange(window:)` forwarded after every action.
    var extraRefresh = false
    var extraWindowNote = false

    static func random(using rng: inout FuzzRNG) -> FuzzMode {
        var mode = FuzzMode()
        mode.limit = rng.chance(0.3) ? 3 : 5
        mode.truncationNone = rng.chance(0.3)
        mode.dotApply = rng.chance(0.2)
        mode.staleReads = rng.chance(0.15)
        mode.field = rng.chance(0.1) ? rng.pick([.url, .email, .webSearch, .secure]) : .standard
        return mode
    }

    var description: String { swiftLiteral }

    var swiftLiteral: String {
        var parts: [String] = []
        if limit != 5 { parts.append("limit: \(limit)") }
        if truncationNone { parts.append("truncationNone: true") }
        if dotApply { parts.append("dotApply: true") }
        if staleReads { parts.append("staleReads: true") }
        if field != .standard { parts.append("field: .\(field.rawValue)") }
        if extraRefresh { parts.append("extraRefresh: true") }
        if extraWindowNote { parts.append("extraWindowNote: true") }
        return "FuzzMode(\(parts.joined(separator: ", ")))"
    }

    init(
        limit: Int = 5, truncationNone: Bool = false, dotApply: Bool = false,
        staleReads: Bool = false, field: FieldKind = .standard,
        extraRefresh: Bool = false, extraWindowNote: Bool = false
    ) {
        self.limit = limit
        self.truncationNone = truncationNone
        self.dotApply = dotApply
        self.staleReads = staleReads
        self.field = field
        self.extraRefresh = extraRefresh
        self.extraWindowNote = extraWindowNote
    }
}

// MARK: - Actions

/// One user/host/embedder action against the session. Multi-character
/// `type` actions contain no delimiters (the generator emits delimiters as
/// their own single-character actions) so "the last keystroke of this
/// action" is a well-defined thing for the invariants.
enum FuzzAction: Equatable, CustomStringConvertible {
    case type(String)
    case space
    /// KeyboardKit's double-space sentence end: second space lands, then
    /// trailing spaces are deleted and ". " inserted — one recorded action.
    case doubleSpace
    case backspace(Int)
    /// Tap the bar entry at `index % bar.count` (no-op on an empty bar).
    case tap(index: Int)
    /// Tap the verbatim / literal-revert slot if the bar has one.
    case tapVerbatim
    /// Directed probe: if the previous action's last keystroke auto-applied
    /// a correction on a space, backspace once (slot must reveal the
    /// literal) and tap the literal (document must read prefix+literal+" ").
    case revertProbe
    case cursorMove(to: Int, silent: Bool)
    case hostReplace(String, silent: Bool)
    case predictSpace
    case refresh
    case windowNote
    case longPress(String)
    case tapChar(Character, dx: Double, dy: Double)
    case field(FieldKind)

    var description: String { swiftLiteral }

    var swiftLiteral: String {
        switch self {
        case .type(let s): return ".type(\(s.debugDescription))"
        case .space: return ".space"
        case .doubleSpace: return ".doubleSpace"
        case .backspace(let n): return ".backspace(\(n))"
        case .tap(let i): return ".tap(index: \(i))"
        case .tapVerbatim: return ".tapVerbatim"
        case .revertProbe: return ".revertProbe"
        case .cursorMove(let to, let silent): return ".cursorMove(to: \(to), silent: \(silent))"
        case .hostReplace(let s, let silent):
            return ".hostReplace(\(s.debugDescription), silent: \(silent))"
        case .predictSpace: return ".predictSpace"
        case .refresh: return ".refresh"
        case .windowNote: return ".windowNote"
        case .longPress(let s): return ".longPress(\(s.debugDescription))"
        case .tapChar(let c, let dx, let dy):
            return ".tapChar(\(String(c).debugDescription), dx: \(dx), dy: \(dy))"
        case .field(let k): return ".field(.\(k.rawValue))"
        }
    }

    /// Actions that are external to the keyboard (cursor jump, host
    /// mutation, field switch): these must never register a word commit.
    var isExternal: Bool {
        switch self {
        case .cursorMove, .hostReplace, .field: return true
        default: return false
        }
    }

    var isSilentExternal: Bool {
        switch self {
        case .cursorMove(_, let silent), .hostReplace(_, let silent): return silent
        default: return false
        }
    }
}

// MARK: - Failure

struct FuzzViolation: CustomStringConvertible {
    let invariant: String
    let detail: String
    var description: String { "[\(invariant)] \(detail)" }
}

struct FuzzFailure: Error, CustomStringConvertible {
    let invariant: String
    let detail: String
    /// Index of the action after which the invariant failed (nil when the
    /// failure is a whole-run property such as determinism).
    let step: Int?
    var description: String {
        "[\(invariant)]" + (step.map { " at step \($0)" } ?? "") + ": \(detail)"
    }
}

// MARK: - Driver

/// Faithful embedder model: proxy + session + ledger, mirroring the type-repl
/// `Typist` and the extension's action handler contract exactly —
/// `noteSelfEdit(before:after:)` around ONE logical action (revert /
/// attachment edits + autocorrect apply + the keystroke), observation reads
/// via `contextBeforeInput`, `AutocorrectApplyGuard` with the pending token
/// stamped at bar time, '.' never applies autocorrect unless `dotApply`,
/// `continuationRevert` / `punctuationAttachment` consulted before every
/// insert, KeyboardKit tap semantics (replace token + space), `.unknown` taps
/// routed through `revertToLiteral` first, events drained after every pass.
///
/// Besides driving, it records what the SESSION instructed (reverts,
/// attachments, applied autocorrects) so the invariants can judge those
/// instructions against the document they acted on.
final class FuzzDriver {
    let engine: TypeEngine
    let session: TypingSession
    let proxy: ProxySimulator
    let mode: FuzzMode

    private(set) var bar: [Suggestion] = []
    private(set) var barPendingToken = ""
    /// The observation window the session saw on the latest pass (what the
    /// bar belongs to; under stale reads this lags the document).
    private(set) var lastWindow = ""
    private(set) var lastTrace: CorrectionTrace?
    private(set) var events: [LearningEvent] = []
    /// Events drained during the most recent action.
    private(set) var actionEvents: [LearningEvent] = []
    /// The document as it stood on the pass that registered the latest
    /// commit (a multi-keystroke action may edit past it before the
    /// invariant pass runs).
    private(set) var documentAtLastCommit = ""
    /// Commit count before the most recent action.
    private(set) var commitsBeforeAction = 0
    /// Set when the LAST KEYSTROKE of the most recent action auto-applied a
    /// correction: literal token, applied text, document prefix before the
    /// token, and the delimiter that triggered it.
    private(set) var lastApplied: (from: String, to: String, docPrefix: String, docSuffix: String, delimiter: Character)?
    /// Latest '.'-apply (dot-apply mode only), for judging the revert.
    private(set) var lastDotApplied: (from: String, to: String)?
    /// Instruction-level violations noticed while executing (revert /
    /// attachment instructions that do not fit the document, probe
    /// outcomes). Collected by the invariant pass.
    private(set) var executionViolations: [FuzzViolation] = []
    private(set) var revertCount = 0
    private(set) var attachmentCount = 0
    private(set) var doubleSpaceFired = false
    /// Coverage counters (printed by the sweep so a green run can be told
    /// apart from a run that never reached the interesting states).
    var coverage: [String: Int] = [:]
    func cover(_ key: String) { coverage[key, default: 0] += 1 }
    /// The most recent bar tap: what was tapped, the pending token it
    /// replaced, the document the driver expects afterwards, and the commit
    /// count before — the tap-commit/tap-events invariants judge it.
    private(set) var lastTap: (suggestion: Suggestion, pending: String, expectedDocument: String,
        commitsBefore: Int, literalRevert: Bool, insertedSpace: Bool, barHadAutocorrect: Bool)?
    /// Per-refresh (per-keystroke) wall-clock seconds and the windows of the
    /// slowest passes.
    private(set) var refreshSeconds: [Double] = []
    private(set) var slowestRefreshes: [(seconds: Double, window: String)] = []
    /// Per-action transcript: document, cursor, bar, commits — the
    /// determinism/metamorphic comparison key.
    private(set) var transcript: [String] = []
    private(set) var maxStepSeconds = 0.0
    private(set) var stepSeconds: [Double] = []
    private let clock = ContinuousClock()

    init(engine: TypeEngine, mode: FuzzMode) {
        self.engine = engine
        self.mode = mode
        engine.resetLanguagePosterior()
        engine.clearSessionVocabulary()
        engine.setPersonalVocabulary(nil)
        engine.setPersonalTouch(nil)
        session = TypingSession(engine: engine)
        session.fieldKind = mode.field
        proxy = ProxySimulator(truncation: mode.truncationNone ? .none : .init())
        proxy.staleReads = mode.staleReads
        // The extension runs one autocomplete pass on activation, before
        // any keystroke; without it the first tap/prediction has no bar.
        refresh()
    }

    var currentWord: String { TypingSession.splitCurrentWord(of: lastWindow).currentWord }
    var context: String { TypingSession.splitCurrentWord(of: lastWindow).context }
    var document: String { proxy.document }

    // MARK: Perform

    func perform(_ actions: [FuzzAction]) {
        for action in actions { perform(action) }
    }

    func perform(_ action: FuzzAction) {
        actionEvents = []
        executionViolations = []
        commitsBeforeAction = session.committedWordCount
        // `lastApplied` describes the LAST KEYSTROKE of the most recent
        // action; only the revert probe reads the previous action's value.
        if action != .revertProbe { lastApplied = nil }
        lastTap = nil
        let start = clock.now
        switch action {
        case .type(let text):
            for c in text { typeChar(c) }
        case .space:
            typeChar(" ")
        case .doubleSpace:
            doubleSpace()
        case .backspace(let n):
            for _ in 0..<max(n, 1) { backspace() }
        case .tap(let index):
            guard !bar.isEmpty else { break }
            tap(bar[index % bar.count])
        case .tapVerbatim:
            if let slot = bar.first(where: \.isVerbatim) { tap(slot) }
        case .revertProbe:
            revertProbe()
        case .cursorMove(let to, let silent):
            proxy.moveCursor(to: to)
            if !silent { session.noteExternalTextChange() }
            refresh()
        case .hostReplace(let text, let silent):
            proxy.hostReplaceText(text)
            if !silent { session.noteExternalTextChange() }
            refresh()
        case .predictSpace:
            predictSpace()
        case .refresh:
            refresh()
        case .windowNote:
            session.noteExternalTextChange(window: proxy.contextBeforeInput)
        case .longPress(let text):
            for c in text {
                session.noteLongPressInsertion(c)
                typeChar(c)
            }
        case .tapChar(let c, let dx, let dy):
            session.noteTap(char: c, dx: dx, dy: dy)
            typeChar(c)
        case .field(let kind):
            session.fieldKind = kind
            session.noteExternalTextChange()
            refresh()
        }
        let seconds = start.duration(to: clock.now).fuzzSeconds
        stepSeconds.append(seconds)
        maxStepSeconds = max(maxStepSeconds, seconds)
        transcript.append(
            "doc=\(proxy.document.debugDescription) cur=\(proxy.cursor)"
                + " bar=\(barDescription) commits=\(session.committedWordCount)"
                + " last=\(session.lastCommittedWord ?? "-")")
        if mode.extraRefresh { refresh() }
        if mode.extraWindowNote { session.noteExternalTextChange(window: proxy.contextBeforeInput) }
    }

    // MARK: Keystrokes

    private var appliedThisKeystroke: (from: String, to: String, docPrefix: String, docSuffix: String, delimiter: Character)?

    private func typeChar(_ c: Character) {
        appliedThisKeystroke = nil
        let ledgerBefore = proxy.trueContextBeforeInput
        if let revert = session.continuationRevert(for: c) {
            revertCount += 1
            cover("revert.continuation")
            if !mode.dotApply {
                executionViolations.append(
                    FuzzViolation(
                        invariant: "no-revert-without-dot-apply",
                        detail: "continuationRevert(for: \(String(c).debugDescription)) returned"
                            + " \(revert) although the embedder never applies on '.'"))
            } else if let dot = lastDotApplied {
                if revert.text != dot.from + "." || revert.deleteCount != dot.to.count + 1 {
                    executionViolations.append(
                        FuzzViolation(
                            invariant: "revert-instruction",
                            detail: "revert \(revert) does not undo dot-apply \(dot.from) → \(dot.to)"))
                }
            }
            if revert.deleteCount > ledgerBefore.count {
                executionViolations.append(
                    FuzzViolation(
                        invariant: "revert-instruction",
                        detail: "revert deletes \(revert.deleteCount) > window \(ledgerBefore.debugDescription)"))
            }
            for _ in 0..<revert.deleteCount { proxy.deleteBackward() }
            proxy.insertText(revert.text)
        }
        if let attachment = session.punctuationAttachment(for: c) {
            attachmentCount += 1
            cover("attachment")
            let live = proxy.trueContextBeforeInput
            if !live.hasSuffix(" .") || attachment.deleteCount != 2 || attachment.text != "." {
                executionViolations.append(
                    FuzzViolation(
                        invariant: "attachment-instruction",
                        detail: "attachment \(attachment) on window \(live.debugDescription)"))
            }
            for _ in 0..<attachment.deleteCount { proxy.deleteBackward() }
            proxy.insertText(attachment.text)
        }
        let applies = TypingSession.isDelimiter(c) && (c != "." || mode.dotApply)
        if applies, let autocorrect = bar.first(where: \.isAutocorrect),
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: barPendingToken,
                textBeforeCursor: proxy.trueContextBeforeInput)
        {
            let word = TypingSession.splitCurrentWord(of: proxy.trueContextBeforeInput).currentWord
            if !word.isEmpty, autocorrect.text != word {
                let prefix = String(proxy.document.prefix(proxy.cursor - word.count))
                let suffix = String(proxy.document.dropFirst(proxy.cursor))
                for _ in 0..<word.count { proxy.deleteBackward() }
                proxy.insertText(autocorrect.text)
                appliedThisKeystroke = (word, autocorrect.text, prefix, suffix, c)
                cover(autocorrect.text.contains(" ") ? "apply.split" : (autocorrect.isRestoration ? "apply.restoration" : "apply.repair"))
                if c == "." { lastDotApplied = (word, autocorrect.text); cover("apply.onDot") }
                if word.hasSuffix(".") { cover("apply.deferredDot") }
            }
        }
        proxy.insertText(String(c))
        // 2026-10 contract: the record names the keystroke and the applied
        // autocorrect text (nil = the token was committed as typed).
        session.noteSelfEdit(
            before: ledgerBefore, after: proxy.trueContextBeforeInput,
            keystroke: c, replacement: appliedThisKeystroke?.to)
        lastApplied = appliedThisKeystroke
        refresh()
    }

    /// KeyboardKit `endSentence`: the second space lands, then — when the
    /// text before the cursor ends in two spaces and the sentence is not
    /// already closed — trailing spaces are deleted and ". " inserted, all
    /// inside one action-handler `handle` call (one ledger record).
    private func doubleSpace() {
        doubleSpaceFired = false
        lastApplied = nil
        let ledgerBefore = proxy.trueContextBeforeInput
        proxy.insertText(" ")
        let live = proxy.trueContextBeforeInput
        let trimmed = live.trimmingCharacters(in: .whitespaces)
        if live.hasSuffix("  "), let last = trimmed.last, !".!?".contains(last) {
            while proxy.trueContextBeforeInput.hasSuffix(" ") { proxy.deleteBackward() }
            proxy.insertText(". ")
            doubleSpaceFired = true
            cover("doubleSpace.fired")
        }
        session.noteSelfEdit(before: ledgerBefore, after: proxy.trueContextBeforeInput, keystroke: " ")
        refresh()
    }

    private func backspace() {
        lastApplied = nil
        let ledgerBefore = proxy.trueContextBeforeInput
        proxy.deleteBackward()
        session.noteSelfEdit(before: ledgerBefore, after: proxy.trueContextBeforeInput)
        refresh()
    }

    // MARK: Taps

    @discardableResult
    private func tap(_ suggestion: Suggestion) -> Bool {
        lastApplied = nil
        let additional =
            suggestion.isVerbatim
            ? session.literalRevertAdditionalDeleteCount(matching: suggestion.text) : 0
        if suggestion.isVerbatim {
            if !session.revertToLiteral(matching: suggestion.text) {
                session.noteVerbatimChoice(suggestion.text)
            }
        }
        let ledgerBefore = proxy.trueContextBeforeInput
        let word = TypingSession.splitCurrentWord(of: ledgerBefore).currentWord
        let deleteCount = word.count + additional
        if deleteCount > ledgerBefore.count {
            executionViolations.append(
                FuzzViolation(
                    invariant: "tap-instruction",
                    detail: "tap \(suggestion.text.debugDescription) deletes \(deleteCount)"
                        + " > window \(ledgerBefore.debugDescription)"))
        }
        let literalRevert = additional > 0 || (suggestion.isVerbatim && session.hasArmedLiteralRevert)
        let barHadAutocorrect = bar.contains(where: \.isAutocorrect)
        let docPrefix = String(proxy.document.prefix(max(proxy.cursor - deleteCount, 0)))
        let docSuffix = String(proxy.document.dropFirst(proxy.cursor))
        let commitsBefore = session.committedWordCount
        for _ in 0..<min(deleteCount, proxy.cursor) { proxy.deleteBackward() }
        proxy.insertText(suggestion.text)
        let (before, after) = proxy.contextWindows()
        var expected = docPrefix + suggestion.text
        var insertedSpace = false
        if !before.hasSuffix(" "), !after.hasPrefix(" ") {
            proxy.insertText(" ")
            expected += " "
            insertedSpace = true
        }
        expected += docSuffix
        lastTap = (suggestion, word, expected, commitsBefore, literalRevert, insertedSpace, barHadAutocorrect)
        cover(
            suggestion.isVerbatim
                ? (literalRevert ? "tap.literalRevert" : "tap.verbatim")
                : (word.isEmpty ? "tap.prediction" : (suggestion.text.contains(" ") ? "tap.split" : "tap.suggestion")))
        if word.hasSuffix(".") { cover("tap.deferredDot") }
        // Non-verbatim taps report the tapped text; verbatim taps are known
        // to the session through `noteVerbatimChoice` / `revertToLiteral`.
        session.noteSelfEdit(
            before: ledgerBefore, after: proxy.trueContextBeforeInput,
            replacement: suggestion.isVerbatim ? nil : suggestion.text)
        refresh()
        return true
    }

    @discardableResult
    private func predictSpace() -> Bool {
        lastApplied = nil
        let windowBefore = proxy.trueContextBeforeInput
        guard windowBefore.isEmpty || windowBefore.hasSuffix(" ") else { return false }
        guard let prediction = bar.first(where: { !$0.isVerbatim && !$0.text.isEmpty }) else {
            return false
        }
        proxy.insertText(prediction.text)
        proxy.insertText(" ")
        cover("predictSpace")
        session.noteSelfEdit(
            before: windowBefore, after: proxy.trueContextBeforeInput,
            keystroke: " ", replacement: prediction.text)
        refresh()
        return true
    }

    /// Backspace-revert contract (wave 36): an autocorrect that auto-applied
    /// on a space is undone by one backspace + one tap on the reserved slot,
    /// restoring the byte-exact literal. Preconditions keep the probe to the
    /// shape the contract names (space delimiter, applied text visible in the
    /// window, no stale reads — the stale observation lags one step).
    private func revertProbe() {
        guard let applied = lastApplied, applied.delimiter == " ", !mode.staleReads,
            !applied.to.hasSuffix("."), !applied.to.contains(" "),
            lastWindow.hasSuffix(applied.to + " ")
        else {
            lastApplied = nil
            return
        }
        let documentBeforeProbe = proxy.document
        cover("revertProbe")
        backspace()
        guard session.hasArmedLiteralRevert, let slot = bar.first, slot.isVerbatim,
            slot.text == applied.from
        else {
            executionViolations.append(
                FuzzViolation(
                    invariant: "backspace-revert-slot",
                    detail: "after \(applied.from.debugDescription) → \(applied.to.debugDescription)"
                        + " on space, one backspace (window \(lastWindow.debugDescription),"
                        + " doc before probe \(documentBeforeProbe.debugDescription))"
                        + " did not lead with the literal; armed=\(session.hasArmedLiteralRevert)"
                        + " bar=\(barDescription)"))
            return
        }
        let commitsBefore = session.committedWordCount
        tap(slot)
        let expected = applied.docPrefix + applied.from + " " + applied.docSuffix
        if proxy.document != expected || session.lastCommittedWord != applied.from
            || session.committedWordCount != commitsBefore + 1
        {
            executionViolations.append(
                FuzzViolation(
                    invariant: "backspace-revert-restores-literal",
                    detail: "tapping literal \(applied.from.debugDescription) gave document"
                        + " \(proxy.document.debugDescription), expected \(expected.debugDescription);"
                        + " lastCommitted=\(session.lastCommittedWord ?? "nil")"
                        + " commits \(commitsBefore) → \(session.committedWordCount)"))
        }
        if bar.contains(where: \.isAutocorrect) {
            executionViolations.append(
                FuzzViolation(
                    invariant: "backspace-revert-restores-literal",
                    detail: "bar re-arms an autocorrect right after the literal revert: \(barDescription)"))
        }
    }

    // MARK: Observation

    func refresh() {
        let before = proxy.contextBeforeInput
        lastWindow = before
        barPendingToken = TypingSession.splitCurrentWord(of: before).currentWord
        let trace = CorrectionTrace()
        let commitsBefore = session.committedWordCount
        let start = clock.now
        bar = session.suggestions(for: before, limit: mode.limit, trace: trace)
        let seconds = start.duration(to: clock.now).fuzzSeconds
        refreshSeconds.append(seconds)
        if slowestRefreshes.count < 3 || seconds > slowestRefreshes.last!.seconds {
            slowestRefreshes.append((seconds, before))
            slowestRefreshes.sort { $0.seconds > $1.seconds }
            if slowestRefreshes.count > 3 { slowestRefreshes.removeLast() }
        }
        lastTrace = trace
        if session.committedWordCount > commitsBefore {
            documentAtLastCommit = proxy.document
            cover("commit")
        }
        if bar.contains(where: \.isAutocorrect) { cover("bar.autocorrect") }
        if bar.contains(where: \.isRestoration) { cover("bar.restoration") }
        if session.hasArmedLiteralRevert { cover("bar.literalSlot") }
        if session.hasPendingLearningEvents {
            let drained = session.drainLearningEvents()
            events += drained
            actionEvents += drained
        }
    }

    var barDescription: String {
        bar.map { s in
            (s.isVerbatim ? "“\(s.text)”" : s.text)
                + (s.isAutocorrect ? "*" : "") + (s.isRestoration ? "~" : "")
        }.joined(separator: " | ")
    }
}

extension Duration {
    var fuzzSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

// MARK: - Invariants

/// The per-step oracle. Every check names the ADR/README/source contract it
/// enforces; sanctioned exceptions are carved out explicitly rather than
/// weakened silently.
enum FuzzInvariants {
    static let quotedTermOpeners: Set<Character> = ["\u{201E}", "\"", "\u{201C}"]

    static func check(_ d: FuzzDriver, after action: FuzzAction) -> [FuzzViolation] {
        var out = d.executionViolations
        let bar = d.bar
        let currentWord = d.currentWord
        let pendingDot = currentWord.hasSuffix(".")
        let stem = pendingDot ? String(currentWord.dropLast()) : currentWord
        let nonVerbatim = bar.filter { !$0.isVerbatim }
        let autocorrects = bar.filter(\.isAutocorrect)
        let mode = d.mode

        func fail(_ invariant: String, _ detail: String) {
            out.append(FuzzViolation(invariant: invariant, detail: detail + " — bar: \(d.barDescription)"
                + " window: \(d.lastWindow.debugDescription)"))
        }

        // Bounded per-step work (hang guard; the release soak reports the
        // real distribution).
        if let last = d.stepSeconds.last, last > FuzzHarness.stepTimeLimitSeconds {
            fail("step-time", "action took \(String(format: "%.2f", last)) s")
        }

        // ---- Bar shape -----------------------------------------------------
        if bar.count > mode.limit { fail("bar-shape", "bar has \(bar.count) > limit \(mode.limit)") }
        if bar.contains(where: { $0.text.isEmpty }) { fail("bar-shape", "empty suggestion text") }
        if Set(bar.map(\.text)).count != bar.count { fail("bar-shape", "duplicate suggestion texts") }
        if autocorrects.count > 1 { fail("bar-shape", "more than one autocorrect flag") }
        if let ac = autocorrects.first {
            if ac.isVerbatim { fail("bar-shape", "verbatim slot flagged autocorrect") }
            if nonVerbatim.first?.text != ac.text {
                fail("bar-shape", "autocorrect is not the top non-verbatim suggestion")
            }
            if ac.text == currentWord { fail("bar-shape", "autocorrect into the byte-identical token") }
            if ac.text != ac.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                fail("bar-shape", "autocorrect text has surrounding whitespace")
            }
        }
        if bar.contains(where: { $0.isVerbatim && $0.isAutocorrect }) {
            fail("bar-shape", "verbatim + autocorrect on one suggestion")
        }
        if bar.filter(\.isVerbatim).count > 1 { fail("bar-shape", "two verbatim slots") }
        if currentWord.isEmpty, bar.contains(where: \.isVerbatim) {
            fail("bar-shape", "verbatim slot with no word in progress")
        }
        if currentWord.isEmpty, !autocorrects.isEmpty {
            fail("bar-shape", "autocorrect flag on a next-word prediction")
        }

        // ---- Verbatim escape hatch (ADR-0006 rule 2) ----------------------
        if !currentWord.isEmpty {
            if bar.isEmpty {
                fail("verbatim-slot", "word in progress but empty bar")
            } else if !bar.contains(where: { $0.text == currentWord }) {
                let literalSlot = d.session.hasArmedLiteralRevert && bar.first?.isVerbatim == true
                if !literalSlot {
                    fail("verbatim-slot", "literal \(currentWord.debugDescription) missing from the bar")
                }
            }
        }

        // ---- Valid word is never auto-replaced (ADR-0006 rule 1) ----------
        // Sanctioned exceptions: the lane-gated single-letter accent path
        // (stem.count == 1) and the skeleton-restoration triple gate (a
        // restoration-ONLY winner over a valid unaccented skeleton,
        // AutocorrectPolicy "skeleton-restoration"). Error-class replacement
        // of a valid word is the violation.
        if let ac = autocorrects.first, stem.count >= 2, !TypingSession.isVerbatimClassToken(stem) {
            let diag = d.engine.compoundDiagnostics(for: stem)
            if diag.typedValid, !ac.isRestoration {
                fail(
                    "valid-word-autocorrect",
                    "typed \(stem.debugDescription) is valid (typedValid) yet an error-class autocorrect"
                        + " \(ac.text.debugDescription) is armed; rule=\(d.lastTrace?.rule ?? "?")")
            }
        }

        // ---- Verbatim-class tokens (ADR-0006 rules 3–5) -------------------
        // Dotted/@/leading-symbol tokens never auto-correct, with ONE
        // sanctioned escape: the dotted space-miss ("sem.er" → "sem er"),
        // standard fields only, word.word shape, no known TLD.
        if TypingSession.isVerbatimClassToken(stem), let ac = autocorrects.first {
            var ok = false
            if mode.field == .standard, let halves = TypingSession.spaceEscapeHalves(of: stem) {
                let expected = (halves.left + " " + halves.right).lowercased() + (pendingDot ? "." : "")
                ok = ac.text.lowercased() == expected
            }
            if !ok {
                fail(
                    "verbatim-class-autocorrect",
                    "verbatim-class token \(currentWord.debugDescription) armed autocorrect"
                        + " \(ac.text.debugDescription)")
            }
        }
        if TypingSession.isVerbatimClassToken(stem), let first = stem.first,
            !(first.isLetter || first.isNumber), !autocorrects.isEmpty
        {
            fail("verbatim-class-autocorrect", "leading-symbol token armed autocorrect")
        }

        // ---- Field gate (ADR-0006 rule 3 + learning privacy) --------------
        if mode.field.suppressesAutocorrect {
            if !autocorrects.isEmpty { fail("field-gate", "autocorrect in \(mode.field) field") }
            if bar.contains(where: \.isRestoration) { fail("field-gate", "restoration in \(mode.field) field") }
            if !d.actionEvents.isEmpty { fail("field-gate", "learning events in \(mode.field) field: \(d.actionEvents)") }
        }

        // ---- Quoted term (issue #3) --------------------------------------
        if let last = d.context.last, quotedTermOpeners.contains(last), !autocorrects.isEmpty {
            fail("quoted-term", "autocorrect armed right after an opening quote")
        }

        // ---- Deferred dot re-appended ------------------------------------
        if pendingDot, !TypingSession.isVerbatimClassToken(stem), !stem.isEmpty {
            for s in nonVerbatim where !s.text.hasSuffix(".") {
                fail("deferred-dot", "suggestion \(s.text.debugDescription) lost the pending dot")
            }
        }

        // ---- Numeric guard (issue #8) -----------------------------------
        if let first = stem.first, first.isNumber {
            for s in nonVerbatim where !s.text.allSatisfy({ $0.isNumber || ".,:".contains($0) }) {
                fail("numeric-guard", "letter suggestion \(s.text.debugDescription) after digit-leading stem")
            }
        }

        // ---- Casing honored (TypeEngine.casingPattern) -------------------
        if !TypingSession.isVerbatimClassToken(stem), stem.count >= 2 {
            let letters = stem.filter(\.isLetter)
            if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
                for s in nonVerbatim where s.text != s.text.uppercased() {
                    fail("casing", "all-caps stem \(stem.debugDescription) got \(s.text.debugDescription)")
                }
            } else if let first = stem.first, first.isUppercase, stem.dropFirst().contains(where: \.isLowercase) {
                for s in nonVerbatim where s.text.first?.isUppercase != true {
                    fail("casing", "title-case stem \(stem.debugDescription) got \(s.text.debugDescription)")
                }
            }
        }

        // ---- External changes never commit -------------------------------
        // Under stale reads a silent cursor move can legitimately confirm a
        // self-edit the stale observation had not echoed yet.
        if action.isExternal, !(mode.staleReads && action.isSilentExternal),
            d.session.committedWordCount != d.commitsBeforeAction
        {
            fail(
                "external-no-commit",
                "\(action) moved committedWordCount \(d.commitsBeforeAction) → \(d.session.committedWordCount)")
        }

        // ---- Committed words exist in the document -----------------------
        if d.session.committedWordCount > d.commitsBeforeAction {
            if let committed = d.session.lastCommittedWord {
                if committed.isEmpty || committed.contains(where: \.isWhitespace) {
                    fail("committed-word", "malformed committed word \(committed.debugDescription)")
                } else if !d.documentAtLastCommit.contains(committed) {
                    fail(
                        "committed-word",
                        "committed \(committed.debugDescription) is not in the document at commit time"
                            + " \(d.documentAtLastCommit.debugDescription)")
                }
            } else {
                fail("committed-word", "commit counted but lastCommittedWord is nil")
            }
        }

        // ---- An applied autocorrect commits its applied text -------------
        // A '.'-apply (stock KeyboardKit, dot-apply mode) yields a deferred-
        // dot token instead: nothing commits yet, the applied text is the
        // pending token, and the revert-on-continuation memo must be armed
        // (ADR-0006 rule 5) so a following letter can undo it.
        if let applied = d.lastApplied, applied.delimiter == ".", !mode.staleReads {
            if d.session.committedWordCount != d.commitsBeforeAction {
                fail("dot-apply-deferred", "'.'-apply \(applied.from.debugDescription) → \(applied.to.debugDescription) committed early")
            }
            // A split ("vantar Klára") leaves only its last word pending.
            let lastWord = applied.to.split(separator: " ").last.map(String.init) ?? applied.to
            if currentWord != lastWord + "." {
                fail("dot-apply-deferred", "'.'-apply left pending \(currentWord.debugDescription), expected \((lastWord + ".").debugDescription)")
            }
            // Observation (not pinned): a SPLIT applied on '.' never arms the
            // revert memo (`noteDotReplacementIfAny` compares the pending stem
            // with the whole emitted autocorrect), so stock dot-apply splits
            // cannot self-heal on continuation. Stock-KeyboardKit-only shape.
            if !applied.to.contains(" "), !d.session.hasPendingContinuationRevert {
                fail("dot-apply-deferred", "'.'-apply \(applied.from.debugDescription) → \(applied.to.debugDescription) did not arm revert-on-continuation")
            }
        } else if let applied = d.lastApplied, !mode.staleReads {
            let stripped = applied.to.hasSuffix(".") ? String(applied.to.dropLast()) : applied.to
            let expected = TypingSession.wordTokens(in: stripped).last ?? stripped
            if d.session.committedWordCount <= d.commitsBeforeAction {
                fail(
                    "applied-autocorrect-committed",
                    "autocorrect \(applied.from.debugDescription) → \(applied.to.debugDescription) applied"
                        + " on \(String(applied.delimiter).debugDescription) but no commit registered")
            } else if d.session.lastCommittedWord != expected {
                fail(
                    "applied-autocorrect-committed",
                    "autocorrect \(applied.from.debugDescription) → \(applied.to.debugDescription) applied"
                        + " but lastCommittedWord is \(d.session.lastCommittedWord.debugDescription),"
                        + " expected \(expected.debugDescription)")
            }
        }

        // ---- Bar taps: KeyboardKit replace-token+space semantics ---------
        // The document must read prefix + tapped text + space; a tap on a
        // word in progress commits exactly the tapped text (predictions and
        // prediction taps are never credited as commits — core.scenarios
        // "mode-2 prediction insert"), and the learning event matches the
        // slot kind: verbatim ⇒ wordTapped, other ⇒ suggestionAccepted.
        if let tap = d.lastTap {
            if d.document != tap.expectedDocument {
                fail(
                    "tap-document",
                    "tapping \(tap.suggestion.text.debugDescription) over \(tap.pending.debugDescription)"
                        + " gave \(d.document.debugDescription), expected \(tap.expectedDocument.debugDescription)")
            }
            if !mode.staleReads {
                let text = tap.suggestion.text
                let stripped = text.hasSuffix(".") ? String(text.dropLast()) : text
                let tokens = TypingSession.wordTokens(in: stripped)
                if tap.pending.isEmpty {
                    if d.session.committedWordCount != tap.commitsBefore {
                        fail("tap-commit", "prediction tap \(text.debugDescription) was credited as a commit")
                    }
                } else if !tokens.isEmpty, tap.insertedSpace {
                    // No space inserted (one already followed the cursor) ⇒
                    // the tapped text is still the pending word, not a commit.
                    if d.session.committedWordCount != tap.commitsBefore + tokens.count {
                        fail(
                            "tap-commit",
                            "tap \(text.debugDescription) over \(tap.pending.debugDescription) moved commits"
                                + " \(tap.commitsBefore) → \(d.session.committedWordCount), expected +\(tokens.count)")
                    } else if d.session.lastCommittedWord != tokens.last {
                        fail(
                            "tap-commit",
                            "tap \(text.debugDescription) over \(tap.pending.debugDescription) committed"
                                + " \(d.session.lastCommittedWord.debugDescription), expected \(tokens.last!.debugDescription)")
                    }
                    if mode.field == .standard, !tap.literalRevert {
                        let typed = TypingSession.strippedEventToken(tap.pending)
                        if tap.suggestion.isVerbatim {
                            if TypingSession.isEventWord(typed),
                                !d.actionEvents.contains(where: { if case .wordTapped(let w) = $0 { return w == typed }; return false })
                            {
                                fail("tap-events", "verbatim tap of \(typed.debugDescription) emitted no wordTapped: \(d.actionEvents)")
                            }
                            if d.actionEvents.contains(where: { if case .suggestionAccepted = $0 { return true }; return false }) {
                                fail("tap-events", "verbatim tap of \(typed.debugDescription) emitted suggestionAccepted: \(d.actionEvents)")
                            }
                        } else if tokens.count == 1, stripped.lowercased() != typed.lowercased(),
                            TypingSession.isEventWord(typed), TypingSession.isEventWord(stripped)
                        {
                            let accepted = d.actionEvents.contains(where: {
                                if case .suggestionAccepted(let t, let a) = $0 {
                                    return t.lowercased() == typed.lowercased() && a.lowercased() == stripped.lowercased()
                                }
                                return false
                            })
                            if !accepted {
                                fail(
                                    "tap-events",
                                    "tap \(stripped.debugDescription) over \(typed.debugDescription) emitted no matching"
                                        + " suggestionAccepted: \(d.actionEvents)")
                            }
                        }
                    }
                }
            }
        }
        if case .predictSpace = action, d.session.committedWordCount != d.commitsBeforeAction {
            fail("prediction-no-commit", "spacebar prediction insert was credited as a commit")
        }

        // ---- Learning-event hygiene (Learning invariant #3, isEventWord) --
        for event in d.actionEvents {
            func checkToken(_ token: String, _ role: String) {
                if token.count < 2 || token.contains(where: \.isWhitespace)
                    || TypingSession.isVerbatimClassToken(token) || !EventLog.isLearnableWord(token)
                {
                    fail("event-hygiene", "\(role) token \(token.debugDescription) in \(event)")
                }
            }
            switch event {
            case .wordCommitted(let word, let previous, _):
                checkToken(word, "wordCommitted")
                if let previous { checkToken(previous, "previousWord") }
            case .suggestionAccepted(let typed, let accepted):
                checkToken(typed, "typed")
                checkToken(accepted, "accepted")
                if typed == accepted { fail("event-hygiene", "suggestionAccepted typed == accepted") }
            case .correctionReverted(let original, let applied):
                checkToken(original, "original")
                checkToken(applied, "applied")
                if original == applied { fail("event-hygiene", "correctionReverted original == applied") }
            case .wordTapped(let word):
                checkToken(word, "wordTapped")
            case .touchSample:
                break
            }
        }

        return out
    }
}

// MARK: - Engines

enum FuzzEngines {
    /// Deterministic shipping defaults: the two wall-clock decode budgets
    /// lifted (as `ArtifactLoader.deterministicConfig` does) so the
    /// expansion caps are the sole limiter and a seed replays byte-exact.
    static func deterministicConfig() -> EngineConfig {
        var config = EngineConfig()
        let budget = productionBudgetSeconds ?? 3600
        config.beamTimeBudget = budget
        config.splitTimeBudget = budget
        return config
    }

    /// `FUZZ_BUDGET=<seconds>` runs the shipping wall-clock decode budgets
    /// (e.g. 0.006) instead of the lifted deterministic ones — closer to the
    /// device, but results then depend on timing, so the determinism
    /// property is skipped and minimization may not converge.
    static var productionBudgetSeconds: Double? {
        FuzzHarness.env("FUZZ_BUDGET").flatMap(Double.init)
    }

    static func fixture() -> TypeEngine {
        let morphology = FakeMorphology([
            "hestur", "hestar", "hesti", "hús", "borða", "íslenska", "veður", "vetur",
            "vist", "víst", "fór", "för", "búð", "ég", "þú", "við", "mál", "tungumál",
        ])
        return Fixtures.engine(morphology: morphology, config: deterministicConfig())
    }

    /// Walk up from this file to the repo root (`data/is/is.lex`).
    static func repoRoot() -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent("data/is/is.lex").path) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    static var realLoadSeconds = 0.0

    /// The production artifacts (is.lex, en.lex, calibration sidecars,
    /// bin-morph + folded index, paradigms, governors) — loaded once per
    /// process, mirroring `type-repl`'s `Artifacts.loadEngine`. nil when
    /// the repo data is not present.
    static let real: TypeEngine? = {
        guard let root = repoRoot() else { return nil }
        let start = ContinuousClock.now
        do {
            let english = try FrequencyLexicon(contentsOf: root.appendingPathComponent("data/en/en.lex"))
            let icelandic = try FrequencyLexicon(contentsOf: root.appendingPathComponent("data/is/is.lex"))
            let englishCalibration = try? LexiconCalibrationProfile(
                contentsOf: root.appendingPathComponent("data/en/en-calibration.json"))
            let icelandicCalibration = try? LexiconCalibrationProfile(
                contentsOf: root.appendingPathComponent("data/is/is-calibration.json"))
            let morphology = try BinaryLemmatizer(
                contentsOf: root.appendingPathComponent("data/is/bin-morph.bin"))
            let folded = root.appendingPathComponent("data/is/bin-morph.folded.bin")
            if FileManager.default.fileExists(atPath: folded.path) {
                try? morphology.loadFoldedIndex(contentsOf: folded)
            }
            let engine = TypeEngine(
                icelandic: icelandic, english: english, morphology: morphology,
                config: deterministicConfig(),
                icelandicCalibration: icelandicCalibration,
                englishCalibration: englishCalibration)
            if let paradigms = try? ParadigmsReader(
                contentsOf: root.appendingPathComponent("data/is/paradigms.bin")),
                let governors = try? GovernorsModel(
                    gzippedJSONContentsOf: root.appendingPathComponent("data/is/governors.json.gz"))
            {
                engine.setInflection(InflectionModel(paradigms: paradigms, governors: governors))
            }
            engine.warmUp()
            realLoadSeconds = start.duration(to: .now).fuzzSeconds
            return engine
        } catch {
            return nil
        }
    }()
}

// MARK: - Corpus + generator

enum FuzzCorpus {
    /// Words harvested from `Scenarios/*.scenarios` `T`/`LONGPRESS` lines
    /// (the project's own real-bug vocabulary), plus a fixed seed list so
    /// the generator is useful even without the scenario files.
    static let words: [String] = {
        var set = Set(seedWords)
        if let root = FuzzEngines.repoRoot() {
            let dir = root.appendingPathComponent("Packages/TypeEngine/Scenarios")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for file in files.sorted() where file.hasSuffix(".scenarios") {
                    guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                    else { continue }
                    for line in text.split(separator: "\n") {
                        var rest: Substring?
                        if line.hasPrefix("T ") { rest = line.dropFirst(2) }
                        if line.hasPrefix("LONGPRESS ") { rest = line.dropFirst(10) }
                        guard var payload = rest else { continue }
                        if payload.hasPrefix("\"") { payload = payload.dropFirst() }
                        if payload.hasSuffix("\"") { payload = payload.dropLast() }
                        for token in payload.split(separator: " ") {
                            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ",.!?„\"“”"))
                            if word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) {
                                set.insert(word)
                            }
                        }
                    }
                }
            }
        }
        return set.sorted()
    }()

    static let seedWords: [String] = [
        "og", "að", "er", "ekki", "hestur", "hestar", "hesti", "hús", "íslenska", "góðan", "dag",
        "daginn", "takk", "gott", "veður", "vetur", "borða", "fyrir", "með", "við", "ég", "þú",
        "það", "þetta", "hann", "hún", "fór", "för", "vist", "víst", "búð", "sími", "símanum",
        "tungumál", "stökkleikanum", "framhaldsskóla", "kartöflunum", "veitingahúsið", "náttúrlega",
        "eitthvað", "hvernig", "núna", "smellir", "á", "í", "the", "and", "with", "which", "hello",
        "green", "world", "don't", "it's", "I'm", "they'd", "because", "weather", "weekend",
        "think", "watson's", "very", "took", "said", "see", "you", "to", "for", "of", "is",
    ]

    static let urlish: [String] = [
        "tilvinstri.is", "www.mbl.is", "profilmynd.tilvinstri.is", "jokull@triptojapan.com",
        "e.g.", "3.14", "21.000", "5G", "#tag", "/goal", "~/path", "sem.er", "læt.hann",
        "github.com", "a.b", "x.y.z",
    ]

    static let emoji: [String] = ["😀", "🇮🇸", "👨‍👩‍👧", "❤️", "👍🏽", "🙂"]

    static let punctuation: [String] = [",", ".", "!", "?", ":", ";", "\n", "„", "\"", "“", "(", ")"]

    static let accented: [String] = ["á", "é", "í", "ó", "ú", "ý", "ð", "þ", "æ", "ö"]

    static let keyboardNeighbors: [Character: [Character]] = {
        let rows = SpatialModel.icelandicRows.map(Array.init)
        var map: [Character: [Character]] = [:]
        for (r, row) in rows.enumerated() {
            for (c, key) in row.enumerated() {
                var near: [Character] = []
                for dr in -1...1 {
                    let rr = r + dr
                    guard rows.indices.contains(rr) else { continue }
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let cc = c + dc
                        if rows[rr].indices.contains(cc) { near.append(rows[rr][cc]) }
                    }
                }
                map[key] = near
            }
        }
        return map
    }()

    static let accentDrop: [Character: Character] = [
        "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y", "ð": "d", "þ": "t", "ö": "o", "æ": "a",
    ]

    /// Inject one keyboard-plausible error: accent drop, adjacent-key
    /// substitution, transposition, omission, doubling, apostrophe drop,
    /// or a near-spacebar missed space (handled by the generator).
    static func damage(_ word: String, using rng: inout FuzzRNG) -> String {
        var chars = Array(word)
        guard chars.count >= 2 else { return word }
        switch rng.int(0...6) {
        case 0:
            if let i = chars.indices.filter({ accentDrop[chars[$0]] != nil }).randomElement(using: &rng) {
                chars[i] = accentDrop[chars[i]]!
            } else {
                chars = Array(word.map { accentDrop[$0] ?? $0 })
            }
        case 1:
            let i = rng.int(0...(chars.count - 1))
            if let near = keyboardNeighbors[Character(String(chars[i]).lowercased())], let n = near.randomElement(using: &rng) {
                chars[i] = n
            }
        case 2:
            let i = rng.int(0...(chars.count - 2))
            chars.swapAt(i, i + 1)
        case 3:
            chars.remove(at: rng.int(0...(chars.count - 1)))
        case 4:
            let i = rng.int(0...(chars.count - 1))
            chars.insert(chars[i], at: i)
        case 5:
            chars.removeAll { $0 == "'" || $0 == "’" }
        default:
            chars = Array(word.map { accentDrop[$0] ?? $0 })
            if chars.count >= 3 {
                let i = rng.int(0...(chars.count - 2))
                chars.swapAt(i, i + 1)
            }
        }
        return String(chars)
    }

    static func token(using rng: inout FuzzRNG) -> String {
        var word = rng.pick(words)
        if rng.chance(0.5) { word = damage(word, using: &rng) }
        if rng.chance(0.08) { word = word.uppercased() }
        else if rng.chance(0.12) { word = word.prefix(1).uppercased() + word.dropFirst() }
        if rng.chance(0.03), let other = Optional(rng.pick(words)) { word += other }  // missed space
        return word
    }

    static func sentence(using rng: inout FuzzRNG) -> String {
        (0..<rng.int(1...5)).map { _ in token(using: &rng) }.joined(separator: " ")
            + (rng.chance(0.5) ? " " : "")
    }
}

struct FuzzGenerator {
    static func actions(count: Int, documentLengthHint: Int = 40, using rng: inout FuzzRNG) -> [FuzzAction] {
        var out: [FuzzAction] = []
        while out.count < count {
            if case .type(let word)? = out.last, rng.chance(0.45),
                word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
            {
                // Finish most words with a delimiter so armed autocorrects
                // actually get applied (and the revert probe has material).
                out.append(rng.chance(0.8) ? .space : .type(rng.pick([",", ".", "!", "?"])))
                continue
            }
            let action: FuzzAction = rng.weighted([
                (34, .type(FuzzCorpus.token(using: &rng))),
                (26, .space),
                (3, .type(rng.pick(FuzzCorpus.punctuation))),
                (4, .type(".")),
                (1, .type((0..<rng.int(2...4)).map { _ in rng.pick(FuzzCorpus.words) }.joined())),
                (7, .backspace(rng.int(1...3))),
                (5, .tap(index: rng.int(1...4))),
                (2, .tapVerbatim),
                (5, .revertProbe),
                (2, .cursorMove(to: rng.int(0...documentLengthHint), silent: rng.chance(0.35))),
                (1, .hostReplace(FuzzCorpus.sentence(using: &rng), silent: rng.chance(0.35))),
                (2, .predictSpace),
                (2, .refresh),
                (2, .windowNote),
                (2, .longPress(rng.pick(FuzzCorpus.accented))),
                (3, .tapChar(rng.pick(Array("asdfghjkleiourtnm")), dx: Double(rng.int(-45...45)) / 100, dy: Double(rng.int(-45...45)) / 100)),
                (2, .type(rng.pick(FuzzCorpus.urlish))),
                (1, .type(rng.pick(FuzzCorpus.emoji))),
                (1, .type(String(rng.int(0...2026)))),
                (2, .doubleSpace),
            ])
            out.append(action)
        }
        return out
    }
}

// MARK: - Harness: run, minimize, report

enum FuzzHarness {
    static var stepTimeLimitSeconds: Double {
        env("FUZZ_STEP_LIMIT").flatMap(Double.init) ?? 5.0
    }

    static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    struct Case {
        let seed: UInt64
        let mode: FuzzMode
        let actions: [FuzzAction]
    }

    static func makeCase(seed: UInt64, steps: Int) -> Case {
        var rng = FuzzRNG(seed: seed)
        let mode = FuzzMode.random(using: &rng)
        let actions = FuzzGenerator.actions(count: steps, using: &rng)
        return Case(seed: seed, mode: mode, actions: actions)
    }

    /// Execute one case against a fresh driver, checking invariants after
    /// every action. Returns the driver (for transcripts) and the first
    /// failure, if any.
    @discardableResult
    static func execute(
        _ actions: [FuzzAction], mode: FuzzMode, engine: TypeEngine
    ) -> (driver: FuzzDriver, failure: FuzzFailure?) {
        let driver = FuzzDriver(engine: engine, mode: mode)
        for (index, action) in actions.enumerated() {
            driver.perform(action)
            let violations = FuzzInvariants.check(driver, after: action)
            if let first = violations.first {
                return (
                    driver,
                    FuzzFailure(
                        invariant: first.invariant,
                        detail: first.detail + "\n--- action: \(action)\n--- document: \(driver.document.debugDescription)"
                            + "\n--- trace:\n\(driver.lastTrace?.report ?? "(none)")",
                        step: index)
                )
            }
        }
        return (driver, nil)
    }

    /// Whole-case properties layered on `execute`: determinism (same
    /// actions twice ⇒ identical transcripts) and, when requested, the
    /// metamorphic refresh/window-note variants (bars, documents and commit
    /// counts at the original observation points must not move).
    static func run(
        _ c: Case, engine: () -> TypeEngine, determinism: Bool, metamorphic: Bool
    ) -> FuzzFailure? {
        runTimed(c, engine: engine, determinism: determinism, metamorphic: metamorphic).failure
    }

    static func runTimed(
        _ c: Case, engine: () -> TypeEngine, determinism: Bool, metamorphic: Bool
    ) -> (failure: FuzzFailure?, refreshSeconds: [Double], coverage: [String: Int], slowest: [(seconds: Double, window: String)]) {
        let first = execute(c.actions, mode: c.mode, engine: engine())
        let d = first.driver
        if let failure = first.failure { return (failure, d.refreshSeconds, d.coverage, d.slowestRefreshes) }
        let failure = runWholeCaseProperties(c, first: d, engine: engine, determinism: determinism, metamorphic: metamorphic)
        return (failure, d.refreshSeconds, d.coverage, d.slowestRefreshes)
    }

    private static func runWholeCaseProperties(
        _ c: Case, first firstDriver: FuzzDriver, engine: () -> TypeEngine, determinism: Bool, metamorphic: Bool
    ) -> FuzzFailure? {
        let first = (driver: firstDriver, failure: FuzzFailure?.none)
        if determinism {
            let second = execute(c.actions, mode: c.mode, engine: engine())
            if let failure = second.failure, failure.invariant != "step-time" {
                return FuzzFailure(
                    invariant: "determinism",
                    detail: "replay failed where the first run passed: \(failure)", step: failure.step)
            }
            if let diff = firstDifference(first.driver.transcript, second.driver.transcript) {
                return FuzzFailure(
                    invariant: "determinism",
                    detail: "replay diverged at step \(diff.index):\n  run 1: \(diff.a)\n  run 2: \(diff.b)",
                    step: diff.index)
            }
        }
        if metamorphic, !c.mode.staleReads {
            for variant in ["extraRefresh", "extraWindowNote"] {
                var mode = c.mode
                if variant == "extraRefresh" { mode.extraRefresh = true } else { mode.extraWindowNote = true }
                let other = execute(c.actions, mode: mode, engine: engine())
                if let failure = other.failure, failure.invariant != "step-time" {
                    return FuzzFailure(
                        invariant: "metamorphic-\(variant)",
                        detail: "variant run failed an invariant the plain run passed: \(failure)",
                        step: failure.step)
                }
                if let diff = firstDifference(first.driver.transcript, other.driver.transcript) {
                    return FuzzFailure(
                        invariant: "metamorphic-\(variant)",
                        detail: "\(variant) changed the transcript at step \(diff.index):\n  plain:   \(diff.a)\n  variant: \(diff.b)",
                        step: diff.index)
                }
            }
        }
        return nil
    }

    static func firstDifference(_ a: [String], _ b: [String]) -> (index: Int, a: String, b: String)? {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "(missing)"
            let y = i < b.count ? b[i] : "(missing)"
            if x != y { return (i, x, y) }
        }
        return nil
    }

    /// ddmin over the action list: the smallest subsequence that still
    /// fails the SAME named invariant.
    static func minimize(
        _ c: Case, failure: FuzzFailure, engine: () -> TypeEngine,
        determinism: Bool, metamorphic: Bool, budget: Int = 400
    ) -> [FuzzAction] {
        var actions = c.actions
        var attempts = 0
        func stillFails(_ candidate: [FuzzAction]) -> Bool {
            attempts += 1
            let result = run(
                Case(seed: c.seed, mode: c.mode, actions: candidate), engine: engine,
                determinism: determinism, metamorphic: metamorphic)
            return result?.invariant == failure.invariant
        }
        // Drop the tail after the failing step first (nothing after it matters).
        if let step = failure.step, step + 1 < actions.count {
            let head = Array(actions.prefix(step + 1))
            if stillFails(head) { actions = head }
        }
        var granularity = 2
        while actions.count >= 2, attempts < budget {
            let chunk = max(1, actions.count / granularity)
            var reduced = false
            var start = 0
            while start < actions.count, attempts < budget {
                var candidate = actions
                candidate.removeSubrange(start..<min(start + chunk, actions.count))
                if !candidate.isEmpty, stillFails(candidate) {
                    actions = candidate
                    reduced = true
                    granularity = max(granularity - 1, 2)
                } else {
                    start += chunk
                }
            }
            if !reduced {
                if chunk == 1 { break }
                granularity = min(granularity * 2, actions.count)
            }
        }
        return actions
    }

    static func report(_ c: Case, minimized: [FuzzAction], failure: FuzzFailure, engineName: String) -> String {
        var lines: [String] = []
        lines.append("FUZZ FAILURE \(failure.invariant) (engine: \(engineName), seed: \(c.seed))")
        lines.append("mode: \(c.mode.swiftLiteral)")
        lines.append("minimized actions (\(minimized.count) of \(c.actions.count)):")
        lines.append("let d = FuzzDriver(engine: FuzzEngines.\(engineName == "fixture" ? "fixture()" : "real!"), mode: \(c.mode.swiftLiteral))")
        lines.append("d.perform([")
        for action in minimized { lines.append("    \(action.swiftLiteral),") }
        lines.append("])")
        lines.append("detail: \(failure.detail)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tests

/// Seed-reproducible property/fuzz layer over `TypingSession` through
/// `ProxySimulator`. Default run is a few seconds; environment knobs:
///
///   FUZZ_ITERATIONS   cases per engine (default: 40 fixture / 12 real in
///                     release; 8 / 1 in debug, where the engine is slow)
///   FUZZ_STEPS        actions per case (default 30)
///   FUZZ_SEED         replay exactly one seed (with the test's engine)
///   FUZZ_BASE_SEED    first seed of the sweep (default 1)
///   FUZZ_METAMORPHIC  1 = run the refresh/window-note variants on every
///                     case (default: every 4th case)
///   FUZZ_STEP_LIMIT   per-action wall-clock hang guard in seconds (default 5)
///   FUZZ_BUDGET       shipping wall-clock decode budget in seconds (e.g.
///                     0.006) instead of the lifted deterministic budgets;
///                     disables the determinism property
///
/// Soak (release; `swift test -c release` enables testable imports itself —
/// only a bare `swift build -c release --target TypeEngineTests` needs
/// `-Xswiftc -enable-testing`):
///   FUZZ_ITERATIONS=800 FUZZ_STEPS=50 swift test -c release --filter TypingSessionFuzzTests
///   FUZZ_METAMORPHIC=1 FUZZ_ITERATIONS=300 swift test -c release --filter TypingSessionFuzzTests
///   FUZZ_BUDGET=0.006 FUZZ_ITERATIONS=400 swift test -c release --filter TypingSessionFuzzTests
final class TypingSessionFuzzTests: XCTestCase {

    private func intEnv(_ name: String, _ fallback: Int) -> Int {
        FuzzHarness.env(name).flatMap(Int.init) ?? fallback
    }

    private func sweep(
        engineName: String, engine: @escaping () -> TypeEngine, defaultIterations: Int
    ) {
        let steps = intEnv("FUZZ_STEPS", 30)
        let metamorphicAll = FuzzHarness.env("FUZZ_METAMORPHIC") == "1"
        let seeds: [UInt64]
        if let one = FuzzHarness.env("FUZZ_SEED").flatMap(UInt64.init) {
            seeds = [one]
        } else {
            let base = UInt64(intEnv("FUZZ_BASE_SEED", 1))
            let iterations = intEnv("FUZZ_ITERATIONS", defaultIterations)
            seeds = (0..<iterations).map { base + UInt64($0) }
        }
        var worstStep = 0.0
        var allSteps: [Double] = []
        var coverage: [String: Int] = [:]
        var slowest: [(seconds: Double, window: String)] = []
        var failures: [String] = []
        let start = ContinuousClock.now
        for (index, seed) in seeds.enumerated() {
            let c = FuzzHarness.makeCase(seed: seed, steps: steps)
            let metamorphic = metamorphicAll || index % 4 == 0
            let deterministic = FuzzEngines.productionBudgetSeconds == nil
            let outcome = FuzzHarness.runTimed(
                c, engine: engine, determinism: deterministic, metamorphic: metamorphic && deterministic)
            allSteps += outcome.refreshSeconds
            worstStep = max(worstStep, outcome.refreshSeconds.max() ?? 0)
            for (key, count) in outcome.coverage { coverage[key, default: 0] += count }
            slowest = Array((slowest + outcome.slowest).sorted { $0.seconds > $1.seconds }.prefix(3))
            if let failure = outcome.failure {
                let minimized = FuzzHarness.minimize(
                    c, failure: failure, engine: engine, determinism: deterministic,
                    metamorphic: metamorphic && deterministic)
                let final = FuzzHarness.run(
                    Case(seed: seed, mode: c.mode, actions: minimized), engine: engine,
                    determinism: deterministic, metamorphic: metamorphic && deterministic) ?? failure
                let text = FuzzHarness.report(c, minimized: minimized, failure: final, engineName: engineName)
                print(text)
                failures.append(text)
                if failures.count >= 3 { break }
            }
        }
        let elapsed = start.duration(to: .now).fuzzSeconds
        let sorted = allSteps.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print(
            "[fuzz] \(engineName): \(seeds.count) cases x \(steps) steps in \(String(format: "%.1f", elapsed)) s;"
                + " per-keystroke p50 \(String(format: "%.1f", p50 * 1000)) ms, p99 \(String(format: "%.1f", p99 * 1000)) ms,"
                + " max \(String(format: "%.1f", worstStep * 1000)) ms over \(sorted.count) passes"
                + (engineName == "real" ? "; artifact load \(String(format: "%.1f", FuzzEngines.realLoadSeconds)) s" : "")
                + "; corpus \(FuzzCorpus.words.count) words")
        print("[fuzz] \(engineName) coverage: " + coverage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        for slow in slowest {
            print("[fuzz] \(engineName) slow pass \(String(format: "%.1f", slow.seconds * 1000)) ms: \(slow.window.debugDescription)")
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) fuzz failure(s):\n\n" + failures.joined(separator: "\n\n"))
        }
    }

    private typealias Case = FuzzHarness.Case

    /// Debug builds run the engine 10–50x slower (the real-artifact beam is
    /// ~1 s/action unoptimized), so the default sweep is sized per build:
    /// the release defaults are the meaningful ones.
    #if DEBUG
        private static let defaultFixtureIterations = 8
        private static let defaultRealIterations = 1
    #else
        private static let defaultFixtureIterations = 40
        private static let defaultRealIterations = 12
    #endif

    func testFixtureEngineFuzz() {
        sweep(engineName: "fixture", engine: FuzzEngines.fixture, defaultIterations: Self.defaultFixtureIterations)
    }

    func testRealArtifactFuzz() throws {
        guard let real = FuzzEngines.real else {
            throw XCTSkip("production artifacts (data/is/is.lex …) not found")
        }
        sweep(engineName: "real", engine: { real }, defaultIterations: Self.defaultRealIterations)
    }

    /// The generator itself must be seed-stable, or no failure report could
    /// ever be replayed.
    func testGeneratorIsSeedStable() {
        let a = FuzzHarness.makeCase(seed: 42, steps: 50)
        let b = FuzzHarness.makeCase(seed: 42, steps: 50)
        XCTAssertEqual(a.mode, b.mode)
        XCTAssertEqual(a.actions, b.actions)
        XCTAssertNotEqual(a.actions, FuzzHarness.makeCase(seed: 43, steps: 50).actions)
    }
}
