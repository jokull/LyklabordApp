import Foundation
import TypeEngine
import XCTest

@testable import EvalKit

final class ConfigOverridesTests: XCTestCase {

    func testAppliesDoubleOverride() throws {
        var config = EngineConfig()
        XCTAssertEqual(config.autocorrectMargin, 1.25, accuracy: 1e-9)
        let keys = try ConfigOverrides.apply(["autocorrectMargin": 2.5], to: &config)
        XCTAssertEqual(config.autocorrectMargin, 2.5, accuracy: 1e-9)
        XCTAssertEqual(keys, ["autocorrectMargin"])
    }

    func testAppliesIntOverride() throws {
        var config = EngineConfig()
        try ConfigOverrides.apply(["minAutocorrectLength": 4], to: &config)
        XCTAssertEqual(config.minAutocorrectLength, 4)
    }

    func testIntOverrideRoundsFractional() throws {
        var config = EngineConfig()
        try ConfigOverrides.apply(["beamMaxEdits": 2.0], to: &config)
        XCTAssertEqual(config.beamMaxEdits, 2)
    }

    func testAppliesBoolOverride() throws {
        var config = EngineConfig()
        XCTAssertTrue(config.foldProfileISEnabled)
        try ConfigOverrides.apply(["foldProfileISEnabled": false], to: &config)
        XCTAssertFalse(config.foldProfileISEnabled)
    }

    func testAppliesMultipleKeysReturnsSorted() throws {
        var config = EngineConfig()
        let keys = try ConfigOverrides.apply(
            ["morphBackoffWeight": 1.0, "autocorrectMargin": 2.0, "beamMaxEdits": 2],
            to: &config)
        XCTAssertEqual(keys, ["autocorrectMargin", "beamMaxEdits", "morphBackoffWeight"])
        XCTAssertEqual(config.morphBackoffWeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(config.autocorrectMargin, 2.0, accuracy: 1e-9)
        XCTAssertEqual(config.beamMaxEdits, 2)
    }

    func testUnknownKeyThrows() {
        var config = EngineConfig()
        XCTAssertThrowsError(try ConfigOverrides.apply(["notAKnob": 1.0], to: &config)) { error in
            guard case let ConfigOverrideError.unknownKey(key) = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "notAKnob")
        }
    }

    func testBoolForNumericKeyThrowsWrongType() {
        var config = EngineConfig()
        XCTAssertThrowsError(try ConfigOverrides.apply(["autocorrectMargin": true], to: &config)) {
            error in
            guard case let ConfigOverrideError.wrongType(key, _) = error else {
                return XCTFail("expected wrongType, got \(error)")
            }
            XCTAssertEqual(key, "autocorrectMargin")
        }
    }

    func testNumberForBoolKeyThrowsWrongType() {
        var config = EngineConfig()
        XCTAssertThrowsError(try ConfigOverrides.apply(["foldProfileISEnabled": 1.0], to: &config)) {
            error in
            guard case ConfigOverrideError.wrongType = error else {
                return XCTFail("expected wrongType, got \(error)")
            }
        }
    }

    func testSupportedKeysSortedAndNonEmpty() {
        let keys = ConfigOverrides.supportedKeys
        XCTAssertFalse(keys.isEmpty)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(keys.contains("autocorrectMargin"))
        XCTAssertTrue(keys.contains("foldProfileISEnabled"))
        XCTAssertTrue(keys.contains("minAutocorrectLength"))
    }

    func testLoadFromJSONFileRoundTrips() throws {
        let json = #"{"autocorrectMargin": 3.0, "beamMaxEdits": 2, "foldProfileENEnabled": false}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overrides-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let (config, keys) = try ConfigOverrides.load(from: url)
        XCTAssertEqual(config.autocorrectMargin, 3.0, accuracy: 1e-9)
        XCTAssertEqual(config.beamMaxEdits, 2)
        XCTAssertFalse(config.foldProfileENEnabled)
        XCTAssertEqual(keys, ["autocorrectMargin", "beamMaxEdits", "foldProfileENEnabled"])
    }

    func testLoadRejectsNonObjectRoot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overrides-\(UUID().uuidString).json")
        try "[1,2,3]".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ConfigOverrides.load(from: url))
    }
}
