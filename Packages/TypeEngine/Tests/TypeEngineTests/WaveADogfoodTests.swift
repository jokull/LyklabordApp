import XCTest

@testable import TypeEngine

/// Wave A dogfood fixes (GitHub issues #6, #8, #9).
final class WaveADogfoodTests: XCTestCase {

    // MARK: - Issue #6: corrections must not eat non-word prefixes

    func testLeadingSymbolTokensAreVerbatimClass() {
        XCTAssertTrue(TypingSession.isVerbatimClassToken("/goal"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("#tag"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("~heim"))
        XCTAssertTrue(TypingSession.isVerbatimClassToken("-flag"))
        // Ordinary words and numbers are untouched.
        XCTAssertFalse(TypingSession.isVerbatimClassToken("goal"))
        XCTAssertFalse(TypingSession.isVerbatimClassToken("hestur"))
        XCTAssertFalse(TypingSession.isVerbatimClassToken("21"))
    }

    func testTrailingSegmentSplitsAfterAnyNonWordCharacter() {
        XCTAssertEqual(TypingSession.trailingSegment(of: "/goal"), "goal")
        XCTAssertEqual(TypingSession.trailingSegment(of: "#tag"), "tag")
        XCTAssertEqual(TypingSession.trailingSegment(of: "profilmynd.tilvinstri"), "tilvinstri")
        XCTAssertEqual(TypingSession.trailingSegment(of: "jokull@solberg"), "solberg")
        XCTAssertEqual(TypingSession.trailingSegment(of: "hestur"), "hestur")
    }

    func testDoubleQuotesAreDelimiters() {
        // „orð tokenizes as orð — the quote is not part of the token, so the
        // word inside quotes corrects/completes normally (and the engine can
        // never "correct" the quote away).
        XCTAssertEqual(TypingSession.splitCurrentWord(of: "„orð").currentWord, "orð")
        XCTAssertEqual(TypingSession.splitCurrentWord(of: "\"orð").currentWord, "orð")
        XCTAssertEqual(TypingSession.splitCurrentWord(of: "sagði \u{201C}orð").currentWord, "orð")
        // Apostrophes stay word-internal (English contractions).
        XCTAssertEqual(TypingSession.splitCurrentWord(of: "don't").currentWord, "don't")
    }

    // MARK: - Issue #9: patronymic title-casing after a capitalized word

    func testPatronymicShape() {
        XCTAssertTrue(TypingSession.isPatronymic("jakobsdóttir"))
        XCTAssertTrue(TypingSession.isPatronymic("jónsson"))
        XCTAssertTrue(TypingSession.isPatronymic("Pétursdóttir"))
        // English -son words must NOT match (season/person/reason).
        XCTAssertFalse(TypingSession.isPatronymic("season"))
        XCTAssertFalse(TypingSession.isPatronymic("person"))
        XCTAssertFalse(TypingSession.isPatronymic("reason"))
        XCTAssertFalse(TypingSession.isPatronymic("hestur"))
    }

    func testTitleCasesPatronymicAfterCapitalizedWord() {
        let out = TypingSession.titleCaseNameSuggestions(
            [
                Suggestion(text: "jakobsdóttir", isAutocorrect: false, confidence: 0.5),
                Suggestion(text: "sagði", isAutocorrect: false, confidence: 0.4),
            ],
            context: "Katrín "
        )
        XCTAssertEqual(out.map(\.text), ["Jakobsdóttir", "sagði"])
    }

    func testNoTitleCaseAfterLowercaseWord() {
        let out = TypingSession.titleCaseNameSuggestions(
            [Suggestion(text: "jakobsdóttir", isAutocorrect: false, confidence: 0.5)],
            context: "hún "
        )
        XCTAssertEqual(out.map(\.text), ["jakobsdóttir"])
    }

    func testVerbatimSlotKeepsTypedCasing() {
        let out = TypingSession.titleCaseNameSuggestions(
            [Suggestion(text: "jakobsdóttir", isAutocorrect: false, confidence: 0, isVerbatim: true)],
            context: "Katrín "
        )
        XCTAssertEqual(out.map(\.text), ["jakobsdóttir"])
    }

    // MARK: - Issue #8: numeric guard (end-to-end through a session)

    func testDigitLeadingTokenGetsNoLetterSuggestions() {
        let session = TypingSession(engine: Fixtures.engine())
        // Simulate having typed "21.000," then "5": current token is "5".
        let suggestions = session.suggestions(for: "kostar 21.000,5", limit: 4)
        for suggestion in suggestions where !suggestion.isVerbatim {
            XCTAssertTrue(
                suggestion.text.allSatisfy { $0.isNumber || ".,:".contains($0) },
                "letter suggestion \(suggestion.text) offered inside a number"
            )
        }
    }
}
