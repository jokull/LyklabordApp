import XCTest

@testable import TypeEngine

/// Suggestions honor the casing of the typed token (live-session diagnosis
/// 2026-08-19: typing in caps lock, "HESTU" produced title-cased
/// "Hestur"/"Hesti" suggestions instead of "HESTUR"/"HESTI").
final class CasingHonoringTests: XCTestCase {

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

    /// `Fixtures.engine()` + an injected personal snapshot (mirrors
    /// `PersonalVocabularyTests.engine(personal:)`).
    private func engine(personal: FakePersonal) -> TypeEngine {
        let engine = Fixtures.engine()
        engine.setPersonalVocabulary(personal)
        return engine
    }

    // MARK: - Pattern classification

    func testCasingPatternClassification() {
        XCTAssertEqual(TypeEngine.casingPattern(of: "HESTU"), .allCaps)
        XCTAssertEqual(TypeEngine.casingPattern(of: "KATRÍN"), .allCaps)
        XCTAssertEqual(TypeEngine.casingPattern(of: "ÉG"), .allCaps)
        XCTAssertEqual(TypeEngine.casingPattern(of: "Hestu"), .titleCase)
        XCTAssertNil(TypeEngine.casingPattern(of: "hestu"))
        // "McDonald" classifies titleCase, but the transform only uppercases
        // the first letter and preserves the tail byte-exact, so interior
        // caps in suggestions survive (and this matches the pre-fix
        // leading-cap behavior exactly).
        XCTAssertEqual(TypeEngine.casingPattern(of: "McDonald"), .titleCase)
        // Digit-leading and first-letter-lowercase tokens carry no pattern.
        XCTAssertNil(TypeEngine.casingPattern(of: "iPhone"))
        XCTAssertNil(TypeEngine.casingPattern(of: "5G"))
        // Single letters ("I") carry no pattern to copy.
        XCTAssertNil(TypeEngine.casingPattern(of: "I"))
    }

    // MARK: - Bar behavior through a session

    func testAllCapsTypingUppercasesSuggestions() {
        let out = typeThrough(session(), "HESTU")
        XCTAssertEqual(out.map(\.text), ["HESTU", "HESTUR", "HESTI"])
    }

    func testAllCapsTypingOfValidWordStaysAllCaps() {
        // "borða" is valid; typed all-caps, the bar must show the caps
        // form, not a title-cased one.
        let out = typeThrough(session(), "BORÐA")
        XCTAssertEqual(out.map(\.text), ["BORÐA"])
    }

    func testTitleCaseTypingKeepsLeadingCapital() {
        let out = typeThrough(session(), "Hestu")
        XCTAssertEqual(out.map(\.text), ["Hestu", "Hestur", "Hesti"])
    }

    func testLowercaseTypingStaysLowercase() {
        let out = typeThrough(session(), "hestu")
        XCTAssertEqual(out.map(\.text), ["hestu", "hestur", "hesti"])
    }

    // MARK: - Caps-lock carry-over into next-word prediction

    func testNextWordPredictionAfterAllCapsWordIsUppercased() {
        // Caps-lock mode: "KATRÍN " committed, the bar predicts the next
        // word in the same case.
        let out = typeThrough(session(), "KATRÍN ")
        XCTAssertEqual(out.map(\.text), ["OG", "AÐ", "ER"])
    }

    func testNextWordPredictionAfterTitleCaseWordStaysLowercase() {
        // A normal capitalized word ("Katrín ") is not caps-lock: the
        // predictions keep the pipeline casing.
        let out = typeThrough(session(), "Katrín ")
        XCTAssertEqual(out.map(\.text), ["og", "að", "er"])
    }

    func testNextWordPredictionWithNoContextIsUnchanged() {
        let out = session().suggestions(for: "", limit: 3)
        XCTAssertEqual(out.map(\.text), ["og", "að", "er"])
    }

    // MARK: - Restored interior-caps surfaces (curated "ChatGPT" style)

    func testAllCapsTypingUppercasesRestoredInteriorCapsSurface() {
        // The personal surface "ChatGPT" is restored by the pipeline, then
        // the all-caps typed token must win: caps-lock typing is deliberate.
        // (Typing the exact word "CHATGPT" yields no engine suggestions at
        // all — a valid typed word is never "corrected" — so drive the
        // restoration through a prefix completion instead.)
        let e = engine(personal: FakePersonal(words: ["ChatGPT": 8]))
        let bar = e.suggestions(context: "", currentWord: "CHATGP", limit: 5)
        XCTAssertTrue(bar.contains { $0.text == "CHATGPT" }, "bar: \(bar.map(\.text))")
    }

    func testTitleCaseTypingKeepsRestoredInteriorCapsSurface() {
        // A leading-cap typed token re-applies only the leading capital and
        // preserves the restored surface's tail byte-exact ("ChatGPT" must
        // not degrade to "Chatgpt").
        let e = engine(personal: FakePersonal(words: ["ChatGPT": 8]))
        let bar = e.suggestions(context: "", currentWord: "Chatgp", limit: 5)
        XCTAssertTrue(bar.contains { $0.text == "ChatGPT" }, "bar: \(bar.map(\.text))")
    }
}
