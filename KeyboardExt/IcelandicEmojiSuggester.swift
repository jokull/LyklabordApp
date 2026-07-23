//
//  IcelandicEmojiSuggester.swift
//  LyklabordKeyboard
//
//  Exact Icelandic label -> emoji lookup. The small bundled index is generated
//  from Unicode CLDR by scripts/build-emoji-labels.py; no typed text leaves the
//  device and the full 3,944-record corpus is not decoded in the extension.
//

import Foundation

struct IcelandicEmojiSuggester {

    private struct Artifact: Decodable {
        let schema: Int
        let locale: String
        let count: Int
        let suggestions: [String: String]
    }

    private let suggestions: [String: String]

    init?(contentsOf url: URL) {
        guard
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let artifact = try? JSONDecoder().decode(Artifact.self, from: data),
            artifact.schema == 1,
            artifact.locale == "is",
            artifact.count == artifact.suggestions.count
        else { return nil }
        suggestions = artifact.suggestions
    }

    /// Return at most one high-confidence match. Prefixes and fuzzy matches
    /// are intentionally excluded: an emoji costs one of the three bar slots.
    func suggestion(for token: String) -> String? {
        guard token.count >= 2 else { return nil }
        let key = token
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "is_IS"))
        return suggestions[key]
    }
}
