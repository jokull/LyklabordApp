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
/// - **tombstones**: set UNION — a deletion on either device wins over
///   everything on the other (counts, user-added status, bigrams), in both
///   directions. This mirrors `PersonalModel`'s local invariant
///   ("deletions must stick") across devices. Known consequence, accepted:
///   with no timestamps, a re-add (`addUserWord`, which clears the local
///   tombstone) loses to a device still carrying the tombstone until that
///   device also syncs the re-add state — deletion is the safer default
///   for a privacy product.
/// - **userAdded**: UNION minus tombstones.
/// - **words**: key union minus tombstones; per-word `WordStats` merge is
///   field-wise max of the four counts, sorted-set union of `daysSeen`
///   (capped at `Configuration.maxDistinctDaysTracked`, keeping the
///   earliest — same policy as `PersonalModel.learnCommit`), and OR of
///   `explicitlyAccepted`.
/// - **bigrams**: per-key max, minus any pair touching a tombstoned word
///   (mirrors `PersonalModel.remove`), then re-capped to the top
///   `Configuration.bigramCap` using the exact ordering `enforceCaps`
///   uses (count desc, key asc) so merge and compaction can never fight.
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
        let tombstones = a.tombstones.union(b.tombstones)
        let userAdded = a.userAdded.union(b.userAdded).subtracting(tombstones)

        var words: [String: PersonalModel.WordStats] = [:]
        words.reserveCapacity(max(a.words.count, b.words.count))
        for key in Set(a.words.keys).union(b.words.keys) {
            guard !tombstones.contains(key) else { continue }
            switch (a.words[key], b.words[key]) {
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
            guard !touchesTombstone(bigramKey: key, tombstones: tombstones) else { continue }
            bigrams[key] = max(a.bigrams[key] ?? 0, b.bigrams[key] ?? 0)
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
            touch: touch
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
    /// never contain whitespace — `EventLog.isLearnableWord`).
    private static func touchesTombstone(bigramKey: String, tombstones: Set<String>) -> Bool {
        guard let space = bigramKey.firstIndex(of: " ") else { return false }
        let first = String(bigramKey[..<space])
        let second = String(bigramKey[bigramKey.index(after: space)...])
        return tombstones.contains(first) || tombstones.contains(second)
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
