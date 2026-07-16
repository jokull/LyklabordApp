import Foundation
import Learning

/// Engine-facing view of the user's personal learning store — the injection
/// seam for M2 personal learning (PLAN.md "Learning").
///
/// Production conformance is `PersonalSnapshot` (below), which adapts a
/// `Learning.PersonalModel` loaded from the App Group container. Tests and
/// the type-repl harness use small in-memory doubles.
///
/// Semantics the engine derives from this view:
///
/// - **Valid personal words** (`allWords()`: learned + user-added, never
///   tombstoned) are treated like lexicon-valid vocabulary: never
///   auto-corrected away, always admissible as suggestion candidates, and
///   boosted in ranking by a personal-source prior (see
///   `EngineConfig.personalBoost*` — an additive score bonus scaled
///   ~log(1+count), NOT a probability normalization: personal token totals
///   are far too small to blend with corpus-scale probabilities, the same
///   apples-to-oranges problem `LexiconCalibration` documents).
/// - **Tombstoned words** are never suggested and never predicted — even
///   when the base lexicons know them — but typed verbatim they behave like
///   any valid word (no correction): deletion means "stop suggesting", not
///   "punish typing".
/// - **Lane posterior**: personal words contribute NO lane evidence in v1.
///   Their language attribution comes from the engine's own lane belief at
///   commit time, so feeding it back would be a self-confirming loop (a
///   sletta committed while the lane was wrong would drag the lane further
///   wrong); and personal counts are orders of magnitude below the corpus
///   evidence they'd be blended with. `laneEvidence` stays base-corpus-only;
///   OOV personal words keep the existing neutral-decay behavior, which is
///   already the conservative right answer.
///
/// Threading: implementations are queried only on the engine's owning queue
/// (the same confinement contract as `TypeEngine` itself). Snapshot swaps
/// happen via `TypeEngine.setPersonalVocabulary`, also on that queue.
public protocol PersonalVocabulary {
    /// All valid personal unigrams — learned + user-added surface forms
    /// (byte-exact, case-preserving) with their commit counts; tombstoned
    /// words are excluded. Called once per snapshot swap (the engine builds
    /// its own case-folded index from it), so linear cost is fine.
    func allWords() -> [(word: String, count: UInt32)]

    /// Personal bigram followers of the exact surface form `first`,
    /// descending count. Pair-level evidence: followers may be returned
    /// even before they are individually learned; tombstoned followers must
    /// be excluded (both `PersonalModel.continuations` and the seeded test
    /// doubles do this).
    func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)]

    /// Personal count of the exact bigram (surface forms); nil if unseen.
    func bigramCount(_ first: String, _ second: String) -> UInt32?

    /// Whether the user deleted this exact surface form in the dictionary
    /// editor (never suggest, never predict; typing it stays uncorrected).
    func isTombstoned(_ word: String) -> Bool

    /// Whether this exact surface form was learned through a DELIBERATE
    /// user act (dictionary-editor add, verbatim tap, import seed) rather
    /// than organically via the commit-day threshold. Drives the wave-26
    /// narrowing of the autocorrect veto: an implicitly learned acute-fold
    /// skeleton of a dominant base word (þvi/því, eg/ég) may not veto the
    /// restoration autocorrect; explicit words always keep full veto power
    /// (see `BlendedLanguageModel.isPersonalProtected`). Defaults to false
    /// (implicit) for conformers that predate the distinction.
    func isExplicit(_ word: String) -> Bool
}

extension PersonalVocabulary {
    /// Default: organic/implicit. Production adapters over
    /// `Learning.PersonalModel` override with the model's explicit flag.
    public func isExplicit(_ word: String) -> Bool { false }
}

/// Production adapter: an immutable engine-side view over a
/// `Learning.PersonalModel` that was loaded fresh from disk.
///
/// Ownership contract: the wrapped model must be an exclusively-owned,
/// read-only copy (the extension loads its own instance from the App Group
/// file and never mutates it; the app's live compacting instance must NOT
/// be wrapped). Swaps are whole-snapshot: when the model file changes on
/// disk, load a new `PersonalModel` and inject a new `PersonalSnapshot`.
public struct PersonalSnapshot: PersonalVocabulary {
    private let model: PersonalModel

    public init(model: PersonalModel) {
        self.model = model
    }

    public func allWords() -> [(word: String, count: UInt32)] {
        // learnedWords/userAddedWords both already exclude tombstones;
        // `frequency(of:)` applies the user-added floor of 1.
        var seen = Set<String>()
        var words: [(word: String, count: UInt32)] = []
        for word in model.learnedWords + model.userAddedWords {
            guard seen.insert(word).inserted else { continue }
            words.append((word: word, count: model.frequency(of: word) ?? 1))
        }
        return words
    }

    public func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)] {
        model.continuations(of: first, limit: limit)
            .map { (word: $0.word, count: $0.frequency) }
    }

    public func bigramCount(_ first: String, _ second: String) -> UInt32? {
        model.bigramFrequency(first, second)
    }

    public func isTombstoned(_ word: String) -> Bool {
        model.isTombstoned(word)
    }

    public func isExplicit(_ word: String) -> Bool {
        model.isExplicit(word)
    }
}

/// Engine-internal mutable holder for the personal vocabulary: the injected
/// snapshot plus the in-session learned overlay (verbatim taps / explicit
/// `learnWord` signals must take effect immediately, before any app-side
/// compaction ever runs).
///
/// One instance is shared (by reference) across the engine's corrector,
/// predictor and blended model, so a snapshot swap is a single O(personal
/// scale) index rebuild — no recalibration, no engine rebuild. All access
/// is confined to the engine's owning queue (see `TypeEngine` docs).
///
/// Internally case-folded: the correction/prediction pipeline works in
/// lowercase, while personal surface forms are byte-exact ("Miðeind").
/// Matching happens on lowercased keys; the canonical (highest-count)
/// surface form is restored at display time via `displaySurface(of:)`.
final class PersonalStore {

    private struct Entry {
        var surface: String
        var count: UInt32
        /// Learned through a deliberate user act (verbatim tap, editor add,
        /// import) — keeps full autocorrect-veto power even for acute-fold
        /// skeletons (see `PersonalVocabulary.isExplicit`). Session-overlay
        /// entries are always explicit: `learnSession` is the verbatim-tap /
        /// explicit-learn path by definition.
        var explicit: Bool
    }

    private var snapshot: PersonalVocabulary?
    /// Lowercased word → canonical surface + summed count, from the snapshot.
    private var index: [String: Entry] = [:]
    /// In-session learned overlay (verbatim tap / learnWord), same keying.
    private var session: [String: Entry] = [:]
    /// Lowercased → surface hints discovered via bigram followers that are
    /// not themselves learned unigrams (so prediction can still display
    /// "Miðeind" rather than "miðeind").
    private var displayHints: [String: String] = [:]

    var isActive: Bool { snapshot != nil || !session.isEmpty }

    // MARK: - Mutation (engine queue only)

    func setSnapshot(_ snapshot: PersonalVocabulary?) {
        self.snapshot = snapshot
        index = [:]
        displayHints = [:]
        guard let snapshot else { return }
        for (word, count) in snapshot.allWords() {
            let key = word.lowercased()
            let explicit = snapshot.isExplicit(word)
            if var existing = index[key] {
                // Case variants of one word merge: counts sum, the
                // higher-count variant becomes the canonical surface, and
                // explicitness is sticky (any deliberately learned variant
                // marks the folded key explicit).
                if count > existing.count { existing.surface = word }
                existing.count = existing.count &+ count
                existing.explicit = existing.explicit || explicit
                index[key] = existing
            } else {
                index[key] = Entry(surface: word, count: max(count, 1), explicit: explicit)
            }
        }
    }

    func learnSession(_ word: String) {
        let key = word.lowercased()
        var entry = session[key] ?? Entry(surface: word, count: 0, explicit: true)
        entry.count &+= 1
        session[key] = entry
    }

    func clearSession() {
        session = [:]
    }

    // MARK: - Queries (all lowercase-tolerant)

    /// Learned/user-added/session-learned — the always-valid contract
    /// (protection from autocorrect + admissibility as a candidate).
    func isValidWord(_ word: String) -> Bool {
        guard isActive else { return false }
        let key = word.lowercased()
        return index[key] != nil || session[key] != nil
    }

    /// Tombstone probe. Tombstones are byte-exact in the model; the engine
    /// pipeline works lowercased, so the exact form, the lowercase form and
    /// the first-letter-capitalized form are all probed (covers the proper
    /// noun / sentence-case variants a user realistically deletes).
    func isTombstoned(_ word: String) -> Bool {
        guard let snapshot else { return false }
        for variant in Self.caseVariants(of: word) where snapshot.isTombstoned(variant) {
            return true
        }
        return false
    }

    /// Whether the word (lowercase pipeline form) was learned through a
    /// deliberate user act — session learns (verbatim tap) always are; for
    /// snapshot words the flag comes from the underlying model (editor
    /// adds, verbatim-tapped commits, import seeds).
    func isExplicitWord(_ word: String) -> Bool {
        let key = word.lowercased()
        return index[key]?.explicit == true || session[key]?.explicit == true
    }

    /// Combined snapshot + session count (0 when unknown).
    func count(of word: String) -> UInt32 {
        let key = word.lowercased()
        return (index[key]?.count ?? 0) &+ (session[key]?.count ?? 0)
    }

    /// Canonical display surface for a lowercase pipeline word, when the
    /// personal store knows a differently-cased canonical form ("miðeind" →
    /// "Miðeind"); nil when there is nothing to restore.
    func displaySurface(of word: String) -> String? {
        guard isActive else { return nil }
        let surface = index[word]?.surface ?? session[word]?.surface ?? displayHints[word]
        guard let surface, surface != word else { return nil }
        return surface
    }

    /// Prefix completions over the personal vocabulary (lowercased pipeline
    /// forms). Personal scale is small (≤ tens of thousands), so a linear
    /// scan is microseconds — the same reasoning as `PersonalLexicon`.
    func completions(of prefix: String, limit: Int) -> [(word: String, count: UInt32)] {
        guard isActive, limit > 0 else { return [] }
        var merged: [String: UInt32] = [:]
        for (key, entry) in index where key.hasPrefix(prefix) {
            merged[key, default: 0] &+= entry.count
        }
        for (key, entry) in session where key.hasPrefix(prefix) {
            merged[key, default: 0] &+= entry.count
        }
        return merged
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    /// Personal bigram followers of `previous` (a lowercase pipeline word):
    /// probes the snapshot with the realistic case variants, folds results
    /// to lowercase for scoring, and remembers the original surfaces as
    /// display hints. Tombstoned followers are excluded by the snapshot.
    func continuations(of previous: String, limit: Int) -> [(word: String, count: UInt32)] {
        guard let snapshot, limit > 0 else { return [] }
        var merged: [String: UInt32] = [:]
        for variant in Self.caseVariants(of: previous) {
            for entry in snapshot.continuations(of: variant, limit: limit) {
                let key = entry.word.lowercased()
                if key != entry.word, index[key] == nil, displayHints[key] == nil {
                    displayHints[key] = entry.word
                }
                merged[key] = max(merged[key] ?? 0, entry.count)
            }
        }
        return merged
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }

    /// Personal count of a (previous, word) pair from the snapshot, probing
    /// the case variants of both lowercase pipeline forms.
    func bigramCount(_ previous: String, _ word: String) -> UInt32? {
        guard let snapshot else { return nil }
        var best: UInt32?
        var wordVariants = Self.caseVariants(of: word)
        if let canonical = index[word.lowercased()]?.surface, !wordVariants.contains(canonical) {
            wordVariants.append(canonical)
        }
        for p in Self.caseVariants(of: previous) {
            for w in wordVariants {
                if let count = snapshot.bigramCount(p, w) {
                    best = max(best ?? 0, count)
                }
            }
        }
        return best
    }

    /// All valid personal words as lowercased pipeline keys (snapshot +
    /// session overlay), sorted for determinism. Input to the personal
    /// lemma lift rebuild (see `InflectionStore.rebuildLift`).
    var allValidKeys: [String] {
        Set(index.keys).union(session.keys).sorted()
    }

    // MARK: - Diagnostics (REPL `:learned`, tests)

    /// Canonical surfaces of all snapshot words, sorted.
    var snapshotWords: [String] {
        index.values.map(\.surface).sorted()
    }

    /// Surfaces learned in this session (overlay), sorted.
    var sessionWords: [String] {
        session.values.map(\.surface).sorted()
    }

    // MARK: - Helpers

    static func caseVariants(of word: String) -> [String] {
        var variants = [word]
        let lower = word.lowercased()
        if lower != word { variants.append(lower) }
        if let first = lower.first {
            let capitalized = String(first).uppercased() + lower.dropFirst()
            if !variants.contains(capitalized) { variants.append(capitalized) }
        }
        return variants
    }
}
