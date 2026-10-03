import Learning
import XCTest

@testable import TypeEngine

/// Regressions for the bugs found at the KeyboardExt/KeyboardKit ↔ TypeEngine
/// apply seam (2026-10 seam audit). Each was a minimal deterministic repro
/// pinned as a strict `XCTExpectFailure`; the fixes turned them into ordinary
/// tests.
///
/// Common root: `TypingSession.heuristicChange` only knew append /
/// replace-current-word / shrink / sliding-window / collapse-to-empty shapes.
/// Several proxy edits the extension and the vendored KeyboardKit perform on
/// device rewrite the TRAILING DELIMITER ("word␣" → "word.", "word␣" →
/// "word.␣", "word␣" → "word.␣" via the double-space ender) and none of those
/// shapes existed, so a self-edit the ledger had already PROVEN ours was still
/// classified `.external`. The session now recognizes those shapes — gated on
/// a ledger-matched observation — and the embedder describes the edits the
/// window cannot show (`noteSelfEdit(before:after:keystroke:replacement:)`).
/// See `SeamDriver` for the exact device edit sequences.
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
    /// "hestur.". The session recognizes the trailing-delimiter rewrite,
    /// remembers that the pending "hestur." is an already-committed word, and
    /// the NEXT space only ends the sentence: still 1 commit, no new commit
    /// event (previously a second `wordCommitted("hestur", previousWord:
    /// "hestur")` — a bogus self-bigram).
    func testDotAttachmentAfterSpaceCommitDoesNotDoubleCommitTheWord() {
        let d = driver(truncation: .none)
        d.type("hestr ")
        XCTAssertEqual(d.document, "hestur ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        _ = d.drainEvents()
        d.typeDotAttachingToSpaceCommit()
        XCTAssertEqual(d.document, "hestur.")
        XCTAssertFalse(
            d.bar.contains(where: \.isAutocorrect),
            "the committed word under an attached dot is never re-corrected: \(d.bar.map(\.text))")
        d.type(" ")
        XCTAssertEqual(d.document, "hestur. ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertFalse(d.drainEvents().contains(where: isWordCommitted))
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    /// Same sequence under the default sentence-cut proxy: the second space
    /// collapses the window to "" and the collapse path must not recover the
    /// stem of the (never pending) "hestur." token as a fresh commit.
    func testDotAttachmentAfterSpaceCommitDoesNotDoubleCommitUnderSentenceCut() {
        let d = driver()
        d.type("hestr ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        _ = d.drainEvents()
        d.typeDotAttachingToSpaceCommit()
        d.type(" ")
        XCTAssertEqual(d.document, "hestur. ")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertFalse(d.drainEvents().contains(where: isWordCommitted))
    }

    /// The attachment ends the sentence: the lane relaxes exactly once, the
    /// same as the plain-typed "hestur. " path — under both window shapes.
    func testDotAttachmentAfterSpaceCommitNotesTheSentenceBoundaryOnce() {
        for truncation in [ProxySimulator.TruncationPolicy.none, .init()] {
            // Plain path: one confirmWord("hestur") + one sentence boundary.
            let plain = driver(truncation: truncation)
            plain.type("hestur. ")
            XCTAssertEqual(plain.session.committedWordCount, 1)
            let relaxed = plain.session.probabilityIcelandic

            let attached = driver(truncation: truncation)
            attached.type("hestr ")
            attached.typeDotAttachingToSpaceCommit()
            attached.type(" ")
            XCTAssertEqual(attached.document, "hestur. ")
            XCTAssertEqual(attached.session.probabilityIcelandic, relaxed, accuracy: 1e-9)
        }
    }

    // MARK: - Return key under the newline cut

    /// `.primary` (return) is an autocorrect trigger in KeyboardKit, so
    /// "hestr⏎" applies "hestur" and inserts "\n". Under the simulator's
    /// default (immediate) newline cut the next window is "". A newline is
    /// not a sentence terminator, so the shape alone cannot tell this
    /// collapse from deleting the whole word; the embedder's record names
    /// the keystroke (`keystroke: "\n"`) and the applied text, and the
    /// commit is confirmed from it. (Real hosts may cut one keystroke later
    /// — see `ProxyFidelityFoundBugTests` for that shape; both must agree.)
    func testReturnCommitIsConfirmedUnderImmediateNewlineCut() {
        let d = driver()
        d.type("hestr")
        d.pressReturn()
        XCTAssertEqual(d.document, "hestur\n")
        XCTAssertEqual(d.proxy.contextBeforeInput, "")
        XCTAssertEqual(d.session.committedWordCount, 1)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
        XCTAssertTrue(
            d.drainEvents().contains {
                if case .suggestionAccepted(let typed, let accepted) = $0 {
                    return typed == "hestr" && accepted == "hestur"
                }
                return false
            })
    }

    /// A Return is a paragraph break, not a sentence end: the lane posterior
    /// after "hestur⏎" equals the visible-window path's, under both cuts.
    func testReturnCommitAgreesAcrossWindowShapes() {
        let visible = driver(truncation: .none)
        visible.type("hestur")
        visible.pressReturn()
        let immediate = driver()
        immediate.type("hestur")
        immediate.pressReturn()
        XCTAssertEqual(immediate.session.committedWordCount, visible.session.committedWordCount)
        XCTAssertEqual(immediate.session.lastCommittedWord, "hestur")
        XCTAssertEqual(
            immediate.session.probabilityIcelandic, visible.session.probabilityIcelandic,
            accuracy: 1e-9)
    }

    /// Deleting a whole one-letter word collapses the window exactly like a
    /// Return would — only the described keystroke tells them apart, and a
    /// backspace record carries none, so nothing commits.
    func testWholeWordBackspaceToEmptyWindowIsNotACommit() {
        let d = driver()
        d.type("h")
        XCTAssertEqual(d.proxy.contextBeforeInput, "h")
        d.backspace()
        XCTAssertEqual(d.proxy.contextBeforeInput, "")
        XCTAssertEqual(d.session.committedWordCount, 0)
    }

    // MARK: - Autocorrect apply at a length-capped (sliding) window

    /// `heuristicChange`'s sliding-window branch only accepted an APPEND past
    /// the overlap: it looked for a suffix of the previous window that
    /// prefixes the new one. When the window is at the proxy's length cap (a
    /// long paragraph with no ". "/newline — chat messages, lists) and the
    /// delimiter APPLIES an autocorrect, the new window both slid AND
    /// replaced the pending word (" ok hestr" → "k hestur "), so no suffix
    /// matched. A ledger-matched observation now aligns a suffix of the
    /// previous COMMITTED CONTEXT instead, and the applied correction is
    /// confirmed (lane update, suggestionAccepted, backspace-revert slot).
    func testAutocorrectApplyAtACappedSlidingWindowIsConfirmed() {
        for unit in [ProxySimulator.CapUnit.characters, .utf16] {
            let d = driver(
                truncation: .init(maxBeforeLength: 9, cutAtSentenceBoundary: false, capUnit: unit))
            d.type("cafe ok hestr")
            XCTAssertEqual(d.proxy.contextBeforeInput, " ok hestr")
            XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
            XCTAssertEqual(d.session.committedWordCount, 2)
            _ = d.drainEvents()
            d.type(" ")
            XCTAssertEqual(d.document, "cafe ok hestur ")
            XCTAssertEqual(d.session.committedWordCount, 3)
            XCTAssertEqual(d.session.lastCommittedWord, "hestur")
            XCTAssertTrue(
                d.drainEvents().contains {
                    if case .suggestionAccepted(let typed, let accepted) = $0 {
                        return typed == "hestr" && accepted == "hestur"
                    }
                    return false
                })
            // (The backspace-revert slot itself is not asserted here: at the
            // length cap a deletion does not shrink the window, and
            // `resolveBackspaceRevert`'s deletion discriminator — pre-existing,
            // outside this audit — does not see it.)
        }
    }

    /// The same cap, plain typing (no apply): unchanged behaviour.
    func testSlidingTruncatedWindowStillCommitsPlainWords() {
        let d = driver(truncation: .init(maxBeforeLength: 9, cutAtSentenceBoundary: false))
        d.type("cafe ok hestur ")
        XCTAssertEqual(d.session.committedWordCount, 3)
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    // MARK: - KeyboardKit tap → "." (auto-inserted space removal/reinsertion)

    /// After a bar tap KeyboardKit auto-inserts a space; a following "."
    /// release removes that space, inserts the dot and re-inserts the space
    /// in ONE handle call: "hestur␣" → "hestur.␣". The trailing-delimiter
    /// rewrite is recognized and the sentence boundary relaxes the lane
    /// exactly as the plain-typed "hestur. " path does (never twice).
    func testTapThenDotNotesTheSentenceBoundaryOnce() {
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
        XCTAssertEqual(kk.session.probabilityIcelandic, relaxed, accuracy: 1e-9)
    }

    // MARK: - KeyboardKit double-space sentence ender

    /// Second space → `endSentence(withText: ". ")`: "hestur␣" → "hestur.␣"
    /// in one handle call. Visible host: a trailing-delimiter rewrite that
    /// ends the sentence. Sentence-cut host: "hestur␣" → "" — a plain shrink
    /// by shape, but the record's keystroke (a space with no word pending)
    /// says the ender fired, so the boundary is noted there too. The lane
    /// relaxes once in both shapes, matching the plain "hestur. " path.
    func testDoubleSpaceEnderNotesTheSentenceBoundaryOnce() {
        for truncation in [ProxySimulator.TruncationPolicy.none, .init()] {
            let plain = driver(truncation: truncation)
            plain.type("hestur. ")
            let relaxed = plain.session.probabilityIcelandic

            let kk = driver(truncation: truncation)
            kk.type("hestur ")
            kk.typeDoubleSpaceEnder()
            XCTAssertEqual(kk.document, "hestur. ")
            XCTAssertEqual(kk.session.committedWordCount, 1)
            XCTAssertEqual(kk.session.probabilityIcelandic, relaxed, accuracy: 1e-9)
        }
    }

    /// The ender's ". " is a sentence boundary for the learning log too: the
    /// next commit must not chain a bigram across it.
    func testDoubleSpaceEnderBreaksTheBigramChain() {
        let d = driver(truncation: .none)
        d.type("hestur ")
        d.typeDoubleSpaceEnder()
        _ = d.drainEvents()
        d.type("og ")
        let previous = d.drainEvents().compactMap { event -> String?? in
            if case .wordCommitted(_, let previousWord, _) = event { return .some(previousWord) }
            return nil
        }
        XCTAssertEqual(previous.count, 1)
        XCTAssertNil(previous.first ?? nil, "no bigram across the sentence ender")
    }
}
