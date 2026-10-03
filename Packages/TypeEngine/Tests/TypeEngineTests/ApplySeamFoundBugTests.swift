import Learning
import XCTest

@testable import TypeEngine

/// Bugs found at the KeyboardExt/KeyboardKit ↔ TypeEngine apply seam
/// (2026-10 seam audit). Each is a minimal deterministic repro wrapped in a
/// STRICT `XCTExpectFailure`, so the suite is green today and flips red —
/// remove the wrapper — once the bug is fixed.
///
/// Common root: `TypingSession.heuristicChange` (TypingSession.swift ~1128)
/// only knows append / replace-current-word / shrink / sliding-window /
/// collapse-to-empty shapes. Several proxy edits the extension and the
/// vendored KeyboardKit perform on device rewrite the TRAILING DELIMITER
/// ("word␣" → "word.", "word␣" → "word.␣", "word␣" → "word.␣" via the
/// double-space ender) and none of those shapes exist, so a self-edit the
/// ledger has already PROVEN ours is still classified `.external`
/// (`classifyChange`, `.matched` + unexplained shape → external). The harness
/// `Typist` performs none of these edits, which is why no scenario catches
/// them. See `SeamDriver` for the exact device edit sequences.
final class ApplySeamFoundBugTests: XCTestCase {

    private func driver(truncation: ProxySimulator.TruncationPolicy = .init()) -> SeamDriver {
        SeamDriver(Fixtures.engine(), proxy: ProxySimulator(truncation: truncation))
    }

    private func isWordCommitted(_ event: LearningEvent) -> Bool {
        if case .wordCommitted = event { return true }
        return false
    }

    // MARK: - Space-commit dot attachment (KeyboardViewController.swift `spaceCommitMemo`)

    /// "hestr" + space → autocorrect commits "hestur␣" (1 commit, a
    /// suggestionAccepted event). The extension's issue-#4 memo then turns the
    /// "." keystroke into "delete the committed space, insert '.'" →
    /// "hestur.". The session cannot explain "hestur␣" → "hestur." →
    /// `.external` → `previousCurrentWord` becomes the deferred-dot token
    /// "hestur.", and the NEXT space commits "hestur" a second time (a second
    /// `wordCommitted("hestur", previousWord: "hestur")` — a bogus
    /// self-bigram as well). Expected: still 1 commit, no new commit event.
    func testDotAttachmentAfterSpaceCommitDoubleCommitsTheWord() {
        let d = driver(truncation: .none)
        d.type("hestr ")
        XCTAssertEqual(d.document, "hestur ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        _ = d.drainEvents()
        d.typeDotAttachingToSpaceCommit()
        XCTAssertEqual(d.document, "hestur.")
        d.type(" ")
        XCTAssertEqual(d.document, "hestur. ")
        XCTExpectFailure(
            "space-commit dot attachment (extension-only edit \"hestur \" → \"hestur.\") is classified external and the following space re-commits \"hestur\" (double commit + duplicate wordCommitted event)",
            strict: true
        ) {
            XCTAssertEqual(d.session.committedWordCount, 1)
            XCTAssertFalse(d.drainEvents().contains(where: isWordCommitted))
        }
    }

    /// Same sequence under the default sentence-cut proxy: the second space
    /// collapses the window to "" and `confirmPendingWordAfterTruncationReset`
    /// re-commits the stem of the (never pending) "hestur." token.
    func testDotAttachmentAfterSpaceCommitDoubleCommitsUnderSentenceCut() {
        let d = driver()
        d.type("hestr ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        _ = d.drainEvents()
        d.typeDotAttachingToSpaceCommit()
        d.type(" ")
        XCTAssertEqual(d.document, "hestur. ")
        XCTExpectFailure(
            "space-commit dot attachment double-commits under the sentence-cut proxy too (confirmPendingWordAfterTruncationReset recovers a word that was already committed)",
            strict: true
        ) {
            XCTAssertEqual(d.session.committedWordCount, 1)
            XCTAssertFalse(d.drainEvents().contains(where: isWordCommitted))
        }
    }

    // MARK: - Return key under the newline cut

    /// `.primary` (return) is an autocorrect trigger in KeyboardKit, so
    /// "hestr⏎" applies "hestur" and inserts "\n". Under the simulator's
    /// default (immediate) newline cut the next window is "" and
    /// `heuristicChange` takes the shrink branch: `.truncationReset` requires
    /// a sentence TERMINATOR (./!/?), a newline is not one, so the applied
    /// correction is never confirmed — no lane update, no suggestionAccepted
    /// event, no backspace-revert memo. (Fidelity caveat: KeyboardKit's own
    /// `isCursorAtNewLine` reads a trailing "\n" from the proxy right after
    /// return, i.e. real hosts may cut one keystroke later — see
    /// `ProxyFidelityFoundBugTests` for that shape; under the session's own
    /// stated model of the cut this is a missed commit.)
    func testReturnCommitIsLostUnderImmediateNewlineCut() {
        let d = driver()
        d.type("hestr")
        d.pressReturn()
        XCTAssertEqual(d.document, "hestur\n")
        XCTAssertEqual(d.proxy.contextBeforeInput, "")
        XCTExpectFailure(
            "a return-key commit is never confirmed when the proxy cuts the window at the newline in the same keystroke (truncationReset only recognises ./!/?)",
            strict: true
        ) {
            XCTAssertEqual(d.session.committedWordCount, 1)
            XCTAssertEqual(d.session.lastCommittedWord, "hestur")
        }
    }

    // MARK: - Autocorrect apply at a length-capped (sliding) window

    /// `heuristicChange`'s sliding-window branch (TypingSession.swift ~1170)
    /// only accepts an APPEND past the overlap: it looks for a suffix of the
    /// previous window that prefixes the new one. When the window is at the
    /// proxy's length cap (a long paragraph with no ". "/newline — chat
    /// messages, lists) and the delimiter APPLIES an autocorrect, the new
    /// window both slid AND replaced the pending word (" ok hestr" →
    /// "k hestur "), so no suffix matches and the ledger-matched self-edit is
    /// classified `.external`: the applied correction is never confirmed (no
    /// lane update, no suggestionAccepted, no backspace-revert slot). Plain
    /// typing at the cap commits fine (`testSlidingTruncatedWindowStillCommits`).
    func testAutocorrectApplyAtACappedSlidingWindowIsNotConfirmed() {
        for unit in [ProxySimulator.CapUnit.characters, .utf16] {
            let d = driver(
                truncation: .init(maxBeforeLength: 9, cutAtSentenceBoundary: false, capUnit: unit))
            d.type("cafe ok hestr")
            XCTAssertEqual(d.proxy.contextBeforeInput, " ok hestr")
            XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
            XCTAssertEqual(d.session.committedWordCount, 2)
            d.type(" ")
            XCTAssertEqual(d.document, "cafe ok hestur ")
            XCTExpectFailure(
                "an autocorrect apply while the proxy window is at its length cap (slide + replace in one keystroke) is classified external and the correction is never confirmed",
                strict: true
            ) {
                XCTAssertEqual(d.session.committedWordCount, 3)
                XCTAssertEqual(d.session.lastCommittedWord, "hestur")
            }
        }
    }

    // MARK: - KeyboardKit tap → "." (auto-inserted space removal/reinsertion)

    /// After a bar tap KeyboardKit auto-inserts a space; a following "."
    /// release removes that space, inserts the dot and re-inserts the space
    /// in ONE handle call: "hestur␣" → "hestur.␣". Unexplained shape →
    /// `.external`: the sentence boundary is never seen, so
    /// `engine.noteSentenceBoundary()` never relaxes the lane (the posterior
    /// differs from the plain-typed "hestur. " path), bigram/previous-word
    /// context and the verbatim-choice memo are dropped.
    func testTapThenDotNeverNotesTheSentenceBoundary() {
        let plain = driver(truncation: .none)
        plain.type("hestr")
        plain.tap("hestur")
        plain.type(". ")
        XCTAssertEqual(plain.document, "hestur. ")
        let relaxed = plain.session.probabilityIcelandic

        let kk = driver(truncation: .none)
        kk.type("hestr")
        kk.tap("hestur")
        kk.typeDotAfterTap()
        XCTAssertEqual(kk.document, "hestur. ")
        XCTAssertEqual(kk.session.committedWordCount, 1)
        XCTExpectFailure(
            "KeyboardKit's tap-then-'.' edit (\"hestur \" → \"hestur. \" in one handle) is classified external, so the sentence boundary never relaxes the lane posterior",
            strict: true
        ) {
            XCTAssertEqual(kk.session.probabilityIcelandic, relaxed, accuracy: 1e-9)
        }
    }

    // MARK: - KeyboardKit double-space sentence ender

    /// Second space → `endSentence(withText: ". ")`: "hestur␣" → "hestur.␣"
    /// in one handle call. Same unexplained shape; the lane is never relaxed
    /// at this sentence end (both proxy shapes — the sentence-cut host sees
    /// "hestur " → "" which is a plain shrink, not a `truncationReset`,
    /// because "hestur " has no terminator).
    func testDoubleSpaceEnderNeverNotesTheSentenceBoundary() {
        for truncation in [ProxySimulator.TruncationPolicy.none, .init()] {
            let plain = driver(truncation: truncation)
            plain.type("hestur. ")
            let relaxed = plain.session.probabilityIcelandic

            let kk = driver(truncation: truncation)
            kk.type("hestur ")
            kk.typeDoubleSpaceEnder()
            XCTAssertEqual(kk.document, "hestur. ")
            XCTAssertEqual(kk.session.committedWordCount, 1)
            XCTExpectFailure(
                "KeyboardKit's double-space sentence ender (\"hestur \" → \"hestur. \") is classified external / plain shrink, so the sentence boundary never relaxes the lane posterior",
                strict: true
            ) {
                XCTAssertEqual(kk.session.probabilityIcelandic, relaxed, accuracy: 1e-9)
            }
        }
    }
}
