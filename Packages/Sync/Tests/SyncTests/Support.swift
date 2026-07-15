import XCTest
import Learning
@testable import Sync

/// Shared builders for payloads, documents, and records.
enum Fixtures {

    static func stats(
        count: UInt32,
        is isCount: UInt32 = 0,
        en: UInt32 = 0,
        un: UInt32 = 0,
        days: [Int32] = [],
        explicit: Bool = false
    ) -> PersonalModel.WordStats {
        PersonalModel.WordStats(
            count: count,
            icelandicCount: isCount,
            englishCount: en,
            unknownCount: un,
            daysSeen: days,
            explicitlyAccepted: explicit
        )
    }

    static func touchStats(samples: [(Double, Double)]) -> TouchKeyStats {
        var stats = TouchKeyStats()
        for (dx, dy) in samples {
            stats.update(dx: dx, dy: dy)
        }
        return stats
    }

    static func payload(
        words: [String: PersonalModel.WordStats] = [:],
        bigrams: [String: UInt32] = [:],
        tombstones: Set<String> = [],
        userAdded: Set<String> = [],
        touch: [String: TouchKeyStats] = [:]
    ) -> SyncPayload {
        SyncPayload(
            words: words,
            bigrams: bigrams,
            tombstones: tombstones,
            userAdded: userAdded,
            touch: touch
        )
    }

    /// Serialized model file bytes for a payload (optionally with a
    /// device-local log marker attached).
    static func modelData(
        _ payload: SyncPayload,
        marker: EventLog.ConsumedMarker? = nil
    ) throws -> Data {
        try PersonalModelDocument(payload: payload, consumedLogMarker: marker).encoded()
    }

    /// A store record exactly as the engine would write it for `payload`.
    static func record(
        _ payload: SyncPayload,
        keyData: Data,
        device: String = "other-device",
        schemaVersion: Int? = nil
    ) throws -> SnapshotRecord {
        let plaintext = try payload.canonicalData()
        return SnapshotRecord(
            sealedBlob: try SyncCrypto.seal(plaintext, keyData: keyData),
            schemaVersion: schemaVersion ?? payload.schemaVersion,
            modelDigest: SyncCrypto.digestHex(plaintext),
            deviceLastWriter: device
        )
    }
}

/// Deterministic seeded RNG for the merge property tests (SplitMix64) —
/// failures reproduce exactly.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random payload generator over a SMALL word alphabet so that two
/// independently generated payloads collide on keys constantly — the
/// interesting merge paths (both-sides entries, tombstone-vs-entry,
/// userAdded-vs-tombstone) are exercised on every iteration.
enum PayloadGen {
    static let alphabet = [
        "á", "hús", "hestur", "jökull", "smellir", "og", "en", "the", "his",
        "prófílmynd", "þú", "æði", "köttur",
    ]

    static func word(_ rng: inout SeededRNG) -> String {
        alphabet[Int(rng.next() % UInt64(alphabet.count))]
    }

    static func payload(_ rng: inout SeededRNG) -> SyncPayload {
        var words: [String: PersonalModel.WordStats] = [:]
        for _ in 0..<(rng.next() % 10) {
            var days: [Int32] = []
            for _ in 0..<(rng.next() % 5) {
                days.append(Int32(20_000 + rng.next() % 12))
            }
            words[word(&rng)] = PersonalModel.WordStats(
                count: UInt32(rng.next() % 50),
                icelandicCount: UInt32(rng.next() % 20),
                englishCount: UInt32(rng.next() % 20),
                unknownCount: UInt32(rng.next() % 20),
                daysSeen: Array(Set(days)).sorted(),
                explicitlyAccepted: rng.next() % 2 == 0
            )
        }
        var bigrams: [String: UInt32] = [:]
        for _ in 0..<(rng.next() % 8) {
            bigrams["\(word(&rng)) \(word(&rng))"] = UInt32(1 + rng.next() % 30)
        }
        var tombstones: Set<String> = []
        for _ in 0..<(rng.next() % 3) {
            tombstones.insert(word(&rng))
        }
        var userAdded: Set<String> = []
        for _ in 0..<(rng.next() % 3) {
            userAdded.insert(word(&rng))
        }
        var touch: [String: TouchKeyStats] = [:]
        for key in ["a", "s", "ð"] where rng.next() % 2 == 0 {
            var stats = TouchKeyStats()
            for _ in 0..<(1 + rng.next() % 6) {
                stats.update(
                    dx: Double(Int64(bitPattern: rng.next() % 100)) / 100.0 - 0.5,
                    dy: Double(Int64(bitPattern: rng.next() % 100)) / 100.0 - 0.5
                )
            }
            touch[key] = stats
        }
        // Mirror PersonalModel invariants the generator must respect:
        // tombstoned words carry no entry / userAdded / bigrams.
        for tomb in tombstones {
            words.removeValue(forKey: tomb)
            userAdded.remove(tomb)
            bigrams = bigrams.filter { key, _ in
                !key.hasPrefix(tomb + " ") && !key.hasSuffix(" " + tomb)
            }
        }
        return Fixtures.payload(
            words: words,
            bigrams: bigrams,
            tombstones: tombstones,
            userAdded: userAdded,
            touch: touch
        )
    }
}
