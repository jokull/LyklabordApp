import XCTest
import Learning
@testable import Sync

/// Merge semantics: targeted cases first, then randomized property tests
/// (seeded — reproducible) over payloads that respect the `PersonalModel`
/// invariants (tombstoned words carry no entry/userAdded/bigrams; that is
/// the state space actual model files live in).
final class MergeTests: XCTestCase {

    // MARK: - Tombstones win, both directions

    func testTombstoneOnRemoteKillsLocalEntry() {
        let local = Fixtures.payload(
            words: ["hestur": Fixtures.stats(count: 9, days: [1, 2], explicit: true)],
            bigrams: ["hestur á": 4, "á hestur": 3, "á hús": 2],
            userAdded: ["hestur"]
        )
        let remote = Fixtures.payload(tombstones: ["hestur"])

        for merged in [PersonalModelMerge.merge(local, remote), PersonalModelMerge.merge(remote, local)] {
            XCTAssertNil(merged.words["hestur"], "deletion must win over counts + explicit flag")
            XCTAssertFalse(merged.userAdded.contains("hestur"), "deletion must win over user-added")
            XCTAssertTrue(merged.tombstones.contains("hestur"))
            XCTAssertNil(merged.bigrams["hestur á"], "bigrams touching a tombstoned word are dropped")
            XCTAssertNil(merged.bigrams["á hestur"])
            XCTAssertEqual(merged.bigrams["á hús"], 2, "unrelated bigrams survive")
        }
    }

    func testTombstoneOnLocalKillsRemoteEntry() {
        let local = Fixtures.payload(tombstones: ["typo"])
        let remote = Fixtures.payload(
            words: ["typo": Fixtures.stats(count: 3, days: [5, 6])],
            userAdded: ["typo"]
        )
        let merged = PersonalModelMerge.merge(local, remote)
        XCTAssertNil(merged.words["typo"])
        XCTAssertFalse(merged.userAdded.contains("typo"))
        XCTAssertTrue(merged.tombstones.contains("typo"))
    }

    // MARK: - Tombstone epochs: an explicit re-add beats a synced deletion

    /// Device deleted "hestur" (epoch 1, synced), then the user re-added it
    /// in the editor (epoch 2, tombstone cleared, user-added). The remote
    /// still holds the epoch-1 tombstone: the re-add must win, from either
    /// side, and the stale tombstone must not come back.
    func testReAddAtHigherEpochBeatsSyncedTombstone() {
        let remote = Fixtures.payload(tombstones: ["hestur"], epochs: ["hestur": 1])
        let local = Fixtures.payload(userAdded: ["hestur"], epochs: ["hestur": 2])
        for merged in [PersonalModelMerge.merge(local, remote), PersonalModelMerge.merge(remote, local)] {
            XCTAssertFalse(merged.tombstones.contains("hestur"), "re-add must clear the synced tombstone")
            XCTAssertTrue(merged.userAdded.contains("hestur"), "re-added word must stay user-added")
            XCTAssertEqual(merged.tombstoneEpoch(of: "hestur"), 2)
        }
    }

    /// … and a LATER explicit delete (epoch 3) beats that re-add, even if
    /// the deleting device still carries the re-add's user-added flag on
    /// the other side of the merge.
    func testLaterDeleteAtHigherEpochBeatsEarlierReAdd() {
        let reAdded = Fixtures.payload(
            words: ["hestur": Fixtures.stats(count: 2, days: [1, 2])],
            userAdded: ["hestur"], epochs: ["hestur": 2])
        let deleted = Fixtures.payload(tombstones: ["hestur"], epochs: ["hestur": 3])
        for merged in [PersonalModelMerge.merge(reAdded, deleted), PersonalModelMerge.merge(deleted, reAdded)] {
            XCTAssertTrue(merged.tombstones.contains("hestur"))
            XCTAssertFalse(merged.userAdded.contains("hestur"))
            XCTAssertNil(merged.words["hestur"])
            XCTAssertEqual(merged.tombstoneEpoch(of: "hestur"), 3)
        }
    }

    /// Concurrent delete vs. re-add that never saw each other land on the
    /// same epoch: the tie goes to the deletion (safer default).
    func testEqualEpochTieGoesToTheTombstone() {
        let deleted = Fixtures.payload(tombstones: ["hestur"], epochs: ["hestur": 1])
        let added = Fixtures.payload(userAdded: ["hestur"], epochs: ["hestur": 1])
        for merged in [PersonalModelMerge.merge(deleted, added), PersonalModelMerge.merge(added, deleted)] {
            XCTAssertTrue(merged.tombstones.contains("hestur"))
            XCTAssertFalse(merged.userAdded.contains("hestur"))
        }
    }

    /// A device that never saw the deletion (epoch 0) still carries the
    /// word's old counts, user-added flag and bigrams. After a re-add at
    /// epoch 2 those are STALE and must not be revived — otherwise the
    /// result would depend on whether the stale device merged before or
    /// after the deletion (see the associativity note in `Merge.swift`).
    func testStaleLowerEpochSideContributesNothingForTheWord() {
        let stale = Fixtures.payload(
            words: ["hestur": Fixtures.stats(count: 10, is: 10, days: [1, 2], explicit: true), "á": Fixtures.stats(count: 3, days: [1])],
            bigrams: ["hestur á": 4, "á hús": 2],
            userAdded: ["hestur"])
        let deleted = Fixtures.payload(tombstones: ["hestur"], epochs: ["hestur": 1])
        let reAdded = Fixtures.payload(userAdded: ["hestur"], epochs: ["hestur": 2])

        let viaDelete = PersonalModelMerge.merge(PersonalModelMerge.merge(stale, deleted), reAdded)
        let viaReAdd = PersonalModelMerge.merge(stale, PersonalModelMerge.merge(deleted, reAdded))
        XCTAssertEqual(viaDelete, viaReAdd, "merge order must not matter")
        XCTAssertNil(viaReAdd.words["hestur"], "counts from before the deletion stay gone")
        XCTAssertNil(viaReAdd.bigrams["hestur á"], "bigrams from before the deletion stay gone")
        XCTAssertEqual(viaReAdd.bigrams["á hús"], 2, "unrelated bigrams untouched")
        XCTAssertEqual(viaReAdd.words["á"]?.count, 3, "unrelated words untouched")
        XCTAssertTrue(viaReAdd.userAdded.contains("hestur"), "the re-add itself is what survives")
    }

    /// Implicit relearning never touches the epoch, so new organic commits
    /// on a device that already synced the deletion stay blocked locally
    /// (`PersonalModel.learnCommit`), and a stale device's organic entry
    /// (epoch 0) still loses to the epoch-1 tombstone — deletions stick.
    func testImplicitEntryAtLowerEpochStillLosesToTombstone() {
        let stale = Fixtures.payload(words: ["typo": Fixtures.stats(count: 4, days: [1, 2])])
        let deleted = Fixtures.payload(tombstones: ["typo"], epochs: ["typo": 1])
        let merged = PersonalModelMerge.merge(stale, deleted)
        XCTAssertNil(merged.words["typo"])
        XCTAssertTrue(merged.tombstones.contains("typo"))
    }

    /// Documents with no epochs at all (pre-epoch builds) must merge exactly
    /// as before: tombstone union, user-added union minus tombstones.
    func testWithoutEpochsMergeIsTheOriginalUnion() {
        let a = Fixtures.payload(
            words: ["hestur": Fixtures.stats(count: 9, days: [1, 2], explicit: true)],
            bigrams: ["hestur á": 4, "á hús": 2],
            userAdded: ["hestur", "hús"])
        let b = Fixtures.payload(tombstones: ["hestur"], userAdded: ["á"])
        let merged = PersonalModelMerge.merge(a, b)
        XCTAssertEqual(merged.tombstones, ["hestur"])
        XCTAssertEqual(merged.userAdded, ["hús", "á"])
        XCTAssertNil(merged.words["hestur"])
        XCTAssertEqual(merged.bigrams, ["á hús": 2])
        XCTAssertTrue(merged.tombstoneEpochs.isEmpty, "no epochs in ⇒ no epochs out (byte-compatible documents)")
    }

    // MARK: - userAdded

    func testUserAddedIsUnionMinusTombstones() {
        let a = Fixtures.payload(tombstones: ["c"], userAdded: ["a", "b"])
        let b = Fixtures.payload(userAdded: ["b", "c"])
        let merged = PersonalModelMerge.merge(a, b)
        XCTAssertEqual(merged.userAdded, ["a", "b"])
        XCTAssertEqual(merged.tombstones, ["c"])
    }

    // MARK: - Word stats

    func testWordStatsFieldwiseMaxUnionDaysOrExplicit() {
        let a = Fixtures.payload(
            words: ["hús": Fixtures.stats(count: 10, is: 8, en: 0, un: 2, days: [1, 3], explicit: false)]
        )
        let b = Fixtures.payload(
            words: ["hús": Fixtures.stats(count: 4, is: 2, en: 1, un: 1, days: [2, 3], explicit: true)]
        )
        let merged = PersonalModelMerge.merge(a, b)
        let stats = merged.words["hús"]
        XCTAssertEqual(stats?.count, 10, "max, not sum — re-merge must be idempotent")
        XCTAssertEqual(stats?.icelandicCount, 8)
        XCTAssertEqual(stats?.englishCount, 1)
        XCTAssertEqual(stats?.unknownCount, 2)
        XCTAssertEqual(stats?.daysSeen, [1, 2, 3], "sorted union of distinct days")
        XCTAssertEqual(stats?.explicitlyAccepted, true, "OR of explicit flags")
    }

    func testDaysSeenUnionIsCapped() {
        let limits = PersonalModelMerge.Limits(
            configuration: PersonalModel.Configuration(maxDistinctDaysTracked: 4)
        )
        let a = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1, days: [1, 2, 3, 4])])
        let b = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1, days: [5, 6, 7, 8])])
        let merged = PersonalModelMerge.merge(a, b, limits: limits)
        XCTAssertEqual(merged.words["orð"]?.daysSeen, [1, 2, 3, 4], "earliest days kept, same as learnCommit")
    }

    // MARK: - Bigrams

    func testBigramMaxThenCapMatchesCompactionOrdering() {
        let limits = PersonalModelMerge.Limits(
            configuration: PersonalModel.Configuration(bigramCap: 2)
        )
        let a = Fixtures.payload(bigrams: ["a b": 5, "b c": 1])
        let b = Fixtures.payload(bigrams: ["a b": 2, "c d": 3, "a a": 3])
        let merged = PersonalModelMerge.merge(a, b, limits: limits)
        // max: ["a b": 5, "b c": 1, "c d": 3, "a a": 3]; cap 2 keeps by
        // (count desc, key asc): "a b"(5), then tie 3/3 → "a a" < "c d".
        XCTAssertEqual(merged.bigrams, ["a b": 5, "a a": 3])
    }

    // MARK: - Touch stats

    func testTouchHigherWeightSideWinsWholesale() {
        let heavy = Fixtures.touchStats(samples: [(0.1, 0.0), (0.2, 0.1), (0.15, 0.05)])
        let light = Fixtures.touchStats(samples: [(-0.4, -0.4)])
        let a = Fixtures.payload(touch: ["a": heavy, "s": light])
        let b = Fixtures.payload(touch: ["a": light, "ð": heavy])
        let merged = PersonalModelMerge.merge(a, b)
        XCTAssertEqual(merged.touch["a"], heavy, "higher effective sample count wins")
        XCTAssertEqual(merged.touch["s"], light, "one-sided keys carried through")
        XCTAssertEqual(merged.touch["ð"], heavy)
    }

    func testTouchTieBreakIsSymmetric() {
        let x = Fixtures.touchStats(samples: [(0.1, 0.2), (0.3, 0.1)])
        let y = Fixtures.touchStats(samples: [(-0.2, 0.0), (0.0, -0.1)])
        let a = Fixtures.payload(touch: ["k": x])
        let b = Fixtures.payload(touch: ["k": y])
        let ab = PersonalModelMerge.merge(a, b).touch["k"]
        let ba = PersonalModelMerge.merge(b, a).touch["k"]
        XCTAssertEqual(ab, ba, "equal-count tie must break identically from both directions")
    }

    // MARK: - Properties (randomized, seeded)

    private let iterations = 200

    func testPropertyIdempotence() {
        var rng = SeededRNG(seed: 0xC0FF_EE01)
        for i in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            XCTAssertEqual(PersonalModelMerge.merge(a, a), a, "merge(a,a) != a at iteration \(i)")
        }
    }

    func testPropertyCommutativity() {
        var rng = SeededRNG(seed: 0xC0FF_EE02)
        for i in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            XCTAssertEqual(
                PersonalModelMerge.merge(a, b),
                PersonalModelMerge.merge(b, a),
                "merge not commutative at iteration \(i)"
            )
        }
    }

    /// The ping-pong-safety property that justifies max-not-sum: folding
    /// either input back into the merge result changes nothing.
    func testPropertyReMergeAbsorption() {
        var rng = SeededRNG(seed: 0xC0FF_EE03)
        for i in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            let merged = PersonalModelMerge.merge(a, b)
            XCTAssertEqual(PersonalModelMerge.merge(merged, a), merged, "re-merging a inflated state at \(i)")
            XCTAssertEqual(PersonalModelMerge.merge(merged, b), merged, "re-merging b inflated state at \(i)")
            XCTAssertEqual(PersonalModelMerge.merge(merged, merged), merged, "self-merge changed state at \(i)")
        }
    }

    func testPropertyAssociativity() {
        var rng = SeededRNG(seed: 0xC0FF_EE04)
        for i in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            let c = PayloadGen.payload(&rng)
            XCTAssertEqual(
                PersonalModelMerge.merge(PersonalModelMerge.merge(a, b), c),
                PersonalModelMerge.merge(a, PersonalModelMerge.merge(b, c)),
                "merge not associative at iteration \(i)"
            )
        }
    }

    /// Tombstones win at equal epochs; a strictly higher epoch wins outright
    /// (that is the only way a re-add can ever beat a deletion). Either way
    /// a tombstoned word carries no entry, no user-added flag, no bigram.
    func testPropertyTombstonesWinAtTheWordsMaxEpoch() {
        var rng = SeededRNG(seed: 0xC0FF_EE05)
        for _ in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            let merged = PersonalModelMerge.merge(a, b)
            var expected: Set<String> = []
            for word in a.tombstones.union(b.tombstones) {
                let top = max(a.tombstoneEpoch(of: word), b.tombstoneEpoch(of: word))
                if (a.tombstones.contains(word) && a.tombstoneEpoch(of: word) == top)
                    || (b.tombstones.contains(word) && b.tombstoneEpoch(of: word) == top) {
                    expected.insert(word)
                }
            }
            XCTAssertEqual(merged.tombstones, expected)
            for word in Set(a.tombstoneEpochs.keys).union(b.tombstoneEpochs.keys) {
                XCTAssertEqual(merged.tombstoneEpoch(of: word), max(a.tombstoneEpoch(of: word), b.tombstoneEpoch(of: word)))
            }
            for tomb in merged.tombstones {
                XCTAssertNil(merged.words[tomb])
                XCTAssertFalse(merged.userAdded.contains(tomb))
                for key in merged.bigrams.keys {
                    XCTAssertFalse(
                        key.hasPrefix(tomb + " ") || key.hasSuffix(" " + tomb),
                        "bigram \(key) touches tombstone \(tomb)"
                    )
                }
            }
        }
    }

    func testPropertyCapsHold() {
        var rng = SeededRNG(seed: 0xC0FF_EE06)
        let limits = PersonalModelMerge.Limits(
            configuration: PersonalModel.Configuration(maxDistinctDaysTracked: 3, bigramCap: 4)
        )
        for _ in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            let merged = PersonalModelMerge.merge(a, b, limits: limits)
            XCTAssertLessThanOrEqual(merged.bigrams.count, 4)
            for stats in merged.words.values {
                XCTAssertLessThanOrEqual(stats.daysSeen.count, 3)
                XCTAssertEqual(stats.daysSeen, stats.daysSeen.sorted(), "daysSeen stays sorted")
            }
        }
    }

    /// Merged output must always load back into a real `PersonalModel`.
    func testPropertyMergedPayloadRoundTripsThroughPersonalModel() throws {
        var rng = SeededRNG(seed: 0xC0FF_EE07)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<20 {
            let merged = PersonalModelMerge.merge(PayloadGen.payload(&rng), PayloadGen.payload(&rng))
            let url = dir.appendingPathComponent("m\(i).json")
            try Fixtures.modelData(merged).write(to: url)
            XCTAssertNoThrow(try PersonalModel(contentsOf: url), "merged payload rejected by PersonalModel at \(i)")
        }
    }
}
