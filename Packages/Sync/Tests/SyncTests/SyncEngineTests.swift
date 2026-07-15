import XCTest
import Learning
@testable import Sync

/// End-to-end engine behavior against the in-memory store + keychain fakes.
final class EngineTests: XCTestCase {

    private var store: InMemoryCloudStore!
    private var keyStore: InMemoryKeyStore!
    private var enabled = true

    override func setUp() {
        super.setUp()
        store = InMemoryCloudStore()
        keyStore = InMemoryKeyStore()
        enabled = true
    }

    private func makeEngine() -> SyncEngine {
        SyncEngine(
            store: store,
            keyStore: keyStore,
            isEnabled: { [weak self] in self?.enabled ?? false },
            deviceIdentifier: "test-device"
        )
    }

    private func decodePayload(_ record: SnapshotRecord, key: Data) throws -> SyncPayload {
        try SyncPayload.decode(try SyncCrypto.open(record.sealedBlob, keyData: key))
    }

    // MARK: - Opt-out

    func testDisabledShortCircuitsWithoutTouchingStoreOrKeychain() async throws {
        enabled = false
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .disabled)
        let fetches = await store.fetchCount
        XCTAssertEqual(fetches, 0, "disabled sync must not fetch")
        XCTAssertNil(keyStore.stored, "disabled sync must not mint a key")
    }

    func testDeleteRemoteWorksWhileDisabled() async throws {
        enabled = false
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        await store.seed(try Fixtures.record(Fixtures.payload(), keyData: key))
        let outcome = await makeEngine().deleteRemote()
        XCTAssertEqual(outcome, .deleted)
        let record = await store.record
        XCTAssertNil(record, "opt-out must not block delete-all")
        XCTAssertNotNil(keyStore.stored, "key kept by default (other devices may still need it)")
    }

    func testDeleteRemoteCanAlsoRemoveKey() async throws {
        keyStore = InMemoryKeyStore(initialKey: SyncCrypto.generateKey())
        let outcome = await makeEngine().deleteRemote(alsoRemoveKey: true)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertNil(keyStore.stored)
    }

    // MARK: - Bootstrap / first push

    func testFirstSyncMintsKeyAndPushes() async throws {
        let payload = Fixtures.payload(words: ["jökull": Fixtures.stats(count: 2, days: [1, 2])])
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(payload))
        XCTAssertEqual(outcome, .pushed)

        let key = try XCTUnwrap(keyStore.stored, "first sync bootstraps the envelope key")
        XCTAssertEqual(key.count, 32)
        let storedRecord = await store.record
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.schemaVersion, PersonalModel.schemaVersion)
        XCTAssertEqual(record.deviceLastWriter, "test-device")
        XCTAssertEqual(record.modelDigest, try payload.digestHex())
        XCTAssertEqual(try decodePayload(record, key: key), payload, "encrypt→save→fetch→decrypt round trip")
    }

    func testKeyMissingWithExistingRemoteNeverMintsSecondKey() async throws {
        let otherKey = SyncCrypto.generateKey()
        await store.seed(try Fixtures.record(Fixtures.payload(), keyData: otherKey))
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .failed(.keyUnavailable, newLocalModelData: nil))
        XCTAssertNil(keyStore.stored, "must wait for iCloud Keychain, not fork the key")
        let saves = await store.saveCount
        XCTAssertEqual(saves, 0, "remote untouched")
    }

    // MARK: - Steady states

    func testUpToDateWhenDigestsMatchWithoutDecrypting() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let payload = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1)])
        // Garbage blob with the CORRECT digest: if the engine tried to
        // decrypt it, the outcome would be cannotDecryptRemote — upToDate
        // proves the digest short-circuit.
        let record = SnapshotRecord(
            sealedBlob: Data([0xDE, 0xAD]),
            schemaVersion: PersonalModel.schemaVersion,
            modelDigest: try payload.digestHex(),
            deviceLastWriter: "other"
        )
        await store.seed(record)
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(payload))
        XCTAssertEqual(outcome, .upToDate)
    }

    func testPushWhenRemoteIsBehind() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let remotePayload = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1, days: [1])])
        let localPayload = Fixtures.payload(words: [
            "orð": Fixtures.stats(count: 5, days: [1, 2]),
            "nýtt": Fixtures.stats(count: 2, days: [2, 3]),
        ])
        await store.seed(try Fixtures.record(remotePayload, keyData: key))
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(localPayload))
        XCTAssertEqual(outcome, .pushed)
        let storedRecord = await store.record
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(try decodePayload(record, key: key), localPayload)
    }

    func testPullWhenLocalIsBehindPreservesLocalLogMarker() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let localPayload = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1, days: [1])])
        let remotePayload = Fixtures.payload(words: [
            "orð": Fixtures.stats(count: 5, days: [1, 2]),
            "fjarlægt": Fixtures.stats(count: 3, days: [4, 5]),
        ])
        await store.seed(try Fixtures.record(remotePayload, keyData: key))
        let marker = EventLog.ConsumedMarker(generation: UUID(), offset: 1234)

        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(localPayload, marker: marker))
        guard case .pulled(let newData) = outcome else {
            return XCTFail("expected pulled, got \(outcome)")
        }
        let newDoc = try PersonalModelDocument(decoding: newData)
        XCTAssertEqual(newDoc.payload, remotePayload, "local was a strict subset — pull yields remote state")
        XCTAssertEqual(newDoc.consumedLogMarker, marker, "device-local log frontier must survive a pull")
        let saves = await store.saveCount
        XCTAssertEqual(saves, 0, "nothing to push when remote already has the superset")
    }

    func testMergedWhenBothSidesChanged() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let localPayload = Fixtures.payload(
            words: ["heima": Fixtures.stats(count: 2, days: [1, 2])],
            tombstones: ["typo"]
        )
        let remotePayload = Fixtures.payload(
            words: [
                "vinnan": Fixtures.stats(count: 4, days: [3, 4]),
                "typo": Fixtures.stats(count: 1, days: [3]),
            ]
        )
        await store.seed(try Fixtures.record(remotePayload, keyData: key))

        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(localPayload))
        guard case .merged(let newData) = outcome else {
            return XCTFail("expected merged, got \(outcome)")
        }
        let mergedPayload = try PersonalModelDocument(decoding: newData).payload
        XCTAssertEqual(mergedPayload.words["heima"]?.count, 2)
        XCTAssertEqual(mergedPayload.words["vinnan"]?.count, 4)
        XCTAssertNil(mergedPayload.words["typo"], "local tombstone kills remote entry")
        XCTAssertTrue(mergedPayload.tombstones.contains("typo"))

        let storedRecord = await store.record
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(try decodePayload(record, key: key), mergedPayload, "pushed record matches new local state")
        XCTAssertEqual(record.modelDigest, try mergedPayload.digestHex())
    }

    // MARK: - Conflict retry

    func testConflictRetriesOnceWithReMerge() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let localPayload = Fixtures.payload(words: ["a": Fixtures.stats(count: 1, days: [1])])
        let remotePayload = Fixtures.payload(words: ["b": Fixtures.stats(count: 2, days: [2])])
        let concurrentPayload = Fixtures.payload(words: ["c": Fixtures.stats(count: 3, days: [3])])
        await store.seed(try Fixtures.record(remotePayload, keyData: key))
        // Third device writes between our fetch and our save:
        await store.queueConcurrentWrite(try Fixtures.record(concurrentPayload, keyData: key))

        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(localPayload))
        guard case .merged(let newData) = outcome else {
            return XCTFail("expected merged after conflict retry, got \(outcome)")
        }
        let mergedPayload = try PersonalModelDocument(decoding: newData).payload
        XCTAssertEqual(Set(mergedPayload.words.keys), ["a", "b", "c"], "retry must fold in the conflicting write")
        let storedRecord = await store.record
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(try decodePayload(record, key: key), mergedPayload)
        let saves = await store.saveCount
        XCTAssertEqual(saves, 2, "exactly one retry")
    }

    func testSecondConflictFailsButStillReturnsMergedLocalData() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let localPayload = Fixtures.payload(words: ["a": Fixtures.stats(count: 1, days: [1])])
        await store.seed(try Fixtures.record(Fixtures.payload(words: ["b": Fixtures.stats(count: 1, days: [1])]), keyData: key))
        await store.queueConcurrentWrite(try Fixtures.record(Fixtures.payload(words: ["c": Fixtures.stats(count: 1, days: [1])]), keyData: key))
        await store.queueConcurrentWrite(try Fixtures.record(Fixtures.payload(words: ["d": Fixtures.stats(count: 1, days: [1])]), keyData: key))

        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(localPayload))
        guard case .failed(let reason, let newData) = outcome else {
            return XCTFail("expected failure after two conflicts, got \(outcome)")
        }
        XCTAssertEqual(reason, .conflict)
        let payload = try PersonalModelDocument(decoding: try XCTUnwrap(newData, "merged local progress must not be discarded")).payload
        XCTAssertTrue(Set(payload.words.keys).isSuperset(of: ["a", "b", "c"]), "local still gains everything merged so far")
        let saves = await store.saveCount
        XCTAssertEqual(saves, 2, "retry once, then give up until next scheduled sync")
    }

    // MARK: - Failure modes (never crash, never clobber)

    func testCorruptRemoteBlobIsSafeError() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        let corrupt = SnapshotRecord(
            sealedBlob: Data(repeating: 0x55, count: 80),
            schemaVersion: PersonalModel.schemaVersion,
            modelDigest: "0000000000000000000000000000000000000000000000000000000000000000",
            deviceLastWriter: "other"
        )
        await store.seed(corrupt)
        let localData = try Fixtures.modelData(Fixtures.payload(words: ["orð": Fixtures.stats(count: 1)]))
        let outcome = await makeEngine().sync(localModelData: localData)
        XCTAssertEqual(outcome, .failed(.cannotDecryptRemote, newLocalModelData: nil))
        let record = await store.record
        XCTAssertEqual(record, corrupt, "remote must NOT be overwritten on decrypt failure")
    }

    func testRemoteEncryptedWithDifferentKeyIsSafeError() async throws {
        keyStore = InMemoryKeyStore(initialKey: SyncCrypto.generateKey())
        await store.seed(try Fixtures.record(Fixtures.payload(), keyData: SyncCrypto.generateKey()))
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload(words: ["x": Fixtures.stats(count: 1)])))
        XCTAssertEqual(outcome, .failed(.cannotDecryptRemote, newLocalModelData: nil))
    }

    func testNewerRemoteSchemaRefusedWithoutDecrypting() async throws {
        let key = SyncCrypto.generateKey()
        keyStore = InMemoryKeyStore(initialKey: key)
        await store.seed(try Fixtures.record(Fixtures.payload(), keyData: key, schemaVersion: PersonalModel.schemaVersion + 1))
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload(words: ["x": Fixtures.stats(count: 1)])))
        XCTAssertEqual(outcome, .failed(.newerRemoteSchema, newLocalModelData: nil))
        let saves = await store.saveCount
        XCTAssertEqual(saves, 0)
    }

    func testUnreadableLocalModelRefusesToSync() async {
        let outcome = await makeEngine().sync(localModelData: Data("garbage".utf8))
        XCTAssertEqual(outcome, .failed(.localModelUnreadable, newLocalModelData: nil))
        let fetches = await store.fetchCount
        XCTAssertEqual(fetches, 0)
    }

    func testNoAccountSurfacesGracefully() async throws {
        await store.failNextFetch(.noAccount)
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .failed(.noAccount, newLocalModelData: nil))
    }

    func testNetworkAndQuotaErrorsSurfaceGracefully() async throws {
        await store.failNextFetch(.networkUnavailable)
        let engine = makeEngine()
        var outcome = await engine.sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .failed(.networkUnavailable, newLocalModelData: nil))

        await store.failNextSave(.quotaExceeded)
        outcome = await engine.sync(localModelData: try Fixtures.modelData(Fixtures.payload(words: ["x": Fixtures.stats(count: 1)])))
        XCTAssertEqual(outcome, .failed(.quotaExceeded, newLocalModelData: nil))
    }

    func testKeychainFailureSurfacesGracefully() async throws {
        keyStore.errorToThrow = SyncKeyStoreError.unexpectedStatus(-25300)
        let outcome = await makeEngine().sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .failed(.keychainFailure, newLocalModelData: nil))
    }

    func testNotActivatedStoreSurfacesGracefully() async throws {
        let engine = SyncEngine(
            store: UnactivatedCloudStore(),
            keyStore: keyStore,
            isEnabled: { true },
            deviceIdentifier: "test-device"
        )
        let outcome = await engine.sync(localModelData: try Fixtures.modelData(Fixtures.payload()))
        XCTAssertEqual(outcome, .failed(.notActivated, newLocalModelData: nil))
        let deleteOutcome = await engine.deleteRemote()
        XCTAssertEqual(deleteOutcome, .failed(.notActivated))
    }

    // MARK: - Two-device convergence (integration-shaped)

    func testTwoDevicesConvergeThroughTheSharedStore() async throws {
        // Shared "iCloud": one store, one keychain (iCloud Keychain roams).
        let engineA = makeEngine()
        let engineB = makeEngine()

        let payloadA = Fixtures.payload(words: ["heima": Fixtures.stats(count: 2, days: [1, 2])])
        let payloadB = Fixtures.payload(
            words: ["vinnan": Fixtures.stats(count: 3, days: [2, 3])],
            userAdded: ["lyklaborð"]
        )

        // A pushes first.
        var outcome = await engineA.sync(localModelData: try Fixtures.modelData(payloadA))
        XCTAssertEqual(outcome, .pushed)

        // B merges A's state with its own and pushes the union.
        outcome = await engineB.sync(localModelData: try Fixtures.modelData(payloadB))
        guard case .merged(let bData) = outcome else {
            return XCTFail("expected merged on device B, got \(outcome)")
        }
        let bPayload = try PersonalModelDocument(decoding: bData).payload

        // A pulls the union; nothing left to push.
        outcome = await engineA.sync(localModelData: try Fixtures.modelData(payloadA))
        guard case .pulled(let aData) = outcome else {
            return XCTFail("expected pulled on device A, got \(outcome)")
        }
        let aPayload = try PersonalModelDocument(decoding: aData).payload
        XCTAssertEqual(aPayload, bPayload, "devices converge to identical state")

        // Both are now up to date — and stay that way (ping-pong safety).
        outcome = await engineA.sync(localModelData: try Fixtures.modelData(aPayload))
        XCTAssertEqual(outcome, .upToDate)
        outcome = await engineB.sync(localModelData: try Fixtures.modelData(bPayload))
        XCTAssertEqual(outcome, .upToDate)
    }
}
