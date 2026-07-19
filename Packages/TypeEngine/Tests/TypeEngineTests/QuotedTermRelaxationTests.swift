import XCTest

@testable import TypeEngine

/// Quoted-term relaxation (GitHub issue #3): a token typed immediately
/// after an opening double quote („ / " / ") is often a deliberate
/// foreign/technical term — suggestions stay offered (tap-only), but the
/// auto-apply flag is stripped so nothing force-replaces a quoted token
/// (dogfood: „vold [c→v miss for "cold"] auto-applied to „völd).
final class QuotedTermRelaxationTests: XCTestCase {

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

    // MARK: - Context predicate

    func testQuotedTermContextDetection() {
        // Immediately after any of the three opening quotes: quoted term.
        XCTAssertTrue(TypingSession.isQuotedTermContext("„"))
        XCTAssertTrue(TypingSession.isQuotedTermContext("\""))
        XCTAssertTrue(TypingSession.isQuotedTermContext("\u{201C}"))
        XCTAssertTrue(TypingSession.isQuotedTermContext("sagði „"))
        // No quote, or a quote NOT immediately before the token: normal.
        XCTAssertFalse(TypingSession.isQuotedTermContext(""))
        XCTAssertFalse(TypingSession.isQuotedTermContext("hestur "))
        XCTAssertFalse(TypingSession.isQuotedTermContext("„orð\u{201C} "))
    }

    // MARK: - End-to-end through a session

    func testQuotedTokenGetsSuggestionsButNoAutocorrect() {
        // "teh" reliably arms autocorrect from a fresh session (see
        // TypingSessionTests.testStandardFieldStillAutocorrects); inside
        // Icelandic quotes the same token must keep its suggestions but
        // lose the auto-apply flag — offer, don't force.
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "„teh")
        XCTAssertTrue(
            bar.contains { !$0.isVerbatim },
            "quoted token must still be OFFERED suggestions, bar: \(bar.map(\.text))"
        )
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "no auto-apply inside quotes, bar: \(bar.map(\.text))"
        )
    }

    func testSameTokenWithoutQuoteKeepsAutocorrect() {
        // Control for the test above: the identical token with no preceding
        // quote arms autocorrect exactly as before — the relaxation is
        // adjacency-gated, not a global weakening.
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "teh")
        XCTAssertTrue(
            bar.contains { $0.isAutocorrect },
            "unquoted token must keep normal autocorrect, bar: \(bar.map(\.text))"
        )
    }

    func testStraightQuoteBehavesLikeIcelandicQuote() {
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "\"teh")
        XCTAssertTrue(bar.contains { !$0.isVerbatim })
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "no auto-apply after a straight quote, bar: \(bar.map(\.text))"
        )
    }

    func testCurlyQuoteBehavesLikeIcelandicQuote() {
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "\u{201C}teh")
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "no auto-apply after a curly opening quote, bar: \(bar.map(\.text))"
        )
    }

    func testQuoteEarlierInSentenceDoesNotSuppress() {
        // A quotation CLOSED earlier in the sentence must not relax the
        // next token: „with" commits the quoted word, then "teh" after the
        // space arms autocorrect normally (the "with the" fixture bigram
        // backs the correction — a bare "teh" after an unrelated previous
        // word does not arm even without quotes, so the control must be
        // context-supported). Only quote ADJACENCY suppresses.
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "„with\u{201C} teh")
        XCTAssertTrue(
            bar.contains { $0.isAutocorrect },
            "token after a closed quotation must autocorrect normally, bar: \(bar.map(\.text))"
        )
    }

    func testOpenQuotationEarlierInSentenceDoesNotSuppressLaterWords() {
        // Inside a still-open quotation only the FIRST token sits right
        // after the quote; the second word („with teh — context ends with
        // the space) corrects normally. The relaxation is per-token
        // adjacency, not a quotation-spanning mode.
        let s = TypingSession(engine: Fixtures.engine())
        let bar = typeThrough(s, "„with teh")
        XCTAssertTrue(
            bar.contains { $0.isAutocorrect },
            "second word of a quotation must autocorrect normally, bar: \(bar.map(\.text))"
        )
    }
}
