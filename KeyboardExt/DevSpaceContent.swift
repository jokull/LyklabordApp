//
//  DevSpaceContent.swift
//  LyklabordKeyboard
//
//  The spacebar as a signal surface. Two layers:
//
//  1. SPACE-COMMIT HINT (all builds): when the engine has an autocorrect armed
//     — i.e. pressing space will replace the typed token — the spacebar turns
//     accent-blue (see `LyklabordStyleService`) and shows the word space will
//     commit (truncated if long). This moves the "space will change your word"
//     affordance from the suggestion bar onto the key that triggers it.
//
//  2. BUILD STAMP (DEBUG only): when idle, the spacebar label shows the
//     extension's own build commit (KeyboardExt/BuildInfo.swift) instead of
//     "Bil". iOS caches the running appex — a fresh app install doesn't
//     guarantee a fresh extension — so the live binary self-identifies on the
//     key itself. Release builds show the standard "Bil".
//

import SwiftUI
import KeyboardKit

extension AutocompleteContext {
    /// The text an armed autocorrect will commit on space, if any.
    var armedAutocorrectText: String? {
        suggestions.first(where: { $0.isAutocorrect })?.text
    }
}

/// Observed wrapper that drives the spacebar's armed-state COLOR reactively.
///
/// Why not a `KeyboardStyleService` subclass: the style service is only
/// re-queried when a button re-renders, and key buttons don't observe the
/// autocomplete context — so the blue arrived one interaction late (observed
/// on device: word appeared, key stayed grey, turned blue on the press).
/// The `keyboardButtonStyle(builder:)` ENVIRONMENT is read by every key via
/// `@Environment`, and this wrapper re-applies it whenever the observed
/// context changes — so the env update re-renders the keys in lockstep with
/// the word label.
struct SpaceCommitHintContainer<Content: View>: View {
    @ObservedObject var autocompleteContext: AutocompleteContext
    let keyboardContext: KeyboardContext
    let content: Content

    init(
        autocompleteContext: AutocompleteContext,
        keyboardContext: KeyboardContext,
        @ViewBuilder content: () -> Content
    ) {
        self.autocompleteContext = autocompleteContext
        self.keyboardContext = keyboardContext
        self.content = content()
    }

    var body: some View {
        let armed = autocompleteContext.armedAutocorrectText != nil
        content.keyboardButtonStyle { params in
            var style = params.standardStyle(for: keyboardContext)
            if armed, params.action == .space {
                style.backgroundColor = params.isPressed
                    ? Color.accentColor.opacity(0.8) : Color.accentColor
                style.foregroundColor = .white
            }
            return style
        }
    }
}

/// The adaptive quote key's teaching face (issue #10). In materialized
/// Icelandic mode the key shows BOTH real glyphs spatially — „ low/leading,
/// " high/trailing — with only the character the next tap will insert in the
/// shared accent blue (the same "contextual/armed result" semantic as the
/// spacebar hint); the inactive glyph is muted. Glyph position is the primary
/// signal, blue is reinforcement. Neutral/English states never reach this
/// view — the key face is the ordinary centered straight quote.
private struct QuoteKeyFace: View {
    /// The character the next tap inserts: „ (open) or " (close).
    let active: String

    var body: some View {
        ZStack {
            Text(SmartPunctuation.open) // „ — low, leading
                .font(.system(size: 20))
                .foregroundStyle(active == SmartPunctuation.open ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 7)
                .padding(.bottom, 4)
            Text(SmartPunctuation.close) // " — high, trailing
                .font(.system(size: 20))
                .foregroundStyle(active == SmartPunctuation.close ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 7)
                .padding(.top, 2)
        }
        .allowsHitTesting(false)
    }
}

struct DevSpaceContent<Standard: View>: View {
    let action: KeyboardAction
    let standard: Standard
    @ObservedObject var autocompleteContext: AutocompleteContext

    var body: some View {
        // Adaptive quote key (issue #10): when the numeric key's resolved
        // action is an Icelandic quote, show the two-glyph teaching face; the
        // straight-quote state keeps the standard centered " label.
        if case .character(let char) = action,
            char == SmartPunctuation.open || char == SmartPunctuation.close {
            QuoteKeyFace(active: char)
        } else if action == .space {
            if let word = autocompleteContext.armedAutocorrectText {
                // Space will commit this word — say so on the key itself.
                // Foreground/background come from LyklabordStyleService (white
                // on accent blue).
                Text(word)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
            } else {
                #if DEBUG
                // Idle spacebar in a DEBUG build: the extension's build stamp,
                // readable (replaces "Bil" — this is a dev instrument).
                Text(BuildInfo.engineCommit)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                #else
                standard
                #endif
            }
        } else {
            standard
        }
    }
}
