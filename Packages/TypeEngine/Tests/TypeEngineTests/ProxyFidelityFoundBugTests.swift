import Learning
import XCTest

@testable import TypeEngine

/// Regressions for engine bugs exposed by `UITextDocumentProxy` quirks the
/// simulator did not model before the 2026-10 seam audit (`ProxySimulator`:
/// lagging boundary cut, selection). Each was a strict `XCTExpectFailure`
/// repro; the fixes turned them into ordinary tests.
final class ProxyFidelityFoundBugTests: XCTestCase {

    private func driver(_ proxy: ProxySimulator) -> SeamDriver {
        SeamDriver(Fixtures.engine(), proxy: proxy)
    }

    private func touchSamples(_ events: [LearningEvent]) -> Int {
        events.filter {
            if case .touchSample = $0 { return true }
            return false
        }.count
    }

    // MARK: - Lagging boundary cut (the shape KeyboardKit's own reads assume)

    /// KeyboardKit's `isCursorAtNewSentence` auto-capitalisation reads a
    /// trailing ". " from `documentContextBeforeInput` right after the space
    /// is typed, so on such hosts the window after "hestur. " is still
    /// "hestur. " and only the NEXT keystroke yields the cut window "o".
    /// `heuristicChange` had no shape for "hestur. " → "o" and classified
    /// the ledger-matched self-edit `.external`, clearing `incomingTaps` —
    /// the first letter's tap sample was lost (1 touchSample at the commit
    /// instead of 2) along with carried context and memos. The new-sentence
    /// shape keeps everything, exactly like the immediate collapse does.
    func testLaggingSentenceCutKeepsTheFirstTapOfTheNewSentence() {
        let immediate = driver(ProxySimulator())
        immediate.type("hestur. ")
        _ = immediate.drainEvents()
        immediate.tapType("o", dx: 0.1, dy: 0.1)
        immediate.tapType("g", dx: 0.2, dy: 0.2)
        immediate.type(" ")
        XCTAssertEqual(touchSamples(immediate.drainEvents()), 2, "control: immediate collapse keeps both taps")

        let lagging = driver(
            ProxySimulator(truncation: .init(holdsBoundaryUntilTextFollows: true)))
        lagging.type("hestur. ")
        XCTAssertEqual(lagging.proxy.contextBeforeInput, "hestur. ")
        _ = lagging.drainEvents()
        lagging.tapType("o", dx: 0.1, dy: 0.1)
        XCTAssertEqual(lagging.proxy.contextBeforeInput, "o")
        lagging.tapType("g", dx: 0.2, dy: 0.2)
        lagging.type(" ")
        XCTAssertEqual(lagging.document, "hestur. og ")
        XCTAssertEqual(lagging.session.committedWordCount, 2)
        XCTAssertEqual(touchSamples(lagging.drainEvents()), 2)
        // Both shapes end in the same lane state.
        XCTAssertEqual(
            lagging.session.probabilityIcelandic, immediate.session.probabilityIcelandic,
            accuracy: 1e-9)
    }

    /// Same shape for paragraphs (`isCursorAtNewLine` reads a trailing "\n"):
    /// "hestr⏎" commits "hestur" under the lagging cut (the window shows
    /// "hestur\n"), then the window goes "hestur\n" → "o" and the first tap
    /// of the new paragraph is kept.
    func testLaggingNewlineCutKeepsTheFirstTapOfTheNewParagraph() {
        let lagging = driver(
            ProxySimulator(truncation: .init(holdsBoundaryUntilTextFollows: true)))
        lagging.type("hestr")
        lagging.pressReturn()
        XCTAssertEqual(lagging.document, "hestur\n")
        XCTAssertEqual(lagging.session.committedWordCount, 1, "the lagging cut keeps the return commit visible")
        _ = lagging.drainEvents()
        lagging.tapType("o", dx: 0.1, dy: 0.1)
        lagging.tapType("g", dx: 0.2, dy: 0.2)
        lagging.type(" ")
        XCTAssertEqual(lagging.session.committedWordCount, 2)
        XCTAssertEqual(touchSamples(lagging.drainEvents()), 2)
    }

    /// A host paste that lands right after a sentence boundary is NOT the
    /// new-sentence shape: it is unexplained by the ledger and stays
    /// external (no commit, taps cleared).
    func testHostPasteAfterSentenceBoundaryStaysExternal() {
        let lagging = driver(
            ProxySimulator(truncation: .init(holdsBoundaryUntilTextFollows: true)))
        lagging.type("hestur. ")
        let commits = lagging.session.committedWordCount
        lagging.hostReplace("hestur. og hestar ")
        XCTAssertEqual(lagging.session.committedWordCount, commits)
    }

    // MARK: - Selection

    /// "ok hest|r|": the user selected the trailing "r" to retype it. The
    /// before-window ends at the selection start ("ok hest") and the engine
    /// arms "hestur". The extension refuses to apply an autocorrect while a
    /// selection is active (`shouldApplyAutocorrectSuggestion` rule 2 —
    /// KeyboardKit's per-character deletes would eat the selection as one of
    /// them: "ok hhestur "); `SeamDriver` mirrors that guard. The space then
    /// replaces the selection and commits the typed word as it stands. The
    /// correct "ok hestur " outcome belongs to the KeyboardKit-side repro
    /// (`KeyboardKitTests/Proxy/ApplySeamFoundBugTests`, out of scope here).
    func testAutocorrectApplyIsRefusedAcrossASelection() {
        let d = driver(ProxySimulator(truncation: .none))
        d.type("ok hestr")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        d.proxy.select(7..<8)
        XCTAssertEqual(d.proxy.contextBeforeInput, "ok hest")
        XCTAssertEqual(d.proxy.selectedText, "r")
        d.session.noteExternalTextChange(window: d.proxy.contextBeforeInput)
        d.refreshOnly()
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        _ = d.drainEvents()
        d.type(" ")
        XCTAssertEqual(d.document, "ok hest ")
        XCTAssertEqual(d.session.lastCommittedWord, "hest")
        XCTAssertFalse(
            d.drainEvents().contains { if case .suggestionAccepted = $0 { return true }; return false })
    }

    /// Robustness when the apply happens anyway (an embedder without the
    /// guard): the record says "hestur" replaced the token, the window shows
    /// "hhestur" — text the session cannot account for. It is classified
    /// external: no commit, no learning event, nothing learned from garbage.
    func testUnguardedApplyAcrossASelectionIsNotCommittedOrLearned() {
        let d = driver(ProxySimulator(truncation: .none))
        d.guardsSelection = false
        d.type("ok hestr")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        d.proxy.select(7..<8)
        d.session.noteExternalTextChange(window: d.proxy.contextBeforeInput)
        d.refreshOnly()
        _ = d.drainEvents()
        let commits = d.session.committedWordCount
        d.type(" ")
        XCTAssertEqual(d.document, "ok hhestur ", "the raw KeyboardKit over-delete")
        XCTAssertEqual(d.session.committedWordCount, commits)
        XCTAssertNotEqual(d.session.lastCommittedWord, "hhestur")
        XCTAssertTrue(d.drainEvents().isEmpty, "nothing is learned from a mangled apply")
    }
}
