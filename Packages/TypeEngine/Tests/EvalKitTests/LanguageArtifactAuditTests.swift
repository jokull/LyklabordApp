import Foundation
import XCTest

@testable import EvalKit

final class LanguageArtifactAuditTests: XCTestCase {
    func testCurrentRepositoryManifestsAndHashesPass() throws {
        guard let root = ArtifactLoader.repoRoot() else {
            throw XCTSkip("repo root unavailable")
        }
        let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-18T16:00:00Z"))
        let result = LanguageArtifactAudit.run(repoRoot: root, referenceDate: reference)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.verifiedFileCount, 15)
        XCTAssertEqual(result.sourceAgeDays["is"], 8)
        XCTAssertEqual(result.sourceAgeDays["en"], 3)
    }

    func testHashMismatchFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for language in ["is", "en"] {
            let directory = root.appendingPathComponent("data/\(language)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(language).lex")
            try Data("actual".utf8).write(to: file)
            let manifest: [String: Any] = [
                "schema": LanguageArtifactAudit.schema,
                "language": language,
                "languageDataGeneration": "generation-good",
                "generationFingerprint": "good",
                "sourceReferenceDate": "2026-07-10",
                "builtAt": "2026-07-11",
                "freshnessPolicy": [
                    "maxSourceAgeAtBuildDays": 30,
                    "maxGenerationAgeAtCommitDays": 180,
                ],
                "requiredShippingArtifacts": ["\(language).lex"],
                "artifacts": [
                    "\(language).lex": [
                        "bytes": 6,
                        "sha256": String(repeating: "0", count: 64),
                    ]
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try data.write(to: directory.appendingPathComponent("LANGUAGE_DATA_MANIFEST.json"))
        }
        let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-18T16:00:00Z"))
        let result = LanguageArtifactAudit.run(repoRoot: root, referenceDate: reference)
        XCTAssertEqual(result.failures.filter { $0.contains("sha256 mismatch") }.count, 2)
        XCTAssertFalse(result.passed)
    }
}
