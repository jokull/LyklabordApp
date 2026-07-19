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

/// Wraps KeyboardKit's standard autocomplete toolbar, swapping in a frecency
/// emoji strip whenever the suggestion list is empty.
struct LyklabordToolbar<Standard: View>: View {

    @ObservedObject var autocompleteContext: AutocompleteContext
    let actionHandler: KeyboardActionHandler
    let standard: Standard

    var body: some View {
        if autocompleteContext.suggestions.isEmpty {
            EmojiFrecencyRow(actionHandler: actionHandler)
        } else {
            standard
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
