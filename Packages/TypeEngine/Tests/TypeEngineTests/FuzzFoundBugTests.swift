import Learning
import XCTest

@testable import TypeEngine

/// Minimal, deterministic reproductions of engine bugs found by the
/// seed-driven fuzzer in `TypingSessionFuzzTests.swift`, kept as ordinary
/// regressions now that they are fixed (each started life as a strict
/// `XCTExpectFailure`; the fuzz oracles' `FuzzKnownBugs` carve-outs went with
/// the wrappers, so the sweep enforces every invariant below).
///
/// All repros drive the production `TypingSession` through `ProxySimulator`
/// with the same embedder contract as `type-repl`'s Typist (`FuzzDriver`),
/// on the deterministic fixture engine (wall-clock decode budgets lifted).
final class FuzzFoundBugTests: XCTestCase {

    private func driver(_ mode: FuzzMode = FuzzMode()) -> FuzzDriver {
        FuzzDriver(engine: FuzzEngines.fixture(), mode: mode)
    }

    // MARK: - Bug 1: a duplicate autocomplete pass must not kill the punctuation-attachment memo

    /// Found by the `metamorphic-extraRefresh` property (fixture seed 17):
    /// `TypingSession.suggestions(for:)` cleared `punctuationAttachmentArmed`
    /// unconditionally on entry, so a no-op observation of the UNCHANGED
    /// window — a duplicate autocomplete request, not a keystroke — spent
    /// the memo. Observations of an unchanged window are now idempotent:
    /// "with ␣." + refresh + space still attaches ("with. ").
    func testDuplicateRefreshKeepsPunctuationAttachment() {
        let control = driver()
        control.perform([.type("wth"), .space, .type("."), .space])
        XCTAssertEqual(control.document, "with. ", "control: attachment fires without the refresh")

        let d = driver()
        d.perform([.type("wth"), .space, .type(".")])
        XCTAssertTrue(d.session.hasPendingPunctuationAttachment)
        d.perform(.refresh)
        XCTAssertTrue(
            d.session.hasPendingPunctuationAttachment,
            "a duplicate observation of the same window must not consume the attachment memo")
        d.perform(.space)
        XCTAssertEqual(d.document, "with. ")
    }

    // MARK: - Bug 2: a duplicate autocomplete pass must not kill revert-on-continuation

    /// Same root cause as bug 1 for `dotReplacement` (ADR-0006 rule 5, the
    /// "profilmynd." URL self-heal under stock KeyboardKit '.'-apply): a
    /// no-op observation between the '.'-apply and the continuing letter
    /// must leave the memo, so the letter lands on the ORIGINAL token
    /// ("hestr.t", not "hestur.t").
    func testDuplicateRefreshKeepsRevertOnContinuation() {
        let mode = FuzzMode(dotApply: true)
        let control = driver(mode)
        control.perform([.type("hestr"), .type("."), .type("t")])
        XCTAssertEqual(control.document, "hestr.t", "control: '.'-apply self-heals on continuation")

        let d = driver(mode)
        d.perform([.type("hestr"), .type(".")])
        XCTAssertEqual(d.document, "hestur.")
        XCTAssertTrue(d.session.hasPendingContinuationRevert)
        d.perform(.refresh)
        XCTAssertTrue(
            d.session.hasPendingContinuationRevert,
            "a duplicate observation of the same window must not consume the revert memo")
        d.perform(.type("t"))
        XCTAssertEqual(d.document, "hestr.t")
    }

    /// A CHANGED window still retires an unconsumed memo (its one-keystroke
    /// window has passed): an embedder that never consults
    /// `continuationRevert` must not see a stale memo later.
    func testChangedWindowRetiresUnconsumedMemos() {
        let d = driver(FuzzMode(dotApply: true))
        d.perform([.type("hestr"), .type(".")])
        XCTAssertTrue(d.session.hasPendingContinuationRevert)
        d.session.noteSelfEdit(before: "hestur.", after: "hestur. ", keystroke: " ")
        _ = d.session.suggestions(for: "hestur. ", limit: 5)
        XCTAssertFalse(d.session.hasPendingContinuationRevert)
    }

    // MARK: - Bug 3: tapping a non-autocorrect slot on a deferred-dot token commits what was tapped

    /// Found by the `tap-commit` / `tap-events` oracles. With the default
    /// sentence-cut proxy window, a tap on "hestr." (autocorrect "hestur."
    /// armed) inserts "hestr. " and the window collapses to "". The collapse
    /// path used to assume the armed autocorrect had been applied and
    /// committed "hestur": the lane trained on a word that is not in the
    /// document and the learning log got BOTH `wordTapped(hestr)` and
    /// `suggestionAccepted(hestr → hestur)`. The verbatim-choice memo now
    /// decides: the typed token committed.
    func testVerbatimTapOnDeferredDotTokenCommitsTheTypedToken() {
        let d = driver()
        d.perform([.type("hestr"), .type(".")])
        XCTAssertEqual(d.currentWord, "hestr.")
        XCTAssertTrue(d.bar.contains { $0.isAutocorrect && $0.text == "hestur." }, d.barDescription)
        d.perform(.tapVerbatim)
        XCTAssertEqual(d.document, "hestr. ", "the embedder inserted the literal")
        XCTAssertEqual(d.session.lastCommittedWord, "hestr")
        XCTAssertFalse(
            d.actionEvents.contains { if case .suggestionAccepted = $0 { return true }; return false },
            "a verbatim tap must not log suggestionAccepted; events: \(d.actionEvents)")
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
    /// "Réttan." committed "Rétta"): with NO autocorrect armed, the collapse
    /// path committed the TYPED token. The tap's record now reports the
    /// tapped text as the replacement, so the tapped word commits and a
    /// suggestionAccepted is logged.
    func testCompletionTapOnDeferredDotTokenCommitsTheTappedToken() {
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
        XCTAssertEqual(d.session.lastCommittedWord, stem)
        XCTAssertTrue(
            d.actionEvents.contains {
                if case .suggestionAccepted(let typed, let accepted) = $0 {
                    return typed == "hesti" && accepted == stem
                }
                return false
            }, "events: \(d.actionEvents)")
        XCTAssertFalse(d.session.hasArmedLiteralRevert, "a tapped alternative is not a force-correction")
    }

    /// Sharpest flavour (fixture seed 20054, stale-read mode, no tap at
    /// all): "hestr." with "hestur." armed, then two spaces under a one-
    /// read-stale proxy. The first space's bar is stale (pending token
    /// "hestr" vs live "hestr.") so `AutocorrectApplyGuard` rejects the
    /// apply; the second space has no word in progress. Nothing was ever
    /// applied — the document reads "hestr.  " — and the described records
    /// (keystroke, no replacement) let the collapse path commit the typed
    /// token instead of trusting the armed autocorrect.
    func testStaleCollapseCommitsTheTypedTokenWhenNothingWasApplied() {
        let d = driver(FuzzMode(staleReads: true))
        d.perform([.type("hestr"), .type("."), .space, .space])
        XCTAssertEqual(d.document, "hestr.  ", "no autocorrect was applied (stale bar failed the apply guard)")
        XCTAssertEqual(d.lastWindow, "", "window collapsed at the sentence cut")
        XCTAssertEqual(d.session.lastCommittedWord, "hestr")
        XCTAssertFalse(
            d.events.contains { if case .suggestionAccepted = $0 { return true }; return false },
            "events: \(d.events)")
    }

    /// Legacy embedders (window-only records, like the harness Typist) keep
    /// the historical reconstruction: an armed autocorrect is assumed applied
    /// on the ". " collapse.
    func testLegacyRecordKeepsTheAssumedApplyOnCollapse() {
        let d = driver()
        d.perform([.type("hestr"), .type(".")])
        XCTAssertEqual(d.lastWindow, "hestr.")
        // A window-only record for the committing space (the Typist's shape).
        d.session.noteSelfEdit(before: "hestr.", after: "")
        _ = d.session.suggestions(for: "", limit: 5)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    // MARK: - Bug 4: deferred-dot acceptance is recognized when the window stays visible

    /// Found by the `tap-events` oracle (fixture seeds 121/140, real 110).
    /// `confirmIfCommitted`'s single-word path tested
    /// `lastEmittedSuggestionTexts.contains(committed)` — but every bar text
    /// for a deferred-dot token carries the pending dot ("hestur."), while
    /// the committed word read back from "hestur. " is "hestur". Both
    /// spellings now match (as the multi-word path already did), so a host
    /// whose window does NOT collapse at ". " logs the acceptance and arms
    /// the backspace-revert slot exactly like the sentence-cut host.
    func testDeferredDotAcceptanceRecognizedWhenWindowStaysVisible() {
        let visible = driver(FuzzMode(truncationNone: true))
        visible.perform([.type("hestr"), .type("."), .space])
        XCTAssertEqual(visible.document, "hestur. ", "the space applied the armed autocorrect")
        XCTAssertEqual(visible.session.lastCommittedWord, "hestur")
        XCTAssertTrue(
            visible.actionEvents.contains {
                if case .suggestionAccepted(let typed, let accepted) = $0 {
                    return typed == "hestr" && accepted == "hestur"
                }
                return false
            }, "events: \(visible.actionEvents)")
        visible.perform(.backspace(2))
        XCTAssertEqual(visible.document, "hestur")
        XCTAssertTrue(visible.session.hasArmedLiteralRevert, "bar: \(visible.barDescription)")

        // The default sentence-cut window takes the collapse path, which
        // recognizes the acceptance and arms the slot the same way.
        let collapsing = driver()
        collapsing.perform([.type("hestr"), .type("."), .space])
        XCTAssertTrue(
            collapsing.actionEvents.contains { if case .suggestionAccepted = $0 { return true }; return false },
            "events: \(collapsing.actionEvents)")
        collapsing.perform(.backspace(2))
        XCTAssertTrue(collapsing.session.hasArmedLiteralRevert, "bar: \(collapsing.barDescription)")
    }

    // MARK: - Bug 5: a stale observation must not arm punctuation attachment late

    /// Found by the `attachment-instruction` oracle (seed 106, stale-read
    /// mode). With a proxy whose first read after each edit is one edit
    /// behind, the observation made on the "x" keystroke still shows "sa ."
    /// — the ledger matches it to the '.' record while the "x" record stays
    /// pending — and the attachment memo armed as if '.' were the keystroke
    /// just typed. The next space then executed the attachment against the
    /// LIVE document "sa .x" and deleted the user's letter. One-shot memos
    /// now arm only from a CURRENT observation (no record still pending).
    func testStaleObservationDoesNotArmPunctuationAttachment() {
        let fresh = driver()
        fresh.perform([.type("sa"), .space, .type("."), .type("x"), .space])
        XCTAssertEqual(fresh.document, "sa .x ", "control: no attachment once a letter follows the dot")

        let stale = driver(FuzzMode(staleReads: true))
        stale.perform([.type("sa"), .space, .type("."), .type("x")])
        XCTAssertEqual(stale.document, "sa .x")
        XCTAssertFalse(stale.session.hasPendingPunctuationAttachment)
        stale.perform(.space)
        XCTAssertEqual(stale.document, "sa .x ")
    }

    // MARK: - Bug 6: a duplicate pass after a window-collapsing autocorrect commit keeps the backspace-revert memo

    /// Found by the `metamorphic-extraRefresh` property (real seed 20009:
    /// "Gtet." + space → "Get. "). The space applies the autocorrect and the
    /// sentence-cut proxy collapses the window to "", so the memo is armed by
    /// the collapse path. `resolveBackspaceRevert` recognized only two
    /// shapes — window ends with the corrected word, or with corrected word
    /// + one delimiter — and the empty collapsed window was neither, so a
    /// duplicate autocomplete request between the commit and the backspace
    /// dropped the escape hatch. Unchanged-window observations are no-ops.
    func testDuplicateRefreshAfterCollapsedAutocorrectCommitKeepsRevertMemo() {
        let control = driver()
        control.perform([.type("hestr"), .type("."), .space, .backspace(2)])
        XCTAssertEqual(control.document, "hestur")
        XCTAssertTrue(control.session.hasArmedLiteralRevert, "control bar: \(control.barDescription)")

        let d = driver()
        d.perform([.type("hestr"), .type("."), .space])
        XCTAssertEqual(d.document, "hestur. ")
        XCTAssertEqual(d.lastWindow, "", "sentence-cut proxy collapsed the window")
        d.perform([.refresh, .refresh, .backspace(2)])
        XCTAssertEqual(d.document, "hestur")
        XCTAssertTrue(d.session.hasArmedLiteralRevert, "bar: \(d.barDescription)")
    }

    // MARK: - Bug 7: a word committed by Return is confirmed under a newline-cutting proxy

    /// Found by the `applied-autocorrect-committed` oracle (real seeds
    /// 30025/30061, "þettadont" + Return → "þetta dont\n" with no commit).
    /// The default `ProxySimulator` policy — like iOS — cuts the before-
    /// window at a newline, so after Return the session observes "". The
    /// only collapse the session understood was the ". " sentence cut; an
    /// empty window after a newline was a plain shrink. The record's
    /// keystroke ("\n") now identifies the Return, and the word commits
    /// exactly as with a non-cutting window (control).
    func testReturnKeyCommitConfirmedUnderNewlineCuttingProxy() {
        let control = driver(FuzzMode(truncationNone: true))
        control.perform([.type("hestur"), .type("\n")])
        XCTAssertEqual(control.session.committedWordCount, 1)
        XCTAssertEqual(control.session.lastCommittedWord, "hestur")

        let d = driver()
        d.perform([.type("hestur"), .type("\n")])
        XCTAssertEqual(d.document, "hestur\n")
        XCTAssertEqual(d.lastWindow, "", "newline-cutting proxy collapsed the window")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertTrue(
            d.actionEvents.contains { if case .wordCommitted(let w, _, _) = $0 { return w == "hestur" }; return false },
            "events: \(d.actionEvents)")
        XCTAssertEqual(
            d.session.probabilityIcelandic, control.session.probabilityIcelandic, accuracy: 1e-9,
            "a paragraph break is not a sentence end for the lane, under either cut")

        // Autocorrect flavour: Return applies "hestr" → "hestur" and the
        // correction is confirmed and revertable.
        let a = driver()
        a.perform([.type("hestr"), .type("\n")])
        XCTAssertEqual(a.document, "hestur\n", "Return applied the armed autocorrect")
        XCTAssertEqual(a.session.lastCommittedWord, "hestur")
        XCTAssertTrue(
            a.actionEvents.contains {
                if case .suggestionAccepted(let typed, let accepted) = $0 {
                    return typed == "hestr" && accepted == "hestur"
                }
                return false
            }, "events: \(a.actionEvents)")
    }
}
