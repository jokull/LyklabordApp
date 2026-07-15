//
//  KeyboardAction+SpaceSequencingTests.swift
//  KeyboardKit
//
//  End-to-end coverage for the better-keyboard fork's PLAN.md "Bottom-row
//  affordances" / "Spacebar behavior" sections, driven through
//  `KeyboardAction.StandardActionHandler.handle(_:on:)` — the same entry
//  point `Keyboard.ButtonGestures` calls for every real key tap/release.
//
//  Two things are under test here, both already built into vendored
//  KeyboardKit 9.9.1 (no new production code needed — see the
//  "Double-space → '. '" note in
//  `KeyboardExt/KeyboardViewController.swift`):
//
//   1. Double-tapping space after a word ends the sentence with ". "
//      (`Keyboard.StandardKeyboardBehavior.shouldEndCurrentSentence` +
//      `StandardActionHandler.tryEndCurrentSentence`).
//   2. That doesn't regress PLAN.md's spacebar mode 1 (space commits a
//      pending autocorrect suggestion first) and doesn't fire on a single
//      space tap.
//
//  `Keyboard_StandardKeyboardBehaviorTests
//  .testShouldEndSentenceOnlyForSpaceAfterPreviousSpace` already covers the
//  `shouldEndCurrentSentence` predicate in isolation; this file exercises
//  the full `handle(_:on:)` sequencing instead, which is what actually runs
//  on device.
//

#if os(iOS) || os(tvOS)
import KeyboardKit
import XCTest

final class KeyboardAction_SpaceSequencingTests: XCTestCase {

    private var handler: KeyboardAction.StandardActionHandler!
    private var controller: MockKeyboardInputViewController!
    private var textDocumentProxy: MockTextDocumentProxy!

    override func setUp() {
        controller = MockKeyboardInputViewController()
        textDocumentProxy = MockTextDocumentProxy()
        textDocumentProxy.documentContextBeforeInput = ""

        let state = controller.state
        state.feedbackContext.settings.isAudioFeedbackEnabled = false
        state.feedbackContext.settings.isHapticFeedbackEnabled = false
        state.keyboardContext.locale = .english
        state.keyboardContext.originalTextDocumentProxy = textDocumentProxy

        handler = KeyboardAction.StandardActionHandler(controller: controller)
    }

    /// Simulates the release of the *second* of two space taps: by the
    /// time a real `GestureButton` fires its `doubleTapAction`/second
    /// `releaseAction`, the first tap's release has already inserted one
    /// space into the document. We model that by seeding the proxy with
    /// the trailing-two-spaces state the buffer would already be in.
    func testDoubleSpaceAfterWordEndsSentenceWithPeriodAndSpace() {
        textDocumentProxy.documentContextBeforeInput = "word  "

        handler.handle(.release, on: .space)

        XCTAssertEqual(
            textDocumentProxy.documentContextBeforeInput, "word",
            "both trailing spaces must be deleted before ' . ' is inserted"
        )
        XCTAssertTrue(textDocumentProxy.hasCalled(\.insertTextRef))
        let insertedTexts = textDocumentProxy.registeredCalls(for: textDocumentProxy.insertTextRef).map(\.arguments)
        XCTAssertTrue(insertedTexts.contains(". "), "expected '. ' among the inserted texts, got \(insertedTexts)")
    }

    func testSingleSpaceAfterWordDoesNotEndTheSentence() {
        textDocumentProxy.documentContextBeforeInput = "word "

        handler.handle(.release, on: .space)

        // No sentence-ending deletion should have happened: a single
        // trailing space is not "closable" (`shouldEndCurrentSentence`
        // requires the buffer to already end with two spaces).
        XCTAssertEqual(textDocumentProxy.documentContextBeforeInput, "word ")
        let insertedTexts = textDocumentProxy.registeredCalls(for: textDocumentProxy.insertTextRef).map(\.arguments)
        XCTAssertFalse(insertedTexts.contains(". "), "a single space tap must never insert a period")
    }

    /// PLAN.md "Spacebar behavior" mode 1: mid-word, space commits the
    /// pending autocorrect suggestion *before* inserting a plain space —
    /// this must keep working once double-space/period handling is in the
    /// same `handle(_:on:)` call chain.
    func testSpaceStillCommitsPendingAutocorrectSuggestionMidWord() {
        textDocumentProxy.documentContextBeforeInput = "helo"
        handler.autocompleteContext.suggestionsFromService = [
            .init(text: "hello", type: .autocorrect)
        ]

        handler.handle(.release, on: .space)

        // The mis-typed word must have been deleted (autocorrect commit)
        // and the corrected suggestion inserted in its place — this is the
        // ordinary mode-1 autocorrect-on-space path, untouched by the
        // double-space/period change.
        XCTAssertNotEqual(textDocumentProxy.documentContextBeforeInput, "helo")
        XCTAssertTrue(textDocumentProxy.hasCalled(\.deleteBackwardRef))
        let insertedTexts = textDocumentProxy.registeredCalls(for: textDocumentProxy.insertTextRef).map(\.arguments)
        XCTAssertTrue(insertedTexts.contains("hello"), "expected the autocorrect suggestion 'hello' to be inserted, got \(insertedTexts)")
        XCTAssertFalse(insertedTexts.contains(". "), "a mid-word space must not also trigger sentence-ending")
    }
}
#endif
