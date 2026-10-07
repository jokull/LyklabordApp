//
//  KeyTouchRouter.swift
//  KeyboardKit
//
//  Lyklaborð fork. Measured on device (research/tap-delay.md): a touch
//  reaches the keyboard process ~25 ms after it happens, but SwiftUI's
//  gesture is not allowed to start until the system gesture gate on the
//  keyboard window gives up, ~100 ms on any key and ~780 ms for a finger
//  held on an edge key. The gate cannot be disabled (iOS re-arms it before
//  every touch). A UIKit gesture recognizer is handed touches directly, so
//  this router reads them there and drives the gesture buttons itself.
//

#if os(iOS)
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Routes raw touches to the gesture buttons that registered with it.
///
/// Add ``recognizer`` to the view that hosts the keyboard and put the router
/// in the environment with `keyTouchRouter(_:)`. Gesture buttons outside a
/// scroll view then register their frame and stop using a SwiftUI gesture.
/// Main thread only.
public final class KeyTouchRouter {

    public init() {}

    struct Target {
        var frame: CGRect
        var changed: (GestureButtonDragValue) -> Void
        var ended: (GestureButtonDragValue) -> Void
        var cancelled: () -> Void
    }

    private var targets: [UUID: Target] = [:]
    private var active: [ObjectIdentifier: (id: UUID, start: CGPoint)] = [:]

    /// The recognizer to add to the keyboard's hosting view.
    public private(set) lazy var recognizer: UIGestureRecognizer = Recognizer(router: self)

    /// Register or refresh a button. `frame` is in window coordinates
    /// (SwiftUI's `.global` space).
    func register(
        id: UUID,
        frame: CGRect,
        changed: @escaping (GestureButtonDragValue) -> Void,
        ended: @escaping (GestureButtonDragValue) -> Void,
        cancelled: @escaping () -> Void
    ) {
        targets[id] = Target(frame: frame, changed: changed, ended: ended, cancelled: cancelled)
    }

    func unregister(id: UUID) {
        targets[id] = nil
    }
}

private extension KeyTouchRouter {

    func value(for touch: UITouch, at point: CGPoint, start: CGPoint, in frame: CGRect) -> GestureButtonDragValue {
        GestureButtonDragValue(
            time: Date(timeIntervalSinceReferenceDate: touch.timestamp),
            location: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            startLocation: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
        )
    }

    /// The button under a point: of those whose frame contains it, the one
    /// whose centre is nearest (frames can overlap by a few points).
    func target(at point: CGPoint) -> (id: UUID, target: Target)? {
        var best: (id: UUID, target: Target, distance: CGFloat)?
        for (id, target) in targets where target.frame.contains(point) {
            let dx = target.frame.midX - point.x
            let dy = target.frame.midY - point.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (id, target, distance)
            }
        }
        return best.map { ($0.id, $0.target) }
    }

    func touchBegan(_ touch: UITouch) {
        let point = touch.location(in: nil)
        guard let hit = target(at: point) else {
            KeyLatencyProbe.count("router.miss")
            return
        }
        // One touch per button; a second finger on the same key is ignored.
        guard !active.values.contains(where: { $0.id == hit.id }) else { return }
        KeyLatencyProbe.count("router.hit")
        active[ObjectIdentifier(touch)] = (hit.id, point)
        hit.target.changed(value(for: touch, at: point, start: point, in: hit.target.frame))
    }

    func touchMoved(_ touch: UITouch) {
        guard let tracked = active[ObjectIdentifier(touch)],
              let target = targets[tracked.id] else { return }
        let point = touch.location(in: nil)
        target.changed(value(for: touch, at: point, start: tracked.start, in: target.frame))
    }

    func touchEnded(_ touch: UITouch) {
        guard let tracked = active.removeValue(forKey: ObjectIdentifier(touch)),
              let target = targets[tracked.id] else { return }
        let point = touch.location(in: nil)
        target.ended(value(for: touch, at: point, start: tracked.start, in: target.frame))
    }

    func touchCancelled(_ touch: UITouch) {
        guard let tracked = active.removeValue(forKey: ObjectIdentifier(touch)) else { return }
        targets[tracked.id]?.cancelled()
    }

    var hasActiveTouches: Bool { !active.isEmpty }

    /// Never recognizes: it only observes touches and forwards them. It
    /// must neither block nor be blocked by SwiftUI's own recognizers,
    /// which still serve everything that is not a routed key.
    final class Recognizer: UIGestureRecognizer {

        init(router: KeyTouchRouter) {
            self.router = router
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        private weak var router: KeyTouchRouter?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { router?.touchBegan($0) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { router?.touchMoved($0) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { router?.touchEnded($0) }
            failIfIdle(event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            touches.forEach { router?.touchCancelled($0) }
            failIfIdle(event)
        }

        /// Let UIKit reset the recognizer once every finger is up.
        private func failIfIdle(_ event: UIEvent) {
            let remaining = event.allTouches?.contains {
                $0.phase != .ended && $0.phase != .cancelled
            } ?? false
            if !remaining, router?.hasActiveTouches != true { state = .failed }
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

public extension EnvironmentValues {

    /// The router that delivers raw touches to gesture buttons, if any.
    @Entry var keyTouchRouter: KeyTouchRouter?
}

public extension View {

    /// Make gesture buttons in this view take their touches from a router
    /// instead of a SwiftUI gesture.
    func keyTouchRouter(_ router: KeyTouchRouter?) -> some View {
        environment(\.keyTouchRouter, router)
    }
}
#endif
