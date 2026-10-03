import Learning
import XCTest

@testable import TypeEngine

/// `ProxySimulator` quirks added by the 2026-10 seam audit (all opt-in), and
/// the engine driven under each of them. Every test here PASSES: these pin
/// the simulator semantics and the engine behaviour that is already correct
/// under the quirk. Engine degradations found under the same quirks live in
/// `ProxyFidelityFoundBugTests` as strict expected failures.
final class ProxyFidelityTests: XCTestCase {

    private func driver(_ proxy: ProxySimulator) -> SeamDriver {
        SeamDriver(Fixtures.engine(), proxy: proxy)
    }

    // MARK: - Simulator: lagging boundary cut

    func testDefaultTruncationStillCollapsesAtTheBoundary() {
        let proxy = ProxySimulator(document: "Fyrsta setning. ")
        XCTAssertEqual(proxy.contextBeforeInput, "")
    }

    func testHeldBoundaryKeepsPreviousSentenceUntilTextFollows() {
        let proxy = ProxySimulator(
            document: "Fyrsta setning. ",
            truncation: .init(holdsBoundaryUntilTextFollows: true))
        XCTAssertEqual(proxy.contextBeforeInput, "Fyrsta setning. ")
        proxy.insertText("ö")
        XCTAssertEqual(proxy.contextBeforeInput, "ö")
        proxy.deleteBackward()
        XCTAssertEqual(proxy.contextBeforeInput, "Fyrsta setning. ", "backspacing to the boundary re-exposes the previous sentence")
    }

    func testHeldBoundaryAppliesToNewlines() {
        let proxy = ProxySimulator(
            document: "lína eitt\n",
            truncation: .init(holdsBoundaryUntilTextFollows: true))
        XCTAssertEqual(proxy.contextBeforeInput, "lína eitt\n")
        proxy.insertText("x")
        XCTAssertEqual(proxy.contextBeforeInput, "x")
    }

    func testHeldBoundaryUsesTheEarlierBoundaryWhenTwoExist() {
        let proxy = ProxySimulator(
            document: "Ein. Tvö. ",
            truncation: .init(holdsBoundaryUntilTextFollows: true))
        XCTAssertEqual(proxy.contextBeforeInput, "Tvö. ")
    }

    // MARK: - Simulator: UTF-16 cap (mid-grapheme window start)

    func testUTF16CapCanStartInsideAGraphemeCluster() {
        // "abe\u{301}cd": 5 Characters, 6 UTF-16 units. Cap 3 → "\u{301}cd".
        let proxy = ProxySimulator(
            document: "abe\u{301}cd",
            truncation: .init(maxBeforeLength: 3, cutAtSentenceBoundary: false, capUnit: .utf16))
        let window = proxy.contextBeforeInput
        XCTAssertEqual(Array(window.unicodeScalars), ["\u{301}", "c", "d"])
        XCTAssertEqual(window.utf16.count, 3)
        XCTAssertEqual(window.count, 3, "the orphaned combining mark is its own Character")
    }

    func testUTF16CapDropsAnOrphanedLowSurrogate() {
        // "a😀b": 3 Characters, 4 UTF-16 units. Cap 2 lands inside the pair.
        let proxy = ProxySimulator(
            document: "a😀b",
            truncation: .init(maxBeforeLength: 2, cutAtSentenceBoundary: false, capUnit: .utf16))
        XCTAssertEqual(proxy.contextBeforeInput, "b")
    }

    func testCharacterCapIsUnchangedByDefault() {
        let proxy = ProxySimulator(
            document: "a😀b", truncation: .init(maxBeforeLength: 2, cutAtSentenceBoundary: false))
        XCTAssertEqual(proxy.contextBeforeInput, "😀b")
    }

    // MARK: - Simulator: deletion granularity

    func testScalarDeletionRemovesACombiningMarkFirst() {
        let proxy = ProxySimulator(document: "he\u{301}")
        proxy.deletionGranularity = .unicodeScalar
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "he")
        XCTAssertEqual(proxy.cursor, 2)
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "h")
    }

    func testScalarDeletionPeelsAZWJSequence() {
        let family = "👨\u{200D}👩\u{200D}👧"
        let proxy = ProxySimulator(document: family)
        proxy.deletionGranularity = .unicodeScalar
        let scalarsBefore = proxy.document.unicodeScalars.count
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document.unicodeScalars.count, scalarsBefore - 1)
        XCTAssertEqual(proxy.cursor, proxy.document.count, "cursor is recounted after the grapheme change")
    }

    func testGraphemeDeletionRemovesAWholeZWJSequenceByDefault() {
        let proxy = ProxySimulator(document: "a👨\u{200D}👩\u{200D}👧")
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "a")
    }

    // MARK: - Simulator: selection

    func testSelectionSplitsTheWindowsAroundTheRange() {
        let proxy = ProxySimulator(document: "ok hestur")
        proxy.select(7..<8)
        XCTAssertEqual(proxy.contextBeforeInput, "ok hest")
        XCTAssertEqual(proxy.contextAfterInput, "r")
        XCTAssertEqual(proxy.selectedText, "u")
        XCTAssertEqual(proxy.cursor, 7)
    }

    func testInsertReplacesTheSelection() {
        let proxy = ProxySimulator(document: "ok hestur")
        proxy.select(3..<9)
        proxy.insertText("hús")
        XCTAssertEqual(proxy.document, "ok hús")
        XCTAssertNil(proxy.selectedText)
        XCTAssertEqual(proxy.cursor, 6)
    }

    func testOneDeleteBackwardRemovesOnlyTheSelection() {
        let proxy = ProxySimulator(document: "ok hestur")
        proxy.select(7..<8)
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "ok hestr")
        XCTAssertNil(proxy.selectedText)
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "ok hesr", "the next delete is an ordinary backspace at the caret")
    }

    func testCursorMoveAndHostReplaceClearTheSelection() {
        let proxy = ProxySimulator(document: "ok hestur")
        proxy.select(0..<2)
        proxy.moveCursor(to: 9)
        XCTAssertNil(proxy.selectedText)
        proxy.select(0..<2)
        proxy.hostReplaceText("new")
        XCTAssertNil(proxy.selectedText)
        XCTAssertEqual(proxy.contextBeforeInput, "new")
    }

    // MARK: - Simulator: adjustTextPosition

    func testAdjustTextPositionMovesByCharactersAndClamps() {
        let proxy = ProxySimulator(document: "hestur")
        proxy.adjustTextPosition(byCharacterOffset: -2)
        XCTAssertEqual(proxy.contextBeforeInput, "hest")
        proxy.adjustTextPosition(byCharacterOffset: 99)
        XCTAssertEqual(proxy.contextBeforeInput, "hestur")
    }

    func testAdjustTextPositionInUTF16UnitsRoundsOutOfASurrogatePair() {
        let proxy = ProxySimulator(document: "a😀b")
        proxy.cursorAdjustmentUnit = .utf16
        proxy.adjustTextPosition(byCharacterOffset: -1)  // "b"
        XCTAssertEqual(proxy.contextBeforeInput, "a😀")
        proxy.adjustTextPosition(byCharacterOffset: -1)  // lands inside 😀 → rounds back to before it
        XCTAssertEqual(proxy.contextBeforeInput, "a")
    }

    func testAsyncAdjustTextPositionIsVisibleOneReadLate() {
        let proxy = ProxySimulator(document: "hestur")
        proxy.asyncCursorAdjustments = true
        proxy.adjustTextPosition(byCharacterOffset: -2)
        XCTAssertEqual(proxy.contextBeforeInput, "hestur", "first observation still shows the old caret")
        XCTAssertEqual(proxy.contextBeforeInput, "hest", "then the move lands")
    }

    func testEditAfterAsyncAdjustLandsAtTheNewCaret() {
        let proxy = ProxySimulator(document: "hestur")
        proxy.asyncCursorAdjustments = true
        proxy.adjustTextPosition(byCharacterOffset: -2)
        proxy.insertText("X")
        XCTAssertEqual(proxy.document, "hestXur")
        XCTAssertEqual(proxy.trueContextBeforeInput, "hestX")
    }

    // MARK: - Simulator: stale-read depth

    func testStaleReadDepthOneKeepsHistoricalSemantics() {
        let proxy = ProxySimulator(document: "a")
        proxy.staleReads = true
        proxy.insertText("b")
        proxy.insertText("c")
        XCTAssertEqual(proxy.contextBeforeInput, "ab", "only the most recent pre-edit state is served")
        XCTAssertEqual(proxy.contextBeforeInput, "abc")
    }

    func testStaleReadDepthTwoLagsTwoActionsBehind() {
        // Actions are delimited by the keyboard's own read-backs
        // (`trueContextBeforeInput`), exactly as every embedder brackets its
        // edits for the ledger. Two actions without an observation read in
        // between are echoed one at a time, never mid-action.
        let proxy = ProxySimulator(document: "a")
        proxy.staleReads = true
        proxy.staleReadDepth = 2
        _ = proxy.trueContextBeforeInput
        proxy.insertText("b")  // action 1
        _ = proxy.trueContextBeforeInput
        proxy.insertText("c")  // action 2: two edits, one snapshot
        proxy.insertText("d")
        _ = proxy.trueContextBeforeInput
        XCTAssertEqual(proxy.contextBeforeInput, "a")
        XCTAssertEqual(proxy.contextBeforeInput, "ab")
        XCTAssertEqual(proxy.contextBeforeInput, "abcd")
    }

    func testStaleReadDepthDropsTheOldestActionBeyondTheDepth() {
        let proxy = ProxySimulator(document: "a")
        proxy.staleReads = true
        proxy.staleReadDepth = 2
        for ch in ["b", "c", "d"] {
            _ = proxy.trueContextBeforeInput
            proxy.insertText(ch)
        }
        _ = proxy.trueContextBeforeInput
        XCTAssertEqual(proxy.contextBeforeInput, "ab")
        XCTAssertEqual(proxy.contextBeforeInput, "abc")
        XCTAssertEqual(proxy.contextBeforeInput, "abcd")
    }

    // MARK: - Engine under the quirks

    func testEngineCommitsAcrossAUTF16CapThatSplitsAGrapheme() {
        // A tiny UTF-16 cap slides the window one unit per keystroke across
        // the decomposed "e\u{301}": the window starts with a bare combining
        // mark for one pass, then without it. Plain-typed commits survive the
        // slide (an autocorrect APPLY at a capped window does not — see
        // `ApplySeamFoundBugTests.testAutocorrectApplyAtACappedSlidingWindowIsNotConfirmed`).
        let d = driver(
            ProxySimulator(
                truncation: .init(maxBeforeLength: 9, cutAtSentenceBoundary: false, capUnit: .utf16)))
        d.type("cafe\u{301} ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        d.type("ok hestur ")
        XCTAssertEqual(d.document, "cafe\u{301} ok hestur ")
        XCTAssertEqual(d.session.committedWordCount, 3)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    func testEngineSurvivesScalarDeletionOfACombiningMark() {
        let proxy = ProxySimulator(truncation: .none)
        proxy.deletionGranularity = .unicodeScalar
        let d = driver(proxy)
        d.type("he")
        d.type("\u{301}")  // host composes "hé" (one Character)
        XCTAssertEqual(d.proxy.contextBeforeInput.count, 2)
        d.backspace()  // peels the combining mark: "he"
        XCTAssertEqual(d.document, "he")
        d.type("stur ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    func testTypingOverASelectionIsAPlainEvolution() {
        let d = driver(ProxySimulator(truncation: .none))
        d.type("ok hestr")
        d.proxy.select(7..<8)  // "ok hest|r|"
        d.session.noteExternalTextChange(window: d.proxy.contextBeforeInput)
        d.refreshOnly()
        d.type("u")  // replaces the selection
        XCTAssertEqual(d.document, "ok hestu")
        XCTAssertEqual(d.session.committedWordCount, 1, "only \"ok\" so far")
        d.type("r ")
        XCTAssertEqual(d.document, "ok hestur ")
        XCTAssertEqual(d.session.committedWordCount, 2)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    func testSpacebarDragIntoTheWordNeverCommits() {
        // Spacebar cursor drag = adjustTextPosition, asynchronous: the
        // extension forwards selectionDidChange (window note) and KeyboardKit
        // re-runs autocomplete; the first read still shows the old caret.
        let proxy = ProxySimulator(truncation: .none)
        proxy.asyncCursorAdjustments = true
        let d = driver(proxy)
        d.type("ok hestur")
        proxy.adjustTextPosition(byCharacterOffset: -2)
        d.session.noteExternalTextChange(window: proxy.contextBeforeInput)  // stale: "ok hestur"
        d.refreshOnly()  // "ok hest": external, nothing commits
        XCTAssertEqual(d.session.committedWordCount, 1, "only \"ok\"; the drag commits nothing")
        d.type("X ")
        XCTAssertEqual(d.document, "ok hestX ur")
        XCTAssertEqual(d.session.committedWordCount, 2)
        XCTAssertEqual(d.session.lastCommittedWord, "hestX")
    }

    func testReturnCommitIsVisibleUnderTheLaggingNewlineCut() {
        let d = driver(ProxySimulator(truncation: .init(holdsBoundaryUntilTextFollows: true)))
        d.type("hestr")
        d.pressReturn()
        XCTAssertEqual(d.document, "hestur\n")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    func testDeepStaleReadsConfirmLateWithoutDoubleCommits() {
        // Reads lag two edits behind; KeyboardKit's textDidChange catch-up
        // passes (`refreshOnly`) let the bar and the ledger catch up before
        // the delimiter, so the apply still lands exactly once.
        let proxy = ProxySimulator(truncation: .none)
        proxy.staleReads = true
        proxy.staleReadDepth = 2
        let d = driver(proxy)
        d.type("hestr")
        d.refreshOnly()
        d.refreshOnly()
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        d.type(" ")
        d.refreshOnly()
        d.refreshOnly()
        XCTAssertEqual(d.document, "hestur ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }
}
