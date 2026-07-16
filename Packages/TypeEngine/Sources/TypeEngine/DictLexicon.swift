import Lexicon

/// Dictionary-backed `Lexicon` for tests and the micro-eval harness.
///
/// The canonical `Lexicon` protocol lives in the Lexicon package (alongside
/// the production `FrequencyLexicon` mmap reader over `.lex` files); this
/// test double stays here because TypeEngine's tests and `type-eval` seed it
/// with tiny in-memory wordlists. Not intended for production use
/// (linear-scan completions).
public struct DictLexicon: Lexicon {
    private let unigrams: [String: UInt32]
    private let bigrams: [String: UInt32]
    public let totalUnigramTokens: UInt64
    /// Words sorted by raw UTF-8 bytes (the same code-point order the
    /// production `.lex` pool uses), for the prefix-cursor walk.
    private let sortedEntries: [(bytes: [UInt8], word: String, frequency: UInt32)]

    /// - Parameters:
    ///   - unigrams: word -> frequency (words should be lowercased)
    ///   - bigrams: "first second" (single space) -> frequency
    public init(unigrams: [String: UInt32], bigrams: [String: UInt32] = [:]) {
        self.unigrams = unigrams
        self.bigrams = bigrams
        self.totalUnigramTokens = unigrams.values.reduce(0) { $0 + UInt64($1) }
        self.sortedEntries = unigrams
            .map { (bytes: Array($0.key.utf8), word: $0.key, frequency: $0.value) }
            .sorted { lhs, rhs in
                let n = min(lhs.bytes.count, rhs.bytes.count)
                var i = 0
                while i < n {
                    if lhs.bytes[i] != rhs.bytes[i] { return lhs.bytes[i] < rhs.bytes[i] }
                    i += 1
                }
                return lhs.bytes.count < rhs.bytes.count
            }
    }

    public func frequency(of word: String) -> UInt32? {
        unigrams[word]
    }

    public func bigramFrequency(_ first: String, _ second: String) -> UInt32? {
        bigrams["\(first) \(second)"]
    }

    public func completions(of prefix: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        return unigrams
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { (word: $0.key, frequency: $0.value) }
    }

    /// Bigram followers of `word`, descending bigram frequency (linear scan
    /// over the bigram table — test-double quality, mirrors
    /// `FrequencyLexicon.continuations(of:limit:)` semantics).
    public func continuations(of word: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = "\(word) "
        return bigrams
            .compactMap { key, freq -> (word: String, frequency: UInt32)? in
                guard key.hasPrefix(prefix) else { return nil }
                return (word: String(key.dropFirst(prefix.count)), frequency: freq)
            }
            .sorted { $0.frequency > $1.frequency || ($0.frequency == $1.frequency && $0.word < $1.word) }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - PrefixSearchableLexicon (beam-decoder substrate)

extension DictLexicon: PrefixSearchableLexicon {

    public func prefixRootCursor() -> LexiconPrefixCursor {
        LexiconPrefixCursor(lowerBound: 0, upperBound: sortedEntries.count, byteDepth: 0)
    }

    public func descend(
        _ cursor: LexiconPrefixCursor, appendingUTF8 bytes: [UInt8]
    ) -> LexiconPrefixCursor {
        let depth = cursor.byteDepth + bytes.count
        guard !cursor.isEmpty, !bytes.isEmpty else {
            return LexiconPrefixCursor(
                lowerBound: cursor.lowerBound, upperBound: cursor.lowerBound, byteDepth: depth)
        }

        /// -1 / 0 / 1: entry's bytes at [cursor.byteDepth, +bytes.count) vs
        /// `bytes`; an entry too short to cover the window sorts before it.
        func compare(_ index: Int) -> Int {
            let word = sortedEntries[index].bytes
            var i = 0
            while i < bytes.count {
                let j = cursor.byteDepth + i
                if j >= word.count { return -1 }
                if word[j] != bytes[i] { return word[j] < bytes[i] ? -1 : 1 }
                i += 1
            }
            return 0
        }

        func bound(strict: Bool) -> Int {
            var lo = cursor.lowerBound
            var hi = cursor.upperBound
            while lo < hi {
                let mid = (lo + hi) >> 1
                let c = compare(mid)
                if strict ? c > 0 : c >= 0 { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        return LexiconPrefixCursor(
            lowerBound: bound(strict: false), upperBound: bound(strict: true), byteDepth: depth)
    }

    public func exactEntry(in cursor: LexiconPrefixCursor) -> (word: String, frequency: UInt32)? {
        guard !cursor.isEmpty, cursor.byteDepth > 0 else { return nil }
        let entry = sortedEntries[cursor.lowerBound]
        guard entry.bytes.count == cursor.byteDepth else { return nil }
        return (word: entry.word, frequency: entry.frequency)
    }

    public func childCursors(
        of cursor: LexiconPrefixCursor, scanLimit: Int
    ) -> [(character: Character, cursor: LexiconPrefixCursor)]? {
        guard cursor.count <= scanLimit else { return nil }
        guard !cursor.isEmpty else { return [] }

        var children: [(character: Character, cursor: LexiconPrefixCursor)] = []
        var groupStart = -1
        var groupBytes: ArraySlice<UInt8> = []

        func closeGroup(endingAt end: Int) {
            guard groupStart >= 0, let character = String(decoding: groupBytes, as: UTF8.self).first
            else { return }
            children.append(
                (
                    character: character,
                    cursor: LexiconPrefixCursor(
                        lowerBound: groupStart,
                        upperBound: end,
                        byteDepth: cursor.byteDepth + groupBytes.count
                    )
                )
            )
        }

        for index in cursor.lowerBound..<cursor.upperBound {
            let word = sortedEntries[index].bytes
            guard word.count > cursor.byteDepth else { continue }
            let lead = word[cursor.byteDepth]
            let scalarLength: Int
            switch lead {
            case ..<0x80: scalarLength = 1
            case ..<0xE0: scalarLength = 2
            case ..<0xF0: scalarLength = 3
            default: scalarLength = 4
            }
            let end = min(cursor.byteDepth + scalarLength, word.count)
            let bytes = word[cursor.byteDepth..<end]
            if bytes != groupBytes {
                closeGroup(endingAt: index)
                groupStart = index
                groupBytes = bytes
            }
        }
        closeGroup(endingAt: cursor.upperBound)
        return children
    }
}
