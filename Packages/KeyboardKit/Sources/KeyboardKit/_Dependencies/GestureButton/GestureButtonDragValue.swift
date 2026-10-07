//
//  GestureButtonDragValue.swift
//  KeyboardKit
//
//  Lyklaborð fork: the gesture button's own drag value, so a press can be
//  driven by something other than a SwiftUI `DragGesture` (whose value has
//  no public initializer). See `KeyTouchRouter`.
//

#if os(iOS) || os(macOS) || os(watchOS) || os(visionOS)
import SwiftUI

/// The position of one touch on a gesture button, in the button's own
/// coordinate space.
public struct GestureButtonDragValue: Equatable {

    public init(
        time: Date,
        location: CGPoint,
        startLocation: CGPoint
    ) {
        self.time = time
        self.location = location
        self.startLocation = startLocation
    }

    public init(_ value: DragGesture.Value) {
        self.init(
            time: value.time,
            location: value.location,
            startLocation: value.startLocation
        )
    }

    /// The touch event's timestamp (system uptime as a reference-date
    /// interval, matching what `DragGesture.Value.time` carries).
    public var time: Date
    public var location: CGPoint
    public var startLocation: CGPoint

    public var translation: CGSize {
        CGSize(
            width: location.x - startLocation.x,
            height: location.y - startLocation.y
        )
    }
}
#endif
