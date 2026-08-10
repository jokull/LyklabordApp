import Learning
import XCTest

@testable import TypeEngine

/// Backspace-revert: the reserved literal slot (wave 36). The iOS convention
/// that, right after an autocorrect force-corrects a word, the first backspace
/// reveals the corrected word and the bar's reserved left slot offers the
/// byte-exact literal the user typed — one tap swaps it back.
///
/// These tests drive the session through a `ProxySimulator` with the exact
/// proxy-edit + ledger discipline the extension's action handler and the
/// `type-repl` Typist use (autocorrect-apply on delimiter, `noteSelfEdit`
/// around every action, the revert-tap routing), so the memo state machine is
/// exercised end-to-end, not in isolation.
final class BackspaceRevertTests: XCTestCase {

    /// Faithful mini-driver: proxy + session + ledger, mirroring `Typist`.
    private final class Driver {
        let session: TypingSession
        let proxy = ProxySimulator()
        private(set) var bar: [Suggestion] = []
        private(set) var events: [LearningEvent] = []

        init(_ engine: TypeEngine) { session = TypingSession(engine: engine) }

        func type(_ text: String) { for c in text { typeChar(c) } }

        private func typeChar(_ c: Character) {
            let before = proxy.trueContextBeforeInput
            let applies = TypingSession.isDelimiter(c) && c != "."
            if applies, let ac = bar.first(where: { $0.isAutocorrect }) {
                let word = TypingSession.splitCurrentWord(
                    of: proxy.trueContextBeforeInput
                ).currentWord
                if !word.isEmpty, ac.text != word {
                    for _ in 0..<word.count { proxy.deleteBackward() }
                    proxy.insertText(ac.text)
                }
            }
            proxy.insertText(String(c))
            session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
            refresh()
        }

        func backspace(_ n: Int = 1) {
            for _ in 0..<n {
                let before = proxy.trueContextBeforeInput
                proxy.deleteBackward()
                session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
                refresh()
            }
        }

        /// Tap the bar entry with this text (KeyboardKit replace-token+space
        /// semantics); a `.unknown` tap routes through the revert path first,
        /// exactly like the extension's action handler and the Typist.
        @discardableResult
        func tap(_ text: String) -> Bool {
            guard let s = bar.first(where: { $0.text == text }) else { return false }
            let literalRevertAdditionalDeleteCount =
                s.isVerbatim
                ? session.literalRevertAdditionalDeleteCount(matching: s.text)
                : 0
            if s.isVerbatim {
                if !session.revertToLiteral(matching: s.text) {
                    session.noteVerbatimChoice(s.text)
                }
            }
            let before = proxy.trueContextBeforeInput
            let word = TypingSession.splitCurrentWord(of: before).currentWord
            for _ in 0..<(word.count + literalRevertAdditionalDeleteCount) {
                proxy.deleteBackward()
            }
            proxy.insertText(s.text)
            let (b, a) = proxy.contextWindows()
            if !b.hasSuffix(" "), !a.hasPrefix(" ") { proxy.insertText(" ") }
            session.noteSelfEdit(before: before, after: proxy.trueContextBeforeInput)
            refresh()
            return true
        }

        func cursorToStartAndBack() {
            proxy.moveCursor(to: 0)
            session.noteExternalTextChange()
            refresh()
            proxy.moveCursor(to: proxy.document.count)
            session.noteExternalTextChange()
            refresh()
        }

        func refreshWithoutEdit() {
            refresh()
        }

        func armExternalAutocorrect(_ text: String) {
            session.noteExternallyArmedAutocorrect(text)
            bar = [Suggestion(text: text, isAutocorrect: true, confidence: 1)]
        }

        private func refresh() {
            bar = session.suggestions(for: proxy.contextBeforeInput, limit: 5)
            if session.hasPendingLearningEvents {
                events += session.drainLearningEvents()
            }
        }

        var document: String { proxy.document }
        var leading: Suggestion? { bar.first }
        var containsText: (String) -> Bool { { text in self.bar.contains { $0.text == text } } }
    }

    private func driver() -> Driver { Driver(Fixtures.engine()) }

    // MARK: - Arming + slot display

    func testAutocorrectCommitThenBackspaceRevealsLiteralSlot() {
        let d = driver()
        d.type("hestr ")
        XCTAssertEqual(d.document, "hestur ")  // force-corrected on the space
        XCTAssertFalse(d.session.hasArmedLiteralRevert)  // slot NOT shown yet

        d.backspace()  // deletes the trailing space, revealing "hestur"
        XCTAssertEqual(d.proxy.contextBeforeInput, "hestur")
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        // The reserved left slot is the byte-exact literal, verbatim class.
        XCTAssertEqual(d.leading?.text, "hestr")
        XCTAssertTrue(d.leading?.isVerbatim == true)
        XCTAssertFalse(d.leading?.isAutocorrect == true)
    }

    func testDuplicateRefreshBeforeAndAfterBackspacePreservesLiteralSlot() {
        let d = driver()
        d.type("hestr ")

        // KeyboardKit may ask for the same window more than once. A no-op
        // request is not a user action and must not spend the revert memo.
        d.refreshWithoutEdit()
        d.backspace()
        XCTAssertEqual(d.leading?.text, "hestr")

        // The quoted slot must also remain stable while it is on screen.
        d.refreshWithoutEdit()
        XCTAssertEqual(d.leading?.text, "hestr")
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
    }

    func testRepeatedSpaceBackspaceKeepsOriginalLiteral() {
        let d = driver()
        d.type("hestr ")
        d.backspace()
        XCTAssertEqual(d.leading?.text, "hestr")

        d.type(" ")
        d.backspace()
        XCTAssertEqual(d.document, "hestur")
        XCTAssertEqual(d.leading?.text, "hestr")
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
    }

    func testManualCorrectionAfterBackspaceDoesNotRearmRejectedCorrection() {
        let d = driver()
        d.type("hestr ")
        d.backspace()    // hestur
        d.backspace(2)  // hest
        d.type("r")     // hestr, recreated manually

        XCTAssertEqual(d.document, "hestr")
        XCTAssertFalse(d.bar.contains(where: \.isAutocorrect))
        d.type(" ")
        XCTAssertEqual(d.document, "hestr ")
    }

    func testExternalArmedProviderGetsSameLiteralRevertContract() {
        let d = driver()
        d.type("omw")
        d.armExternalAutocorrect("on my way")
        d.type(" ")
        XCTAssertEqual(d.document, "on my way ")

        d.backspace()
        XCTAssertEqual(d.leading?.text, "omw")
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        XCTAssertEqual(
            d.session.literalRevertAdditionalDeleteCount(matching: "omw"),
            "on my ".count
        )
    }

    func testTappingReservedSlotRestoresTheByteExactLiteral() {
        let d = driver()
        d.type("hestr ")
        d.backspace()
        XCTAssertTrue(d.tap("hestr"))
        XCTAssertEqual(d.document, "hestr ")
        XCTAssertEqual(d.session.lastCommittedWord, "hestr")
        // The revert consumed the memo — no stale slot afterwards.
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
    }

    func testRevertPreservesCasingAndDiacritics() {
        // The literal is taken from the session's record of the typed token,
        // never re-derived from the correction: casing survives byte-for-byte.
        let d = driver()
        d.type("Godan ")
        XCTAssertEqual(d.document, "Góðan ")
        d.backspace()
        XCTAssertEqual(d.leading?.text, "Godan")
        d.tap("Godan")
        XCTAssertEqual(d.document, "Godan ")
    }

    func testSplitAutocorrectCommitThenBackspaceRevealsLiteralSlot() {
        let d = driver()
        d.type("gottnveður ")
        XCTAssertEqual(d.document, "gott veður ")
        XCTAssertFalse(d.session.hasArmedLiteralRevert)

        d.backspace()
        XCTAssertEqual(d.document, "gott veður")
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        XCTAssertEqual(d.leading?.text, "gottnveður")
        XCTAssertEqual(
            d.session.literalRevertAdditionalDeleteCount(matching: "gottnveður"),
            "gott ".count
        )
    }

    func testTappingSplitLiteralRestoresWholeUnsplitToken() {
        let d = driver()
        d.type("gottnveður ")
        d.backspace()

        XCTAssertTrue(d.tap("gottnveður"))
        XCTAssertEqual(d.document, "gottnveður ")
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
    }

    func testSecondBackspaceDropsSplitLiteralSlot() {
        let d = driver()
        d.type("gottnveður ")
        d.backspace()
        XCTAssertTrue(d.session.hasArmedLiteralRevert)

        d.backspace()
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
        XCTAssertFalse(d.containsText("gottnveður"))
    }

    // MARK: - Negatives (never a stale literal slot)

    func testBackspaceAfterAValidWordOffersNoRevert() {
        let d = driver()
        d.type("hestur ")  // valid word: no autocorrect, no memo
        d.backspace()
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
        // Ordinary verbatim escape hatch (the word itself), not a phantom
        // revert of a correction that never happened.
        XCTAssertEqual(d.leading?.text, "hestur")
    }

    func testTypingAfterBackspaceDropsTheSlot() {
        let d = driver()
        d.type("hestr ")
        d.backspace()
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        d.type("a")  // continues into the corrected word
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
        XCTAssertFalse(d.containsText("hestr"))
    }

    func testSecondBackspaceDropsTheSlot() {
        let d = driver()
        d.type("hestr ")
        d.backspace()
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        d.backspace()  // deletes INTO the corrected word
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
        XCTAssertFalse(d.containsText("hestr"))
    }

    func testCursorMoveClearsTheMemo() {
        let d = driver()
        d.type("hestr ")
        d.backspace()
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        d.cursorToStartAndBack()
        XCTAssertFalse(d.session.hasArmedLiteralRevert)
        XCTAssertFalse(d.containsText("hestr"))
    }

    func testNewWordReplacesMemoWithMostRecentAutocorrect() {
        // A second committed word overwrites the first word's memo: the
        // correction boundary now belongs to the most recent commit.
        let d = driver()
        d.type("hestr ")
        d.type("hus ")
        XCTAssertEqual(d.document, "hestur hús ")
        d.backspace()
        XCTAssertTrue(d.session.hasArmedLiteralRevert)
        XCTAssertEqual(d.leading?.text, "hus")  // the SECOND word's literal
        XCTAssertFalse(d.containsText("hestr"))
    }

    // MARK: - Ledger attribution / learning

    func testRevertEmitsCorrectionRevertedNotAWordCommit() {
        let d = driver()
        d.type("hestr ")
        // The commit itself is a suggestionAccepted (typo → correction).
        XCTAssertEqual(d.events.count, 1)
        guard case .suggestionAccepted(let typed, let accepted) = d.events[0] else {
            return XCTFail("expected suggestionAccepted, got \(d.events)")
        }
        XCTAssertEqual(typed, "hestr")
        XCTAssertEqual(accepted, "hestur")

        d.backspace()
        d.tap("hestr")
        // The revert is the SAME rejection signal as revert-on-continuation:
        // a correctionReverted event, NOT a wordCommitted/wordTapped (the
        // restored literal is not force-learned as a real word).
        let after = Array(d.events.dropFirst())
        XCTAssertEqual(after.count, 1, "unexpected extra events: \(after)")
        guard case .correctionReverted(let original, let applied) = after.first else {
            return XCTFail("expected correctionReverted, got \(after)")
        }
        XCTAssertEqual(original, "hestr")
        XCTAssertEqual(applied, "hestur")
    }

    func testRevertSuppressesImmediateReCorrection() {
        // After reverting, the restored literal must not be re-corrected by an
        // immediate delimiter (verbatim-choice suppression) — the revert never
        // arms a fresh autocorrect.
        let d = driver()
        d.type("hestr ")
        d.backspace()
        d.tap("hestr")
        XCTAssertEqual(d.document, "hestr ")
        XCTAssertFalse(d.bar.contains { $0.isAutocorrect })
    }

    // MARK: - revertToLiteral guardrails

    func testRevertToLiteralIsANoOpWhenNotArmed() {
        let d = driver()
        d.type("hestr ")  // memo armed but slot not showing (no backspace yet)
        XCTAssertFalse(d.session.revertToLiteral(matching: "hestr"))
        d.backspace()
        // Armed slot, but a non-matching text is refused.
        XCTAssertFalse(d.session.revertToLiteral(matching: "nope"))
        XCTAssertTrue(d.session.hasArmedLiteralRevert)  // still armed
        XCTAssertTrue(d.session.revertToLiteral(matching: "hestr"))
    }
}
