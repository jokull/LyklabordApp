import Foundation

/// Importer for Microsoft SwiftKey's personal-data export.
///
/// SwiftKey's "Download your data" export contains
/// `SwiftKey Keyboard/Dictionary/vocabulary.txt` — a UTF-8 text file with
/// `#`-prefixed header comments followed by one learned vocabulary entry per
/// line (words, names, hashtags, stray punctuation). This importer turns
/// that list into explicitly-accepted learned words in a `PersonalModel`,
/// giving migrating users their years of personal vocabulary on day one.
///
/// The export file is the user's personal data: it is read from a location
/// the user provides (Files picker) and must never be bundled or committed.
public enum SwiftKeyImport {

    public struct Summary: Equatable, Sendable {
        /// Words imported (or refreshed) as explicitly-accepted learned words.
        public var imported: Int
        /// Lines skipped: comments, blanks, symbols, digits, invalid tokens.
        public var skippedInvalid: Int
        /// Words skipped because the user previously deleted them here —
        /// a tombstone in Lyklaborð outranks SwiftKey history.
        public var skippedTombstoned: Int
    }

    /// Parse a `vocabulary.txt` export into clean candidate words.
    ///
    /// - `#`-prefixed lines and blanks are dropped (header comments; also
    ///   strips a leading `#` from hashtag entries so the bare word imports —
    ///   our tokenizer treats `#` as a boundary, so `#startup` is typed as
    ///   `#` + `startup`).
    /// - Curly apostrophes fold to `'` (matches lexicon normalization).
    /// - A candidate must pass `EventLog.isLearnableWord` (letters with
    ///   internal apostrophes/hyphens; no digits/symbols/whitespace) and be
    ///   at least 2 characters — single-character entries are either already
    ///   in the base lexicons or noise.
    /// - Case is preserved (names matter); exact duplicates dedupe.
    public static func parseVocabulary(_ text: String) -> (words: [String], skipped: Int) {
        var seen = Set<String>()
        var words: [String] = []
        var skipped = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Header comments start with "# " or are bare "#"; hashtag
            // vocabulary entries are "#word" — strip the marker and keep
            // the word.
            if line.hasPrefix("#") {
                let stripped = String(line.dropFirst())
                if stripped.isEmpty || stripped.hasPrefix(" ") { continue }
                line = stripped
            }
            line = line
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .precomposedStringWithCanonicalMapping
            guard SwiftKeyImport.isImportableWord(line) else {
                skipped += 1
                continue
            }
            guard seen.insert(line).inserted else { continue }
            words.append(line)
        }
        return (words, skipped)
    }

    /// Convenience: read and parse a vocabulary.txt at `url`.
    public static func parseVocabulary(at url: URL) throws -> (words: [String], skipped: Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parseVocabulary(text)
    }

    /// Stricter than `EventLog.isLearnableWord` (which validates tokenizer
    /// output and tolerates attached punctuation): an importable word is
    /// letters with internal apostrophes/hyphens only, starting and ending
    /// with a letter. Export files carry junk ("'70", "x!") that must not
    /// become vocabulary.
    public static func isImportableWord(_ word: String) -> Bool {
        guard word.count >= 2, EventLog.isLearnableWord(word) else { return false }
        guard let first = word.unicodeScalars.first, let last = word.unicodeScalars.last,
            CharacterSet.letters.contains(first), CharacterSet.letters.contains(last)
        else { return false }
        for scalar in word.unicodeScalars {
            if CharacterSet.letters.contains(scalar) { continue }
            if scalar == "'" || scalar == "-" { continue }
            return false
        }
        return true
    }
}

extension PersonalModel {

    /// Bulk-import previously learned vocabulary (e.g. a SwiftKey export) as
    /// explicitly-accepted learned words.
    ///
    /// Imported words behave like verbatim-tapped words: valid immediately,
    /// never auto-corrected away, surviving decay. Counts are seeded at
    /// `seedCount` (attribution: unknown) so organic usage quickly outranks
    /// the flat import baseline. Existing entries are upgraded to
    /// explicitly-accepted but their organic counts are kept if higher.
    /// Tombstoned words are NOT resurrected — a deletion made here outranks
    /// imported history.
    public func importLearnedWords(
        _ candidates: [String],
        seedCount: UInt32 = 3
    ) -> SwiftKeyImport.Summary {
        var summary = SwiftKeyImport.Summary(imported: 0, skippedInvalid: 0, skippedTombstoned: 0)
        for word in candidates {
            guard SwiftKeyImport.isImportableWord(word) else {
                summary.skippedInvalid += 1
                continue
            }
            if isTombstoned(word) {
                summary.skippedTombstoned += 1
                continue
            }
            upsertExplicitEntry(word, seedCount: seedCount)
            summary.imported += 1
        }
        return summary
    }
}
