import Learning
import XCTest

@testable import TypeEngine

/// Engine bugs exposed by `UITextDocumentProxy` quirks the simulator did not
/// model before the 2026-10 seam audit (`ProxySimulator`: lagging boundary
/// cut, selection). Each repro is wrapped in a STRICT `XCTExpectFailure` so
/// the suite is green today and flips red once fixed.
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
    /// `heuristicChange` has no shape for "hestur. " → "o" (the sliding
    /// alignment needs a suffix of the old window to prefix the new one), so
    /// the ledger-matched self-edit is classified `.external`:
    /// `incomingTaps` is cleared and the first letter's tap sample is lost
    /// (1 touchSample at the commit instead of 2); carried bigram context and
    /// the verbatim/backspace-revert memos go with it. Under the historical
    /// immediate collapse ("hestur. " → "") the `.truncationReset` path keeps
    /// everything.
    func testLaggingSentenceCutDropsTheFirstTapOfTheNewSentence() {
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
        XCTExpectFailure(
            "a one-keystroke-late sentence cut (\"hestur. \" → \"o\") is classified external: the new sentence's first tap sample (and carried context/memos) is dropped",
            strict: true
        ) {
            XCTAssertEqual(touchSamples(lagging.drainEvents()), 2)
        }
    }

    /// Same shape for paragraphs (`isCursorAtNewLine` reads a trailing "\n"):
    /// "hestr⏎" commits "hestur" fine under the lagging cut (contrast with the
    /// immediate-cut loss in `ApplySeamFoundBugTests`), but the window then
    /// goes "hestur\n" → "o" and the first tap of the new paragraph is lost.
    func testLaggingNewlineCutDropsTheFirstTapOfTheNewParagraph() {
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
        XCTExpectFailure(
            "a one-keystroke-late newline cut (\"hestur\\n\" → \"o\") is classified external: the new paragraph's first tap sample is dropped",
            strict: true
        ) {
            XCTAssertEqual(touchSamples(lagging.drainEvents()), 2)
        }
    }

    // MARK: - Selection

    /// "ok hest|r|": the user selected the trailing "r" to retype it. The
    /// before-window ends at the selection start ("ok hest"), the engine arms
    /// "hestur", and the space applies it the KeyboardKit way — delete
    /// `currentWord.count` (4) times, then insert. UIKit's first
    /// `deleteBackward` removes the SELECTION, so the remaining three eat
    /// "est" and the document ends up "ok hhestur ". The session then commits
    /// (and logs a suggestionAccepted for) the garbage word "hhestur". The
    /// embedder side of this is KeyboardKit's `replaceCurrentWordPreCursorPart`
    /// (see `KeyboardKitTests/Proxy/ApplySeamFoundBugTests`); the session has
    /// no way to see the selection and faithfully learns the damage.
    func testAutocorrectApplyAcrossASelectionOverDeletesAndLearnsGarbage() {
        let d = driver(ProxySimulator(truncation: .none))
        d.type("ok hestr")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        d.proxy.select(7..<8)
        XCTAssertEqual(d.proxy.contextBeforeInput, "ok hest")
        XCTAssertEqual(d.proxy.selectedText, "r")
        d.session.noteExternalTextChange(window: d.proxy.contextBeforeInput)
        d.refreshOnly()
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        d.type(" ")
        XCTExpectFailure(
            "autocorrect apply with an active selection over-deletes (KeyboardKit deletes word.count times; UIKit's first deleteBackward removes the selection) and the session commits/learns the mangled word",
            strict: true
        ) {
            XCTAssertEqual(d.document, "ok hestur ")
            XCTAssertEqual(d.session.lastCommittedWord, "hestur")
        }
    }
}
