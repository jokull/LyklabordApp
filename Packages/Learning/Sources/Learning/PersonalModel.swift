import Foundation

public enum PersonalModelError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case ioError(String)
    case invalidWord(String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): return "Unsupported personal-model schema version \(v)"
        case .ioError(let detail): return "Personal model I/O error: \(detail)"
        case .invalidWord(let word): return "Not a learnable word: \(word)"
        }
    }
}

/// The compacted personal learning store: word counts with per-language
/// attribution, capped bigram counts, tombstones, user-added words, and the
/// per-key adaptive touch statistics. Owned and persisted by the containing
/// app; the keyboard extension loads a read-only copy (or a
/// `PersonalLexicon` snapshot) at launch.
///
/// ## Hard constraints (from PLAN)
///
/// - **Surface forms only.** Icelandic surface forms overlap heavily across
///   lemmas ("á" = preposition | river | eiga-form), so learned counts are
///   keyed by the exact committed string — byte-exact, case-preserving.
///   There is NO lemma-level merging anywhere in this type; the documented
///   wave-2 seam for unambiguous-only lemma *boosts* is `LemmaBoostProviding`.
/// - **Tombstones win.** A word the user deleted in the dictionary editor is
///   never auto-relearned — not by commits, not by verbatim taps — until the
///   user explicitly re-adds it (`addUserWord`) or clears the tombstone.
/// - **Single words / pairs only**, mirroring the event-log privacy
///   invariants. Nothing here can reconstruct running text.
///
/// ## Learning threshold
///
/// A word becomes *learned* (valid for suggestions/autocorrect protection)
/// only after commits on `Configuration.learnedDayThreshold` distinct day
/// buckets (default 2), OR immediately on an explicit signal (verbatim-tap
/// `wordTapped`, or `addUserWord`). Rationale: one-off typos routinely get
/// committed once; requiring a second, later day filters them out without
/// asking the user anything — the SwiftKey failure mode (typo pollution) in
/// reverse. Explicit signals skip the threshold because the user literally
/// pointed at the word and said "this one".
///
/// ## Decay ("the corpus adapts around the user")
///
/// At compaction, when the summed word count exceeds
/// `Configuration.decayTotalCountCeiling`, every word and bigram count is
/// scaled by `decayFactor` (default 0.5, integer floor). Entries that reach
/// zero are dropped — unless explicitly signalled or user-added — so
/// abandoned vocabulary eventually vanishes while active vocabulary keeps
/// getting re-inflated by fresh commits. Multiplicative decay preserves
/// relative ranking; the ceiling bounds both file size and how long stale
/// habits linger. Touch statistics decay separately (see `TouchKeyStats`,
/// per-key threshold) because taps arrive orders of magnitude faster than
/// new vocabulary.
///
/// ## Persistence
///
/// A single versioned JSON file (`schemaVersion` top-level field), written
/// with `.atomic` (write-temp-then-rename). JSON over a custom binary
/// format is deliberate: personal scale is small (a few thousand words —
/// well under the 1MB target), Codable gives free forward evolution via
/// optional fields, and a human-readable store is part of the transparency
/// story (the user can literally read everything the keyboard knows).
/// Loaded fully into memory; all queries are dictionary lookups.
public final class PersonalModel {

    public static let schemaVersion = 1

    public struct Configuration: Sendable {
        /// Distinct day buckets required before a word counts as learned.
        public var learnedDayThreshold: Int
        /// Distinct days tracked per word (small cap; only the threshold
        /// comparison needs them).
        public var maxDistinctDaysTracked: Int
        /// Maximum bigram entries kept after compaction (top by count).
        public var bigramCap: Int
        /// Maximum word entries kept after compaction (explicit/user-added
        /// entries are never evicted).
        public var maxWordEntries: Int
        /// When the summed word count exceeds this, multiplicative decay runs.
        public var decayTotalCountCeiling: UInt64
        /// Multiplicative decay factor applied to word/bigram counts.
        public var decayFactor: Double
        /// Per-key effective-sample-count threshold that triggers touch decay.
        public var touchSampleDecayThreshold: Double
        /// Touch-statistics decay factor (exponential forgetting).
        public var touchDecayFactor: Double

        public init(
            learnedDayThreshold: Int = 2,
            maxDistinctDaysTracked: Int = 8,
            bigramCap: Int = 20_000,
            maxWordEntries: Int = 25_000,
            decayTotalCountCeiling: UInt64 = 200_000,
            decayFactor: Double = 0.5,
            touchSampleDecayThreshold: Double = 500,
            touchDecayFactor: Double = 0.5
        ) {
            self.learnedDayThreshold = learnedDayThreshold
            self.maxDistinctDaysTracked = maxDistinctDaysTracked
            self.bigramCap = bigramCap
            self.maxWordEntries = maxWordEntries
            self.decayTotalCountCeiling = decayTotalCountCeiling
            self.decayFactor = decayFactor
            self.touchSampleDecayThreshold = touchSampleDecayThreshold
            self.touchDecayFactor = touchDecayFactor
        }
    }

    /// Per-surface-form statistics. Language counts are attribution only —
    /// they never merge forms (see the Icelandic constraint above).
    public struct WordStats: Codable, Equatable, Sendable {
        public var count: UInt32
        public var icelandicCount: UInt32
        public var englishCount: UInt32
        public var unknownCount: UInt32
        /// Distinct day buckets seen (sorted ascending, capped).
        public var daysSeen: [Int32]
        /// Verbatim-tap (or equivalently strong) signal received — learned
        /// immediately, survives decay-to-zero.
        public var explicitlyAccepted: Bool

        public init(
            count: UInt32 = 0,
            icelandicCount: UInt32 = 0,
            englishCount: UInt32 = 0,
            unknownCount: UInt32 = 0,
            daysSeen: [Int32] = [],
            explicitlyAccepted: Bool = false
        ) {
            self.count = count
            self.icelandicCount = icelandicCount
            self.englishCount = englishCount
            self.unknownCount = unknownCount
            self.daysSeen = daysSeen
            self.explicitlyAccepted = explicitlyAccepted
        }
    }

    public struct CompactionSummary: Equatable, Sendable {
        public var eventsApplied: Int
        public var linesSkipped: Int
        public var decayed: Bool
        public var logTruncated: Bool
    }

    public let configuration: Configuration

    private(set) var words: [String: WordStats]
    /// Key: "first second" (single space), values decayed alongside words.
    private(set) var bigrams: [String: UInt32]
    private(set) var tombstones: Set<String>
    private(set) var userAdded: Set<String>
    /// Key: single-character string (Codable-friendly `Character`).
    private(set) var touch: [String: TouchKeyStats]
    /// Consume-up-to frontier of the event log (see `EventLog.ConsumedMarker`).
    public private(set) var consumedLogMarker: EventLog.ConsumedMarker?

    // MARK: - Init / persistence

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        words = [:]
        bigrams = [:]
        tombstones = []
        userAdded = []
        touch = [:]
        consumedLogMarker = nil
    }

    private struct Stored: Codable {
        var schemaVersion: Int
        var words: [String: WordStats]
        var bigrams: [String: UInt32]
        var tombstones: [String]
        var userAdded: [String]
        var touch: [String: TouchKeyStats]
        var consumedLogMarker: EventLog.ConsumedMarker?
    }

    public convenience init(contentsOf url: URL, configuration: Configuration = Configuration()) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersonalModelError.ioError("load failed: \(error)")
        }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.schemaVersion == Self.schemaVersion else {
            throw PersonalModelError.unsupportedSchemaVersion(stored.schemaVersion)
        }
        self.init(configuration: configuration)
        words = stored.words
        bigrams = stored.bigrams
        tombstones = Set(stored.tombstones)
        userAdded = Set(stored.userAdded)
        touch = stored.touch
        consumedLogMarker = stored.consumedLogMarker
    }

    /// Atomic replace (write-temp-then-rename via `.atomic`); deterministic
    /// bytes (sorted keys) so identical state ⇒ identical file, which keeps
    /// the future CloudKit sync layer's change detection trivial.
    public func save(to url: URL) throws {
        let stored = Stored(
            schemaVersion: Self.schemaVersion,
            words: words,
            bigrams: bigrams,
            tombstones: tombstones.sorted(),
            userAdded: userAdded.sorted(),
            touch: touch,
            consumedLogMarker: consumedLogMarker
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PersonalModelError.ioError("save failed: \(error)")
        }
    }

    // MARK: - Queries (engine + dictionary editor)

    /// Learned = valid vocabulary: suggestable, protected from autocorrect.
    public func isLearned(_ word: String) -> Bool {
        guard !tombstones.contains(word) else { return false }
        if userAdded.contains(word) { return true }
        guard let stats = words[word] else { return false }
        return stats.explicitlyAccepted || stats.daysSeen.count >= configuration.learnedDayThreshold
    }

    public func isTombstoned(_ word: String) -> Bool {
        tombstones.contains(word)
    }

    public func isUserAdded(_ word: String) -> Bool {
        userAdded.contains(word)
    }

    /// Personal frequency of a LEARNED word; nil for unlearned/tombstoned
    /// words (pending words never leak into ranking). User-added words get
    /// a floor of 1 even with zero commits (always-valid contract).
    public func frequency(of word: String) -> UInt32? {
        guard isLearned(word) else { return nil }
        let count = words[word]?.count ?? 0
        if userAdded.contains(word) { return max(count, 1) }
        return count
    }

    /// Raw commit count regardless of learned status (dictionary editor /
    /// diagnostics — not for ranking).
    public func commitCount(of word: String) -> UInt32 {
        words[word]?.count ?? 0
    }

    /// Per-language attribution of a word's commits (editor/diagnostics).
    public func languageAttribution(of word: String) -> (icelandic: UInt32, english: UInt32, unknown: UInt32)? {
        guard let stats = words[word] else { return nil }
        return (stats.icelandicCount, stats.englishCount, stats.unknownCount)
    }

    public func bigramFrequency(_ first: String, _ second: String) -> UInt32? {
        bigrams[Self.bigramKey(first, second)]
    }

    /// Followers of `word` by descending bigram count (ties broken
    /// lexicographically — deterministic). Bigram evidence is pair-level, so
    /// followers are returned even before they individually cross the
    /// learned threshold; tombstoned followers are excluded.
    public func continuations(of word: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = word + " "
        return bigrams
            .compactMap { key, count -> (word: String, frequency: UInt32)? in
                guard key.hasPrefix(prefix) else { return nil }
                let follower = String(key.dropFirst(prefix.count))
                guard !tombstones.contains(follower) else { return nil }
                return (word: follower, frequency: count)
            }
            .sorted { $0.frequency > $1.frequency || ($0.frequency == $1.frequency && $0.word < $1.word) }
            .prefix(limit)
            .map { $0 }
    }

    /// Organically learned words (threshold or explicit signal), sorted
    /// lexicographically — deterministic listing for the dictionary editor.
    /// A word that is both user-added and organically committed appears in
    /// both lists; the editor should union them.
    public var learnedWords: [String] {
        words.keys.filter { isLearned($0) }.sorted()
    }

    /// User-added words, sorted lexicographically.
    public var userAddedWords: [String] {
        userAdded.sorted()
    }

    // MARK: - Dictionary editing

    /// Delete a word: removes counts, removes user-added status, drops every
    /// bigram containing it, and tombstones it so it never auto-relearns
    /// (SwiftKey pain #8 — deletions must stick).
    public func remove(word: String) {
        words.removeValue(forKey: word)
        userAdded.remove(word)
        tombstones.insert(word)
        let asFirst = word + " "
        let asSecond = " " + word
        bigrams = bigrams.filter { key, _ in
            !key.hasPrefix(asFirst) && !key.hasSuffix(asSecond)
        }
    }

    /// Explicitly add a word: always valid, never autocorrected, learned
    /// immediately. Clears any tombstone — an explicit re-add is the one
    /// sanctioned way back in.
    public func addUserWord(_ word: String) throws {
        guard EventLog.isLearnableWord(word) else {
            throw PersonalModelError.invalidWord(word)
        }
        tombstones.remove(word)
        userAdded.insert(word)
    }

    /// Clear a tombstone without re-adding the word: future commits may
    /// relearn it organically (counts start from zero).
    public func removeTombstone(_ word: String) {
        tombstones.remove(word)
    }

    /// Bulk-import support (see `SwiftKeyImport`): upsert an explicitly-
    /// accepted entry with a seeded count. Internal — external callers go
    /// through `importLearnedWords(_:seedCount:)`, which validates and
    /// respects tombstones.
    func upsertExplicitEntry(_ word: String, seedCount: UInt32) {
        var stats = words[word] ?? WordStats()
        stats.explicitlyAccepted = true
        stats.count = max(stats.count, seedCount)
        stats.unknownCount = max(stats.unknownCount, seedCount)
        words[word] = stats
    }

    // MARK: - Touch model accessors

    /// Mean tap offset from key center for `char`, with the effective sample
    /// count as weight (callers blend toward the static key center while
    /// weight is low). Nil until the key has any samples.
    public func keyOffset(for char: Character) -> (dx: Double, dy: Double, weight: Double)? {
        guard let stats = touch[String(char)], stats.count > 0 else { return nil }
        return (stats.meanDX, stats.meanDY, stats.count)
    }

    /// Full per-key statistics (means + covariance) for the 2D Gaussian.
    public func touchStatistics(for char: Character) -> TouchKeyStats? {
        touch[String(char)]
    }

    /// Keys with any touch statistics, sorted (deterministic).
    public var touchKeys: [Character] {
        touch.keys.sorted().compactMap { $0.first }
    }

    /// Wipe the adaptive touch model (transparency parity with the
    /// dictionary editor — PLAN: "deletable/resettable in the app").
    public func resetTouchModel() {
        touch = [:]
    }

    // MARK: - Compaction

    /// Merge all unconsumed events from `log` into the model, then decay and
    /// enforce caps if needed. Does NOT touch the disk — see
    /// `compactAndSave(applying:to:)` for the crash-safe full sequence.
    @discardableResult
    public func compact(applying log: EventLog) throws -> CompactionSummary {
        let result = try log.read(after: consumedLogMarker)
        for logged in result.events {
            apply(logged)
        }
        consumedLogMarker = result.endMarker
        let decayed = decayIfNeeded()
        enforceCaps()
        return CompactionSummary(
            eventsApplied: result.events.count,
            linesSkipped: result.skippedLines,
            decayed: decayed,
            logTruncated: false
        )
    }

    /// The full crash-safe compaction sequence, in the only safe order:
    ///
    /// 1. read + merge (`compact`), marker updated in memory
    /// 2. save model atomically — the consumed frontier is now durable, so a
    ///    crash cannot double-apply these events
    /// 3. truncate the log's consumed prefix (new generation; a concurrent
    ///    writer's post-read appends are preserved in the tail)
    /// 4. save again with the new-generation marker (cheap; if we crash
    ///    before this, the generation mismatch self-heals on the next run)
    ///
    /// Callers must run this inside ONE `CoordinatedFileAccess.coordinateWrite`
    /// block on the log URL so no append lands between steps 1 and 3 unseen.
    @discardableResult
    public func compactAndSave(
        applying log: EventLog,
        to modelURL: URL,
        truncatingLog: Bool = true
    ) throws -> CompactionSummary {
        var summary = try compact(applying: log)
        try save(to: modelURL)
        if truncatingLog, let marker = consumedLogMarker {
            consumedLogMarker = try log.truncate(consumedUpTo: marker)
            try save(to: modelURL)
            summary.logTruncated = true
        }
        return summary
    }

    // MARK: - Event application

    private func apply(_ logged: LoggedEvent) {
        switch logged.event {
        case .wordCommitted(let word, let previousWord, let hint):
            learnCommit(word: word, hint: hint, day: logged.day, explicit: false)
            if let previousWord,
               !tombstones.contains(previousWord),
               !tombstones.contains(word) {
                bigrams[Self.bigramKey(previousWord, word), default: 0] += 1
            }
        case .suggestionAccepted(_, let accepted):
            // Accepting a suggestion is a commit of the accepted word; the
            // typed token is a typo by definition and is NOT learned.
            learnCommit(word: accepted, hint: .unknown, day: logged.day, explicit: false)
        case .correctionReverted(let original, _):
            // The user rejected our correction and got `original` back —
            // counts as a commit of `original`, but NOT as an explicit
            // learn: a single revert can still be a one-off (conservative;
            // revisit in wave-2 tuning). The rejected `applied` word is not
            // penalized here — its base-lexicon rank is engine territory.
            learnCommit(word: original, hint: .unknown, day: logged.day, explicit: false)
        case .wordTapped(let word):
            // Verbatim-tap: explicit signal, learns immediately — but a
            // tombstone still wins (deletions only reversed via the editor).
            learnCommit(word: word, hint: .unknown, day: logged.day, explicit: true)
        case .touchSample(let keyChar, let dx, let dy):
            let key = String(keyChar)
            var stats = touch[key] ?? TouchKeyStats()
            stats.update(dx: dx, dy: dy)
            if stats.count > configuration.touchSampleDecayThreshold {
                stats.decay(by: configuration.touchDecayFactor)
            }
            touch[key] = stats
        }
    }

    private func learnCommit(word: String, hint: LanguageHint, day: Int32, explicit: Bool) {
        guard !tombstones.contains(word) else { return }  // tombstones never auto-relearn
        var stats = words[word] ?? WordStats()
        stats.count &+= 1
        switch hint {
        case .icelandic: stats.icelandicCount &+= 1
        case .english: stats.englishCount &+= 1
        case .unknown: stats.unknownCount &+= 1
        }
        if explicit {
            stats.explicitlyAccepted = true
        }
        if !stats.daysSeen.contains(day) && stats.daysSeen.count < configuration.maxDistinctDaysTracked {
            let insertAt = stats.daysSeen.firstIndex { $0 > day } ?? stats.daysSeen.endIndex
            stats.daysSeen.insert(day, at: insertAt)
        }
        words[word] = stats
    }

    // MARK: - Decay & caps

    /// Multiplicative decay when the summed word count exceeds the ceiling.
    /// Returns true if decay ran.
    private func decayIfNeeded() -> Bool {
        let total = words.values.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        guard total > configuration.decayTotalCountCeiling else { return false }
        let factor = configuration.decayFactor

        var decayedWords: [String: WordStats] = [:]
        decayedWords.reserveCapacity(words.count)
        for (word, var stats) in words {
            stats.count = UInt32(Double(stats.count) * factor)
            stats.icelandicCount = UInt32(Double(stats.icelandicCount) * factor)
            stats.englishCount = UInt32(Double(stats.englishCount) * factor)
            stats.unknownCount = UInt32(Double(stats.unknownCount) * factor)
            if stats.count == 0 && !stats.explicitlyAccepted && !userAdded.contains(word) {
                continue  // abandoned vocabulary vanishes
            }
            decayedWords[word] = stats
        }
        words = decayedWords

        var decayedBigrams: [String: UInt32] = [:]
        decayedBigrams.reserveCapacity(bigrams.count)
        for (key, count) in bigrams {
            let decayedCount = UInt32(Double(count) * factor)
            if decayedCount > 0 {
                decayedBigrams[key] = decayedCount
            }
        }
        bigrams = decayedBigrams
        // Tombstones and userAdded are membership sets — decay never touches
        // them (deletions and explicit adds are permanent user decisions).
        return true
    }

    private func enforceCaps() {
        if bigrams.count > configuration.bigramCap {
            let keep = bigrams
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(configuration.bigramCap)
            bigrams = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if words.count > configuration.maxWordEntries {
            // Evict lowest-count non-explicit, non-user-added entries first.
            let evictable = words
                .filter { !$0.value.explicitlyAccepted && !userAdded.contains($0.key) }
                .sorted { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
            var overage = words.count - configuration.maxWordEntries
            for (word, _) in evictable {
                guard overage > 0 else { break }
                words.removeValue(forKey: word)
                overage -= 1
            }
        }
    }

    static func bigramKey(_ first: String, _ second: String) -> String {
        first + " " + second
    }
}
