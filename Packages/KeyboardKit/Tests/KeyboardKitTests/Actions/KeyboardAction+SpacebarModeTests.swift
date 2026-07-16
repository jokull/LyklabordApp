//
//  KeyboardAction+SpacebarModeTests.swift
//  KeyboardKit
//
//  Sequencing coverage for the better-keyboard fork's PLAN.md "Spacebar
//  behavior — three user-selectable modes", extending the mirror-test
//  pattern in `KeyboardAction+SpaceSequencingTests.swift`. Everything runs
//  through `StandardActionHandler.handle(_:on:)` — the exact entry point
//  `Keyboard.ButtonGestures` calls for every real key release.
//
//  Why mirror tests: the production interceptors live in the app-extension
//  target (`KeyboardExt/`, `BetterKeyboardActionHandler` +
//  `BetterKeyboardAutocompleteService`), which the KeyboardKit package test
//  target cannot import. So this file verifies the *KeyboardKit mechanisms*
//  those modes are built on, plus a faithful local mirror of the mode-2
//  space interception, at the same `handle(_:on:)` granularity that runs on
//  device:
//
//   - Mode 3 ("always insert a space") is implemented in the service by
//     demoting `.autocorrect` suggestions to `.regular`. We assert the
//     downstream fact that makes that work: a `.regular` suggestion is NOT
//     auto-applied on space, while an `.autocorrect` one is (mode 1). Nothing
//     mode-3-specific is needed in the handler because of this.
//   - Mode 2 ("always insert a prediction") is implemented in the handler.
//     `Mode2MirrorHandler` below reproduces the production logic verbatim
//     (insert the top bar prediction before the space when no word is in
//     progress) so we can exercise its sequencing and its guards.
//

#if os(iOS) || os(tvOS)
import KeyboardKit
import XCTest

final class KeyboardAction_SpacebarModeTests: XCTestCase {

    private var controller: MockKeyboardInputViewController!
    private var textDocumentProxy: MockTextDocumentProxy!

    override func setUp() {
        controller = MockKeyboardInputViewController()
        textDocumentProxy = MockTextDocumentProxy()
        textDocumentProxy.documentContextBeforeInput = ""

        let state = controller.state
        state.feedbackContext.settings.isAudioFeedbackEnabled = false
        state.feedbackContext.settings.isHapticFeedbackEnabled = false
        state.keyboardContext.locale = .init(identifier: "is")
        state.keyboardContext.originalTextDocumentProxy = textDocumentProxy
        // Make sure the space action's `controller.insertText(" ")` lands on
        // the same mock we assert against (the space gesture inserts via the
        // controller, the prediction/autocorrect via the context proxy).
        controller.textDocumentProxyReplacement = textDocumentProxy
    }

    private func insertedTexts() -> [String] {
        textDocumentProxy
            .registeredCalls(for: textDocumentProxy.insertTextRef)
            .map(\.arguments)
    }

    // MARK: - Mode 3 mechanism ("always insert a space")

    /// Mode 3 demotes every `.autocorrect` suggestion to `.regular` in the
    /// service bridge. This asserts the mechanism that makes that suppress
    /// the commit: a `.regular` suggestion is NEVER auto-applied on a space —
    /// the space just inserts, the mistyped word is left verbatim, and the
    /// user's only path to the correction is tapping the bar (PLAN.md mode 3).
    func testRegularSuggestionIsNotAutoAppliedOnSpace() {
        let handler = KeyboardAction.StandardActionHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "helo"
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "hello", type: .regular)
        ]

        handler.handle(.release, on: .space)

        XCTAssertEqual(
            textDocumentProxy.documentContextBeforeInput, "helo",
            "a regular (non-autocorrect) suggestion must not delete/replace the typed word"
        )
        XCTAssertFalse(
            textDocumentProxy.hasCalled(\.deleteBackwardRef),
            "mode 3 must not commit a correction on space"
        )
        XCTAssertFalse(
            insertedTexts().contains("hello"),
            "mode 3 must not insert the correction on space; got \(insertedTexts())"
        )
        XCTAssertTrue(insertedTexts().contains(" "), "the space itself must still be inserted")
    }

    /// The contrast case (mode 1 / mode 2 keep the autocorrect type): the
    /// SAME word + suggestion, but typed `.autocorrect`, IS committed on
    /// space. This is exactly what mode 3's demotion turns off.
    func testAutocorrectSuggestionIsAppliedOnSpace() {
        let handler = KeyboardAction.StandardActionHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "helo"
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "hello", type: .autocorrect)
        ]

        handler.handle(.release, on: .space)

        XCTAssertNotEqual(textDocumentProxy.documentContextBeforeInput, "helo")
        XCTAssertTrue(textDocumentProxy.hasCalled(\.deleteBackwardRef))
        XCTAssertTrue(
            insertedTexts().contains("hello"),
            "mode 1/2 must commit the autocorrect suggestion on space; got \(insertedTexts())"
        )
    }

    // MARK: - Mode 2 sequencing ("always insert a prediction")

    /// No word in progress (buffer ends in a space) + a prediction in the
    /// bar: space injects the prediction, THEN the space — "sentence by
    /// spacebar". No correction/delete happens.
    func testModeTwoInsertsPredictionThenSpaceWhenNoWordInProgress() {
        let handler = Mode2MirrorHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "halló "
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "heimur", type: .regular),
            .init(text: "vinur", type: .regular)
        ]

        handler.handle(.release, on: .space)

        let inserted = insertedTexts()
        XCTAssertEqual(
            inserted.firstIndex(of: "heimur"), 0,
            "the top prediction must be inserted first; got \(inserted)"
        )
        XCTAssertTrue(inserted.contains(" "), "the space must follow the prediction; got \(inserted)")
        XCTAssertFalse(
            textDocumentProxy.hasCalled(\.deleteBackwardRef),
            "inserting a prediction on a fresh word must not delete anything"
        )
    }

    /// Empty bar → mode 2 falls back to a plain space (no word inserted, no
    /// deletion). Guards the "falling back to a plain space when the bar is
    /// empty" requirement.
    func testModeTwoFallsBackToPlainSpaceWhenBarEmpty() {
        let handler = Mode2MirrorHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "halló "
        handler.autocompleteContext.suggestionsFromService = []

        handler.handle(.release, on: .space)

        let inserted = insertedTexts()
        XCTAssertEqual(inserted, [" "], "empty bar must insert exactly one plain space; got \(inserted)")
        XCTAssertFalse(textDocumentProxy.hasCalled(\.deleteBackwardRef))
    }

    /// Word IN progress → mode 2 must NOT inject a prediction; the ordinary
    /// mid-word autocorrect-on-space (mode 1) path runs instead. This is the
    /// "never double-fires with mode-1 commit" guard: the two conditions
    /// (word in progress vs. not) are mutually exclusive, so a mid-word space
    /// still commits the autocorrect and nothing gets inserted twice.
    func testModeTwoDoesNotFireMidWordAndLeavesAutocorrectIntact() {
        let handler = Mode2MirrorHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "hel"
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "hello", type: .autocorrect)
        ]

        handler.handle(.release, on: .space)

        let inserted = insertedTexts()
        XCTAssertTrue(
            textDocumentProxy.hasCalled(\.deleteBackwardRef),
            "mid-word space must still commit the autocorrect (mode-1 path)"
        )
        XCTAssertEqual(
            inserted.filter { $0 == "hello" }.count, 1,
            "the corrected word must be inserted exactly once (no mode-2 double-fire); got \(inserted)"
        )
    }

    /// The verbatim quoted slot (`.unknown`) and emoji suggestions are never
    /// chosen as the mode-2 prediction — only the primary regular prediction
    /// is. Guards `spacePrediction()`'s skip filter.
    func testModeTwoSkipsVerbatimAndEmojiSuggestions() {
        let handler = Mode2MirrorHandler(controller: controller)
        textDocumentProxy.documentContextBeforeInput = "halló "
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "halló", type: .unknown),   // quoted verbatim escape hatch
            .init(text: "😀", type: .emoji),
            .init(text: "heimur", type: .regular)   // the real prediction
        ]

        handler.handle(.release, on: .space)

        let inserted = insertedTexts()
        XCTAssertEqual(inserted.first, "heimur", "must skip the verbatim + emoji slots; got \(inserted)")
    }
}

// MARK: - Mode-2 mirror handler

/// Faithful in-test reproduction of `BetterKeyboardActionHandler`'s spacebar
/// mode-2 interception (`KeyboardExt/KeyboardViewController.swift`). Kept in
/// lockstep with that production code: on a `.space` release with no word in
/// progress, inject the top non-verbatim/non-emoji prediction before letting
/// `super` insert the space. The production field-kind gate
/// (URL/email/secure) is omitted here — `MockTextDocumentProxy` can't vary
/// its field traits — and is exercised via the shared `fieldKind(for:)`
/// mapping used across the correction pipeline instead.
private final class Mode2MirrorHandler: KeyboardAction.StandardActionHandler {

    override func handle(
        _ gesture: Keyboard.Gesture,
        on action: KeyboardAction,
        replaced: Bool
    ) {
        if gesture == .release, action == .space, shouldInsertSpacePrediction(),
            let prediction = spacePrediction()
        {
            keyboardContext.textDocumentProxy.insertText(prediction)
        }
        super.handle(gesture, on: action, replaced: replaced)
    }

    private func shouldInsertSpacePrediction() -> Bool {
        if spaceDragGestureHandler.currentDragTextPositionOffset != 0 { return false }
        let before = keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        return before.isEmpty || before.hasSuffix(" ")
    }

    private func spacePrediction() -> String? {
        autocompleteContext.suggestions.first {
            !$0.isUnknown && $0.type != .emoji && !$0.text.isEmpty
        }?.text
    }
}
#endif
