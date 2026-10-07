//
//  GestureButton.swift
//  GestureButton
//
//  Created by Daniel Saidi on 2022-11-24.
//  Copyright © 2022-2025 Daniel Saidi. All rights reserved.
//

#if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
import SwiftUI

/// This button can be used to trigger gesture-based actions.
///
/// A `cancelDelay` can be specified to make a button cancel
/// its gesture if no values are registered during the delay.
/// This can be used to avoid a button from getting stuck in
/// a pressed state, which for instance can happen when it's
/// placed next to a scroll view and touched by accident.
///
/// > Important: Make sure to use ``GestureButtonScrollState``
/// if the button is within a `ScrollView`, otherwise it may
/// block the scroll view gestures in iOS 17 and earlier and
/// trigger unwanted actions in iOS 18 and later.
public struct GestureButton<Label: View>: View {
    
    /// Create a gesture button.
    ///
    /// - Parameters:
    ///   - config: A custom config, if any.
    ///   - isPressed: A custom, optional binding to track pressed state, if any.
    ///   - scrollState: The scroll state to use, if any.
    ///   - pressAction: The action to trigger when the button is pressed, if any.
    ///   - releaseInsideAction: The action to trigger when the button is released inside, if any.
    ///   - releaseOutsideAction: The action to trigger when the button is released outside of its bounds, if any.
    ///   - longPressAction: The action to trigger when the button is long pressed, if any.
    ///   - doubleTapAction: The action to trigger when the button is double tapped, if any.
    ///   - repeatTimer: A custom repeat timer to use for the repeating action, if any.
    ///   - repeatAction: The action to repeat while the button is being pressed, if any.
    ///   - dragStartAction: The action to trigger when a drag gesture starts, if any.
    ///   - dragAction: The action to trigger when a drag gesture changes, if any.
    ///   - dragEndAction: The action to trigger when a drag gesture ends, if any.
    ///   - endAction: The action to trigger when a button gesture ends, if any.
    ///   - label: The button label.
    public init(
        config: GestureButtonConfiguration? = nil,
        isPressed: Binding<Bool>? = nil,
        scrollState: GestureButtonScrollState? = nil,
        pressAction: Action? = nil,
        releaseInsideAction: Action? = nil,
        releaseOutsideAction: Action? = nil,
        longPressAction: Action? = nil,
        doubleTapAction: Action? = nil,
        repeatTimer: GestureButtonTimer? = nil,
        repeatAction: Action? = nil,
        dragStartAction: DragAction? = nil,
        dragAction: DragAction? = nil,
        dragEndAction: DragAction? = nil,
        endAction: Action? = nil,
        label: @escaping LabelBuilder
    ) {
        self.initConfig = config
        self._state = .init(wrappedValue: .init(
            isPressed: isPressed,
            repeatTimer: repeatTimer
        ))

        self.pressAction = pressAction
        self.releaseInsideAction = releaseInsideAction
        self.releaseOutsideAction = releaseOutsideAction
        self.longPressAction = longPressAction
        self.doubleTapAction = doubleTapAction
        self.repeatAction = repeatAction
        self.dragStartAction = dragStartAction
        self.dragAction = dragAction
        self.dragEndAction = dragEndAction
        self.endAction = endAction

        self.isInScrollView = scrollState != nil
        self._scrollState = .init(wrappedValue: scrollState ?? .init())
        self.label = label
    }
    
    private let initConfig: GestureButtonConfiguration?

    public typealias Action = () -> Void
    public typealias DragAction = (GestureButtonDragValue) -> Void
    public typealias LabelBuilder = (_ isPressed: Bool) -> Label
    
    private let pressAction: Action?
    private let releaseInsideAction: Action?
    private let releaseOutsideAction: Action?
    private let longPressAction: Action?
    private let doubleTapAction: Action?
    private let repeatAction: Action?
    private let dragStartAction: DragAction?
    private let dragAction: DragAction?
    private let dragEndAction: DragAction?
    private let endAction: Action?

    @StateObject
    private var state: GestureButtonState

    @ObservedObject
    private var scrollState: GestureButtonScrollState
    
    @Environment(\.gestureButtonConfiguration)
    private var environmentConfig

    #if os(iOS)
    @Environment(\.keyTouchRouter)
    private var touchRouter
    #endif

    private let isInScrollView: Bool
    private let label: LabelBuilder
    
    private var config: GestureButtonConfiguration {
        initConfig ?? environmentConfig
    }
    
    public var body: some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            content
        } else if isInScrollView {
            /// The `simultaneousGesture` below doesn't work
            /// in iOS 17 and `ScrollViewGestureButton` does
            /// only work in iOS 17 and earlier.
            ScrollViewGestureButton(
                isPressed: $state.isPressed,
                pressAction: pressAction,
                releaseInsideAction: releaseInsideAction,
                releaseOutsideAction: releaseOutsideAction,
                longPressDelay: config.longPressDelay,
                longPressAction: longPressAction,
                doubleTapTimeout: config.doubleTapTimeout,
                doubleTapAction: doubleTapAction,
                repeatDelay: config.repeatDelay,
                repeatAction: repeatAction,
                repeatTimer: state.repeatTimer,
                dragStartAction: dragStartAction.map { action in { action(.init($0)) } },
                dragAction: dragAction.map { action in { action(.init($0)) } },
                dragEndAction: dragEndAction.map { action in { action(.init($0)) } },
                endAction: endAction,
                label: label
            )
        } else {
            content
        }
    }
    
    var content: some View {
        label(state.isPressed)
            .overlay(touchView)
            .onDisappear { state.isRemoved = true }
            .accessibilityAddTraits(.isButton)
    }

    /// Lyklaborð fork: with a ``KeyTouchRouter`` in the environment (and
    /// outside a scroll view) the button takes raw touches from the router
    /// and installs no SwiftUI gesture at all.
    @ViewBuilder
    var touchView: some View {
        #if os(iOS)
        if let touchRouter, !isInScrollView {
            routedTouchView(touchRouter)
        } else {
            gestureView
        }
        #else
        gestureView
        #endif
    }
}

#if os(iOS)
private extension GestureButton {

    /// Registers the button's frame and handlers with the router. The
    /// registration is refreshed on every evaluation, so the router always
    /// holds the handlers of the current view value.
    func routedTouchView(_ router: KeyTouchRouter) -> some View {
        GeometryReader { geo in
            let id = state.routerID
            let _ = router.register(
                id: id,
                frame: geo.frame(in: .global),
                changed: { handleDragWithState($0) },
                ended: { handleDragEndedWithState($0, in: geo) },
                cancelled: { handleCancelled() }
            )
            // A gesture that does nothing still has a job: it claims the
            // touch for this key in SwiftUI's hit-testing. Without it a
            // touch on the upper part of a top-row key fell through to the
            // suggestion bar, whose tap area reaches down over the keys, so
            // one touch both typed the letter and tapped a suggestion.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                .onDisappear { router.unregister(id: id) }
        }
    }

    /// The system took the touch away (a system gesture began): end the
    /// press without releasing it.
    func handleCancelled() {
        defer { state.stopDragGesture() }
        guard state.isDragGestureStarted else { return }
        setScrollGestureDisabledState(false)
        reset()
        endAction?()
    }
}
#endif

private extension GestureButton {
    
    func gesture(
        for geo: GeometryProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { handleDrag(.init($0)) }
            .onEnded { handleDragEnded(.init($0), in: geo) }
    }
    
    var gestureView: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(gesture(for: geo))
        }
    }
    
    func handleDrag(
        _ value: GestureButtonDragValue
    ) {
        if scrollState.isScrolling { return }
        if isInScrollView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                handleDragWithState(value)
            }
        } else {
            handleDragWithState(value)
        }
    }
    
    func handleDragWithState(
        _ value: GestureButtonDragValue
    ) {
        state.updateDragGesture(with: value)
        if scrollState.isScrolling { return }
        tryHandleDrag(value)
        if state.isDragGestureStarted { return }
        // Lyklaborð fork: latency probe. `value.time` is the touch-down
        // event time, so the first number is how long the touch waited
        // before SwiftUI delivered it.
        let probeStart = KeyLatencyProbe.now
        KeyLatencyProbe.record("press.1-touchToCallback", ms: (KeyLatencyProbe.now - value.time.timeIntervalSinceReferenceDate) * 1000)
        state.startDragGesture(with: value)
        setScrollGestureDisabledState(true)
        tryHandlePress(value)
        KeyLatencyProbe.record("press.2-handler", ms: (KeyLatencyProbe.now - probeStart) * 1000)
        if KeyLatencyProbe.isEnabled {
            DispatchQueue.main.async {
                KeyLatencyProbe.record("press.3-untilMainFree", ms: (KeyLatencyProbe.now - probeStart) * 1000)
                KeyLatencyProbe.notePress()
            }
        }
    }
    
    func handleDragEnded(_ value: GestureButtonDragValue, in geo: GeometryProxy) {
        if isInScrollView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                handleDragEndedWithState(value, in: geo)
            }
        } else {
            handleDragEndedWithState(value, in: geo)
        }
    }
    
    func handleDragEndedWithState(
        _ value: GestureButtonDragValue,
        in geo: GeometryProxy
    ) {
        defer { state.stopDragGesture() }
        guard state.isDragGestureStarted else { return }
        setScrollGestureDisabledState(false)
        let probeStart = KeyLatencyProbe.now
        KeyLatencyProbe.record("release.1-touchToCallback", ms: (KeyLatencyProbe.now - value.time.timeIntervalSinceReferenceDate) * 1000)
        tryHandleRelease(value, in: geo)
        KeyLatencyProbe.record("release.2-handler", ms: (KeyLatencyProbe.now - probeStart) * 1000)
        if KeyLatencyProbe.isEnabled {
            DispatchQueue.main.async {
                KeyLatencyProbe.record("release.3-untilMainFree", ms: (KeyLatencyProbe.now - probeStart) * 1000)
            }
        }
    }

    func handleRepeatAction() {
        guard let repeatAction else { return }
        repeatAction()
    }

    func reset() {
        state.isPressed = false
        state.longPressDate = Date()
        state.repeatDate = Date()
        tryStopRepeatTimer()
    }
    
    func setScrollGestureDisabledState(_ new: Bool) {
        if scrollState.isScrollGestureDisabled == new { return }
        scrollState.isScrollGestureDisabled = new
    }
}

private extension GestureButton {

    var usesTouchRouter: Bool {
        #if os(iOS)
        touchRouter != nil && !isInScrollView
        #else
        false
        #endif
    }

    func tryHandlePress(_ value: GestureButtonDragValue) {
        if state.isPressed { return }
        state.isPressed = true
        state.pressSerial += 1
        pressAction?()
        dragStartAction?(value)
        tryTriggerCancelAfterDelay()
        tryTriggerLongPressAfterDelay()
        tryTriggerRepeatAfterDelay()
    }

    /// Try to handle any new drag gestures as a press event.
    func tryHandleDrag(_ value: GestureButtonDragValue) {
        guard state.isPressed else { return }
        dragAction?(value)
    }

    /// This function will trigger several actions, based on
    /// how the gesture is ended. It will always trigger the
    /// drag end and end actions, then either of the release
    /// inside or outside actions.
    func tryHandleRelease(_ value: GestureButtonDragValue, in geo: GeometryProxy) {
        let shouldTrigger = state.isPressed
        reset()
        guard shouldTrigger else { return }
        state.releaseDate = tryTriggerDoubleTap() ? .distantPast : Date()
        dragEndAction?(value)
        if geo.contains(value.location) {
            releaseInsideAction?()
        } else {
            releaseOutsideAction?()
        }
        endAction?()
    }

    /// This function tries to fix an iOS bug, where buttons
    /// may not always receive a gesture end event. This can
    /// for instance happen when the button is near a scroll
    /// view and is accidentally touched when a user scrolls.
    /// The function checks if the original gesture is still
    /// the last gesture when the cancel delay triggers, and
    /// will if so cancel the gesture. Since this will cause
    /// completely still gestures to be seen as accidentally
    /// triggered, this function can yield incorrect results
    /// and should be replaced by a proper bug fix.
    func tryTriggerCancelAfterDelay() {
        guard let delay = config.cancelDelay else { return }
        // Lyklaborð fork: the stuck-press guard exists because SwiftUI can
        // lose a gesture's end event. Routed touches always end or cancel,
        // so the guard is not armed for them.
        if usesTouchRouter { return }
        let value = state.lastDragGestureValue
        let pressSerial = state.pressSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Lyklaborð fork: only cancel the press that armed this timer,
            // and only if it is still down. Upstream fired for any earlier
            // tap whose touch never moved, three seconds after the fact,
            // and its `endAction` cleared the shared callout context: a
            // long-press menu opened within three seconds of typing a
            // top-row key flashed and closed.
            guard state.pressSerial == pressSerial, state.isPressed else { return }
            let location = state.lastDragGestureValue?.location
            guard location == value?.location else { return }
            self.reset()
            self.endAction?()
        }
    }

    /// This function tries to trigger the double tap action
    /// if the current date is within the double tap timeout
    /// since the last release.
    func tryTriggerDoubleTap() -> Bool {
        let interval = Date().timeIntervalSince(state.releaseDate)
        let isDoubleTap = interval < config.doubleTapTimeout
        if isDoubleTap { doubleTapAction?() }
        return isDoubleTap
    }

    /// This function tries to trigger the long press action
    /// after the specified long press delay.
    func tryTriggerLongPressAfterDelay() {
        guard let action = longPressAction else { return }
        let date = Date()
        state.longPressDate = date
        DispatchQueue.main.asyncAfter(deadline: .now() + config.longPressDelay) {
            if state.isRemoved { return }
            if state.lastMaxDragDistance > config.longPressMaxDragDistance { return }
            guard state.longPressDate == date else { return }
            action()
        }
    }

    /// This function tries to start a repeat action trigger
    /// timer after repeat delay.
    func tryTriggerRepeatAfterDelay() {
        let date = Date()
        state.repeatDate = date
        DispatchQueue.main.asyncAfter(deadline: .now() + config.repeatDelay) {
            if state.isRemoved { return }
            guard state.repeatDate == date else { return }
            self.tryStartRepeatTimer()
        }
    }

    /// Try to start the repeat timer.
    func tryStartRepeatTimer() {
        if state.repeatTimer.isActive { return }
        state.repeatTimer.start {
            Task { await handleRepeatAction() }
        }
    }

    /// Try to stop the repeat timer.
    func tryStopRepeatTimer() {
        guard state.repeatTimer.isActive else { return }
        state.repeatTimer.stop()
    }
}

#Preview {
    
    struct Preview: View {

        @StateObject var state = GestureButtonPreview.State()
        @StateObject var scrollState = GestureButtonScrollState()

        var body: some View {
            GestureButtonPreview.Content(state: state) {
                GestureButton(
                    isPressed: $state.isPressed,
                    scrollState: scrollState,
                    pressAction: { state.pressCount += 1 },
                    releaseInsideAction: { state.releaseInsideCount += 1 },
                    releaseOutsideAction: { state.releaseOutsideCount += 1 },
                    longPressAction: { state.longPressCount += 1 },
                    doubleTapAction: { state.doubleTapCount += 1 },
                    repeatAction: { state.repeatCount += 1 },
                    dragStartAction: { state.dragStartValue = $0.location },
                    dragAction: { state.dragChangedValue = $0.location },
                    dragEndAction: { state.dragEndValue = $0.location },
                    endAction: { state.endCount += 1 },
                    label: { GestureButtonPreview.Item(isPressed: $0) }
                )
            }
            .gestureButtonConfiguration(
                .init(longPressDelay: 0.8)
            )
        }
    }
    
    return Preview()
}
#endif
