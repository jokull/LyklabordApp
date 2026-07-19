//
//  LyklabordEmojiKeyboard.swift
//  LyklabordKeyboard
//
//  The in-keyboard emoji picker shown when the bottom-row emoji key is tapped.
//
//  Why an in-keyboard picker at all: iOS gives a custom keyboard extension no
//  API to switch to the SYSTEM emoji keyboard — `advanceToNextInputMode()`
//  only cycles through the user's enabled keyboards, and Apple's App Extension
//  Programming Guide is explicit that "there is no API ... for picking a
//  particular keyboard to switch to." So every third-party keyboard ships its
//  own emoji grid; this is ours.
//
//  Implementation: a thin SwiftUI wrapper around the vendored ISEmojiView
//  (isaced/ISEmojiView @ 0.3.5, MIT, Packages/ISEmojiView), which is a
//  purpose-built emoji *keyboard* view — categories, recently-used, skin-tone
//  variants, long-press preview, and a delete key — that fills the keyboard
//  area (not a modal). It was privacy-audited to zero network/analytics calls
//  before vendoring, so the extension's "no networking code" guarantee holds.
//
//  Every interaction routes back through the shared `KeyboardActionHandler`,
//  exactly like the letter keys: an emoji selection inserts via
//  `.emoji`, the ABC button returns to letters, and delete maps to
//  `.backspace`. Recents are persisted by ISEmojiView in the extension's own
//  UserDefaults (declared CA92.1 in PrivacyInfo.xcprivacy) — on device, never
//  synced anywhere.
//

import SwiftUI
import KeyboardKit
import ISEmojiView

/// In-keyboard emoji picker (ISEmojiView) wired to the keyboard's action
/// handler. Kept as a distinct view type (≠ `Emoji.KeyboardWrapper`, the empty
/// KeyboardKit Pro placeholder) so KeyboardKit's `hasEmojiKeyboard` is true —
/// which both keeps the `.keyboardType(.emojis)` key in the layout and shows
/// this view when it's tapped.
struct LyklabordEmojiKeyboard: View {

    /// Routes emoji taps / ABC / delete through the shared action handler, so
    /// emoji insertion uses the same path (feedback, autocomplete reset, proxy
    /// insert) as every other key.
    let actionHandler: KeyboardActionHandler

    var body: some View {
        EmojiView_SwiftUI(
            needToShowAbcButton: true,      // "ABC" returns to the letter keyboard
            needToShowDeleteButton: true,   // backspace on the emoji keyboard
            didSelect: { emoji in
                actionHandler.handle(.release, on: .emoji(KeyboardKit.Emoji(emoji)))
            },
            didPressChangeKeyboard: {
                actionHandler.handle(.release, on: .keyboardType(.alphabetic))
            },
            didPressDeleteBackward: {
                actionHandler.handle(.release, on: .backspace)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
