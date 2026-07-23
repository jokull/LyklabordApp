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
    @ObservedObject var keyboardContext: KeyboardContext
    @ObservedObject var searchSession: IcelandicEmojiSearchSession
    let beginSearch: () -> Void

    var body: some View {
        if keyboardContext.keyboardType == .emojiSearch {
            searchOverlay
        } else {
            browsePicker
        }
    }

    private var browsePicker: some View {
        VStack(spacing: 0) {
            Button {
                beginSearch()
            } label: {
                Label("Leita að emoji", systemImage: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("emoji-search-button")
            .accessibilityHint("Opnar leit með íslenska lyklaborðinu")

            picker
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        EmojiView_SwiftUI(
            needToShowAbcButton: true,      // "ABC" returns to the letter keyboard
            needToShowDeleteButton: true,   // backspace on the emoji keyboard
            didSelect: { emoji in
                // Emoji insertion is a RELEASE action in KeyboardKit.
                actionHandler.handle(.release, on: .emoji(KeyboardKit.Emoji(emoji)))
            },
            didPressChangeKeyboard: {
                // `.keyboardType` and `.backspace` are PRESS actions in
                // KeyboardKit (no release action) — calling them on `.release`
                // silently no-ops, so both use `.press`.
                actionHandler.handle(.press, on: .keyboardType(.alphabetic))
            },
            didPressDeleteBackward: {
                actionHandler.handle(.press, on: .backspace)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// KeyboardKit reserves the ordinary 50pt toolbar above its alphabetic
    /// rows in `.emojiSearch`. This one-band overlay occupies exactly that
    /// safe strip; its clear remainder disables hit-testing so every letter,
    /// space, backspace, ABC, globe, and Done key remains reachable.
    private var searchOverlay: some View {
        VStack(spacing: 0) {
            searchBand.frame(height: 50)
            Color.clear.allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchBand: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(searchSession.query.isEmpty ? "Leita" : searchSession.query)
                    .foregroundStyle(searchSession.query.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .accessibilityLabel("Emoji-leit")
                    .accessibilityValue(
                        "\(searchSession.query), \(searchSession.results.count) niðurstöður"
                    )
                if !searchSession.query.isEmpty {
                    Button { searchSession.clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hreinsa emoji-leit")
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 10)
            .frame(width: 116, height: 36, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 9))

            if searchSession.loadFailed {
                status("Emoji-leit er ekki tiltæk")
            } else if !searchSession.query.isEmpty && searchSession.results.isEmpty {
                status("Engin emoji fundust")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 5) {
                        ForEach(searchSession.results) { result in
                            resultButton(result)
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .padding(.leading, 8)
        .background(Color(uiColor: .systemBackground).opacity(0.96))
        .accessibilityIdentifier("emoji-search-band")
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultButton(_ result: IcelandicEmojiSearchResult) -> some View {
        let emoji = KeyboardKit.Emoji(result.emoji)
        return Button {
            actionHandler.handle(.release, on: .emoji(emoji))
        } label: {
            Text(result.emoji)
                .font(.system(size: 27))
                .frame(width: 39, height: 39)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.name)
        .accessibilityHint("Setur emoji inn")
        .contextMenu {
            if emoji.hasSkinToneVariants {
                ForEach(emoji.skinToneVariants) { variant in
                    Button {
                        actionHandler.handle(.release, on: .emoji(variant))
                    } label: {
                        Text(variant.char)
                    }
                    .accessibilityLabel(result.name)
                }
            }
        }
    }
}
