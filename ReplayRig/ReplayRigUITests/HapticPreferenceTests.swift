//
//  HapticPreferenceTests.swift
//  ReplayRigUITests
//

import KeyboardKit
import XCTest

final class HapticPreferenceTests: XCTestCase {

    func testDisabledSettingSuppressesSpaceLongPress() {
        let controller = KeyboardInputViewController()
        let settings = controller.state.feedbackContext.settings
        let original = settings.isHapticFeedbackEnabled
        defer {
            controller.state.feedbackContext.settings.isHapticFeedbackEnabled = original
        }

        let handler = KeyboardAction.StandardActionHandler(controller: controller)
        controller.state.feedbackContext.settings.isHapticFeedbackEnabled = false
        XCTAssertFalse(
            handler.shouldTriggerHapticFeedback(for: .longPress, on: .space)
        )

        controller.state.feedbackContext.settings.isHapticFeedbackEnabled = true
        XCTAssertTrue(
            handler.shouldTriggerHapticFeedback(for: .longPress, on: .space)
        )
    }

    func testDisabledSettingSuppressesCalloutSelectionFeedback() {
        let keyboardContext = KeyboardContext()
        let feedbackContext = FeedbackContext()
        let original = feedbackContext.settings.isHapticFeedbackEnabled
        defer {
            feedbackContext.settings.isHapticFeedbackEnabled = original
        }
        let feedbackService = CountingFeedbackService()
        let service = Callouts.StandardCalloutService(
            keyboardContext: keyboardContext,
            feedbackContext: feedbackContext,
            feedbackService: feedbackService
        )

        feedbackContext.settings.isHapticFeedbackEnabled = false
        service.triggerFeedbackForSelectionChange()
        XCTAssertEqual(feedbackService.hapticCount, 0)

        feedbackContext.settings.isHapticFeedbackEnabled = true
        service.triggerFeedbackForSelectionChange()
        XCTAssertEqual(feedbackService.hapticCount, 1)
    }
}

private final class CountingFeedbackService: FeedbackService {
    private(set) var hapticCount = 0

    func triggerAudioFeedback(_ feedback: Feedback.Audio) {}

    func triggerHapticFeedback(_ feedback: Feedback.Haptic) {
        hapticCount += 1
    }
}
