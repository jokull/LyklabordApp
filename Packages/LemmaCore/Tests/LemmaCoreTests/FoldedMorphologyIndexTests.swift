import Foundation
import XCTest

@testable import LemmaCore

final class FoldedMorphologyIndexTests: XCTestCase {
    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func fixture(
        sourceWordFormCount: UInt32 = 10,
        sourceArtifactFingerprint: UInt64 = 0x1122_3344_5566_7788,
        magic: UInt32 = 0x4642_4931,
        version: UInt32 = 1
    ) -> Data {
        let entries: [(String, [UInt32])] = [
            ("afmaeli", [1, 4]),
            ("for", [2]),
            ("hus", [3]),
        ]
        var keyPool = Data()
        var keyOffsets: [UInt32] = []
        var keyLengths: [UInt8] = []
        var valueOffsets: [UInt32] = [0]
        var wordIDs: [UInt32] = []
        for (key, ids) in entries {
            let bytes = Data(key.utf8)
            keyOffsets.append(UInt32(keyPool.count))
            keyLengths.append(UInt8(bytes.count))
            keyPool.append(bytes)
            wordIDs.append(contentsOf: ids)
            valueOffsets.append(UInt32(wordIDs.count))
        }
        while !keyPool.count.isMultiple(of: 4) { keyPool.append(0) }

        var data = Data()
        for value in [
            magic, version, UInt32(entries.count), UInt32(wordIDs.count),
            UInt32(keyPool.count), sourceWordFormCount,
            UInt32(truncatingIfNeeded: sourceArtifactFingerprint),
            UInt32(truncatingIfNeeded: sourceArtifactFingerprint >> 32),
        ] {
            append(value, to: &data)
        }
        data.append(keyPool)
        for value in keyOffsets { append(value, to: &data) }
        data.append(contentsOf: keyLengths)
        while !data.count.isMultiple(of: 4) { data.append(0) }
        for value in valueOffsets { append(value, to: &data) }
        for value in wordIDs { append(value, to: &data) }
        return data
    }

    func testExactLookupMissAndCollisionRange() throws {
        let index = try FoldedMorphologyIndex(data: fixture())

        XCTAssertEqual(index.version, 1)
        XCTAssertEqual(index.keyCount, 3)
        XCTAssertEqual(index.referenceCount, 4)
        XCTAssertEqual(index.sourceWordFormCount, 10)
        XCTAssertEqual(index.sourceArtifactFingerprint, 0x1122_3344_5566_7788)
        XCTAssertEqual(index.wordFormIDs(matching: "afmaeli"), [1, 4])
        XCTAssertEqual(index.wordFormIDs(matching: "FOR"), [2])
        XCTAssertEqual(index.wordFormIDs(matching: "hus"), [3])
        XCTAssertEqual(index.wordFormIDs(matching: "missing"), [])
        XCTAssertEqual(index.wordFormIDs(matching: ""), [])
    }

    func testRejectsWrongMagicVersionAndTruncation() {
        XCTAssertThrowsError(try FoldedMorphologyIndex(data: fixture(magic: 0)))
        XCTAssertThrowsError(try FoldedMorphologyIndex(data: fixture(version: 2)))
        XCTAssertThrowsError(try FoldedMorphologyIndex(data: Data(repeating: 0, count: 12)))

        let complete = fixture()
        XCTAssertThrowsError(
            try FoldedMorphologyIndex(data: complete.prefix(complete.count - 1)))
    }

    func testBinaryLemmatizerRejectsMismatchedSidecarCohort() throws {
        let morphologyURL = try XCTUnwrap(
            Bundle.module.url(forResource: "bin-morph.core.bin", withExtension: nil))
        let lemmatizer = try BinaryLemmatizer(contentsOf: morphologyURL)
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("folded.bin")
        try fixture(sourceWordFormCount: 1).write(to: sidecarURL)
        defer { try? FileManager.default.removeItem(at: sidecarURL) }

        XCTAssertThrowsError(try lemmatizer.loadFoldedIndex(contentsOf: sidecarURL)) { error in
            guard case FoldedMorphologyIndexError.sourceWordFormCount(
                expected: lemmatizer.wordFormCount, actual: 1) = error
            else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(lemmatizer.hasFoldedIndex)
    }

    func testBinaryLemmatizerRejectsSameCountFromDifferentArtifact() throws {
        let morphologyURL = try XCTUnwrap(
            Bundle.module.url(forResource: "bin-morph.core.bin", withExtension: nil))
        let lemmatizer = try BinaryLemmatizer(contentsOf: morphologyURL)
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("folded.bin")
        try fixture(
            sourceWordFormCount: UInt32(lemmatizer.wordFormCount),
            sourceArtifactFingerprint: lemmatizer.artifactFingerprint ^ 1
        ).write(to: sidecarURL)
        defer { try? FileManager.default.removeItem(at: sidecarURL) }

        XCTAssertThrowsError(try lemmatizer.loadFoldedIndex(contentsOf: sidecarURL)) { error in
            guard case FoldedMorphologyIndexError.sourceArtifactFingerprint(
                expected: lemmatizer.artifactFingerprint, actual: _) = error
            else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(lemmatizer.hasFoldedIndex)
    }
}
