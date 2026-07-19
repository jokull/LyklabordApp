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
