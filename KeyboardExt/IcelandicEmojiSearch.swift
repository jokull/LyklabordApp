// Icelandic emoji search core. The query is private keyboard UI state: this
// file never touches UITextDocumentProxy, autocomplete, learning, or logs.

import Combine
import Foundation

struct IcelandicEmojiSearchResult: Equatable, Identifiable {
    let emoji: String
    let name: String
    let rank: Int
    let stableOrder: Int

    var id: String { emoji }
}

struct IcelandicEmojiSearchIndex {
    struct Metadata: Equatable {
        let cldrVersion: String
        let emojiVersion: String
        let pickerSHA256: String
        let emojiCount: Int
        let tokenCount: Int
        let postingCount: Int
    }

    enum LoadError: Error, Equatable {
        case unsupportedSchema
        case invalidLocale
        case invalidCohort
        case invalidCounts
        case malformedEntry
    }

    private struct Artifact: Decodable {
        let schema: Int
        let locales: [String]
        let cldrVersion: String
        let emojiVersion: String
        let pickerSha256: String
        let emojiCount: Int
        let tokenCount: Int
        let postingCount: Int
        let strongMatches: [String: String]
        let entries: [[String]]
    }

    private struct Entry {
        let emoji: String
        let icelandicName: String
        let englishName: String
        let nameTokens: NSString
        let keywordTokens: NSString
        let stableOrder: Int
    }

    let metadata: Metadata
    private let entries: [Entry]
    private let strongMatches: [String: String]

    init(data: Data) throws {
        let artifact = try JSONDecoder().decode(Artifact.self, from: data)
        guard artifact.schema == 4 else { throw LoadError.unsupportedSchema }
        guard artifact.locales == ["is", "en"] else { throw LoadError.invalidLocale }
        guard artifact.cldrVersion == "48.2",
              artifact.emojiVersion == "17.0",
              artifact.pickerSha256 == "71a20055c75b4351825caf54bb716d87af9968d3490803f6a4c34426f050e172"
        else { throw LoadError.invalidCohort }
        guard artifact.entries.count == artifact.emojiCount,
              artifact.emojiCount == 1_586,
              artifact.tokenCount == 6_016,
              artifact.postingCount == 14_595
        else { throw LoadError.invalidCounts }

        var decoded: [Entry] = []
        decoded.reserveCapacity(artifact.entries.count)
        for (order, row) in artifact.entries.enumerated() {
            guard row.count == 5,
                  !row[0].isEmpty,
                  !row[1].isEmpty,
                  !row[2].isEmpty,
                  row[3].first == "|",
                  row[3].last == "|",
                  row[4].first == "|",
                  row[4].last == "|"
            else {
                throw LoadError.malformedEntry
            }
            decoded.append(Entry(
                emoji: row[0],
                icelandicName: row[1],
                englishName: row[2],
                nameTokens: row[3] as NSString,
                keywordTokens: row[4] as NSString,
                stableOrder: order
            ))
        }
        metadata = Metadata(
            cldrVersion: artifact.cldrVersion,
            emojiVersion: artifact.emojiVersion,
            pickerSHA256: artifact.pickerSha256,
            emojiCount: artifact.emojiCount,
            tokenCount: artifact.tokenCount,
            postingCount: artifact.postingCount
        )
        entries = decoded
        strongMatches = artifact.strongMatches
    }

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "is-search", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Self(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    func name(for emoji: String) -> String? {
        entries.first { Self.emojiKey($0.emoji) == Self.emojiKey(emoji) }?.icelandicName
    }

    func frecencyResult(for emoji: String, order: Int) -> IcelandicEmojiSearchResult? {
        guard let entry = entries.first(where: {
            Self.emojiKey($0.emoji) == Self.emojiKey(emoji)
        }) else { return nil }
        return IcelandicEmojiSearchResult(
            emoji: entry.emoji, name: entry.icelandicName, rank: 0, stableOrder: order
        )
    }

    func search(
        _ rawQuery: String,
        limit: Int = 24,
        frecencyOrder: [String: Int] = [:]
    ) -> [IcelandicEmojiSearchResult] {
        let query = Self.normalize(rawQuery)
        guard !query.isEmpty, limit > 0 else { return [] }
        let foldedQuery = Self.fold(query)
        let exactTokenNeedle = "|\(query)|"
        let tokenPrefixNeedle = "|\(query)"
        var normalizedFrecency: [String: Int] = [:]
        for (emoji, order) in frecencyOrder.sorted(by: { $0.value < $1.value }) {
            if normalizedFrecency[Self.emojiKey(emoji)] == nil {
                normalizedFrecency[Self.emojiKey(emoji)] = order
            }
        }

        let directResults = entries.compactMap { entry -> IcelandicEmojiSearchResult? in
            let isStrongMatch = strongMatches[query].map(Self.emojiKey) == Self.emojiKey(entry.emoji)
            guard let rank = (isStrongMatch
                ? -1
                : Self.rank(
                    query: query,
                    exactTokenNeedle: exactTokenNeedle,
                    tokenPrefixNeedle: tokenPrefixNeedle,
                    icelandicName: entry.icelandicName,
                    englishName: entry.englishName,
                    nameTokens: entry.nameTokens,
                    keywordTokens: entry.keywordTokens
                ))
            else { return nil }
            return IcelandicEmojiSearchResult(
                emoji: entry.emoji,
                name: entry.icelandicName,
                rank: rank,
                stableOrder: entry.stableOrder
            )
        }
        let matched = directResults.isEmpty ? entries.compactMap { entry -> IcelandicEmojiSearchResult? in
            guard let rank = Self.rank(
                        query: foldedQuery,
                        exactTokenNeedle: "|\(foldedQuery)|",
                        tokenPrefixNeedle: "|\(foldedQuery)",
                        icelandicName: Self.fold(entry.icelandicName),
                        englishName: Self.fold(entry.englishName),
                        nameTokens: Self.fold(entry.nameTokens as String) as NSString,
                        keywordTokens: Self.fold(entry.keywordTokens as String) as NSString
            ) else { return nil }
            return IcelandicEmojiSearchResult(
                emoji: entry.emoji,
                name: entry.icelandicName,
                rank: rank + 5,
                stableOrder: entry.stableOrder
            )
        } : directResults

        return matched.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let lhsFrecency = normalizedFrecency[Self.emojiKey($0.emoji)] ?? Int.max
            let rhsFrecency = normalizedFrecency[Self.emojiKey($1.emoji)] ?? Int.max
            if lhsFrecency != rhsFrecency { return lhsFrecency < rhsFrecency }
            return $0.stableOrder < $1.stableOrder
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func rank(
        query: String,
        exactTokenNeedle: String,
        tokenPrefixNeedle: String,
        icelandicName: String,
        englishName: String,
        nameTokens: NSString,
        keywordTokens: NSString
    ) -> Int? {
        if icelandicName == query || englishName == query { return 0 }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return nil }

        if queryTokens.count == 1 {
            if hasExactToken(keywordTokens, exactTokenNeedle) { return 1 }
            if hasExactToken(nameTokens, exactTokenNeedle) { return 2 }
            if hasTokenPrefix(nameTokens, tokenPrefixNeedle) { return 3 }
            if hasTokenPrefix(keywordTokens, tokenPrefixNeedle) { return 4 }
            return nil
        }

        if hasExactToken(keywordTokens, "|#\(query)|") { return 1 }

        var worstRank = 2
        for queryToken in queryTokens {
            let exactNeedle = "|\(queryToken)|"
            let prefixNeedle = "|\(queryToken)"
            if hasExactToken(nameTokens, exactNeedle) {
                worstRank = max(worstRank, 2)
            } else if hasTokenPrefix(nameTokens, prefixNeedle) {
                worstRank = max(worstRank, 3)
            } else if hasTokenPrefix(keywordTokens, prefixNeedle) {
                worstRank = max(worstRank, 4)
            } else {
                return nil
            }
        }
        return worstRank
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "is"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "is"))
    }

    private static func emojiKey(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{FE0E}", with: "")
            .replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    private static func tokens(_ value: String) -> [String] {
        value.split { character in
            isTokenSeparator(character)
        }.map(String.init)
    }

    private static func hasExactToken(_ field: NSString, _ needle: String) -> Bool {
        field.range(of: needle).location != NSNotFound
    }

    private static func hasTokenPrefix(_ field: NSString, _ needle: String) -> Bool {
        field.range(of: needle).location != NSNotFound
    }

    private static func isTokenSeparator(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber || character == "-")
    }
}

@MainActor
final class IcelandicEmojiSearchSession: ObservableObject {
    enum Mode: Equatable { case browse, search }

    @Published private(set) var mode: Mode = .browse
    @Published private(set) var query = ""
    @Published private(set) var results: [IcelandicEmojiSearchResult] = []
    @Published private(set) var loadFailed = false

    private var index: IcelandicEmojiSearchIndex?
    private var expectedHostWindow: String?
    private var expectedInsertedEmoji: String?
    private var acceptedHostWindow: String?
    private let loader: () throws -> IcelandicEmojiSearchIndex
    private let frecency: () -> [String]

    init(
        loader: @escaping () throws -> IcelandicEmojiSearchIndex = {
            try IcelandicEmojiSearchIndex.bundled()
        },
        frecency: @escaping () -> [String] = { EmojiFrequencyStore.shared.top(24) }
    ) {
        self.loader = loader
        self.frecency = frecency
    }

    func begin(hostWindow: String? = nil) {
        mode = .search
        acceptedHostWindow = hostWindow
        refresh()
    }

    func append(_ text: String) {
        guard mode == .search else { return }
        if text.allSatisfy(\.isWhitespace) {
            guard !query.isEmpty, query.last?.isWhitespace != true else { return }
            query.append(" ")
            refresh()
            return
        }
        query.append(contentsOf: text)
        refresh()
    }

    func backspace() {
        guard mode == .search, !query.isEmpty else { return }
        query.removeLast()
        refresh()
    }

    func done() {
        query = ""
        results = []
        mode = .browse
        expectedHostWindow = nil
        expectedInsertedEmoji = nil
        acceptedHostWindow = nil
    }

    func exit() { done() }

    func clear() {
        guard mode == .search else { return }
        query = ""
        refresh()
    }

    func expectEmojiHostInsertion(before: String, emoji: String) {
        expectedHostWindow = before + emoji
        expectedInsertedEmoji = emoji
    }

    /// Returns true when an external host mutation invalidated search. Repeated
    /// callbacks for the accepted window are harmless; the selected-emoji
    /// transform is also accepted if iOS truncates the proxy's context window.
    func hostContextDidChange(window: String) -> Bool {
        guard mode == .search else { return false }
        if let expectedHostWindow,
           let expectedInsertedEmoji,
           window.hasSuffix(expectedInsertedEmoji),
           expectedHostWindow.hasSuffix(window) {
            acceptedHostWindow = window
            self.expectedHostWindow = nil
            self.expectedInsertedEmoji = nil
            return false
        }
        if window == acceptedHostWindow { return false }
        done()
        return true
    }

    private func refresh() {
        if index == nil, !loadFailed {
            do { index = try loader() } catch { loadFailed = true }
        }
        guard let index else { results = []; return }
        if query.isEmpty {
            let ordered = frecency()
            results = ordered.enumerated().compactMap { offset, emoji in
                index.frecencyResult(for: emoji, order: offset)
            }
        } else {
            let order = Dictionary(uniqueKeysWithValues: frecency().enumerated().map { ($1, $0) })
            results = index.search(query, frecencyOrder: order)
        }
    }
}
