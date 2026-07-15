import Foundation
import Learning

public enum ModelDocumentError: Error, Equatable {
    /// The bytes are not a decodable PersonalModel file, or declare a schema
    /// version this Sync build does not understand.
    case undecodable(String)
}

/// The sync-relevant subset of a serialized `PersonalModel`: everything
/// EXCEPT `consumedLogMarker`.
///
/// `consumedLogMarker` is the compactor's read frontier into THIS DEVICE's
/// event log — strictly device-local state. Syncing it would corrupt the
/// other device's log consumption (generation UUIDs never match across
/// devices) and, worse, every compaction rotates it, which would make the
/// remote digest churn even when no learning content changed. So the
/// payload — the thing that is encrypted, digested, and merged — excludes
/// it, and `PersonalModelDocument` re-attaches the LOCAL marker when a
/// pulled/merged payload is written back to disk.
///
/// Field names and value types mirror `PersonalModel`'s private `Stored`
/// struct exactly (schema version 1); the value types themselves
/// (`PersonalModel.WordStats`, `TouchKeyStats`, `EventLog.ConsumedMarker`)
/// are reused from Learning so the JSON stays byte-compatible.
/// `DocumentRoundTripTests` locks this mirror against drift by asserting a
/// byte-identical re-encode of a real `PersonalModel.save` file.
public struct SyncPayload: Equatable, Sendable {
    public var schemaVersion: Int
    public var words: [String: PersonalModel.WordStats]
    public var bigrams: [String: UInt32]
    public var tombstones: Set<String>
    public var userAdded: Set<String>
    public var touch: [String: TouchKeyStats]

    public init(
        schemaVersion: Int = PersonalModel.schemaVersion,
        words: [String: PersonalModel.WordStats] = [:],
        bigrams: [String: UInt32] = [:],
        tombstones: Set<String> = [],
        userAdded: Set<String> = [],
        touch: [String: TouchKeyStats] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.words = words
        self.bigrams = bigrams
        self.tombstones = tombstones
        self.userAdded = userAdded
        self.touch = touch
    }

    /// Canonical plaintext bytes: JSON with sorted keys and sorted set
    /// arrays — deterministic for a given state (same contract as
    /// `PersonalModel.save`), so `digestHex()` is a stable cross-device
    /// fingerprint. These are also exactly the bytes that get AES-GCM
    /// sealed into the CloudKit record.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// SHA-256 (lowercase hex) of `canonicalData()` — the record's
    /// `modelDigest` field.
    public func digestHex() throws -> String {
        SyncCrypto.digestHex(try canonicalData())
    }

    public static func decode(_ plaintext: Data) throws -> SyncPayload {
        do {
            let payload = try JSONDecoder().decode(SyncPayload.self, from: plaintext)
            guard payload.schemaVersion == PersonalModel.schemaVersion else {
                throw ModelDocumentError.undecodable("unsupported payload schema \(payload.schemaVersion)")
            }
            return payload
        } catch let error as ModelDocumentError {
            throw error
        } catch {
            throw ModelDocumentError.undecodable("payload decode failed: \(error)")
        }
    }
}

extension SyncPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, words, bigrams, tombstones, userAdded, touch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        words = try container.decode([String: PersonalModel.WordStats].self, forKey: .words)
        bigrams = try container.decode([String: UInt32].self, forKey: .bigrams)
        tombstones = Set(try container.decode([String].self, forKey: .tombstones))
        userAdded = Set(try container.decode([String].self, forKey: .userAdded))
        touch = try container.decode([String: TouchKeyStats].self, forKey: .touch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(words, forKey: .words)
        try container.encode(bigrams, forKey: .bigrams)
        // Sets encode as sorted arrays — part of the determinism contract.
        try container.encode(tombstones.sorted(), forKey: .tombstones)
        try container.encode(userAdded.sorted(), forKey: .userAdded)
        try container.encode(touch, forKey: .touch)
    }
}

/// A full serialized `PersonalModel` file = sync payload + the device-local
/// `consumedLogMarker`. This is what `SyncEngine` reads from and hands back
/// to the app: `encoded()` produces bytes that `PersonalModel(contentsOf:)`
/// loads directly (byte-identical to what `PersonalModel.save` would write
/// for the same state).
public struct PersonalModelDocument: Equatable {
    public var payload: SyncPayload
    public var consumedLogMarker: EventLog.ConsumedMarker?

    public init(payload: SyncPayload, consumedLogMarker: EventLog.ConsumedMarker?) {
        self.payload = payload
        self.consumedLogMarker = consumedLogMarker
    }

    /// Mirror of `PersonalModel`'s private `Stored` struct.
    private struct Stored: Codable {
        var schemaVersion: Int
        var words: [String: PersonalModel.WordStats]
        var bigrams: [String: UInt32]
        var tombstones: [String]
        var userAdded: [String]
        var touch: [String: TouchKeyStats]
        var consumedLogMarker: EventLog.ConsumedMarker?
    }

    public init(decoding data: Data) throws {
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw ModelDocumentError.undecodable("model file decode failed: \(error)")
        }
        guard stored.schemaVersion == PersonalModel.schemaVersion else {
            throw ModelDocumentError.undecodable("unsupported model schema \(stored.schemaVersion)")
        }
        payload = SyncPayload(
            schemaVersion: stored.schemaVersion,
            words: stored.words,
            bigrams: stored.bigrams,
            tombstones: Set(stored.tombstones),
            userAdded: Set(stored.userAdded),
            touch: stored.touch
        )
        consumedLogMarker = stored.consumedLogMarker
    }

    public func encoded() throws -> Data {
        let stored = Stored(
            schemaVersion: payload.schemaVersion,
            words: payload.words,
            bigrams: payload.bigrams,
            tombstones: payload.tombstones.sorted(),
            userAdded: payload.userAdded.sorted(),
            touch: payload.touch,
            consumedLogMarker: consumedLogMarker
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }
}
