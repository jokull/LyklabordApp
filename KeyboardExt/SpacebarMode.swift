//
//  SpacebarMode.swift
//  BetterKeyboardExt
//
//  Extension-side consumer of the spacebar-behavior setting (PLAN.md
//  "Spacebar behavior — three user-selectable modes", SwiftKey parity per MS
//  support docs). The containing app's settings screen writes the user's
//  choice into the App Group `UserDefaults` suite; this extension reads it
//  back and drives modes 2 and 3. Mode 1 is the current M1 behavior and
//  needs no code beyond defaulting to it.
//

import Foundation

/// The three user-selectable spacebar behaviors.
///
/// SOURCE OF TRUTH: `App/AppModel.swift`'s `SpacebarMode` enum. This is a
/// deliberate duplicate — the keyboard-extension target cannot import App
/// code — so the three raw values below MUST stay byte-for-byte identical to
/// the app's enum cases (`completeCurrentWord` / `alwaysInsertPrediction` /
/// `alwaysInsertSpace`), and `defaultsKey` / the suite name MUST match
/// `AppModel.spacebarModeDefaultsKey` ("is.lyklabord.settings.spacebarMode")
/// and `AppModel.appGroupIdentifier` ("group.is.lyklabord"). The app persists
/// `SpacebarMode.rawValue` under that key via `@AppStorage`
/// (`App/SettingsView.swift`); we read the same string here.
enum SpacebarMode: String {

    /// Mode 1 (default, current M1 behavior): mid-word, space commits the
    /// center/autocorrect suggestion + a space; at a word boundary space is
    /// just a space. Driven entirely by KeyboardKit auto-applying our
    /// `.autocorrect` suggestion on the space delimiter — this mode adds no
    /// code, it's simply the absence of the mode-2/mode-3 interceptions.
    case completeCurrentWord

    /// Mode 2: space injects the primary prediction even with zero letters
    /// typed ("sentence by spacebar"). Implemented in
    /// `BetterKeyboardActionHandler.handle(_:on:replaced:)` — on a `.space`
    /// release with no word in progress, insert the top bar prediction
    /// before the space instead of a bare space. Needs next-word prediction
    /// to be useful; falls back to a plain space when the bar is empty.
    case alwaysInsertPrediction

    /// Mode 3: space is always a literal space; corrections apply ONLY when
    /// the user taps the bar. Implemented in the service bridge
    /// (`BetterKeyboardAutocompleteService.performAutocomplete`) by demoting
    /// every `.autocorrect` suggestion to `.regular` before it reaches the
    /// context, so the bar still shows everything but nothing auto-commits
    /// on space. No action-handler change needed — with no `.autocorrect`
    /// suggestion present, KeyboardKit's space-commit path is a no-op.
    case alwaysInsertSpace

    /// Raw-value key in the App Group `UserDefaults` suite. Mirrors
    /// `AppModel.spacebarModeDefaultsKey`.
    static let defaultsKey = "is.lyklabord.settings.spacebarMode"

    /// Read the current mode live from the App Group `UserDefaults` suite.
    ///
    /// Robust by design (PLAN.md — the extension degrades gracefully without
    /// Full Access): a nil `appGroupId`, an unavailable suite (Full Access
    /// denied, so the shared container can't be opened), a missing value, or
    /// an unrecognized raw value ALL fall back to mode 1
    /// (`.completeCurrentWord`) — exactly the behavior the keyboard has had
    /// since M1. Cheap enough to call on `viewWillAppear`; the service
    /// caches the result so per-keystroke reads never hit `UserDefaults`.
    static func current(appGroupId: String?) -> SpacebarMode {
        guard
            let appGroupId,
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: defaultsKey),
            let mode = SpacebarMode(rawValue: raw)
        else { return .completeCurrentWord }
        return mode
    }
}
