//
//  KeyboardStatus.swift
//  BetterKeyboard
//
//  Detects whether the Lyklaborð keyboard extension is enabled in iOS
//  Settings, so onboarding can collapse to a done-state instead of showing
//  a 68-year-old a walkthrough for something she already finished.
//
//  Mechanism: iOS mirrors the enabled-keyboards list into the standard
//  `UserDefaults` under the "AppleKeyboards" key (bundle ids for third-party
//  keyboards, layout ids like "is_IS@sw=Icelandic" for Apple's). This is the
//  same read KeyboardKit's own `KeyboardStatusInspector` ships (vendored at
//  Packages/KeyboardKit/Sources/KeyboardKit/Status/) — we re-implement the
//  two lines here because the app target deliberately does not link
//  KeyboardKit (the UI framework belongs to the extension). No private API,
//  no KVC: a plain defaults read of a documented-by-convention key.
//
//  The value is a point-in-time read — call `isKeyboardEnabled` again when
//  the scene re-activates (the user flips the toggle in Settings and swipes
//  back) rather than caching it. `ContentView` keys its layout off a
//  `@State` refreshed on `scenePhase == .active`.
//

import Foundation

enum KeyboardStatus {

    /// Must match `PRODUCT_BUNDLE_IDENTIFIER` of the BetterKeyboardExt
    /// target in `project.yml`.
    static let keyboardExtensionBundleId = "is.solberg.lyklabord.keyboard"

    /// Whether the Lyklaborð keyboard is currently enabled in
    /// Settings → General → Keyboard → Keyboards.
    static var isKeyboardEnabled: Bool {
        let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return keyboards.contains(keyboardExtensionBundleId)
    }
}
