//
//  TextReplacements.swift
//  LyklabordKeyboard
//
//  System text replacements (issue #5): iOS exposes the user's
//  Settings → General → Keyboard → Text Replacement shortcuts (plus
//  Apple-shipped common-word pairs and unpaired contact names) to keyboard
//  extensions via `UILexicon` — but never auto-applies them for third-party
//  keyboards, so the extension must match and expand them itself. This type
//  is the PURE half of that feature: an immutable shortcut → expansion
//  table with a whole-token, case-insensitive lookup. The impure halves —
//  fetching the lexicon (`requestSupplementaryLexicon`, a
//  `UIInputViewController` method) and riding the expansion through the
//  armed-autocorrect machinery — live in `KeyboardViewController` and
//  `LyklabordAutocompleteService` respectively.
//
//  Kept UIKit-free and value-semantic on purpose: `UILexicon` cannot be
//  constructed in tests (UIKit, extension-only), so the controller reduces
//  it to plain string pairs at the boundary and everything below is
//  deterministic. No XCTest target exists for KeyboardExt; coverage is
//  compilation + on-device verification (matching the file-level testing
//  note in issue #5).
//
//  Privacy: entries include contact names. The table is in-memory only —
//  never logged (not even counts of *which* entries matched), never written
//  to the App Group, never fed to learning or the dev-mode session
//  recorder's suggestion pass (see the injection-ordering comment in
//  `LyklabordAutocompleteService.performAutocomplete`).
//

import Foundation

/// Immutable shortcut → expansion table built from the system `UILexicon`.
struct TextReplacements {

    /// Lowercased `UILexiconEntry.userInput` → `documentText`, verbatim.
    /// Lowercasing at build time makes the per-keystroke lookup a single
    /// dictionary hit on the lowercased typed token — no scan of the entry
    /// list on the hot path.
    private let expansions: [String: String]

    /// - Parameter entries: `(userInput, documentText)` pairs in `UILexicon`
    ///   order. First entry wins on a duplicate shortcut so the table is
    ///   deterministic regardless of how iOS interleaves user-defined
    ///   replacements with its own common-word/contact entries.
    init(entries: [(shortcut: String, replacement: String)]) {
        var map: [String: String] = [:]
        map.reserveCapacity(entries.count)
        for entry in entries {
            let key = entry.shortcut.lowercased()
            guard !key.isEmpty, !entry.replacement.isEmpty else { continue }
            if map[key] == nil { map[key] = entry.replacement }
        }
        self.expansions = map
    }

    var isEmpty: Bool { expansions.isEmpty }

    /// Entry count only — safe to log (contents never are).
    var count: Int { expansions.count }

    /// The expansion for `token`, or nil.
    ///
    /// - Whole-token, case-insensitive equality ONLY (issue #5 guard):
    ///   a shortcut never fires on a prefix — "om" must not expand while
    ///   the user is still typing toward "omg". The caller passes the
    ///   session's complete pending token (`TypingSession.splitCurrentWord`),
    ///   so dotted/'@' tokens compare whole too.
    /// - Byte-identical expansion ⇒ nil: `UILexicon`'s common-word entries
    ///   are often identity pairs ("word" → "word"); returning them would
    ///   arm a no-op autocorrect and light the blue spacebar hint for
    ///   nothing. A CASE-differing match still fires ("ipad" → "iPad" —
    ///   exactly the capitalization service those Apple entries exist for).
    func match(token: String) -> String? {
        guard !token.isEmpty else { return nil }
        guard let replacement = expansions[token.lowercased()] else { return nil }
        guard replacement != token else { return nil }
        return replacement
    }
}
