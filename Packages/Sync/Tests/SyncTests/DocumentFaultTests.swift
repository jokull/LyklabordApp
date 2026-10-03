import XCTest
import Learning
@testable import Sync

/// Malformed, truncated and version-skewed input to the crypto envelope,
/// the document codec and the engine. Everything here must be a thrown /
/// returned error — never a crash, never a clobbered local or remote.
final class DocumentFaultTests: XCTestCase {

    private func samplePayload() -> SyncPayload {
        Fixtures.payload(
            words: [
                "jökull": Fixtures.stats(count: 5, is: 5, days: [20_000, 20_001]),
                "the": Fixtures.stats(count: 2, en: 2, days: [20_001], explicit: true),
            ],
            bigrams: ["jökull bráðnar": 3],
            tombstones: ["óvinur"],
            userAdded: ["Þórsmörk"],
            touch: ["a": Fixtures.touchStats(samples: [(0.1, -0.2), (0.15, -0.1)])]
        )
    }

    // MARK: - Crypto envelope

    func testSealedBlobTruncatedAtEveryOffsetCannotOpen() throws {
        let key = SyncCrypto.generateKey()
        let sealed = try SyncCrypto.seal(try samplePayload().canonicalData(), keyData: key)
        for cut in 0..<sealed.count {
            XCTAssertThrowsError(try SyncCrypto.open(sealed.prefix(cut), keyData: key), "cut=\(cut)") { error in
                XCTAssertEqual(error as? SyncCryptoError, .cannotOpen, "cut=\(cut)")
            }
        }
        XCTAssertNoThrow(try SyncCrypto.open(sealed, keyData: key))
    }

    func testSealedBlobWithAnySingleBitFlipCannotOpen() throws {
        let key = SyncCrypto.generateKey()
        let sealed = try SyncCrypto.seal(try samplePayload().canonicalData(), keyData: key)
        for position in 0..<sealed.count {
            for bit in 0..<8 {
                var flipped = sealed
                flipped[position] ^= UInt8(1 << bit)
                XCTAssertThrowsError(try SyncCrypto.open(flipped, keyData: key), "byte \(position) bit \(bit)") { error in
                    XCTAssertEqual(error as? SyncCryptoError, .cannotOpen)
                }
            }
        }
    }

    func testSealedBlobWithExtraTrailingBytesCannotOpen() throws {
        let key = SyncCrypto.generateKey()
        var sealed = try SyncCrypto.seal(Data("x".utf8), keyData: key)
        sealed.append(0x00)
        XCTAssertThrowsError(try SyncCrypto.open(sealed, keyData: key))
    }

    func testKeyOfEveryWrongSizeIsRejectedBeforeTouchingTheBlob() throws {
        let sealed = try SyncCrypto.seal(Data("x".utf8), keyData: SyncCrypto.generateKey())
        for size in [0, 1, 16, 24, 31, 33, 64] {
            XCTAssertThrowsError(try SyncCrypto.open(sealed, keyData: Data(repeating: 1, count: size))) { error in
                XCTAssertEqual(error as? SyncCryptoError, .invalidKeySize(size))
            }
        }
    }

    // MARK: - Document / payload codec

    func testModelFileTruncatedAtEveryOffsetThrows() throws {
        let data = try Fixtures.modelData(samplePayload(), marker: EventLog.ConsumedMarker(generation: UUID(), offset: 99))
        for cut in 0..<data.count {
            XCTAssertThrowsError(try PersonalModelDocument(decoding: data.prefix(cut)), "cut=\(cut)")
            XCTAssertThrowsError(try SyncPayload.decode(data.prefix(cut)), "cut=\(cut)")
        }
        XCTAssertNoThrow(try PersonalModelDocument(decoding: data))
    }

    func testPayloadWithEveryByteCorruptedNeverCrashes() throws {
        // Many flips still yield valid JSON (a digit changes) — that must
        // decode to SOMETHING sane or throw; it must never trap.
        let data = try samplePayload().canonicalData()
        for position in 0..<data.count {
            var corrupted = data
            corrupted[position] ^= 0x01
            if let payload = try? SyncPayload.decode(corrupted) {
                // Whatever decoded must be re-encodable and mergeable.
                XCTAssertNoThrow(try payload.canonicalData(), "byte \(position)")
                _ = PersonalModelMerge.merge(payload, samplePayload())
            }
        }
    }

    func testSchemaVersionSkewIsRejectedInBothDirections() throws {
        func json(schema: Int) -> Data {
            Data(#"{"schemaVersion":\#(schema),"words":{},"bigrams":{},"tombstones":[],"userAdded":[],"touch":{}}"#.utf8)
        }
        for schema in [0, -1, 2, 99, Int.max] {
            XCTAssertThrowsError(try SyncPayload.decode(json(schema: schema)), "schema \(schema)")
            XCTAssertThrowsError(try PersonalModelDocument(decoding: json(schema: schema)), "schema \(schema)")
        }
        XCTAssertNoThrow(try SyncPayload.decode(json(schema: PersonalModel.schemaVersion)))
    }

    func testMissingAndExtraFieldsBehaveAsCodableContract() throws {
        // A future, additive field must not break decoding (forward
        // compatibility is the stated reason for choosing JSON).
        let extra = Data(#"{"schemaVersion":1,"words":{},"bigrams":{},"tombstones":[],"userAdded":[],"touch":{},"futureField":42}"#.utf8)
        XCTAssertNoThrow(try SyncPayload.decode(extra))
        XCTAssertNoThrow(try PersonalModelDocument(decoding: extra))
        // A missing required collection is undecodable.
        let missing = Data(#"{"schemaVersion":1,"words":{},"bigrams":{},"tombstones":[],"touch":{}}"#.utf8)
        XCTAssertThrowsError(try SyncPayload.decode(missing))
    }

    // MARK: - Epoch field skew (ADR-0009: additive field, both directions)

    /// A document written by a build that predates `tombstoneEpochs` has no
    /// such key. A new reader must decode it (all epochs 0), merge it with
    /// an epoch-carrying payload under the documented rules, and re-encode
    /// WITHOUT the key when nothing carries an epoch — byte-identical to
    /// what the old build wrote.
    func testOldWriterNewReader() throws {
        let old = Data(#"{"schemaVersion":1,"words":{},"bigrams":{},"tombstones":["hestur"],"userAdded":["hús"],"touch":{}}"#.utf8)
        let payload = try SyncPayload.decode(old)
        XCTAssertTrue(payload.tombstoneEpochs.isEmpty)
        XCTAssertEqual(payload.tombstoneEpoch(of: "hestur"), 0)
        XCTAssertFalse(String(decoding: try payload.canonicalData(), as: UTF8.self).contains("tombstoneEpochs"),
                       "no epochs ⇒ no key ⇒ the old build's digest is unchanged")
        XCTAssertFalse(String(decoding: try PersonalModelDocument(decoding: old).encoded(), as: UTF8.self).contains("tombstoneEpochs"))

        // The old device's tombstone (epoch 0) loses to a new device's
        // explicit re-add (epoch 2) …
        let reAdded = Fixtures.payload(userAdded: ["hestur"], epochs: ["hestur": 2])
        let merged = PersonalModelMerge.merge(payload, reAdded)
        XCTAssertFalse(merged.tombstones.contains("hestur"))
        XCTAssertTrue(merged.userAdded.contains("hestur"))
        XCTAssertTrue(merged.userAdded.contains("hús"))
        // … and the merged document now carries the epoch for the new fleet.
        let reEncoded = try SyncPayload.decode(try merged.canonicalData())
        XCTAssertEqual(reEncoded, merged)
        XCTAssertEqual(reEncoded.tombstoneEpoch(of: "hestur"), 2)
    }

    /// A document written by THIS build, read by a build that predates the
    /// field (modelled by a local struct mirroring the old `Stored` shape
    /// with `JSONDecoder`'s default ignore-unknown-keys behaviour): decodes,
    /// every pre-existing field round-trips, and the old build's union
    /// merge sees a plain tombstone/user-added set. The old build then
    /// re-encodes WITHOUT epochs — the documented mixed-fleet limitation
    /// (ADR-0009): its union re-tombstones a re-added word until it updates,
    /// while the new device keeps its re-add locally (epoch 2 > 0).
    func testNewWriterOldReader() throws {
        struct OldStored: Codable, Equatable {
            var schemaVersion: Int
            var words: [String: PersonalModel.WordStats]
            var bigrams: [String: UInt32]
            var tombstones: [String]
            var userAdded: [String]
            var touch: [String: TouchKeyStats]
            var consumedLogMarker: EventLog.ConsumedMarker?
        }
        var payload = samplePayload()
        payload.tombstoneEpochs = ["óvinur": 1, "Þórsmörk": 2]
        let marker = EventLog.ConsumedMarker(generation: UUID(), offset: 7)
        let data = try Fixtures.modelData(payload, marker: marker)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"tombstoneEpochs\""))

        let old = try JSONDecoder().decode(OldStored.self, from: data)
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertEqual(old.words, payload.words)
        XCTAssertEqual(old.bigrams, payload.bigrams)
        XCTAssertEqual(Set(old.tombstones), payload.tombstones)
        XCTAssertEqual(Set(old.userAdded), payload.userAdded)
        XCTAssertEqual(old.touch, payload.touch)
        XCTAssertEqual(old.consumedLogMarker, marker)

        // What the old build pushes back: the same state minus the epochs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stripped = try SyncPayload.decode(try encoder.encode(old))
        XCTAssertTrue(stripped.tombstoneEpochs.isEmpty)
        var expected = payload
        expected.tombstoneEpochs = [:]
        XCTAssertEqual(stripped, expected)

        // New device (re-add at epoch 2) vs. the stripped remote: the
        // re-add survives locally; nothing crashes, nothing is lost that
        // the old build could represent.
        let newLocal = Fixtures.payload(userAdded: ["Þórsmörk"], epochs: ["Þórsmörk": 2])
        let merged = PersonalModelMerge.merge(newLocal, stripped)
        XCTAssertTrue(merged.userAdded.contains("Þórsmörk"))
        XCTAssertEqual(merged.tombstones, ["óvinur"])
    }

    func testNonFiniteTouchValuesInRemoteJSONAreRejectedNotPropagated() {
        // JSONDecoder's default non-conforming-float strategy throws on
        // "nan"/"inf" tokens; make sure a hostile remote cannot smuggle a
        // NaN into the merge (where it would poison every device's save).
        let hostile = Data(#"{"schemaVersion":1,"words":{},"bigrams":{},"tombstones":[],"userAdded":[],"touch":{"a":{"count":1,"meanDX":nan,"meanDY":0,"m2DX":0,"m2DY":0,"cDXDY":0}}}"#.utf8)
        XCTAssertThrowsError(try SyncPayload.decode(hostile))
        let hostileInf = Data(#"{"schemaVersion":1,"words":{},"bigrams":{},"tombstones":[],"userAdded":[],"touch":{"a":{"count":1,"meanDX":1e999,"meanDY":0,"m2DX":0,"m2DY":0,"cDXDY":0}}}"#.utf8)
        XCTAssertThrowsError(try SyncPayload.decode(hostileInf), "1e999 overflows to +inf and must be rejected")
    }

    // MARK: - Engine against hostile remotes

    private func engine(store: InMemoryCloudStore, keyStore: InMemoryKeyStore) -> SyncEngine {
        SyncEngine(store: store, keyStore: keyStore, isEnabled: { true }, deviceIdentifier: "d")
    }

    /// A remote payload violating the PersonalModel invariants (word also
    /// tombstoned, unsorted/duplicate days, user-added tombstone, bigram
    /// touching a tombstone, oversize days list): the merge must normalize
    /// it, the result must satisfy the invariants, and a second sync must
    /// be `.upToDate` — no perpetual push churn from normalization.
    func testInvariantViolatingRemoteIsNormalizedAndConverges() async throws {
        let key = SyncCrypto.generateKey()
        let store = InMemoryCloudStore()
        let keyStore = InMemoryKeyStore(initialKey: key)
        let hostile = SyncPayload(
            words: [
                "typo": Fixtures.stats(count: 3, days: [5]),
                "hús": Fixtures.stats(count: 1, days: [9, 3, 3, 1, 1, 7, 8, 2, 4, 6, 10, 11]),
            ],
            bigrams: ["typo hús": 2, "hús typo": 1, "hús hús": 4],
            tombstones: ["typo"],
            userAdded: ["typo"],
            touch: [:]
        )
        await store.seed(try Fixtures.record(hostile, keyData: key))
        let local = Fixtures.payload(words: ["heima": Fixtures.stats(count: 2, days: [1, 2])])

        let outcome = await engine(store: store, keyStore: keyStore).sync(localModelData: try Fixtures.modelData(local))
        guard case .merged(let data) = outcome else { return XCTFail("expected merged, got \(outcome)") }
        let merged = try PersonalModelDocument(decoding: data).payload
        XCTAssertNil(merged.words["typo"])
        XCTAssertFalse(merged.userAdded.contains("typo"))
        XCTAssertTrue(merged.tombstones.contains("typo"))
        XCTAssertNil(merged.bigrams["typo hús"])
        XCTAssertNil(merged.bigrams["hús typo"])
        XCTAssertEqual(merged.bigrams["hús hús"], 4)
        let days = try XCTUnwrap(merged.words["hús"]?.daysSeen)
        XCTAssertEqual(days, days.sorted())
        XCTAssertLessThanOrEqual(days.count, PersonalModel.Configuration().maxDistinctDaysTracked)
        // Observation (not asserted as a bug — compaction never produces
        // duplicates): the ONE-SIDED path `capped()` sorts and caps but does
        // not dedupe, unlike the two-sided `mergedDays`. A hostile remote
        // could therefore keep `[5, 5]` and count as "two distinct days".
        XCTAssertEqual(days, [1, 1, 2, 3, 3, 4, 6, 7], "one-sided normalization keeps duplicates today")

        // Converges: the normalized state is now both local and remote.
        let again = await engine(store: store, keyStore: keyStore).sync(localModelData: data)
        XCTAssertEqual(again, .upToDate)
        // And loads into a real model.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hostile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertNoThrow(try PersonalModel(contentsOf: url))
    }

    /// Record header says schema 1 (passes the pre-decrypt gate) but the
    /// encrypted payload declares a different schema. Must be a safe
    /// failure with remote untouched. (Observation: it is reported as
    /// `.cannotDecryptRemote`, whose user remedy is "delete iCloud data" —
    /// misleading for what is really a version skew, but safe.)
    func testRecordHeaderAndPayloadSchemaMismatchIsSafeFailure() async throws {
        let key = SyncCrypto.generateKey()
        let store = InMemoryCloudStore()
        let keyStore = InMemoryKeyStore(initialKey: key)
        let futurePayload = SyncPayload(schemaVersion: PersonalModel.schemaVersion + 1, words: ["x": Fixtures.stats(count: 1)])
        let record = try Fixtures.record(futurePayload, keyData: key, schemaVersion: PersonalModel.schemaVersion)
        await store.seed(record)
        let outcome = await engine(store: store, keyStore: keyStore).sync(localModelData: try Fixtures.modelData(Fixtures.payload(words: ["y": Fixtures.stats(count: 1)])))
        guard case .failed(let reason, let data) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertNil(data)
        XCTAssertTrue(reason == .cannotDecryptRemote || reason == .newerRemoteSchema, "\(reason)")
        let stored = await store.record
        XCTAssertEqual(stored, record, "remote must not be overwritten")
    }

    /// Lying digest: the record claims a digest that does not match its
    /// plaintext. The engine never verifies this (it trusts the digest for
    /// change detection), so merge still proceeds from the decrypted
    /// content and the pushed record carries a correct digest.
    func testRecordWithWrongDigestStillMergesFromDecryptedContent() async throws {
        let key = SyncCrypto.generateKey()
        let store = InMemoryCloudStore()
        let keyStore = InMemoryKeyStore(initialKey: key)
        var record = try Fixtures.record(Fixtures.payload(words: ["remote": Fixtures.stats(count: 1, days: [1, 2])]), keyData: key)
        record.modelDigest = String(repeating: "0", count: 64)
        await store.seed(record)
        let outcome = await engine(store: store, keyStore: keyStore).sync(localModelData: try Fixtures.modelData(Fixtures.payload(words: ["local": Fixtures.stats(count: 1, days: [1, 2])])))
        guard case .merged(let data) = outcome else { return XCTFail("expected merged, got \(outcome)") }
        let merged = try PersonalModelDocument(decoding: data).payload
        XCTAssertEqual(Set(merged.words.keys), ["remote", "local"])
        let storedRecord = await store.record
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.modelDigest, try merged.digestHex())
    }
}
