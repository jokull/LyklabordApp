import Foundation
import TypeEngine

/// Drives a `TypingSession` through a `ProxySimulator` exactly the way the
/// keyboard extension is driven on device:
///
/// - every keystroke is `proxy.insertText` (or `deleteBackward`),
/// - the session only ever sees `proxy.contextBeforeInput` — the truncated
///   window, never the full document,
/// - typing a word delimiter while the bar holds an `.autocorrect`
///   suggestion first replaces the current word (delete-backward x n +
///   insert), mirroring KeyboardKit's `StandardActionHandler` space-commit.
///   Like the extension's action-handler subclass, '.' does NOT apply the
///   pending autocorrect (the commit decision for a trailing dot is
///   deferred to the next keystroke — URLs/domains must survive); set
///   `appliesAutocorrectOnDot` to model STOCK KeyboardKit behavior, which
///   applies on '.' and relies on revert-on-continuation to self-heal,
/// - before inserting a letter/digit the session is offered the
///   revert-on-continuation decision (`continuationRevert(for:)`) and any
///   returned instruction is executed as proxy edits, exactly like the
///   extension's action-handler hook,
/// - tapping a suggestion replaces the current token and inserts a space
///   (KeyboardKit `insertAutocompleteSuggestion` semantics); verbatim taps
///   are reported to the session so autocorrect is suppressed for that
///   token,
/// - cursor jumps / host mutations notify the session via
///   `noteExternalTextChange()` and trigger a refresh, which is what a
///   correct extension should do from `selectionDidChange`/`textDidChange`.
final class Typist {
    let session: TypingSession
    let proxy: ProxySimulator
    var limit: Int

    /// Model STOCK KeyboardKit '.'-behavior (apply pending autocorrect on
    /// the period keystroke). Off by default = our action-handler subclass,
    /// which defers the apply to the next delimiter.
    var appliesAutocorrectOnDot = false

    private(set) var lastSuggestions: [Suggestion] = []
    /// The context window the session saw on the most recent refresh.
    private(set) var lastContextBefore = ""
    private(set) var lastLatencyMicros = 0.0
    private(set) var latenciesMicros: [Double] = []
    /// Set when the most recent keystroke applied an autocorrect.
    private(set) var lastAppliedAutocorrect: (from: String, to: String)?
    /// Set when the most recent keystroke executed a revert-on-continuation.
    private(set) var lastRevert: RevertInstruction?

    private let clock = ContinuousClock()

    init(engine: TypeEngine, proxy: ProxySimulator = ProxySimulator(), limit: Int = 5) {
        self.session = TypingSession(engine: engine)
        self.proxy = proxy
        self.limit = limit
    }

    /// Word currently in progress, as of the last refresh.
    var currentWord: String {
        TypingSession.splitCurrentWord(of: lastContextBefore).currentWord
    }

    // MARK: - Typing

    func type(_ text: String) {
        for character in text { typeCharacter(character) }
    }

    func typeCharacter(_ character: Character) {
        lastAppliedAutocorrect = nil
        lastRevert = nil
        // Revert-on-continuation (extension action-handler hook): before a
        // letter/digit lands, the session may order the last '.'-triggered
        // auto-replacement undone. Non-continuation characters discard the
        // memo inside the session.
        if let revert = session.continuationRevert(for: character) {
            for _ in 0..<revert.deleteCount { proxy.deleteBackward() }
            proxy.insertText(revert.text)
            lastRevert = revert
        }
        // Punctuation attachment (extension action-handler hook, PLAN.md
        // "Space-miss correction" #3): a space right after "word ␣." orders
        // the stray space removed before this keystroke's space lands, so
        // the document reads "word.␣". Other characters discard the memo
        // inside the session.
        if let attachment = session.punctuationAttachment(for: character) {
            for _ in 0..<attachment.deleteCount { proxy.deleteBackward() }
            proxy.insertText(attachment.text)
        }
        // KeyboardKit space-commit: a delimiter keystroke first applies the
        // pending autocorrect suggestion (replace current word), then inserts
        // the delimiter. '.' is excluded by our action-handler subclass (the
        // deferral) unless stock behavior is being modeled.
        let appliesAutocorrect =
            TypingSession.isDelimiter(character)
            && (character != "." || appliesAutocorrectOnDot)
        if appliesAutocorrect,
            let autocorrect = lastSuggestions.first(where: { $0.isAutocorrect })
        {
            let word = currentWord
            if !word.isEmpty, autocorrect.text != word {
                for _ in 0..<word.count { proxy.deleteBackward() }
                proxy.insertText(autocorrect.text)
                lastAppliedAutocorrect = (from: word, to: autocorrect.text)
            }
        }
        proxy.insertText(String(character))
        refresh()
    }

    func pressBackspace(_ count: Int = 1) {
        for _ in 0..<count {
            proxy.deleteBackward()
            refresh()
        }
    }

    // MARK: - Suggestion taps

    /// Tap the bar suggestion whose text matches; returns false when it is
    /// not in the bar. Mirrors KeyboardKit's `handle(_ suggestion:)` →
    /// `insertAutocompleteSuggestion`: replace the current token with the
    /// suggestion text, then insert a space unless one is adjacent. The
    /// extension bridges the token boundary difference (KeyboardKit's own
    /// current-word never spans dots) with `additionalDeleteCount`, so
    /// "replace the whole pending token" is the shared semantics. Verbatim
    /// taps are reported to the session (autocorrect suppression memo).
    @discardableResult
    func tapSuggestion(_ text: String) -> Bool {
        guard let suggestion = lastSuggestions.first(where: { $0.text == text }) else {
            return false
        }
        lastAppliedAutocorrect = nil
        lastRevert = nil
        if suggestion.isVerbatim {
            session.noteVerbatimChoice(suggestion.text)
        }
        let word = currentWord
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(suggestion.text)
        let (before, after) = proxy.contextWindows()
        if !before.hasSuffix(" "), !after.hasPrefix(" ") {
            proxy.insertText(" ")
        }
        refresh()
        return true
    }

    // MARK: - External events

    /// Cursor jump / host mutation happened on the proxy; tell the session
    /// and re-run autocomplete on the new window.
    func externalChange() {
        session.noteExternalTextChange()
        refresh()
    }

    /// Same event, but WITHOUT notifying the session — exercises the
    /// session's internal non-append window-change detection (the
    /// belt-and-braces path for hosts/timing where the extension's
    /// selectionDidChange/textDidChange forwarding is missed).
    func silentExternalChange() {
        refresh()
    }

    /// Simulate the extension forwarding `textDidChange`/`selectionDidChange`
    /// to the session: the window-aware, idempotent note. Fires after our
    /// own insertions too on device, so scenarios use it to prove it never
    /// disturbs normal typing.
    func forwardWindowNote() {
        session.noteExternalTextChange(window: proxy.contextBeforeInput)
    }

    /// Re-read the proxy and re-run autocomplete (KeyboardKit does this on
    /// every text change; also useful to sync after stale reads).
    func refresh() {
        let before = proxy.contextBeforeInput
        lastContextBefore = before
        let start = clock.now
        lastSuggestions = session.suggestions(for: before, limit: limit)
        let micros = start.duration(to: clock.now).microseconds
        lastLatencyMicros = micros
        latenciesMicros.append(micros)
    }

    /// Fresh field: empty document, session state + posterior reset.
    func reset(document: String = "") {
        proxy.hostReplaceText(document)
        session.reset()
        lastSuggestions = []
        lastContextBefore = ""
        lastAppliedAutocorrect = nil
        lastRevert = nil
        latenciesMicros.removeAll()
        lastLatencyMicros = 0
    }

    // MARK: - Presentation helpers

    /// Human description of what a space press would commit right now.
    var spaceCommitDescription: String {
        let word = currentWord
        if word.isEmpty {
            return "space is just a space (no word in progress)"
        }
        if let autocorrect = lastSuggestions.first(where: { $0.isAutocorrect }) {
            return "space commits \"\(autocorrect.text)\" (AUTOCORRECT from \"\(word)\")"
        }
        return "space commits \"\(word)\" (as typed)"
    }

    /// One-line suggestion bar; autocorrect flagged with `*`, the verbatim
    /// escape-hatch slot rendered quoted (like the device toolbar).
    var barDescription: String {
        guard !lastSuggestions.isEmpty else { return "(no suggestions)" }
        return lastSuggestions.enumerated()
            .map { index, s in
                let text = s.isVerbatim ? "\u{201C}\(s.text)\u{201D}" : s.text
                return "\(index + 1).\(text)\(s.isAutocorrect ? "*" : "")"
            }
            .joined(separator: "  ")
    }
}
