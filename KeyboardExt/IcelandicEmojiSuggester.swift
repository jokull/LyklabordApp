//
//  IcelandicEmojiSuggester.swift
//  LyklabordKeyboard
//
//  Exact label -> emoji lookup, Icelandic and English. The two small bundled
//  indexes are generated from Unicode CLDR by scripts/build-emoji-labels.py; no
//  typed text leaves the device and the full 3,944-record corpus is not decoded
//  in the extension.
//
//  Icelandic labels always match. English labels match only while the typing
//  lane is English: many are ordinary Icelandic words with another meaning
//  ("man" → 👨, "send" → 📩), and an emoji costs one of the three bar slots.
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
    private let englishSuggestions: [String: String]

    /// `englishURL` is optional in every sense: nil, missing or corrupt
    /// leaves English matching off and Icelandic matching unchanged.
    init?(
        contentsOf url: URL,
        english englishURL: URL? = nil,
        availability: EmojiAvailability = .current
    ) {
        guard let icelandic = Self.load(url, locale: "is", availability: availability) else {
            return nil
        }
        suggestions = icelandic
        englishSuggestions =
            englishURL.flatMap { Self.load($0, locale: "en", availability: availability) } ?? [:]
    }

    private static func load(
        _ url: URL, locale: String, availability: EmojiAvailability
    ) -> [String: String]? {
        guard
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let artifact = try? JSONDecoder().decode(Artifact.self, from: data),
            artifact.schema == 2,
            artifact.locale == locale,
            artifact.count == artifact.suggestions.count
        else { return nil }
        return artifact.suggestions.compactMapValues {
            availability.supports(tier: $0.tier) ? $0.emoji : nil
        }
    }

    /// Return at most one high-confidence match. Prefixes and fuzzy matches
    /// are intentionally excluded: an emoji costs one of the three bar slots.
    /// An Icelandic label wins over an English one for the same token.
    func suggestion(for token: String, englishLane: Bool = false) -> String? {
        guard token.count >= 2 else { return nil }
        let key = token
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "is_IS"))
        if let icelandic = suggestions[key] { return icelandic }
        return englishLane ? englishSuggestions[key] : nil
    }
}
