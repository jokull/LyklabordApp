//
//  LyklabordKeyboardMetrics.swift
//  LyklabordKeyboard
//
//  Compact iPhone geometry shared by the toolbar and layout service. Kept
//  pure so the ReplayRig can lock the intended dimensions without rendering
//  the full keyboard extension.
//

import CoreGraphics

enum LyklabordKeyboardMetrics {
    /// Slightly tighter than Apple's roughly 48pt suggestion surface while
    /// retaining a comfortable full-width tap target.
    static let toolbarHeight: CGFloat = 44
    static let toolbarPadding: CGFloat = 2

    /// KeyboardKit uses 56pt rows on large/liquid-glass phones. Apple's
    /// reference keyboard uses roughly 54pt rows in portrait.
    static let maxPortraitRowHeight: CGFloat = 54

    static func rowHeight(
        standard: CGFloat,
        isPortrait: Bool
    ) -> CGFloat {
        isPortrait ? min(standard, maxPortraitRowHeight) : standard
    }
}
