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
        let suggestions: [String: Suggestion]
    }

    private struct Suggestion: Decodable {
        let emoji: String
        let tier: Int

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            emoji = try values.decode(String.self)
            tier = try values.decode(Int.self)
            guard values.isAtEnd, !emoji.isEmpty, (0...2).contains(tier) else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "Malformed emoji suggestion"
                )
            }
        }
    }

    private let suggestions: [String: String]

    init?(contentsOf url: URL, availability: EmojiAvailability = .current) {
        guard
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let artifact = try? JSONDecoder().decode(Artifact.self, from: data),
            artifact.schema == 2,
            artifact.locale == "is",
            artifact.count == artifact.suggestions.count
        else { return nil }
        suggestions = artifact.suggestions.compactMapValues {
            availability.supports(tier: $0.tier) ? $0.emoji : nil
        }
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
