import XCTest
import Learning
@testable import Sync

final class SyncCryptoTests: XCTestCase {

    func testGeneratedKeyIs256Bits() {
        XCTAssertEqual(SyncCrypto.generateKey().count, 32)
        XCTAssertNotEqual(SyncCrypto.generateKey(), SyncCrypto.generateKey(), "keys must be random")
    }

    func testSealOpenRoundTrip() throws {
        let key = SyncCrypto.generateKey()
        let plaintext = Data("orðasafn með íslenskum stöfum: ðþæö".utf8)
        let sealed = try SyncCrypto.seal(plaintext, keyData: key)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try SyncCrypto.open(sealed, keyData: key), plaintext)
    }

    func testSealIsNonDeterministicButDigestIsStable() throws {
        let key = SyncCrypto.generateKey()
        let plaintext = Data("sama efni".utf8)
        let sealed1 = try SyncCrypto.seal(plaintext, keyData: key)
        let sealed2 = try SyncCrypto.seal(plaintext, keyData: key)
        XCTAssertNotEqual(sealed1, sealed2, "fresh nonce per seal — change detection must use the plaintext digest")
        XCTAssertEqual(SyncCrypto.digestHex(plaintext), SyncCrypto.digestHex(plaintext))
    }

    func testTamperedBlobThrowsSafeError() throws {
        let key = SyncCrypto.generateKey()
        var sealed = try SyncCrypto.seal(Data("efni".utf8), keyData: key)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try SyncCrypto.open(sealed, keyData: key)) { error in
            XCTAssertEqual(error as? SyncCryptoError, .cannotOpen)
        }
    }

    func testTruncatedAndGarbageBlobsThrowSafeError() {
        let key = SyncCrypto.generateKey()
        XCTAssertThrowsError(try SyncCrypto.open(Data(), keyData: key))
        XCTAssertThrowsError(try SyncCrypto.open(Data([0x01, 0x02, 0x03]), keyData: key))
        XCTAssertThrowsError(try SyncCrypto.open(Data(repeating: 0xAB, count: 64), keyData: key))
    }

    func testWrongKeyThrowsSafeError() throws {
        let sealed = try SyncCrypto.seal(Data("leyndarmál".utf8), keyData: SyncCrypto.generateKey())
        XCTAssertThrowsError(try SyncCrypto.open(sealed, keyData: SyncCrypto.generateKey())) { error in
            XCTAssertEqual(error as? SyncCryptoError, .cannotOpen)
        }
    }

    func testInvalidKeySizeRejected() {
        XCTAssertThrowsError(try SyncCrypto.seal(Data("x".utf8), keyData: Data(repeating: 0, count: 16))) { error in
            XCTAssertEqual(error as? SyncCryptoError, .invalidKeySize(16))
        }
    }

    func testDigestHexKnownVector() {
        // SHA-256("") — standard vector; locks the hex formatting.
        XCTAssertEqual(
            SyncCrypto.digestHex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }
}

/// Locks the Sync package's schema mirror against `PersonalModel`'s actual
/// on-disk format: a model built through the REAL Learning pipeline must
/// decode into a document and re-encode byte-identically.
final class DocumentRoundTripTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDocTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Builds a real PersonalModel with words, bigrams, a tombstone, a
    /// user-added word, touch samples, and a consumed-log marker.
    private func makeRealModelData() throws -> Data {
        var day: Int32 = 20_000
        let logURL = directory.appendingPathComponent("events.log")
        let modelURL = directory.appendingPathComponent("model.json")
        let log = EventLog(url: logURL, dayProvider: { day })
        let model = PersonalModel()

        try log.append(.wordCommitted(word: "jökull", previousWord: nil, languageHint: .icelandic))
        try log.append(.wordCommitted(word: "bráðnar", previousWord: "jökull", languageHint: .icelandic))
        try log.append(.touchSample(keyChar: "a", dx: 0.12, dy: -0.05))
        day = 20_001
        try log.append(.wordCommitted(word: "jökull", previousWord: nil, languageHint: .icelandic))
        try log.append(.wordTapped(word: "the"))
        try model.compactAndSave(applying: log, to: modelURL)

        try model.addUserWord("lyklaborð")
        model.remove(word: "the")
        try model.save(to: modelURL)
        return try Data(contentsOf: modelURL)
    }

    func testDecodeThenEncodeIsByteIdentical() throws {
        let original = try makeRealModelData()
        let document = try PersonalModelDocument(decoding: original)
        XCTAssertEqual(try document.encoded(), original, "schema mirror drifted from PersonalModel.save format")
    }

    func testDecodedDocumentReflectsModelState() throws {
        let data = try makeRealModelData()
        let document = try PersonalModelDocument(decoding: data)
        XCTAssertEqual(document.payload.schemaVersion, PersonalModel.schemaVersion)
        XCTAssertEqual(document.payload.words["jökull"]?.count, 2)
        XCTAssertEqual(document.payload.words["jökull"]?.daysSeen, [20_000, 20_001])
        XCTAssertEqual(document.payload.bigrams["jökull bráðnar"], 1)
        XCTAssertEqual(document.payload.tombstones, ["the"])
        XCTAssertEqual(document.payload.userAdded, ["lyklaborð"])
        XCTAssertEqual(document.payload.touch["a"]?.count, 1)
        XCTAssertNotNil(document.consumedLogMarker, "compaction stored a marker")
    }

    func testCanonicalDigestIgnoresConsumedLogMarker() throws {
        let payload = Fixtures.payload(words: ["orð": Fixtures.stats(count: 1)])
        let markerA = EventLog.ConsumedMarker(generation: UUID(), offset: 42)
        let withMarker = try PersonalModelDocument(decoding: Fixtures.modelData(payload, marker: markerA))
        let withoutMarker = try PersonalModelDocument(decoding: Fixtures.modelData(payload))
        XCTAssertEqual(
            try withMarker.payload.digestHex(),
            try withoutMarker.payload.digestHex(),
            "device-local marker churn must not change the sync digest"
        )
    }

    func testCanonicalDataIsDeterministic() throws {
        var rng = SeededRNG(seed: 0xD16E_57)
        for _ in 0..<50 {
            let payload = PayloadGen.payload(&rng)
            XCTAssertEqual(try payload.canonicalData(), try payload.canonicalData())
            // decode → re-encode is stable too
            let decoded = try SyncPayload.decode(try payload.canonicalData())
            XCTAssertEqual(decoded, payload)
            XCTAssertEqual(try decoded.canonicalData(), try payload.canonicalData())
        }
    }

    func testUndecodableAndWrongSchemaRejected() {
        XCTAssertThrowsError(try PersonalModelDocument(decoding: Data("not json".utf8)))
        let futureSchema = Data(#"{"schemaVersion":99,"words":{},"bigrams":{},"tombstones":[],"userAdded":[],"touch":{}}"#.utf8)
        XCTAssertThrowsError(try PersonalModelDocument(decoding: futureSchema))
        XCTAssertThrowsError(try SyncPayload.decode(futureSchema))
    }
}
