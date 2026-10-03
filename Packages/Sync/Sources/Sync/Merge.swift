import Foundation
import Learning

/// Merge of two `SyncPayload` states from different devices.
///
/// ## Why max, not sum (and no three-way ancestor)
///
/// There is no common-ancestor snapshot to diff against (a third state to
/// store, migrate, and trust), so the merge is designed as a **join
/// semilattice**: every per-field operation is associative, commutative,
/// and idempotent — `merge(a, a) == a`, `merge(merge(a, b), b) ==
/// merge(a, b)`. That makes the whole system ping-pong-safe: device A can
/// pull B's snapshot, push the merge, B pulls it back, re-merges, pushes
/// again … and nothing inflates, ever. Summing counts would require exactly
/// the ancestor bookkeeping we don't have — re-merging the same remote
/// snapshot twice would double-count. The cost of max is that cross-device
/// totals undercount (a word typed 10× on each of two devices merges to
/// 10, not 20); counts only drive relative ranking, so this is harmless —
/// and both devices keep re-inflating their own counts organically.
///
/// ## Per-field semantics
///
/// - **tombstone epochs** (`tombstoneEpochs`, absent = 0): per-word MAX.
///   `PersonalModel` bumps a word's epoch on every explicit editor action
///   that flips its tombstone state (delete, re-add, clear) and on nothing
///   else — so the epoch is a monotonic "how many times has the user
///   changed their mind about this word" counter that needs no clock.
/// - **tombstones**: decided PER WORD by the side(s) at the word's maximum
///   epoch. If one side is strictly ahead, its view wins outright — this
///   is what lets an explicit re-add (`addUserWord` → epoch+1, tombstone
///   cleared) beat a synced deletion, and a LATER explicit delete
///   (epoch+1 again) beat that re-add. If both sides are at the same
///   epoch, the tombstone wins (OR) — concurrent delete vs. re-add that
///   never saw each other resolves to deletion, the safer default for a
///   privacy product. With no epochs anywhere (documents from builds that
///   predate them) every word ties at 0 and this degenerates to the
///   original set union, byte for byte.
/// - **everything else that belongs to a word** — `userAdded`, its
///   `WordStats` entry, and any bigram touching it — is taken ONLY from the
///   side(s) at that word's maximum epoch. A device that never saw a
///   deletion is carrying stale counts for the word; mixing them back in
///   after a re-add would make the result depend on merge order (see
///   "Why the epoch gates stats too" below). Among the sides that qualify:
///   `userAdded` is OR; `WordStats` is field-wise max of the four counts,
///   sorted-set union of `daysSeen` (capped at
///   `Configuration.maxDistinctDaysTracked`, keeping the earliest — same
///   policy as `PersonalModel.learnCommit`), and OR of `explicitlyAccepted`.
///   Implicit learning (typing the word again) never touches the epoch, so
///   "deletions stick" against organic relearning exactly as before.
/// - **bigrams**: per-key max over the sides at the max epoch of BOTH
///   words, minus any pair touching a tombstoned word (mirrors
///   `PersonalModel.remove`), then re-capped to the top
///   `Configuration.bigramCap` using the exact ordering `enforceCaps`
///   uses (count desc, key asc) so merge and compaction can never fight.
///
/// ## Why the epoch gates stats too
///
/// Take A (never synced since, word count 10, epoch 0), a deletion D
/// (epoch 1) and the user's re-add R (epoch 2). If stats were merged with
/// a plain max regardless of epoch, `merge(merge(A, D), R)` would drop
/// A's counts at the D step and end with none, while `merge(A, merge(D,
/// R))` would keep them — associativity broken, and two devices could
/// disagree forever. Gating every per-word field on the word's max epoch
/// makes the per-word merge a lexicographic join (epoch first, then the
/// old per-field joins among the tied sides), which is still a
/// semilattice; the property tests in `MergeTests` check all four laws
/// with random epochs.
/// - **touch**: per-key, keep the WHOLE stats struct from the side with
///   the higher effective sample count (higher weight = better-trained
///   Gaussian). Never averaged: Welford aggregates from different devices
///   are not linearly combinable without breaking the decay bookkeeping,
///   and per-device tap distributions genuinely differ less than
///   per-key ones. Ties break on a deterministic field comparison so the
///   pick is symmetric (commutativity holds).
/// - **schemaVersion**: both sides are validated to the supported version
///   before merge (see `SyncEngine`), so this is just carried through.
///
/// Word entries are deliberately NOT re-capped here (`maxWordEntries`):
/// eviction depends on eviction-order state that belongs to compaction;
/// the next local compaction enforces it. Bigrams ARE capped because the
/// cap ordering is fully determined by the map itself.
public enum PersonalModelMerge {

    /// Caps the merge must respect, sourced from the same defaults
    /// compaction uses.
    public struct Limits: Sendable {
        public var bigramCap: Int
        public var maxDistinctDaysTracked: Int

        public init(configuration: PersonalModel.Configuration = PersonalModel.Configuration()) {
            bigramCap = configuration.bigramCap
            maxDistinctDaysTracked = configuration.maxDistinctDaysTracked
        }
    }

    public static func merge(
        _ a: SyncPayload,
        _ b: SyncPayload,
        limits: Limits = Limits()
    ) -> SyncPayload {
        // Per-word epoch frontier, and which side(s) sit on it. A side at a
        // lower epoch has a stale view of that word and contributes nothing
        // for it — not its tombstone, not its counts, not its bigrams.
        var epochs: [String: UInt32] = [:]
        for (word, epoch) in a.tombstoneEpochs { epochs[word] = epoch }
        for (word, epoch) in b.tombstoneEpochs { epochs[word] = max(epochs[word] ?? 0, epoch) }
        func current(_ side: SyncPayload, _ word: String) -> Bool {
            side.tombstoneEpoch(of: word) == (epochs[word] ?? 0)
        }

        var tombstones: Set<String> = []
        for word in a.tombstones where current(a, word) { tombstones.insert(word) }
        for word in b.tombstones where current(b, word) { tombstones.insert(word) }

        var userAdded: Set<String> = []
        for word in a.userAdded where current(a, word) && !tombstones.contains(word) { userAdded.insert(word) }
        for word in b.userAdded where current(b, word) && !tombstones.contains(word) { userAdded.insert(word) }

        var words: [String: PersonalModel.WordStats] = [:]
        words.reserveCapacity(max(a.words.count, b.words.count))
        for key in Set(a.words.keys).union(b.words.keys) {
            guard !tombstones.contains(key) else { continue }
            let x = current(a, key) ? a.words[key] : nil
            let y = current(b, key) ? b.words[key] : nil
            switch (x, y) {
            case (let x?, let y?):
                words[key] = mergeStats(x, y, maxDays: limits.maxDistinctDaysTracked)
            case (let x?, nil):
                words[key] = capped(x, maxDays: limits.maxDistinctDaysTracked)
            case (nil, let y?):
                words[key] = capped(y, maxDays: limits.maxDistinctDaysTracked)
            case (nil, nil):
                break
            }
        }

        var bigrams: [String: UInt32] = [:]
        bigrams.reserveCapacity(max(a.bigrams.count, b.bigrams.count))
        for key in Set(a.bigrams.keys).union(b.bigrams.keys) {
            let (first, second) = splitBigram(key)
            guard !tombstones.contains(first), !tombstones.contains(second) else { continue }
            let x = current(a, first) && current(a, second) ? a.bigrams[key] : nil
            let y = current(b, first) && current(b, second) ? b.bigrams[key] : nil
            if let count = [x, y].compactMap({ $0 }).max() {
                bigrams[key] = count
            }
        }
        if bigrams.count > limits.bigramCap {
            let keep = bigrams
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .prefix(limits.bigramCap)
            bigrams = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }

        var touch: [String: TouchKeyStats] = [:]
        touch.reserveCapacity(max(a.touch.count, b.touch.count))
        for key in Set(a.touch.keys).union(b.touch.keys) {
            switch (a.touch[key], b.touch[key]) {
            case (let x?, let y?): touch[key] = preferredTouch(x, y)
            case (let x?, nil): touch[key] = x
            case (nil, let y?): touch[key] = y
            case (nil, nil): break
            }
        }

        return SyncPayload(
            schemaVersion: max(a.schemaVersion, b.schemaVersion),
            words: words,
            bigrams: bigrams,
            tombstones: tombstones,
            userAdded: userAdded,
            touch: touch,
            tombstoneEpochs: epochs
        )
    }

    // MARK: - Per-entry merges

    private static func mergeStats(
        _ a: PersonalModel.WordStats,
        _ b: PersonalModel.WordStats,
        maxDays: Int
    ) -> PersonalModel.WordStats {
        PersonalModel.WordStats(
            count: max(a.count, b.count),
            icelandicCount: max(a.icelandicCount, b.icelandicCount),
            englishCount: max(a.englishCount, b.englishCount),
            unknownCount: max(a.unknownCount, b.unknownCount),
            daysSeen: mergedDays(a.daysSeen, b.daysSeen, cap: maxDays),
            explicitlyAccepted: a.explicitlyAccepted || b.explicitlyAccepted
        )
    }

    /// Cap enforcement must also run on one-sided entries so that
    /// `merge(a, a) == merge(a, b)` when b lacks the word — idempotence
    /// requires identical treatment of both paths. (An in-cap entry is
    /// returned unchanged.)
    private static func capped(_ stats: PersonalModel.WordStats, maxDays: Int) -> PersonalModel.WordStats {
        guard stats.daysSeen.count > maxDays else { return stats }
        var capped = stats
        capped.daysSeen = Array(stats.daysSeen.sorted().prefix(maxDays))
        return capped
    }

    /// Sorted union, keep the EARLIEST `cap` days — matches
    /// `PersonalModel.learnCommit`, which stops recording new days once the
    /// cap is reached. Only the learned-threshold comparison (≥2 distinct
    /// days) consumes these, so which days survive is immaterial as long as
    /// the choice is deterministic.
    private static func mergedDays(_ a: [Int32], _ b: [Int32], cap: Int) -> [Int32] {
        Array(Set(a).union(b).sorted().prefix(cap))
    }

    /// Bigram keys are `"first second"` with exactly one space (words can
    /// never contain whitespace — `EventLog.isLearnableWord`). A key with
    /// no space (hostile input) is treated as a single word on both sides.
    private static func splitBigram(_ key: String) -> (first: String, second: String) {
        guard let space = key.firstIndex(of: " ") else { return (key, key) }
        return (String(key[..<space]), String(key[key.index(after: space)...]))
    }

    /// Higher effective sample count wins; ties break on a deterministic,
    /// symmetric field-by-field comparison so `preferredTouch(x, y) ==
    /// preferredTouch(y, x)` always.
    private static func preferredTouch(_ a: TouchKeyStats, _ b: TouchKeyStats) -> TouchKeyStats {
        if a.count != b.count { return a.count > b.count ? a : b }
        let ka = [a.meanDX, a.meanDY, a.m2DX, a.m2DY, a.cDXDY]
        let kb = [b.meanDX, b.meanDY, b.m2DX, b.m2DY, b.cDXDY]
        for (x, y) in zip(ka, kb) where x != y {
            return x < y ? a : b
        }
        return a  // fully equal — either side
    }
}
