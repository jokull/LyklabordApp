// Version-aware Unicode emoji repertoire shared by every keyboard surface.
// The generated catalog is authoritative; runtime glyph probing is deliberately
// not used because individual-glyph APIs cannot validate ZWJ shaping.

import Foundation
import ISEmojiView

struct EmojiAvailability: Equatable {
    let maximumTier: Int

    init(operatingSystemVersion version: OperatingSystemVersion) {
        if version.majorVersion > 26
            || (version.majorVersion == 26 && version.minorVersion >= 4) {
            maximumTier = 2       // Unicode Emoji 17.0
        } else if version.majorVersion > 18
                    || (version.majorVersion == 18 && version.minorVersion >= 4) {
            maximumTier = 1       // Unicode Emoji 16.0
        } else {
            maximumTier = 0       // Unicode Emoji 15.1 (Lyklaborð's iOS 18 floor)
        }
    }

    init(maximumTier: Int) {
        self.maximumTier = maximumTier
    }

    static let current = EmojiAvailability(
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
    )

    func supports(tier: Int) -> Bool {
        tier >= 0 && tier <= maximumTier
    }
}

struct EmojiCatalog {
    struct Metadata: Equatable {
        let emojiVersion: String
        let sequenceCount: Int
        let familyCount: Int
    }

    private struct Artifact: Decodable {
        let schema: Int
        let emojiVersion: String
        let sequenceCount: Int
        let familyCount: Int
        let categories: [ArtifactCategory]
    }

    private struct ArtifactCategory: Decodable {
        let title: String
        let families: [ArtifactFamily]
    }

    private struct ArtifactFamily: Decodable {
        let base: String
        let variants: [Variant]
    }

    struct Variant: Decodable, Equatable {
        let emoji: String
        let tier: Int

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            emoji = try values.decode(String.self)
            tier = try values.decode(Int.self)
            guard values.isAtEnd, !emoji.isEmpty, (0...2).contains(tier) else {
                throw DecodingError.dataCorruptedError(
                    in: values,
                    debugDescription: "Malformed emoji catalog variant"
                )
            }
        }
    }

    private struct Family {
        let base: String
        let variants: [Variant]
    }

    private struct CatalogCategory {
        let category: ISEmojiView.Category
        let families: [Family]
    }

    enum LoadError: Error, Equatable {
        case unsupportedSchema
        case invalidCounts
        case unknownCategory(String)
        case malformedFamily
    }

    let metadata: Metadata
    private let categories: [CatalogCategory]

    init(data: Data) throws {
        let artifact = try JSONDecoder().decode(Artifact.self, from: data)
        guard artifact.schema == 1, artifact.emojiVersion == "17.0" else {
            throw LoadError.unsupportedSchema
        }
        guard artifact.sequenceCount == 3_944, artifact.familyCount == 1_914 else {
            throw LoadError.invalidCounts
        }

        var decodedCategories: [CatalogCategory] = []
        var decodedSequences = 0
        var decodedFamilies = 0
        for artifactCategory in artifact.categories {
            guard let category = Self.category(named: artifactCategory.title) else {
                throw LoadError.unknownCategory(artifactCategory.title)
            }
            let families = try artifactCategory.families.map { family -> Family in
                guard !family.base.isEmpty,
                      family.variants.contains(where: { Self.key($0.emoji) == Self.key(family.base) })
                else { throw LoadError.malformedFamily }
                decodedSequences += family.variants.count
                decodedFamilies += 1
                return Family(base: family.base, variants: family.variants)
            }
            decodedCategories.append(CatalogCategory(category: category, families: families))
        }
        guard decodedSequences == artifact.sequenceCount,
              decodedFamilies == artifact.familyCount
        else { throw LoadError.invalidCounts }

        metadata = Metadata(
            emojiVersion: artifact.emojiVersion,
            sequenceCount: artifact.sequenceCount,
            familyCount: artifact.familyCount
        )
        categories = decodedCategories
    }

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Self(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static let shared: EmojiCatalog? = try? bundled()
    static let currentPickerCategories: [EmojiCategory]? =
        shared?.pickerCategories(availability: .current)

    func pickerCategories(availability: EmojiAvailability = .current) -> [EmojiCategory] {
        categories.compactMap { catalogCategory in
            let emojis = catalogCategory.families.compactMap { family -> ISEmojiView.Emoji? in
                guard let base = family.variants.first(where: {
                    Self.key($0.emoji) == Self.key(family.base)
                        && availability.supports(tier: $0.tier)
                }) else { return nil }
                let variants = family.variants
                    .filter { availability.supports(tier: $0.tier) }
                    .map(\.emoji)
                guard !variants.isEmpty else { return nil }
                // Keep the canonical base first even if Emoji Test ever changes
                // the order of a family's modifier rows.
                let ordered = [base.emoji] + variants.filter {
                    Self.key($0) != Self.key(base.emoji)
                }
                return ISEmojiView.Emoji(emojis: ordered)
            }
            guard !emojis.isEmpty else { return nil }
            return EmojiCategory(category: catalogCategory.category, emojis: emojis)
        }
    }

    func isAvailable(_ emoji: String, availability: EmojiAvailability = .current) -> Bool {
        let key = Self.key(emoji)
        return categories.contains { category in
            category.families.contains { family in
                family.variants.contains {
                    Self.key($0.emoji) == key && availability.supports(tier: $0.tier)
                }
            }
        }
    }

    func variants(
        for emoji: String,
        availability: EmojiAvailability = .current
    ) -> [String] {
        let key = Self.key(emoji)
        for category in categories {
            if let family = category.families.first(where: { family in
                family.variants.contains { Self.key($0.emoji) == key }
            }) {
                return family.variants
                    .filter { availability.supports(tier: $0.tier) }
                    .map(\.emoji)
            }
        }
        return []
    }

    private static func category(named title: String) -> ISEmojiView.Category? {
        switch title {
        case "Smileys & People": return .smileysAndPeople
        case "Animals & Nature": return .animalsAndNature
        case "Food & Drink": return .foodAndDrink
        case "Activity": return .activity
        case "Travel & Places": return .travelAndPlaces
        case "Objects": return .objects
        case "Symbols": return .symbols
        case "Flags": return .flags
        default: return nil
        }
    }

    static func key(_ emoji: String) -> String {
        emoji.replacingOccurrences(of: "\u{FE0E}", with: "")
            .replacingOccurrences(of: "\u{FE0F}", with: "")
    }
}
