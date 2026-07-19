//
//  SmartPunctuation.swift
//  LyklabordKeyboard
//
//  Locale-aware punctuation transforms layered on the native baseline
//  (docs/PUNCTUATION_BEHAVIOR.md, decision D1). v1: Icelandic double quotes.
//
//  Icelandic opens with „ (U+201E, low) and closes with " (U+201C, high) —
//  never the English "…" or straight quotes. Rules (per owner spec):
//    - only in the ICELANDIC lane (English passages keep straight/English quotes);
//    - a straight " OPENS with „ at a quotation-start position;
//    - a straight " CLOSES with " only when it can be done SAFELY — i.e. a
//      backward scan finds an unmatched opening „ (otherwise leave the straight
//      quote untouched rather than emit a lone closing ");
//    - the colloquial ,,gæsalappir" input method: a double comma at an opening
//      position becomes „ (handled at the call site, which owns the proxy edit).
//
//  Pure + context-only; the lane gate and the ,,→„ proxy edit live in the
//  action handler. On-device; nothing leaves the keyboard.
//

import Foundation

enum SmartPunctuation {

    static let openChar: Character = "\u{201E}"  // „
    static let closeChar: Character = "\u{201C}" // "
    static let open = String(openChar)
    static let close = String(closeChar)

    /// The replacement for a typed straight `"`, or `nil` to leave it as-is.
    /// - `„` when this begins a new quotation;
    /// - `"` only when there is an unmatched opening `„` behind the cursor;
    /// - `nil` otherwise (can't safely determine a close — don't emit a lone `"`).
    static func icelandicDoubleQuote(before context: String) -> String? {
        if opensNewQuote(before: context) { return open }
        return hasUnmatchedOpen(context) ? close : nil
    }

    /// Whether a quote typed here begins a new quotation: at the start of the
    /// field, or right after whitespace or an opening bracket.
    static func opensNewQuote(before context: String) -> Bool {
        guard let prev = context.last else { return true } // start of field
        return prev.isWhitespace || "([{".contains(prev)
    }

    /// Backward scan for an opening `„` with no matching closing `"` after it.
    static func hasUnmatchedOpen(_ context: String) -> Bool {
        var depth = 0
        for ch in context {
            if ch == openChar { depth += 1 }
            else if ch == closeChar { depth = max(0, depth - 1) }
        }
        return depth > 0
    }
}

/// The adaptive numeric-layout quote key (issue #10): ONE pure resolver owns
/// what the key displays, announces, previews, and inserts — a label/output
/// mismatch is the bug this exists to eliminate.
///
/// The key materializes Icelandic quotes only when the lane has actually
/// materialized (P(IS) strictly > 0.5 — a missing session or the neutral tie
/// stays a straight quote) and the context is safe; everything else falls back
/// to the ordinary straight `"`. Explicit long-press selections bypass the
/// resolver entirely and insert literally.
enum QuoteKey {

    /// What the next tap of the quote key will do.
    enum State {
        /// Straight `"` — neutral/English lane, non-standard field, or an
        /// ambiguous Icelandic position.
        case neutral
        /// Icelandic opening `„` (U+201E).
        case icelandicOpen
        /// Icelandic closing `"` (U+201C) — only when a backward scan finds
        /// an unmatched `„`.
        case icelandicClose
    }

    /// The single decision point. `usesIcelandicQuotes` is the quote-specific
    /// lane semantic (strictly P(IS) > 0.5, false for missing sessions — see
    /// `LyklabordAutocompleteService.usesIcelandicQuotes`), deliberately
    /// distinct from the broader `isIcelandicLane` (≥ 0.5, defaults IS).
    static func state(
        usesIcelandicQuotes: Bool,
        isStandardField: Bool,
        context: String
    ) -> State {
        guard usesIcelandicQuotes, isStandardField else { return .neutral }
        if SmartPunctuation.opensNewQuote(before: context) { return .icelandicOpen }
        if SmartPunctuation.hasUnmatchedOpen(context) { return .icelandicClose }
        return .neutral
    }

    /// The exact character a tap inserts (and the key face displays).
    static func character(for state: State) -> String {
        switch state {
        case .neutral: return "\""
        case .icelandicOpen: return SmartPunctuation.open   // „ U+201E
        case .icelandicClose: return SmartPunctuation.close // " U+201C
        }
    }

    /// Long-press alternatives, nearest-first relative to the current tap
    /// result (issue #10 ordering). Explicit selections insert literally.
    static func calloutCharacters(for state: State) -> [String] {
        switch state {
        case .neutral: return ["\"", "„", "\u{201C}", "\u{201D}", "«", "»"]
        case .icelandicOpen: return ["„", "\u{201C}", "\"", "\u{201D}", "«", "»"]
        case .icelandicClose: return ["\u{201C}", "„", "\"", "\u{201D}", "«", "»"]
        }
    }

    /// Every character the quote key can present/insert — the set the action
    /// handler must own so KeyboardKit's stock locale quotation replacement
    /// never rewrites them behind the resolver's back.
    static let ownedCharacters: Set<String> = ["\"", "\u{201D}", "„", "\u{201C}"]
}
