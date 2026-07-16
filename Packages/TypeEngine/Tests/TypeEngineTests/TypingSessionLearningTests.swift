import XCTest
import Learning

@testable import TypeEngine

/// Learning-event emission from the typing session (M2): what gets
/// buffered, with what payload, and — above all — the HARD privacy gates
/// that keep sensitive contexts and non-words out of the log.
final class TypingSessionLearningTests: XCTestCase {

    private func session() -> TypingSession {
        TypingSession(engine: Fixtures.engine())
    }

    /// Feed text character-by-character (proxy-window style).
    @discardableResult
    private func typeThrough(
        _ session: TypingSession, _ text: String, startingFrom prefix: String = ""
    ) -> [Suggestion] {
        var result: [Suggestion] = []
        var buffer = prefix
        for ch in text {
            buffer.append(ch)
            result = session.suggestions(for: buffer, limit: 3)
        }
        return result
    }

    // MARK: - wordCommitted

    func testCommitEmitsWordCommittedWithPreviousWordChain() {
        let s = session()
        typeThrough(s, "hestur og ")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events.count, 2)
        guard case .wordCommitted(let w1, let p1, _) = events[0],
            case .wordCommitted(let w2, let p2, _) = events[1]
        else {
            return XCTFail("expected two wordCommitted events, got \(events)")
        }
        XCTAssertEqual(w1, "hestur")
        XCTAssertNil(p1)
        XCTAssertEqual(w2, "og")
        XCTAssertEqual(p2, "hestur")
    }

    func testSentenceInitialAutocapIsStrippedAtCapture() {
        // Wave 26 (session 2026-07-16T22-45-30): a sentence-initial commit
        // whose leading cap is the only casing on common base vocabulary is
        // an iOS autocap artifact — learned lowercase, so it can never
        // title-case future mid-sentence corrections.
        let s = session()
        typeThrough(s, "Hestur og ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let w1, let p1, _) = events.first else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(w1, "hestur")
        XCTAssertNil(p1)
    }

    func testSentenceInitialProperNounKeepsItsCap() {
        // "miðeind" is OOV in the fixtures: the artifact test fails and the
        // byte-exact contract holds even at the autocap position.
        let s = session()
        typeThrough(s, "Miðeind ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let word, _, _) = events.first else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "Miðeind")
    }

    func testMidSentenceCapitalizedCommitKeepsItsCap() {
        // Mid-sentence caps are deliberate (proper nouns): never stripped.
        let s = session()
        typeThrough(s, "og Hestur ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let word, let previous, _) = events.last else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "Hestur")
        XCTAssertEqual(previous, "og")
    }

    func testLanguageHintComesFromLaneEvidenceNotPosterior() {
        let s = session()
        // Drive the posterior strongly English first…
        typeThrough(s, "the with and ")
        _ = s.drainLearningEvents()
        XCTAssertLessThan(s.probabilityIcelandic, 0.4)
        // …then commit a strongly-Icelandic word: its hint must still be
        // .icelandic (per-word evidence), not the lane's current belief.
        typeThrough(s, "hestur ", startingFrom: "the with and ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let word, _, let hint) = events.last else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "hestur")
        XCTAssertEqual(hint, .icelandic)
    }

    func testPreviousWordDoesNotSpanSentenceBoundary() {
        let s = session()
        typeThrough(s, "hestur")
        _ = s.suggestions(for: "hestur.")
        _ = s.suggestions(for: "hestur. ")  // deferred-dot commit + boundary
        typeThrough(s, "og ", startingFrom: "hestur. ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let word, let previous, _) = events.last else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "og")
        XCTAssertNil(previous, "bigram evidence must not span the sentence boundary")
    }

    func testPreviousWordClearedByExternalChange() {
        let s = session()
        typeThrough(s, "hestur ")
        s.noteExternalTextChange()
        typeThrough(s, "og ", startingFrom: "hestur ")
        let events = s.drainLearningEvents()
        guard case .wordCommitted(let word, let previous, _) = events.last else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "og")
        XCTAssertNil(previous)
    }

    // MARK: - suggestionAccepted

    func testAutocorrectApplyEmitsSuggestionAccepted() {
        let s = session()
        let bar = typeThrough(s, "teh")
        XCTAssertEqual(bar.first(where: { $0.isAutocorrect })?.text, "the")
        // The embedder's delimiter keystroke applies the correction: the
        // window evolves "teh" → "the " in one step.
        _ = s.suggestions(for: "the ")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events.count, 1)
        guard case .suggestionAccepted(let typed, let accepted) = events[0] else {
            return XCTFail("expected suggestionAccepted, got \(events)")
        }
        XCTAssertEqual(typed, "teh")
        XCTAssertEqual(accepted, "the")
    }

    func testSuggestionTapEmitsSuggestionAcceptedNotWordCommitted() {
        let s = session()
        typeThrough(s, "hestr")
        // Tapping "hestur" in the bar: token replaced + space (KeyboardKit
        // semantics) — one window step.
        _ = s.suggestions(for: "hestur ")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events.count, 1)
        guard case .suggestionAccepted(let typed, let accepted) = events[0] else {
            return XCTFail("expected suggestionAccepted, got \(events)")
        }
        XCTAssertEqual(typed, "hestr")
        XCTAssertEqual(accepted, "hestur")
    }

    // MARK: - wordTapped (verbatim tap / learnWord)

    func testVerbatimTapEmitsWordTappedAndLearnsImmediately() {
        let s = session()
        typeThrough(s, "kubbur")
        s.noteVerbatimChoice("kubbur")
        XCTAssertTrue(s.engine.isPersonalWord("kubbur"), "session-immediate learn")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events, [.wordTapped(word: "kubbur")])
    }

    func testVerbatimTapCommitDoesNotDoubleCount() {
        // The tap's wordTapped is the strongest signal; the commit that the
        // tap itself produces must not ALSO emit a wordCommitted.
        let s = session()
        typeThrough(s, "kubbur")
        s.noteVerbatimChoice("kubbur")
        _ = s.suggestions(for: "kubbur ")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events, [.wordTapped(word: "kubbur")])
    }

    func testDuplicateLearnSignalsForOneTapAreDeduplicated() {
        // On device both our action handler (noteVerbatimChoice) and
        // KeyboardKit's autolearn (learnWord) fire for the same tap.
        let s = session()
        typeThrough(s, "kubbur")
        s.noteVerbatimChoice("kubbur")
        s.learnWordImmediately("kubbur")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events, [.wordTapped(word: "kubbur")])
    }

    // MARK: - correctionReverted

    func testRevertOnContinuationEmitsCorrectionReverted() {
        let s = session()
        typeThrough(s, "teh")
        // Host-side '.'-apply replaced the pending token ("teh" → "the.").
        _ = s.suggestions(for: "the.")
        XCTAssertTrue(s.hasPendingContinuationRevert)
        let revert = s.continuationRevert(for: "t")
        XCTAssertNotNil(revert)
        let events = s.drainLearningEvents()
        XCTAssertEqual(events, [.correctionReverted(original: "teh", applied: "the")])
    }

    // MARK: - Privacy gates (HARD)

    func testSensitiveFieldKindsEmitNoEvents() {
        for kind in [FieldKind.url, .email, .webSearch, .secure] {
            let s = session()
            s.fieldKind = kind
            typeThrough(s, "hestur og teh ")
            s.noteVerbatimChoice("kubbur")
            XCTAssertFalse(s.hasPendingLearningEvents, "\(kind) leaked events")
            XCTAssertTrue(s.drainLearningEvents().isEmpty, "\(kind) leaked events")
            XCTAssertFalse(
                s.engine.isPersonalWord("kubbur"),
                "\(kind) must not even feed the in-session overlay"
            )
        }
    }

    func testHostPastedMultiWordTextEmitsNoEvents() {
        let s = session()
        typeThrough(s, "hestur ")
        _ = s.drainLearningEvents()
        // Multi-word appears in one step with no matching split suggestion:
        // host paste — never committed, never logged.
        _ = s.suggestions(for: "hestur þetta er límdur texti ")
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
    }

    func testDigitOnlyTokensAreNotLogged() {
        let s = session()
        typeThrough(s, "1234 ")
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
    }

    func testVerbatimClassTokensAreNeverLogged() {
        // URL/email-shaped tokens (internal '.'/'@') are filtered from all
        // events even in standard fields — and from explicit learns.
        let s = session()
        typeThrough(s, "jokull@triptojapan.com ")
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
        s.noteVerbatimChoice("tilvinstri.is")
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
        XCTAssertFalse(s.engine.isPersonalWord("tilvinstri.is"))
    }

    func testPreviousWordFailingValidationIsDroppedNotTheEvent() {
        let s = session()
        typeThrough(s, "1234 hestur ")
        let events = s.drainLearningEvents()
        XCTAssertEqual(events.count, 1)
        guard case .wordCommitted(let word, let previous, _) = events[0] else {
            return XCTFail("expected wordCommitted, got \(events)")
        }
        XCTAssertEqual(word, "hestur")
        XCTAssertNil(previous, "digit-only predecessor must be dropped")
    }

    // MARK: - Lifecycle

    func testResetClearsPendingEventsAndOverlay() {
        let s = session()
        typeThrough(s, "hestur ")
        s.noteVerbatimChoice("kubbur")
        XCTAssertTrue(s.hasPendingLearningEvents)
        s.reset()
        XCTAssertFalse(s.hasPendingLearningEvents)
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
        XCTAssertFalse(s.engine.isPersonalWord("kubbur"))
    }

    func testDrainClearsTheBuffer() {
        let s = session()
        typeThrough(s, "hestur ")
        XCTAssertFalse(s.drainLearningEvents().isEmpty)
        XCTAssertTrue(s.drainLearningEvents().isEmpty)
    }
}
