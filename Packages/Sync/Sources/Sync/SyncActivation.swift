import Foundation

/// CloudKit activation constants and the deliberate "not provisioned yet"
/// gate.
///
/// The CloudKit container ("iCloud.is.lyklabord") requires the paid-team
/// provisioning step (App ID + iCloud capability + container creation in
/// the developer portal) which is deferred — see PLAN.md M3/M4. Until then
/// the app wires `SyncEngine` to `UnactivatedCloudStore`, so every code
/// path compiles, unit-tests, and degrades gracefully (`.notActivated`)
/// without ever touching `CKContainer` (instantiating a `CKContainer` for
/// an identifier missing from the entitlements raises an Objective-C
/// exception at runtime).
public enum SyncActivation {

    /// TODO(provisioning): flip to `true` once the paid Apple Developer
    /// team exists and the following steps are done:
    ///   1. Create the iCloud container `iCloud.is.lyklabord` in the
    ///      developer portal.
    ///   2. Add the CloudKit capability + container to the APP target's
    ///      entitlements only (`App/BetterKeyboard.entitlements`) — the
    ///      keyboard extension NEVER gets CloudKit (architecture
    ///      invariant: the extension ships zero network code).
    ///   3. Deploy the `PersonalModelSnapshot` schema (fields below) to
    ///      the production CloudKit environment.
    ///   4. Set `ITSAppUsesNonExemptEncryption` appropriately (v1-blocker
    ///      list: CryptoKit sync is exempt-standard-crypto, but the key
    ///      must be declared).
    public static let isCloudKitProvisioned = false

    /// The CloudKit container identifier this product will use.
    /// TODO(provisioning): this is where the real `CKContainer` gets
    /// activated — `CloudKitRecordStore(containerIdentifier:)` consumes it.
    public static let containerIdentifier = "iCloud.is.lyklabord"

    /// Custom record zone in the user's PRIVATE database. A custom zone
    /// (not the default zone) so we get atomic operations and could adopt
    /// zone-level change tokens later without a migration.
    public static let zoneName = "PersonalModelZone"

    /// Record type of the single snapshot record.
    public static let recordType = "PersonalModelSnapshot"

    /// Fixed record name — there is exactly ONE snapshot record per user;
    /// every device fetches/merges/saves the same record.
    public static let recordName = "current"

    /// CKRecord field names (documented here so the CloudKit schema can be
    /// created by hand in the dashboard during the provisioning step).
    public enum Field {
        /// AES-GCM sealed `SyncPayload` bytes (`Data`), used when the blob
        /// is small enough to inline.
        public static let sealedBlob = "sealedBlob"
        /// Same content as `sealedBlob` but as a `CKAsset`, used when the
        /// blob exceeds the inline-record budget (~1MB per record).
        public static let sealedBlobAsset = "sealedBlobAsset"
        /// `PersonalModel.schemaVersion` of the plaintext — lets a device
        /// refuse a snapshot written by a NEWER app version without
        /// decrypting it.
        public static let schemaVersion = "schemaVersion"
        /// Lowercase hex SHA-256 of the canonical plaintext payload bytes.
        /// Change detection without decryption: if the remote digest equals
        /// the local digest, the states are identical and sync is a no-op.
        public static let modelDigest = "modelDigest"
        /// Opaque per-device identifier of the last writer (diagnostics
        /// only — never used in merge logic; merges are symmetric).
        public static let deviceLastWriter = "deviceLastWriter"
    }
}
