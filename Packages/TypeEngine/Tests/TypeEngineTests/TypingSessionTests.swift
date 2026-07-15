import XCTest

@testable import TypeEngine

final class TypingSessionTests: XCTestCase {

    private func session() -> TypingSession {
        TypingSession(engine: Fixtures.engine())
    }

    /// Feed text character-by-character, like keystrokes coming through the
    /// proxy, returning the suggestions from the final keystroke.
    @discardableResult
    private func typeThrough(
        _ session: TypingSession, _ text: String, limit: Int = 3
    ) -> [Suggestion] {
        var result: [Suggestion] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            result = session.suggestions(for: buffer, limit: limit)
        }
        return result
    }

    // MARK: - splitCurrentWord

    func testSplitCurrentWordWithNoDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "hest")
        XCTAssertEqual(context, "")
        XCTAssertEqual(word, "hest")
    }

    func testSplitCurrentWordAfterSpace() {
        let (context, word) = TypingSession.splitCurrentWord(of: "góðan d")
        XCTAssertEqual(context, "góðan ")
        XCTAssertEqual(word, "d")
    }

    func testSplitCurrentWordWithTrailingDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "hestur ")
        XCTAssertEqual(context, "hestur ")
        XCTAssertEqual(word, "")
    }

    func testSplitCurrentWordTreatsPunctuationAsDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "já,nei")
        XCTAssertEqual(context, "já,")
        XCTAssertEqual(word, "nei")
    }

    func testApostropheIsNotADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "she don't")
        XCTAssertEqual(context, "she ")
        XCTAssertEqual(word, "don't")
    }

    func testTypographicApostropheIsNotADelimiter() {
        // iOS smart punctuation inserts U+2019, not the straight apostrophe.
        let (context, word) = TypingSession.splitCurrentWord(of: "she don’t")
        XCTAssertEqual(context, "she ")
        XCTAssertEqual(word, "don’t")
    }

    func testHyphenIsNotADelimiter() {
        let (_, word) = TypingSession.splitCurrentWord(of: "vel-þekkt")
        XCTAssertEqual(word, "vel-þekkt")
    }

    func testNewlineIsADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "halló\nheim")
        XCTAssertEqual(context, "halló\n")
        XCTAssertEqual(word, "heim")
    }

    func testLastWordStripsDelimiters() {
        XCTAssertEqual(TypingSession.lastWord(in: "fara í búð, "), "búð")
        // Deferral semantics: a dot at the very end of the text is not yet
        // a delimiter (the commit decision waits for the next keystroke),
        // so the trailing token still carries it; once whitespace follows,
        // the dot is a delimiter and is stripped.
        XCTAssertEqual(TypingSession.lastWord(in: "hestur."), "hestur.")
        XCTAssertEqual(TypingSession.lastWord(in: "hestur. "), "hestur")
        XCTAssertNil(TypingSession.lastWord(in: "  ,. "))
        XCTAssertNil(TypingSession.lastWord(in: ""))
    }

    // MARK: - Dotted tokens (URL/domain/email/file shape, PLAN.md layer 3)

    func testInternalDotIsNotADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "sjá profilmynd.tilvinstri.is")
        XCTAssertEqual(context, "sjá ")
        XCTAssertEqual(word, "profilmynd.tilvinstri.is")
    }

    func testAtSignIsNotADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "jokull@triptojapan.com")
        XCTAssertEqual(context, "")
        XCTAssertEqual(word, "jokull@triptojapan.com")
    }

    func testTrailingDotIsDeferred() {
        // "word." at the cursor: the dot may become word-internal (URL) or
        // a sentence period — the split keeps it pending until the next
        // keystroke decides.
        let (context, word) = TypingSession.splitCurrentWord(of: "profilmynd.")
        XCTAssertEqual(context, "")
        XCTAssertEqual(word, "profilmynd.")
    }

    func testDotFollowedBySpaceIsADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "hestur. ")
        XCTAssertEqual(context, "hestur. ")
        XCTAssertEqual(word, "")
    }

    func testDoubleDotIsADelimiter() {
        // A second '.' resolves the deferral: "word.." is a finished word
        // plus ".." (ellipsis-style), never a dotted token.
        let (context, word) = TypingSession.splitCurrentWord(of: "hestur..")
        XCTAssertEqual(context, "hestur..")
        XCTAssertEqual(word, "")
    }

    func testDotAfterDelimiterIsADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "því .is")
        XCTAssertEqual(context, "því .")
        XCTAssertEqual(word, "is")
    }

    func testVerbatimClassTokenDetection() {
        XCTAssertTrue(TypingSession.isVerbatimClassToken("profilmynd.tilvinstri"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("jokull@triptojapan"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("e.g"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("3.14"))
        XCTAssertFalse(TypingSession.isVerbatimClassToken("hestur"))
        XCTAssertFalse(TypingSession.isVerbatimClassToken("hestur."))  // trailing dot only
        XCTAssertFalse(TypingSession.isVerbatimClassToken("don't"))
        XCTAssertFalse(TypingSession.isVerbatimClassToken(""))
    }

    func testWordTokensKeepDottedTokensWhole() {
        XCTAssertEqual(
            TypingSession.wordTokens(in: "sjá profilmynd.tilvinstri.is "),
            ["sjá", "profilmynd.tilvinstri.is"]
        )
        XCTAssertEqual(TypingSession.wordTokens(in: "the. "), ["the"])
        XCTAssertEqual(TypingSession.wordTokens(in: "completely different "), ["completely", "different"])
    }

    // MARK: - Completion gate

    func testSingleCharacterYieldsOnlyTheVerbatimSlot() {
        // The ≥2-char gate still keeps the engine out of 1-char prefixes,
        // but the verbatim escape hatch (layer 1) is always present for a
        // non-empty current word.
        let bar = session().suggestions(for: "h")
        XCTAssertEqual(bar.count, 1)
        XCTAssertEqual(bar.first?.text, "h")
        XCTAssertEqual(bar.first?.isVerbatim, true)
    }

    func testTwoCharactersYieldSuggestions() {
        // Engine suggestions (beyond the verbatim slot) kick in at 2 chars.
        XCTAssertTrue(session().suggestions(for: "he").contains { !$0.isVerbatim })
    }

    func testEmptyTextYieldsNextWordPredictions() {
        // Empty current word is prediction, not completion; not gated, and
        // no verbatim slot (there is no typed token to escape-hatch).
        let bar = session().suggestions(for: "")
        XCTAssertFalse(bar.isEmpty)
        XCTAssertFalse(bar.contains { $0.isVerbatim })
    }

    func testGateAppliesToCurrentWordNotWholeText() {
        // 1-char *current word* after committed context is still gated
        // (verbatim slot only, no engine suggestions).
        let s = session()
        typeThrough(s, "góðan d")
        let bar = s.suggestions(for: "góðan d")
        XCTAssertEqual(bar.map(\.text), ["d"])
        XCTAssertEqual(bar.first?.isVerbatim, true)
    }

    // MARK: - Verbatim escape hatch (layer 1)

    func testVerbatimSlotLeadsTheBar() {
        let s = session()
        let bar = typeThrough(s, "hestr")
        XCTAssertEqual(bar.first?.text, "hestr")
        XCTAssertEqual(bar.first?.isVerbatim, true)
        XCTAssertFalse(bar.first?.isAutocorrect ?? true)
        XCTAssertTrue(bar.dropFirst().allSatisfy { !$0.isVerbatim })
    }

    func testVerbatimSlotCountsAgainstTheLimit() {
        let s = session()
        let bar = typeThrough(s, "hestr", limit: 3)
        XCTAssertLessThanOrEqual(bar.count, 3)
        XCTAssertEqual(bar.first?.isVerbatim, true)
    }

    func testVerbatimChoiceSuppressesAutocorrect() {
        // The user tapped the verbatim slot for "teh"; if the token shows
        // up again as the pending word (e.g. no auto-inserted space), an
        // immediate delimiter must not re-correct it.
        let s = session()
        XCTAssertTrue(typeThrough(s, "teh").contains { $0.isAutocorrect })
        s.noteVerbatimChoice("teh")
        let bar = s.suggestions(for: "teh")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
        XCTAssertEqual(bar.first?.text, "teh")
        XCTAssertEqual(bar.first?.isVerbatim, true)
    }

    func testVerbatimChoiceMemoIsClearedByCommit() {
        let s = session()
        typeThrough(s, "teh")
        s.noteVerbatimChoice("teh")
        typeThrough(s, "teh og ")  // "og" commits: memo gone
        let bar = s.suggestions(for: "teh og teh")
        XCTAssertTrue(bar.contains { $0.isAutocorrect })
    }

    // MARK: - Field-type gate (layer 2)

    func testURLFieldSuppressesAutocorrectButKeepsSuggestions() {
        for kind in [FieldKind.url, .email, .webSearch] {
            let s = session()
            s.fieldKind = kind
            let bar = typeThrough(s, "teh")
            XCTAssertFalse(bar.contains { $0.isAutocorrect }, "\(kind) must not autocorrect")
            XCTAssertTrue(bar.contains { !$0.isVerbatim }, "\(kind) keeps tap-only suggestions")
        }
    }

    func testStandardFieldStillAutocorrects() {
        let s = session()
        s.fieldKind = .standard
        XCTAssertTrue(typeThrough(s, "teh").contains { $0.isAutocorrect })
    }

    // MARK: - Dotted-token typing (layer 3)

    func testDottedTokenNeverAutocorrects() {
        let s = session()
        var buffer = ""
        for ch in "teh.tilvinstri.is" {
            buffer.append(ch)
            let bar = s.suggestions(for: buffer)
            if buffer.contains(".") && !buffer.hasSuffix(".") {
                // Internal dot present: verbatim-class, autocorrect dead.
                XCTAssertFalse(
                    bar.contains { $0.isAutocorrect },
                    "autocorrect fired on \(buffer)"
                )
                XCTAssertEqual(bar.first?.text, buffer)
                XCTAssertEqual(bar.first?.isVerbatim, true)
            }
        }
        XCTAssertEqual(s.committedWordCount, 0, "no dot may commit inside the token")
        s.suggestions(for: "teh.tilvinstri.is ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "teh.tilvinstri.is")
    }

    func testDottedTokenSegmentSuggestionsAreTapOnlyAndFullToken() {
        let s = session()
        let bar = typeThrough(s, "takk.hestr")
        // Suggestions correct the trailing segment but replace the whole
        // token, so a tap can't shear the URL apart.
        XCTAssertTrue(bar.contains { $0.text == "takk.hestur" }, "bar: \(bar.map(\.text))")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    func testEmailShapedTokenNeverAutocorrects() {
        let s = session()
        let bar = typeThrough(s, "jokull@triptojapan.com")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
        s.suggestions(for: "jokull@triptojapan.com ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "jokull@triptojapan.com")
    }

    // MARK: - Deferred '.'-commit (layer 3 delimiter semantics)

    func testTrailingDotDoesNotCommit() {
        let s = session()
        typeThrough(s, "hestur.")
        XCTAssertEqual(s.committedWordCount, 0)
        XCTAssertNil(s.lastCommittedWord)
    }

    func testDotThenSpaceCommitsTheStem() {
        let s = session()
        typeThrough(s, "hestur. ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    func testDotThenLetterGrowsOneDottedToken() {
        let s = session()
        typeThrough(s, "hestur.i")
        XCTAssertEqual(s.committedWordCount, 0)
        s.suggestions(for: "hestur.is ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur.is")
    }

    func testPendingDotKeepsAutocorrectArmedWithDotAppended() {
        // "teh." must still become "the. " when a space follows (sentence
        // period), so the autocorrect stays armed, dot included — the
        // deferred apply replaces the whole pending token.
        let s = session()
        let bar = typeThrough(s, "teh.")
        let autocorrect = bar.first { $0.isAutocorrect }
        XCTAssertEqual(autocorrect?.text, "the.")
        // The embedder applies it on the space; the session reads the
        // corrected form back out of the committed text.
        s.suggestions(for: "the. ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "the")
    }

    func testDeferredCommitSurvivesProxySentenceCut() {
        // Real proxies cut the before-window at ". ", so the space that
        // commits "teh." can collapse the window to "" in the same
        // keystroke. The commit must be recovered from session state —
        // including the corrected form the embedder just applied.
        let s = session()
        typeThrough(s, "teh.")
        s.suggestions(for: "")  // ". " sentence cut right after the apply
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "the")
    }

    // MARK: - Revert-on-continuation (layer 4 fallback)

    func testHostDotApplyThenLetterRevertsTheCorrection() {
        // Stock-KeyboardKit shape: the host applied "the." on the period
        // keystroke ("teh" + '.'), then the user typed a letter — the
        // session must order the correction undone.
        let s = session()
        typeThrough(s, "teh")
        s.suggestions(for: "the.")  // host applied the armed autocorrect + '.'
        let revert = s.continuationRevert(for: "t")
        XCTAssertEqual(revert, RevertInstruction(deleteCount: 4, text: "teh."))
        // After the revert edits + the continuation letter, typing resumes
        // on the original token with no spurious commit or external reset.
        s.suggestions(for: "teh.t")
        XCTAssertEqual(s.committedWordCount, 0)
        s.suggestions(for: "teh.ti ")
        XCTAssertEqual(s.lastCommittedWord, "teh.ti")
    }

    func testRevertMemoIsDiscardedOnNonContinuation() {
        let s = session()
        typeThrough(s, "teh")
        s.suggestions(for: "the.")
        XCTAssertNil(s.continuationRevert(for: " "), "space is not a continuation")
        XCTAssertNil(s.continuationRevert(for: "t"), "memo must be one-shot")
    }

    func testRevertMemoDiesAfterTheNextKeystroke() {
        let s = session()
        typeThrough(s, "teh")
        s.suggestions(for: "the.")
        s.suggestions(for: "the. ")  // next keystroke landed: window passed
        XCTAssertNil(s.continuationRevert(for: "t"))
    }

    func testNoRevertMemoWithoutAReplacement() {
        let s = session()
        typeThrough(s, "hestur.")  // typed dot, nothing was replaced
        XCTAssertNil(s.continuationRevert(for: "t"))
    }

    // MARK: - Commit detection

    func testTypingSpaceCommitsWordAndUpdatesPosterior() {
        let s = session()
        typeThrough(s, "the ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "the")
        XCTAssertLessThan(s.probabilityIcelandic, 0.5)
        XCTAssertEqual(s.posteriorUpdateCount, 1)
    }

    func testCommittedWordIsReadFromContextNotTypedFragment() {
        // Autocorrect flow: the user typed "teh", KeyboardKit replaced it
        // with "the" and inserted a space; the session must confirm "the".
        let s = session()
        typeThrough(s, "teh")
        s.suggestions(for: "the ")
        XCTAssertEqual(s.lastCommittedWord, "the")
        XCTAssertLessThan(s.probabilityIcelandic, 0.5)
    }

    func testDoubleSpaceCommitsOnlyOnce() {
        let s = session()
        typeThrough(s, "the  ")
        XCTAssertEqual(s.committedWordCount, 1)
    }

    func testCommaCommitsWord() {
        let s = session()
        typeThrough(s, "hestur,")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
        XCTAssertGreaterThan(s.probabilityIcelandic, 0.5)
    }

    func testUnknownWordCommitDoesNotMovePosterior() {
        let s = session()
        typeThrough(s, "zzzqqq ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.posteriorUpdateCount, 0)
        XCTAssertEqual(s.probabilityIcelandic, 0.5)
    }

    func testOnlyTrailingWordOfContextIsCommitted() {
        let s = session()
        typeThrough(s, "og hestur ")
        // "og" commits at the first space, "hestur" at the second.
        XCTAssertEqual(s.committedWordCount, 2)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    // MARK: - Space-miss splits (multi-word suggestions)

    func testAppliedSplitSuggestionCommitsEachWord() {
        let s = session()
        // "gottnveður" = "gott veður" with the spacebar tap landing on n;
        // the split leads the engine suggestions.
        let bar = typeThrough(s, "gottnveður")
        XCTAssertTrue(bar.contains { $0.text == "gott veður" })
        // Delimiter applies the suggestion (KeyboardKit replaces the token
        // and a space follows): BOTH words are committed, in order.
        s.suggestions(for: "gott veður ")
        XCTAssertEqual(s.committedWordCount, 2)
        XCTAssertEqual(s.lastCommittedWord, "veður")
    }

    func testMultiWordHostChangeIsStillNeverCommitted() {
        let s = session()
        typeThrough(s, "gottnveður")
        // Multi-word text that was NOT an emitted suggestion: host paste,
        // not an applied split — no commits.
        s.suggestions(for: "gott vetur ")
        XCTAssertEqual(s.committedWordCount, 0)
    }

    // MARK: - Punctuation attachment ("word ␣.␣" → "word.␣")

    func testPunctuationAttachmentOrdersEditOnSpace() {
        let s = session()
        typeThrough(s, "hestur .")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertTrue(s.hasPendingPunctuationAttachment)
        XCTAssertEqual(
            s.punctuationAttachment(for: " "),
            RevertInstruction(deleteCount: 2, text: ".")
        )
        // The embedder executes the edit, then inserts the space: the next
        // window is a clean evolution — no spurious commit, memo gone.
        s.suggestions(for: "hestur. ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertFalse(s.hasPendingPunctuationAttachment)
    }

    func testPunctuationAttachmentIsDiscardedByLetter() {
        let s = session()
        typeThrough(s, "hestur .")
        XCTAssertTrue(s.hasPendingPunctuationAttachment)
        // ".net"-style continuation: the letter consumes the memo with no
        // edit, and it does not come back for a later space.
        XCTAssertNil(s.punctuationAttachment(for: "n"))
        XCTAssertFalse(s.hasPendingPunctuationAttachment)
        XCTAssertNil(s.punctuationAttachment(for: " "))
    }

    func testPunctuationAttachmentRequiresExactlyOneSpace() {
        let s = session()
        typeThrough(s, "hestur  .")
        XCTAssertFalse(s.hasPendingPunctuationAttachment)
    }

    func testPunctuationAttachmentNotArmedByDeferredDot() {
        let s = session()
        // "hestur." is a pending deferred-dot token, not a stray period.
        typeThrough(s, "hestur.")
        XCTAssertFalse(s.hasPendingPunctuationAttachment)
    }

    func testPunctuationAttachmentMemoDiesAfterOneKeystroke() {
        let s = session()
        typeThrough(s, "hestur .")
        XCTAssertTrue(s.hasPendingPunctuationAttachment)
        // A keystroke lands WITHOUT the embedder consulting the memo (e.g.
        // wiring raced): the next suggestions() call discards it.
        s.suggestions(for: "hestur .x")
        XCTAssertFalse(s.hasPendingPunctuationAttachment)
    }

    // MARK: - External text changes (cursor jumps, host mutation)

    func testExternalChangeNotePreventsSpuriousCommit() {
        let s = session()
        typeThrough(s, "hestur bor")
        XCTAssertEqual(s.committedWordCount, 1)
        // Cursor jumps to just after "hestur " — new window ends with a
        // delimiter, which would look like a word commit without the note.
        s.noteExternalTextChange()
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "cursor jump must not commit")
    }

    func testCursorJumpIsDetectedInternallyWithoutNote() {
        // Even with NO noteExternalTextChange call, the session's window-
        // change classifier must not misread a cursor jump (word-in-progress
        // vanishing from the window without new text) as a word commit.
        let s = session()
        typeThrough(s, "hestur bor")
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "cursor jump misread as commit")
    }

    func testBackspacingAwayWordInProgressDoesNotRecommit() {
        // "hestur " committed once; starting a word and deleting it again
        // must not re-commit "hestur" (old quirk: prevWord nonempty + word
        // empty was treated as a commit even when nothing was added).
        let s = session()
        typeThrough(s, "hestur b")
        XCTAssertEqual(s.committedWordCount, 1)
        s.suggestions(for: "hestur ")  // backspace deleted the "b"
        XCTAssertEqual(s.committedWordCount, 1, "backspace must not re-commit")
    }

    func testHostMultiWordChangeWithoutNoteIsNotCommitted() {
        // A change that introduces several words at once is a host paste/
        // autofill, not a user keystroke — no commit even without the note.
        let s = session()
        typeThrough(s, "hest")
        s.suggestions(for: "completely different ")
        XCTAssertEqual(s.committedWordCount, 0)
    }

    func testSlidingTruncatedWindowStillCommits() {
        // Length-capped proxy window: the front chars fall away while
        // typing. The session must still detect the commit.
        let s = session()
        s.suggestions(for: "stur borð")
        s.suggestions(for: "stur borða")
        s.suggestions(for: "tur borða ")  // window slid by one + space
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "borða")
    }

    // MARK: - Window-aware external-change note (extension forwarding)

    func testWindowNoteIsIgnoredForOwnEdits() {
        // textDidChange fires after our own insertions too; forwarding the
        // (new) window must not reset the pending word.
        let s = session()
        typeThrough(s, "teh")
        s.noteExternalTextChange(window: "teh")  // same window: no-op
        s.noteExternalTextChange(window: "the ")  // valid evolution: no-op
        s.suggestions(for: "the ")
        XCTAssertEqual(s.committedWordCount, 1, "note must not swallow the commit")
        XCTAssertEqual(s.lastCommittedWord, "the")
    }

    func testWindowNoteClearsOnInconsistentWindow() {
        let s = session()
        typeThrough(s, "hestur bor")
        // Cursor jumped somewhere unrelated: window not a typing evolution.
        s.noteExternalTextChange(window: "annar texti allt")
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "note should have cleared pending word")
    }

    // MARK: - Sentence-truncation bigram-context carry

    func testSentenceTruncationCarriesBigramContext() {
        // The iOS proxy cuts the before-window at ". "; the words are still
        // on screen, so the first word of the new sentence should keep
        // bigram context ("góðan" -> "dag" in the fixtures). With the
        // deferred '.'-commit, "góðan." is still pending at the dot; the
        // space keystroke both commits it and collapses the window.
        let s = session()
        typeThrough(s, "góðan.")
        XCTAssertNil(s.lastCommittedWord, "trailing dot commit is deferred")
        let predictions = s.suggestions(for: "")  // proxy sentence cut
        XCTAssertEqual(s.lastCommittedWord, "góðan")
        XCTAssertEqual(predictions.first?.text, "dag", "carried bigram context should rank dag first")
    }

    func testTruncationCarryDoesNotSurviveExternalChange() {
        let s = session()
        typeThrough(s, "góðan.")
        s.suggestions(for: "")
        s.noteExternalTextChange()  // cursor jump
        let predictions = s.suggestions(for: "")
        XCTAssertNotEqual(predictions.first?.text, "dag", "carry must not survive external changes")
    }

    func testBackspaceToEmptyDoesNotCarryContext() {
        // Deleting everything is not a sentence cut: no terminator in the
        // pre-collapse window, so no carried context.
        let s = session()
        typeThrough(s, "góðan dag")
        s.suggestions(for: "góðan ")
        s.suggestions(for: "góðan")
        s.suggestions(for: "góða")
        s.suggestions(for: "gó")
        s.suggestions(for: "g")
        let predictions = s.suggestions(for: "")
        XCTAssertNotEqual(predictions.first?.text, "dag")
    }

    // MARK: - Sentence-boundary lane decay

    func testSentenceTerminatorDecaysLaneTowardNeutral() {
        // Same words, one committed by ". " instead of " ": the sentence
        // boundary must shed laneBoundaryDecay of the distance to 0.5 —
        // relax, not reset.
        let spaceSession = session()
        typeThrough(spaceSession, "og að er ")
        let boundarySession = session()
        typeThrough(boundarySession, "og að er. ")
        let d = boundarySession.engine.config.laneBoundaryDecay
        XCTAssertEqual(
            boundarySession.probabilityIcelandic,
            0.5 + (spaceSession.probabilityIcelandic - 0.5) * (1 - d),
            accuracy: 1e-9
        )
        XCTAssertGreaterThan(boundarySession.probabilityIcelandic, 0.6, "lane must survive the boundary")
    }

    func testCommaDoesNotDecayLane() {
        let spaceSession = session()
        typeThrough(spaceSession, "og að er ")
        let commaSession = session()
        typeThrough(commaSession, "og að er, ")
        XCTAssertEqual(
            commaSession.probabilityIcelandic,
            spaceSession.probabilityIcelandic,
            accuracy: 1e-9,
            "only sentence terminators decay the lane"
        )
    }

    // MARK: - Reset

    func testResetClearsPosteriorAndCounters() {
        let s = session()
        typeThrough(s, "the and ")
        XCTAssertNotEqual(s.probabilityIcelandic, 0.5)
        s.reset()
        XCTAssertEqual(s.probabilityIcelandic, 0.5)
        XCTAssertEqual(s.committedWordCount, 0)
        XCTAssertEqual(s.posteriorUpdateCount, 0)
        XCTAssertNil(s.lastCommittedWord)
    }
}
