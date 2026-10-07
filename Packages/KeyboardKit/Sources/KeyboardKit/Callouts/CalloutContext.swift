//
//  CalloutContext.swift
//  KeyboardKit
//
//  Created by Daniel Saidi on 2023-01-24.
//  Copyright © 2021-2025 Daniel Saidi. All rights reserved.
//

import Combine
import SwiftUI

/// This context has observable callout-related state and is
/// used for both input and action callouts.
///
/// KeyboardKit will create an instance of this context, and
/// inject into the environment, when you set up KeyboardKit
/// as shown in <doc:Getting-Started-Article>.
public class CalloutContext: ObservableObject {

    /// Create a keyboard callout context.
    public init() {}


    /// The coordinate space to use for callout.
    public let coordinateSpace = "com.keyboardkit.coordinate.callout"


    @available(*, deprecated, message: "Inject actions with the .keyboardCalloutActions view modifier instead.")
    public var calloutService: CalloutService? {
        get { _calloutService }
        set { _calloutService = newValue }
    }
    var _calloutService: CalloutService?

    /// The scale to apply if the items must be compressed.
    public var compressedWidthScale = 0.85
    
    /// The scale to apply to drag selection index changes.
    public var dragIndexScaleFactor = 0.8

    /// The last time an input was updated.
    public var lastInputUpdate = Date()

    /// The minimum input callout duration.
    public var minimumInputDuration: TimeInterval = 0.05

    /// The action handler to use when tapping actions.
    public var actionHandler: (KeyboardAction) -> Void = { _ in }


    /// The currently active button frame.
    @Published public private(set) var buttonFrame: CGRect = .zero

    /// The current input action, if any.
    @Published public private(set) var inputAction: KeyboardAction?

    /// The current secondary actions.
    @Published public private(set) var secondaryActions: [KeyboardAction] = []

    /// The current secondary action callout alignment.
    @Published public private(set) var secondaryActionsAlignment: HorizontalAlignment = .leading

    /// The current secondary action index.
    @Published public private(set) var secondaryActionsIndex: Int = -1
}

public extension CalloutContext {

    var selectedSecondaryAction: KeyboardAction? {
        let index = secondaryActionsIndex
        return isSecondaryActionIndexValid(index) ? secondaryActions[index] : nil
    }

    @discardableResult
    func handleSelectedSecondaryAction() -> Bool {
        guard let action = selectedSecondaryAction else { return false }
        // LyklaborÃ° fork: mark the action as callout-selected before
        // it reaches the action handler — the deliberateness signal for
        // TypeEngine (long-pressed characters veto lane folding), and the
        // cue NOT to attribute the base key's touch point to this
        // character. See Keyboard.TouchEvidence.
        Keyboard.TouchEvidence.noteCalloutSelection(action)
        actionHandler(action)
        resetSecondaryActions()
        return true
    }

    /// Reset the input action. This will remove the callout.
    func resetInputAction() {
        inputAction = nil
    }

    /// Reset the context with a slight delay, since we want
    /// the callout to be visible for a short while, even if
    /// the user immediately releases the button.
    func resetInputActionWithDelay() {
        let delay = minimumInputDuration
        let date = Date()
        lastInputUpdate = date
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.lastInputUpdate > date { return }
            self.resetInputAction()
        }
    }

    /// Reset the context. This will dismiss the callout.
    func resetSecondaryActions() {
        secondaryActions = []
        secondaryActionsIndex = -1
    }

    /// Update the current input for a certain action.
    func updateInputAction(
        _ action: KeyboardAction?,
        in geo: GeometryProxy
    ) {
        if action?.inputCalloutText == nil { return }
        lastInputUpdate = Date()
        inputAction = action
        buttonFrame = geo.frame(in: .named(coordinateSpace))
    }

    /// Update the secondary actions for a certain action.
    func updateSecondaryActions(
        _ actions: [KeyboardAction]?,
        for action: KeyboardAction,
        in geo: GeometryProxy,
        alignment: HorizontalAlignment? = nil
    ) {
        let actions = actions ?? _calloutService?.calloutActions(for: action)
        guard let actions else { return }
        buttonFrame = geo.frame(in: .named(coordinateSpace))
        secondaryActionsAlignment = alignment ?? resolveSecondaryActionAlignment(for: geo)
        secondaryActions = isLeading ? actions : actions.reversed()
        secondaryActionsIndex = secondaryActionStartIndex
        guard !secondaryActions.isEmpty else { return }
        triggerSelectionChangeFeedback()
    }

    #if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
    /// Update the secondary action selection with a drag gesture value.
    func updateSecondaryActionsSelection(
        with value: GestureButtonDragValue
    ) {
        guard buttonFrame != .zero else { return }
        if shouldResetSecondaryActions(for: value.translation) { return resetSecondaryActions() }
        guard shouldUpdateSecondaryActionSelection(for: value.translation) else { return }
        let standardStyle = Callouts.CalloutStyle.standard
        let maxButtonSize = standardStyle.actionItemMaxSize
        let buttonSize = buttonFrame.size.limited(to: maxButtonSize)
        guard buttonSize.width > 1 else { return }
        let currentIndex = self.secondaryActionsIndex
        // LyklaborÃ° fork: when the drag lands PAST the callout's item
        // range, deselect (index -1) so a release commits nothing — instead
        // of upstream's clamp back to `secondaryActionStartIndex`, which
        // re-selects the base character and inserts it on release. The clamp
        // is invisible for a letter key (the natural "drag away to cancel"
        // is a downward swipe, handled earlier by `shouldResetSecondaryActions`
        // — `dragTranslation.height > buttonFrame.height`), but a BOTTOM-ROW
        // key (our SwiftKey-style `.` between space and return) has no room
        // below it, so that downward-reset is unreachable and the horizontal
        // drag-out was the ONLY exit — and it wrongly committed. Clearing on
        // out-of-range aligns the bottom-row key with the letter-key path and
        // mirrors iOS (drag past the callout ends → no insertion).
        // `Self.resolvedSecondaryActionIndex` is the pure, unit-tested seam.
        let index = Self.resolvedSecondaryActionIndex(
            locationX: value.location.x,
            buttonWidth: buttonSize.width,
            dragIndexScaleFactor: dragIndexScaleFactor,
            actionCount: secondaryActions.count,
            isLeading: isLeading
        )
        let newIndex = index ?? -1
        if currentIndex != newIndex { triggerSelectionChangeFeedback() }
        self.secondaryActionsIndex = newIndex
    }

    /// Map a drag x-location onto a secondary-action index, returning `nil`
    /// when the drag lands outside the callout's item range (the far-drag-out
    /// dismissal — see `updateSecondaryActionsSelection(with:)`). Pure and
    /// geometry-free so it can be unit-tested without a `GeometryProxy`.
    static func resolvedSecondaryActionIndex(
        locationX: CGFloat,
        buttonWidth: CGFloat,
        dragIndexScaleFactor: Double,
        actionCount: Int,
        isLeading: Bool
    ) -> Int? {
        guard buttonWidth > 1, actionCount > 0 else { return nil }
        let indexWidth = max(20, dragIndexScaleFactor * buttonWidth)
        let offset = isLeading ? Int(locationX / indexWidth) : Int(abs(locationX - indexWidth) / indexWidth)
        let index = isLeading ? offset : actionCount - offset - 1
        return (index >= 0 && index < actionCount) ? index : nil
    }
    #endif
}

extension CalloutContext {

    func triggerSelectionChangeFeedback() {
        _calloutService?.triggerFeedbackForSelectionChange()
    }
}

private extension CalloutContext {

    var isLeading: Bool {
        secondaryActionsAlignment == .leading
    }

    var secondaryActionStartIndex: Int {
        isLeading ? 0 : secondaryActions.count - 1
    }

    func isSecondaryActionIndexValid(
        _ index: Int
    ) -> Bool {
        index >= 0 && index < secondaryActions.count
    }

    func resolveSecondaryActionAlignment(
        for geo: GeometryProxy
    ) -> HorizontalAlignment {
        #if os(iOS)
        let center = UIScreen.main.bounds.size.width / 2
        let isTrailing = buttonFrame.origin.x > center
        return isTrailing ? .trailing : .leading
        #else
        return .leading
        #endif
    }

    func shouldResetSecondaryActions(
        for dragTranslation: CGSize
    ) -> Bool {
        dragTranslation.height > buttonFrame.height
    }

    func shouldUpdateSecondaryActionSelection(
        for dragTranslation: CGSize
    ) -> Bool {
        let translation = dragTranslation.width
        if translation == 0 { return true }
        return isLeading ? translation > 0 : translation < 0
    }
}
