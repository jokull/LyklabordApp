import Foundation

/// A half-open range `[lowerBound, upperBound)` of a lexicon's sorted
/// unigram table, covering exactly the words that share an (implicit) UTF-8
/// byte prefix of length `byteDepth`.
///
/// This is the state of an incremental prefix walk: start at
/// `prefixRootCursor()` (the whole table, empty prefix) and narrow one
/// character at a time with `descend(_:appendingUTF8:)`. Because the pool is
/// sorted by raw UTF-8 bytes (code-point order — see FORMAT.md), every
/// prefix's words form one contiguous index range, and narrowing is two
/// binary searches *restricted to the parent range* that only compare the
/// newly appended bytes at offset `byteDepth`.
///
/// The cursor deliberately does not store the prefix string itself: callers
/// that need the surface form of an exact hit read it back through
/// `exactEntry(in:)`. A cursor is only meaningful against the lexicon that
/// produced it.
///
/// UTF-8 note: `byteDepth` counts BYTES, not characters. Callers must append
/// whole characters (all Icelandic letters are 2-byte UTF-8 sequences), so a
/// cursor produced by the public API is always scalar-aligned; the byte-wise
/// representation is an internal detail of the byte-sorted pool.
public struct LexiconPrefixCursor: Hashable, Sendable {
    /// First index of the range (inclusive).
    public let lowerBound: Int
    /// One past the last index of the range (exclusive).
    public let upperBound: Int
    /// Byte length of the prefix all words in the range share.
    public let byteDepth: Int

    public init(lowerBound: Int, upperBound: Int, byteDepth: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.byteDepth = byteDepth
    }

    /// True when no word carries this prefix.
    public var isEmpty: Bool { lowerBound >= upperBound }
    /// Number of words carrying this prefix.
    public var count: Int { max(0, upperBound - lowerBound) }
}

/// Incremental prefix-range navigation over a sorted-pool lexicon — the
/// substrate for beam-search decoding (TypeEngine's spatial decoder walks
/// typed characters and lexicon prefixes in lockstep, narrowing a cursor per
/// hypothesized intended character).
///
/// Additive to `Lexicon`: conformers still support all point lookups; this
/// protocol only exposes the sorted-order structure they already have.
public protocol PrefixSearchableLexicon: Lexicon {
    /// Cursor over the whole unigram table (the empty prefix).
    func prefixRootCursor() -> LexiconPrefixCursor

    /// Narrow `cursor` to the words whose next bytes (at `cursor.byteDepth`)
    /// equal `bytes`. Returns an empty cursor (at the extended depth) when
    /// no word continues that way. `bytes` must be the UTF-8 of one or more
    /// whole characters, normalized the same way the lexicon's stored words
    /// are (lowercased, NFC, straight apostrophe — see
    /// `FrequencyLexicon.normalizedKey`).
    func descend(
        _ cursor: LexiconPrefixCursor, appendingUTF8 bytes: [UInt8]
    ) -> LexiconPrefixCursor

    /// The word that IS the cursor's prefix (byte length == `byteDepth`),
    /// with its frequency — or nil when the prefix is not itself a word.
    /// In byte-sorted order that word, when present, is always the first
    /// entry of the range.
    func exactEntry(in cursor: LexiconPrefixCursor) -> (word: String, frequency: UInt32)?

    /// All distinct one-CHARACTER extensions of the cursor's prefix, as
    /// (character, narrowed cursor) pairs in byte-sorted order — one linear
    /// scan of the range instead of two binary searches per probed
    /// character, which is what makes small ranges cheap to expand
    /// exhaustively (the beam decoder's deep states). Entries equal to the
    /// prefix itself (the `exactEntry`) are skipped.
    ///
    /// Returns nil when `cursor.count > scanLimit`: large ranges are
    /// cheaper to probe with `descend` (callers fall back).
    func childCursors(
        of cursor: LexiconPrefixCursor, scanLimit: Int
    ) -> [(character: Character, cursor: LexiconPrefixCursor)]?
}

extension PrefixSearchableLexicon {
    /// Convenience: narrow by one character (converts to UTF-8; hot callers
    /// should precompute byte arrays and use `descend(_:appendingUTF8:)`).
    public func descend(
        _ cursor: LexiconPrefixCursor, appending character: Character
    ) -> LexiconPrefixCursor {
        descend(cursor, appendingUTF8: Array(String(character).utf8))
    }
}

// MARK: - FrequencyLexicon conformance

extension FrequencyLexicon: PrefixSearchableLexicon {

    public func prefixRootCursor() -> LexiconPrefixCursor {
        LexiconPrefixCursor(lowerBound: 0, upperBound: unigramCount, byteDepth: 0)
    }

    public func descend(
        _ cursor: LexiconPrefixCursor, appendingUTF8 bytes: [UInt8]
    ) -> LexiconPrefixCursor {
        let depth = cursor.byteDepth + bytes.count
        guard !cursor.isEmpty, !bytes.isEmpty else {
            return LexiconPrefixCursor(
                lowerBound: cursor.lowerBound, upperBound: cursor.lowerBound, byteDepth: depth)
        }
        return withPrefixBuffer { buf in
            // Every word in [lowerBound, upperBound) shares the first
            // `cursor.byteDepth` bytes, so both bounds compare only the
            // appended bytes at that offset.
            let lo = suffixBound(
                bytes, at: cursor.byteDepth, in: cursor, strict: false, buf: buf)
            let hi = suffixBound(
                bytes, at: cursor.byteDepth, in: cursor, strict: true, buf: buf)
            return LexiconPrefixCursor(lowerBound: lo, upperBound: hi, byteDepth: depth)
        }
    }

    public func exactEntry(in cursor: LexiconPrefixCursor) -> (word: String, frequency: UInt32)? {
        guard !cursor.isEmpty, cursor.byteDepth > 0 else { return nil }
        return withPrefixBuffer { buf in
            // The word equal to the prefix is byte-shortest among all words
            // sharing it, so it sorts first in the range when present.
            let index = cursor.lowerBound
            guard prefixWordLength(at: index, buf: buf) == cursor.byteDepth else { return nil }
            return (
                word: prefixWordString(at: index, buf: buf),
                frequency: prefixWordFrequency(at: index, buf: buf)
            )
        }
    }

    public func childCursors(
        of cursor: LexiconPrefixCursor, scanLimit: Int
    ) -> [(character: Character, cursor: LexiconPrefixCursor)]? {
        guard cursor.count <= scanLimit else { return nil }
        guard !cursor.isEmpty else { return [] }
        return withPrefixBuffer { buf in
            var children: [(character: Character, cursor: LexiconPrefixCursor)] = []
            var groupStart = -1
            var groupBytes: [UInt8] = []

            func closeGroup(endingAt end: Int) {
                guard groupStart >= 0 else { return }
                let scalar = String(decoding: groupBytes, as: UTF8.self)
                guard let character = scalar.first else { return }
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
                let length = prefixWordLength(at: index, buf: buf)
                // The exact-prefix word has no next character; in sorted
                // order it can only be the first entry.
                guard length > cursor.byteDepth else { continue }
                let bytes = prefixScalarBytes(
                    at: index, depth: cursor.byteDepth, length: length, buf: buf)
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
}
