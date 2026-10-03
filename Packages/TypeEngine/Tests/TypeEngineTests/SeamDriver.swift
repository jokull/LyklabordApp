import Learning
import XCTest

@testable import TypeEngine

/// Test driver for the KeyboardExt ↔ TypeEngine apply seam.
///
/// Mirrors the extension's `LyklabordActionHandler` + `LyklabordAutocompleteService`
/// contract against a `ProxySimulator`, the same way the harness `Typist` and
/// `BackspaceRevertTests.Driver` do — plus the proxy edits that exist ONLY in
/// KeyboardExt / the vendored KeyboardKit and are not modelled by `Typist`:
///
/// - the space-commit dot attachment (`KeyboardViewController.swift`,
///   `spaceCommitMemo`): "góður␣" + "." → "góður.",
/// - KeyboardKit's auto-inserted-space removal/reinsertion after a bar tap
///   ("hestur␣" + "." → "hestur.␣" in ONE handle call),
/// - the double-space sentence ender (`endSentence(withText: ". ")`),
/// - the return key as an autocorrect trigger (`.primary` is a system action),
/// - a separately PUBLISHED bar (`AutocompleteContext`) that can lag behind the
///   session's observations (delivery lag), consulted through the same
///   `AutocorrectApplyGuard` as the extension.
///
/// Every proxy mutation of one logical action is recorded into the session's
/// expected-edit ledger as one `noteSelfEdit(before:after:)`, exactly like the
/// action handler's outermost `handle` call.
final class SeamDriver {
    let session: TypingSession
    let proxy: ProxySimulator
    let limit: Int

    /// Bar as the toolbar would show it (published), stamped with the pending
    /// token of the window it was computed for (`pendingTokenInfoKey`).
    private(set) var publishedBar: [Suggestion] = []
    private(set) var publishedPendingToken = ""
    /// Latest computed result (what the engine queue produced last).
    private(set) var latestBar: [Suggestion] = []
    private(set) var latestPendingToken = ""
    private(set) var events: [LearningEvent] = []
    private(set) var lastAppliedAutocorrect: (from: String, to: String)?
    /// When true, computed results are NOT published (delivery lag); call
    /// `deliverLatest()` to publish the most recent one.
    var holdDeliveries = false

    init(_ engine: TypeEngine, proxy: ProxySimulator = ProxySimulator(), limit: Int = 5) {
        self.session = TypingSession(engine: engine)
        self.proxy = proxy
        self.limit = limit
    }

    var document: String { proxy.document }
    var bar: [Suggestion] { publishedBar }
    var armedAutocorrect: Suggestion? { publishedBar.first(where: \.isAutocorrect) }
    var leading: Suggestion? { publishedBar.first }
    func barContains(_ text: String) -> Bool { publishedBar.contains { $0.text == text } }

    // MARK: - Typing (action handler `handle(.release, .character)`)

    func type(_ text: String) { for c in text { typeChar(c) } }

    func typeChar(_ c: Character) {
        lastAppliedAutocorrect = nil
        let before = proxy.trueContextBeforeInput
        if let revert = session.continuationRevert(for: c) { execute(revert) }
        if let attach = session.punctuationAttachment(for: c) { execute(attach) }
        if TypingSession.isDelimiter(c), c != "." {
            applyArmedAutocorrectIfCurrent()
        }
        proxy.insertText(String(c))
        session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
        refresh()
    }

    /// Type one character WITH its touch point (the action handler's
    /// `noteKeyTap` forward, before the insert).
    func tapType(_ c: Character, dx: Double, dy: Double) {
        session.noteTap(char: c, dx: dx, dy: dy)
        typeChar(c)
    }

    /// Return key: `.primary` IS an autocorrect trigger in KeyboardKit
    /// (`KeyboardAction.shouldApplyAutocorrectSuggestion`), and the newline is a
    /// delimiter for the session.
    func pressReturn() {
        typeChar("\n")
    }

    /// The space-commit apply: the published `.autocorrect` replaces the
    /// current word only when `AutocorrectApplyGuard` confirms the stamped
    /// token is still the live token (the extension's
    /// `tryApplyAutocorrectSuggestion` override).
    private func applyArmedAutocorrectIfCurrent() {
        guard let autocorrect = armedAutocorrect else { return }
        let live = proxy.trueContextBeforeInput
        guard
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: publishedPendingToken, textBeforeCursor: live)
        else { return }
        let word = TypingSession.splitCurrentWord(of: live).currentWord
        guard !word.isEmpty, autocorrect.text != word else { return }
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(autocorrect.text)
        lastAppliedAutocorrect = (from: word, to: autocorrect.text)
    }

    func backspace(_ n: Int = 1) {
        for _ in 0..<n {
            let before = proxy.trueContextBeforeInput
            proxy.deleteBackward()
            session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
            refresh()
        }
    }

    // MARK: - Bar taps (`handle(_ suggestion:)` → `insertAutocompleteSuggestion`)

    @discardableResult
    func tap(_ text: String) -> Bool {
        guard let s = publishedBar.first(where: { $0.text == text }) else { return false }
        lastAppliedAutocorrect = nil
        let extra = s.isVerbatim ? session.literalRevertAdditionalDeleteCount(matching: s.text) : 0
        if s.isVerbatim, !session.revertToLiteral(matching: s.text) {
            session.noteVerbatimChoice(s.text)
        }
        let before = proxy.trueContextBeforeInput
        let word = TypingSession.splitCurrentWord(of: before).currentWord
        for _ in 0..<(word.count + extra) { proxy.deleteBackward() }
        proxy.insertText(s.text)
        let (b, a) = proxy.contextWindows()
        if !b.hasSuffix(" "), !a.hasPrefix(" ") {
            proxy.insertText(" ")
            tapInsertedSpace = true
        }
        session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
        refresh()
        return true
    }

    /// KeyboardKit's `ProxyState.spaceState == .autoInserted` analogue.
    private var tapInsertedSpace = false

    // MARK: - Extension / KeyboardKit-only proxy edits (not in Typist)

    /// `KeyboardViewController.swift` `spaceCommitMemo` (issue #4): the period
    /// typed right after a space that committed an armed autocorrect deletes
    /// that one space so the period attaches ("góður␣" + "." → "góður.").
    /// Precondition mirrors the extension: the previous action was a released
    /// space whose apply landed (window ends with candidate + " ").
    func typeDotAttachingToSpaceCommit() {
        guard let applied = lastAppliedAutocorrect else {
            XCTFail("dot attachment needs a preceding space-commit apply")
            return
        }
        lastAppliedAutocorrect = nil
        let before = proxy.trueContextBeforeInput
        if before.hasSuffix(applied.to + " ") {
            proxy.deleteBackward()
        }
        // '.' never applies autocorrect (deferral) — plain insert.
        proxy.insertText(".")
        session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
        refresh()
    }

    /// Stock KeyboardKit after a bar tap that auto-inserted a space: a '.'
    /// release runs `tryRemoveAutocompleteInsertedSpace` (delete the auto
    /// space), inserts the dot, then `tryReinsertAutocompleteRemovedSpace`
    /// (re-insert the space) — "hestur␣" → "hestur.␣" in one handle call.
    func typeDotAfterTap() {
        lastAppliedAutocorrect = nil
        let before = proxy.trueContextBeforeInput
        if tapInsertedSpace, before.hasSuffix(" ") {
            proxy.deleteBackward()
            proxy.insertText(".")
            proxy.insertText(" ")
        } else {
            proxy.insertText(".")
        }
        tapInsertedSpace = false
        session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
        refresh()
    }

    /// KeyboardKit double-space sentence ender: the second space is inserted,
    /// then `endSentence(withText: ". ")` deletes the trailing spaces and
    /// inserts ". " — one handle call, one ledger record.
    func typeDoubleSpaceEnder() {
        lastAppliedAutocorrect = nil
        let before = proxy.trueContextBeforeInput
        proxy.insertText(" ")
        while proxy.trueContextBeforeInput.hasSuffix(" ") { proxy.deleteBackward() }
        proxy.insertText(". ")
        session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
        refresh()
    }

    // MARK: - Host / external events

    /// Host app rewrites the document (autofill, host autocorrect, undo);
    /// the extension forwards `textDidChange` as a window note and KeyboardKit
    /// runs an autocomplete pass on the new window.
    func hostReplace(_ text: String, cursorAt: Int? = nil) {
        proxy.hostReplaceText(text, cursorAt: cursorAt)
        session.noteExternalTextChange(window: proxy.contextBeforeInput)
        refresh()
    }

    /// Cursor jump: `selectionDidChange` forwards the window note; KeyboardKit
    /// re-runs autocomplete on the changed window.
    func moveCursor(to offset: Int) {
        proxy.moveCursor(to: offset)
        session.noteExternalTextChange(window: proxy.contextBeforeInput)
        refresh()
    }

    /// Re-run autocomplete on the current window (a duplicate pass).
    func refreshOnly() { refresh() }

    /// Publish the most recent computed result (delivery catching up).
    func deliverLatest() {
        publishedBar = latestBar
        publishedPendingToken = latestPendingToken
    }

    func drainEvents() -> [LearningEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - Internals

    private func execute(_ edit: RevertInstruction) {
        for _ in 0..<edit.deleteCount { proxy.deleteBackward() }
        proxy.insertText(edit.text)
    }

    /// One autocomplete pass: the session observes the proxy window (the
    /// `performAutocomplete` read), the result is stamped with the pending
    /// token of THAT window, and published unless deliveries are held.
    private func refresh() {
        let window = proxy.contextBeforeInput
        latestPendingToken = TypingSession.splitCurrentWord(of: window).currentWord
        latestBar = session.suggestions(for: window, limit: limit)
        if session.hasPendingLearningEvents {
            events += session.drainLearningEvents()
        }
        if !holdDeliveries { deliverLatest() }
    }
}
