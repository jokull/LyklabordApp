import Learning
import XCTest

@testable import TypeEngine

/// Minimal, deterministic reproductions of engine bugs found by the
/// seed-driven fuzzer in `TypingSessionFuzzTests.swift`. Each is wrapped in a
/// strict `XCTExpectFailure`, so the suite stays green today and flips red —
/// asking for the wrapper to be removed — the moment the bug is fixed.
///
/// All repros drive the production `TypingSession` through `ProxySimulator`
/// with the same embedder contract as `type-repl`'s Typist (`FuzzDriver`),
/// on the deterministic fixture engine (wall-clock decode budgets lifted).
/// The fuzz oracles carve these known shapes out (search `FuzzKnownBugs`);
/// remove the carve-out together with the wrapper when fixing.
final class FuzzFoundBugTests: XCTestCase {

    private func driver(_ mode: FuzzMode = FuzzMode()) -> FuzzDriver {
        FuzzDriver(engine: FuzzEngines.fixture(), mode: mode)
    }

    // MARK: - Bug 1: a duplicate autocomplete pass kills the punctuation-attachment memo

    /// Found by the `metamorphic-extraRefresh` property (fixture seed 17):
    /// `TypingSession.suggestions(for:)` clears `punctuationAttachmentArmed`
    /// unconditionally on entry (TypingSession.swift, top of the method:
    /// "A revert or attachment memo not consumed before the next keystroke
    /// landed is dead"), so a no-op observation of the UNCHANGED window —
    /// a duplicate autocomplete request, not a keystroke — spends the memo.
    /// The backspace-revert memo was explicitly hardened against exactly
    /// this ("Duplicate autocomplete requests are observations, not user
    /// intent, and must never consume the memo"); the attachment memo was
    /// not. Expected: "with ␣." + refresh + space still attaches ("with. ").
    func testDuplicateRefreshKillsPunctuationAttachment() {
        let control = driver()
        control.perform([.type("wth"), .space, .type("."), .space])
        XCTAssertEqual(control.document, "with. ", "control: attachment fires without the refresh")

        let d = driver()
        d.perform([.type("wth"), .space, .type(".")])
        XCTAssertTrue(d.session.hasPendingPunctuationAttachment)
        d.perform(.refresh)
        XCTExpectFailure(
            "duplicate no-op observation consumes the punctuation-attachment memo", strict: true
        ) {
            XCTAssertTrue(
                d.session.hasPendingPunctuationAttachment,
                "a duplicate observation of the same window must not consume the attachment memo")
        }
        d.perform(.space)
        XCTExpectFailure("space after the refresh no longer attaches the period", strict: true) {
            XCTAssertEqual(d.document, "with. ")
        }
    }

    // MARK: - Bug 2: a duplicate autocomplete pass kills revert-on-continuation

    /// Same root cause as bug 1 for `dotReplacement` (ADR-0006 rule 5, the
    /// "profilmynd." URL self-heal under stock KeyboardKit '.'-apply): a
    /// no-op observation between the '.'-apply and the continuing letter
    /// clears the memo, so the letter lands on the CORRECTED token and the
    /// URL/domain is mangled ("hestur.t" instead of "hestr.t").
    func testDuplicateRefreshKillsRevertOnContinuation() {
        let mode = FuzzMode(dotApply: true)
        let control = driver(mode)
        control.perform([.type("hestr"), .type("."), .type("t")])
        XCTAssertEqual(control.document, "hestr.t", "control: '.'-apply self-heals on continuation")

        let d = driver(mode)
        d.perform([.type("hestr"), .type(".")])
        XCTAssertEqual(d.document, "hestur.")
        XCTAssertTrue(d.session.hasPendingContinuationRevert)
        d.perform(.refresh)
        XCTExpectFailure(
            "duplicate no-op observation consumes the revert-on-continuation memo", strict: true
        ) {
            XCTAssertTrue(
                d.session.hasPendingContinuationRevert,
                "a duplicate observation of the same window must not consume the revert memo")
        }
        d.perform(.type("t"))
        XCTExpectFailure("continuation letter after the refresh no longer reverts the '.'-apply", strict: true) {
            XCTAssertEqual(d.document, "hestr.t")
        }
    }

    // MARK: - Bug 3: tapping a non-autocorrect slot on a deferred-dot token commits the ARMED autocorrect

    /// Found by the `tap-commit` / `tap-events` oracles. With the default
    /// sentence-cut proxy window, a tap on "hestr." (autocorrect "hestur."
    /// armed) inserts "hestr. " and the window collapses to "". The session
    /// takes `confirmPendingWordAfterTruncationReset`, which assumes the
    /// collapse was caused by a delimiter that APPLIED the armed autocorrect
    /// (`let token = lastEmittedAutocorrect ?? previousCurrentWord`), so it
    /// commits "hestur": the lane posterior trains on a word that is not in
    /// the document, `lastCommittedWord` is wrong, and the learning log gets
    /// BOTH `wordTapped(hestr)` (the verbatim tap) and
    /// `suggestionAccepted(hestr → hestur)` — the opposite signals — for one
    /// commit. The `verbatimChoice` memo set by the tap is not consulted on
    /// this path. Any non-autocorrect bar tap over a deferred-dot token has
    /// the same shape. Under `TruncationPolicy.none` the committed form is
    /// read back from the visible window and is correct.
    func testVerbatimTapOnDeferredDotTokenCommitsArmedAutocorrect() {
        let d = driver()
        d.perform([.type("hestr"), .type(".")])
        XCTAssertEqual(d.currentWord, "hestr.")
        XCTAssertTrue(d.bar.contains { $0.isAutocorrect && $0.text == "hestur." }, d.barDescription)
        d.perform(.tapVerbatim)
        XCTAssertEqual(d.document, "hestr. ", "the embedder inserted the literal")
        XCTExpectFailure(
            "truncation-reset commit path assumes the armed autocorrect was applied", strict: true
        ) {
            XCTAssertEqual(d.session.lastCommittedWord, "hestr")
        }
        XCTExpectFailure("verbatim tap over a deferred-dot token logs suggestionAccepted", strict: true) {
            XCTAssertFalse(
                d.actionEvents.contains { if case .suggestionAccepted = $0 { return true }; return false },
                "a verbatim tap must not log suggestionAccepted; events: \(d.actionEvents)")
        }
        XCTAssertTrue(
            d.actionEvents.contains { if case .wordTapped(let w) = $0 { return w == "hestr" }; return false },
            "events: \(d.actionEvents)")

        // Visible-window control: no sentence cut ⇒ the commit is read from
        // the document and is correct.
        let control = driver(FuzzMode(truncationNone: true))
        control.perform([.type("hestr"), .type("."), .tapVerbatim])
        XCTAssertEqual(control.document, "hestr. ")
        XCTAssertEqual(control.session.lastCommittedWord, "hestr")
    }

    /// Second flavour (real-artifact seeds 5024/5028: "Rétta." + tap
    /// "Réttan." committed "Rétta"): with NO autocorrect armed, the same
    /// path commits the TYPED token (`previousCurrentWord`), so a tapped
    /// completion/alternative over a deferred-dot token is never the word
    /// that commits. The lane trains on the typo and no suggestionAccepted
    /// is logged.
    func testCompletionTapOnDeferredDotTokenCommitsTypedToken() {
        let d = driver()
        d.perform([.type("hesti"), .type(".")])  // valid word: nothing armed
        XCTAssertEqual(d.currentWord, "hesti.")
        XCTAssertFalse(d.bar.contains(where: \.isAutocorrect), d.barDescription)
        guard let alternative = d.bar.first(where: { !$0.isVerbatim }) else {
            return XCTFail("fixture bar has no alternative to tap: \(d.barDescription)")
        }
        let stem = String(alternative.text.dropLast())
        d.perform(.tap(index: d.bar.firstIndex(of: alternative)!))
        XCTAssertEqual(d.document, alternative.text + " ")
        XCTExpectFailure("truncation-reset commit path commits the typed token, not the tapped one", strict: true) {
            XCTAssertEqual(d.session.lastCommittedWord, stem)
        }
    }

    /// Sharpest flavour (fixture seed 20054, stale-read mode, no tap at
    /// all): "hestr." with "hestur." armed, then two spaces under a one-
    /// read-stale proxy. The first space's bar is stale (pending token
    /// "hestr" vs live "hestr.") so `AutocorrectApplyGuard` rejects the
    /// apply; the second space has no word in progress. Nothing was ever
    /// applied — the document reads "hestr.  " — yet the collapse path
    /// commits `lastEmittedAutocorrect` = "hestur" and logs
    /// `suggestionAccepted(hestr → hestur)`: the session trusts the armed
    /// autocorrect with no evidence it was applied.
    func testStaleCollapseCommitsAutocorrectThatWasNeverApplied() {
        let d = driver(FuzzMode(staleReads: true))
        d.perform([.type("hestr"), .type("."), .space, .space])
        XCTAssertEqual(d.document, "hestr.  ", "no autocorrect was applied (stale bar failed the apply guard)")
        XCTAssertEqual(d.lastWindow, "", "window collapsed at the sentence cut")
        XCTExpectFailure("collapse path commits the armed-but-never-applied autocorrect", strict: true) {
            XCTAssertEqual(d.session.lastCommittedWord, "hestr")
        }
    }

    // MARK: - Bug 4: deferred-dot acceptance is not recognized when the window stays visible

    /// Found by the `tap-events` oracle (fixture seeds 121/140, real 110).
    /// `confirmIfCommitted`'s single-word path tests
    /// `lastEmittedSuggestionTexts.contains(committed)` — but every bar text
    /// for a deferred-dot token carries the pending dot ("hestur."), while
    /// the committed word read back from "hestur. " is "hestur". The
    /// multi-word (split) path right above it tolerates the dot
    /// (`$0 == joined || $0 == joined + "."`); the single-word path does
    /// not. Consequences for any host whose window does NOT collapse at
    /// ". " (`TruncationPolicy.none`): an applied autocorrect / tapped
    /// suggestion over "word." is logged as a plain `wordCommitted` instead
    /// of `suggestionAccepted`, and `revertLiteral` stays nil so the
    /// backspace-revert slot never arms. Under the default sentence-cut
    /// proxy the truncation-reset path handles the same keystrokes correctly
    /// (control below).
    func testDeferredDotAcceptanceMissedWhenWindowStaysVisible() {
        let visible = driver(FuzzMode(truncationNone: true))
        visible.perform([.type("hestr"), .type("."), .space])
        XCTAssertEqual(visible.document, "hestur. ", "the space applied the armed autocorrect")
        XCTAssertEqual(visible.session.lastCommittedWord, "hestur")
        XCTExpectFailure("single-word commit path ignores the pending dot on bar texts", strict: true) {
            XCTAssertTrue(
                visible.actionEvents.contains {
                    if case .suggestionAccepted(let typed, let accepted) = $0 {
                        return typed == "hestr" && accepted == "hestur"
                    }
                    return false
                }, "events: \(visible.actionEvents)")
        }
        visible.perform(.backspace(2))
        XCTAssertEqual(visible.document, "hestur")
        XCTExpectFailure("backspace-revert slot never arms for a deferred-dot autocorrect commit", strict: true) {
            XCTAssertTrue(visible.session.hasArmedLiteralRevert, "bar: \(visible.barDescription)")
        }

        // Control: the default sentence-cut window takes the truncation-
        // reset path, which recognizes the acceptance and arms the slot.
        let collapsing = driver()
        collapsing.perform([.type("hestr"), .type("."), .space])
        XCTAssertTrue(
            collapsing.actionEvents.contains { if case .suggestionAccepted = $0 { return true }; return false },
            "events: \(collapsing.actionEvents)")
        collapsing.perform(.backspace(2))
        XCTAssertTrue(collapsing.session.hasArmedLiteralRevert, "bar: \(collapsing.barDescription)")
    }

    // MARK: - Bug 5: a stale observation arms punctuation attachment one keystroke late and eats a letter

    /// Found by the `attachment-instruction` oracle (seed 106, stale-read
    /// mode). With a proxy whose first read after each edit is one edit
    /// behind (the briefly-stale real proxy the ledger exists for), the
    /// observation made on the "x" keystroke still shows "sa ." — the
    /// ledger matches it to the '.' record (the "x" record stays pending),
    /// `heuristicChange` diffs "sa " → "sa ." as an appended "." and
    /// `armPunctuationAttachmentIfAny` arms the memo as if '.' were the
    /// keystroke just typed. The next space then executes the attachment
    /// against the LIVE document "sa .x": delete 2 (" x"? no — the trailing
    /// ".x"), insert ".", insert " " → "sa . ". The user's letter is gone
    /// and the period is detached from the word. Without stale reads the
    /// same keystrokes give "sa .x ". The session could know the window was
    /// not current: a later self-edit record was still unconfirmed when the
    /// memo armed.
    func testStaleObservationArmsPunctuationAttachmentLateAndEatsLetter() {
        let fresh = driver()
        fresh.perform([.type("sa"), .space, .type("."), .type("x"), .space])
        XCTAssertEqual(fresh.document, "sa .x ", "control: no attachment once a letter follows the dot")

        let stale = driver(FuzzMode(staleReads: true))
        stale.perform([.type("sa"), .space, .type("."), .type("x")])
        XCTAssertEqual(stale.document, "sa .x")
        XCTExpectFailure("attachment memo armed from a one-edit-stale observation", strict: true) {
            XCTAssertFalse(stale.session.hasPendingPunctuationAttachment)
        }
        stale.perform(.space)
        XCTExpectFailure("late attachment deletes the user's letter", strict: true) {
            XCTAssertEqual(stale.document, "sa .x ")
        }
    }

    // MARK: - Bug 6: a duplicate pass after a window-collapsing autocorrect commit drops the backspace-revert memo

    /// Found by the `metamorphic-extraRefresh` property (real seed 20009:
    /// "Gtet." + space → "Get. "). The space applies the autocorrect and the
    /// sentence-cut proxy collapses the window to "", so the memo is armed
    /// by `confirmPendingWordAfterTruncationReset`. `resolveBackspaceRevert`
    /// recognizes only two shapes — window ends with the corrected word, or
    /// with corrected word + one delimiter — and the empty collapsed window
    /// is neither, so the first observation that evaluates the memo drops
    /// it. Without a duplicate pass that observation is the first backspace
    /// (window "hestur."), which the one-pass `backspaceRevertJustArmed`
    /// grace skips, and the second backspace ("hestur") matches — the memo
    /// survives by luck. A duplicate autocomplete request between the commit
    /// and the backspace ("observations, not user intent, must never consume
    /// the memo") kills the escape hatch.
    func testDuplicateRefreshAfterCollapsedAutocorrectCommitDropsRevertMemo() {
        let control = driver()
        control.perform([.type("hestr"), .type("."), .space, .backspace(2)])
        XCTAssertEqual(control.document, "hestur")
        XCTAssertTrue(control.session.hasArmedLiteralRevert, "control bar: \(control.barDescription)")

        let d = driver()
        d.perform([.type("hestr"), .type("."), .space])
        XCTAssertEqual(d.document, "hestur. ")
        XCTAssertEqual(d.lastWindow, "", "sentence-cut proxy collapsed the window")
        d.perform([.refresh, .backspace(2)])
        XCTAssertEqual(d.document, "hestur")
        XCTExpectFailure("resolveBackspaceRevert drops the memo on the collapsed (empty) window", strict: true) {
            XCTAssertTrue(d.session.hasArmedLiteralRevert, "bar: \(d.barDescription)")
        }
    }

    // MARK: - Bug 7: a word committed by Return is never confirmed under a newline-cutting proxy

    /// Found by the `applied-autocorrect-committed` oracle (real seeds
    /// 30025/30061, "þettadont" + Return → "þetta dont\n" with no commit).
    /// The default `ProxySimulator` policy — like iOS — cuts the before-
    /// window at a newline, so after Return the session observes "". The
    /// only collapse the session understands is the ". " sentence cut
    /// (`heuristicChange`: `window.isEmpty, endsWithSentenceTerminator(
    /// previous)` → `.truncationReset`); an empty window after a newline is
    /// classified as a plain shrink and nothing commits. Every word typed
    /// before Return therefore skips `confirmWord` (no lane update), emits no
    /// learning event, and an autocorrect applied by Return never arms the
    /// backspace-revert memo. With a non-cutting window the same keystrokes
    /// commit normally (control).
    func testReturnKeyCommitLostUnderNewlineCuttingProxy() {
        let control = driver(FuzzMode(truncationNone: true))
        control.perform([.type("hestur"), .type("\n")])
        XCTAssertEqual(control.session.committedWordCount, 1)
        XCTAssertEqual(control.session.lastCommittedWord, "hestur")

        let d = driver()
        d.perform([.type("hestur"), .type("\n")])
        XCTAssertEqual(d.document, "hestur\n")
        XCTAssertEqual(d.lastWindow, "", "newline-cutting proxy collapsed the window")
        XCTExpectFailure("empty window after Return is not recognized as a commit", strict: true) {
            XCTAssertEqual(d.session.committedWordCount, 1)
        }
        XCTExpectFailure("no wordCommitted learning event for a word delimited by Return", strict: true) {
            XCTAssertTrue(
                d.actionEvents.contains { if case .wordCommitted(let w, _, _) = $0 { return w == "hestur" }; return false },
                "events: \(d.actionEvents)")
        }

        // Autocorrect flavour: Return applies "hestr" → "hestur" and the
        // correction is neither confirmed nor revertable.
        let a = driver()
        a.perform([.type("hestr"), .type("\n")])
        XCTAssertEqual(a.document, "hestur\n", "Return applied the armed autocorrect")
        XCTExpectFailure("autocorrect applied by Return is never confirmed", strict: true) {
            XCTAssertEqual(a.session.lastCommittedWord, "hestur")
        }
    }
}
