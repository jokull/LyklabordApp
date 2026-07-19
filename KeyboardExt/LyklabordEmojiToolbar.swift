//
//  LyklabordEmojiToolbar.swift
//  LyklabordKeyboard
//
//  The autocomplete toolbar with one Lyklaborð twist: when there are no
//  suggestions to show (idle, or an empty field), the bar — which would
//  otherwise sit blank — is repurposed into a quick strip of the user's
//  most-used emoji (frecency, see EmojiFrequencyStore). The moment real
//  autocomplete suggestions exist, the standard toolbar returns.
//
//  Taps route through the shared action handler, so inserting an emoji here
//  also records it back into the frecency store (self-reinforcing) and reuses
//  the same feedback/insert path as every other key. On-device only.
//

import SwiftUI
import KeyboardKit

/// The autocomplete toolbar with two Lyklaborð twists:
///
/// - **Empty state** → a frecency emoji strip instead of a blank bar.
/// - **Hoisted slot** → when an autocorrect is armed, that word already lives
///   on the (blue) spacebar — see DevSpaceContent — so the bar drops it and
///   backfills with the next candidate (the service publishes 4 for this).
///   Net effect: the bar always shows up to three *distinct* suggestions —
///   verbatim escape hatch + two more — instead of duplicating the spacebar.
///   Filtering happens HERE only; `autocompleteContext.suggestions` keeps the
///   armed suggestion, which is what the space-commit path reads.
///   PERSONAL-LEARNED armed words are exempt from hoisting entirely
///   (`armedAutocorrectText` excludes them): the spacebar has no long-press,
///   so hoisting would remove the eject affordance — they stay in the bar as
///   a highlighted chip and `armed` is false here, taking the prefix(3) path.
struct LyklabordToolbar<Standard: View>: View {

    @ObservedObject var autocompleteContext: AutocompleteContext
    let actionHandler: KeyboardActionHandler
    let suggestionAction: (Autocomplete.Suggestion) -> Void
    let standard: Standard

    var body: some View {
        let all = autocompleteContext.suggestions
        if all.isEmpty {
            EmojiFrecencyRow(actionHandler: actionHandler)
        } else {
            let plain = all.filter { $0.type != .emoji }
            let emoji = all.filter { $0.type == .emoji }
            let armed = autocompleteContext.armedAutocorrectText != nil
            let bar = armed
                ? plain.filter { !$0.isAutocorrect }
                : Array(plain.prefix(3))
            Autocomplete.Toolbar(
                suggestions: Array(bar.prefix(3)) + emoji,
                suggestionAction: suggestionAction
            )
        }
    }
}

/// A single row of the top frecency emoji, spread evenly across the toolbar
/// width. Recomputed each time the bar transitions to empty (the enclosing
/// `if` recreates it), so it reflects recent use without reordering mid-view.
private struct EmojiFrecencyRow: View {

    let actionHandler: KeyboardActionHandler
    private let emojis = EmojiFrequencyStore.shared.top(8)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(emojis, id: \.self) { emoji in
                Button {
                    actionHandler.handle(.release, on: .emoji(KeyboardKit.Emoji(emoji)))
                } label: {
                    Text(emoji)
                        .font(.system(size: 22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
