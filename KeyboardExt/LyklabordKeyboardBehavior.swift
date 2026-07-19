//
//  LyklabordKeyboardBehavior.swift
//  LyklabordKeyboard
//
//  Custom keyboard behavior — currently just decision D3/D2 of the punctuation
//  wave (docs/PUNCTUATION_BEHAVIOR.md): a period preceded by a digit is an
//  ORDINAL or decimal ("21.", "1.000,50", "v2.0"), not a sentence end, so it
//  must not auto-capitalize the following word. In Icelandic this is constant —
//  dates ("þann 21. mars"), lists, versions — and native/generic keyboards get
//  it wrong, capitalizing "Mars".
//
//  Everything else defers to KeyboardKit's StandardKeyboardBehavior unchanged
//  (double-space→". ", sentence auto-cap, layout switching, backspace range).
//

import Foundation
import KeyboardKit

final class LyklabordKeyboardBehavior: Keyboard.StandardKeyboardBehavior {

    override func preferredKeyboardCase(
        after gesture: Keyboard.Gesture,
        on action: KeyboardAction
    ) -> Keyboard.KeyboardCase {
        let base = super.preferredKeyboardCase(after: gesture, on: action)
        // Only ever downgrade an AUTO-capitalization. If the user is holding
        // shift or has caps lock on (keyboardCase itself is uppercased/locked),
        // leave it — that's a deliberate uppercase, not sentence auto-cap.
        guard base == .uppercased,
            keyboardContext.keyboardCase != .uppercased,
            keyboardContext.keyboardCase != .capsLocked
        else { return base }

        let before = keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        return isAfterOrdinalPeriod(before) ? .lowercased : base
    }

    /// True when the text before the cursor ends with `<digit>.` (optionally
    /// followed by whitespace) — i.e. the only reason it "looks like" a new
    /// sentence is an ordinal/decimal period.
    private func isAfterOrdinalPeriod(_ before: String) -> Bool {
        var iterator = before.reversed().drop(while: { $0 == " " || $0 == "\n" }).makeIterator()
        guard iterator.next() == "." else { return false }        // last non-space is "."
        guard let prev = iterator.next(), prev.isNumber else { return false } // digit before it
        return true
    }
}
