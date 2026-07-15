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

    func testPropertyTombstonesAlwaysWin() {
        var rng = SeededRNG(seed: 0xC0FF_EE05)
        for _ in 0..<iterations {
            let a = PayloadGen.payload(&rng)
            let b = PayloadGen.payload(&rng)
            let merged = PersonalModelMerge.merge(a, b)
            XCTAssertEqual(merged.tombstones, a.tombstones.union(b.tombstones))
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
