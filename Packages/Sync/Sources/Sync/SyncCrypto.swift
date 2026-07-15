import CryptoKit
import Foundation

public enum SyncCryptoError: Error, Equatable, CustomStringConvertible {
    /// Key material is not exactly 256 bits.
    case invalidKeySize(Int)
    /// The sealed blob failed to open: truncated envelope, tampered
    /// ciphertext/tag, or a different key. Deliberately one opaque case —
    /// callers must treat all of these identically (safe error, never
    /// clobber local state).
    case cannotOpen

    public var description: String {
        switch self {
        case .invalidKeySize(let bytes): return "Sync key must be 32 bytes, got \(bytes)"
        case .cannotOpen: return "Sealed sync blob cannot be opened (corrupt or wrong key)"
        }
    }
}

/// The crypto envelope for the CloudKit snapshot: AES-256-GCM via CryptoKit.
///
/// ## Design
///
/// - **One symmetric key per user**, generated on the first-ever sync (only
///   when no remote snapshot exists yet — see `SyncEngine`), stored in the
///   iCloud Keychain (`ICloudKeychainStore`) so every device of the same
///   Apple ID receives it transparently. The key never leaves the Keychain
///   item and is never logged; this file only ever holds it in memory as
///   `SymmetricKey`.
/// - **Sealed blob format** is CryptoKit's *combined* representation:
///   `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`. A fresh random nonce
///   is generated per seal, so sealing the same plaintext twice yields
///   different blobs — which is why change detection uses `digestHex` of
///   the PLAINTEXT, not of the sealed blob.
/// - **Plaintext** is the canonical (sorted-keys) JSON of `SyncPayload`,
///   which is deterministic byte-for-byte for a given model state (the
///   `PersonalModel.save` contract), so the SHA-256 digest is a stable
///   state fingerprint across devices.
public enum SyncCrypto {

    public static let keySizeBytes = 32

    /// Fresh 256-bit key as raw bytes (what `SyncKeyStore` persists).
    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// AES-GCM seal; returns the combined `nonce ‖ ciphertext ‖ tag` blob.
    public static func seal(_ plaintext: Data, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                // Only nil for non-standard nonce sizes; ours is the 12-byte
                // default, so this is unreachable — mapped to an error
                // rather than a crash on principle.
                throw SyncCryptoError.cannotOpen
            }
            return combined
        } catch let error as SyncCryptoError {
            throw error
        } catch {
            throw SyncCryptoError.cannotOpen
        }
    }

    /// Opens a combined AES-GCM blob. Any failure (truncation, tamper,
    /// wrong key) throws `SyncCryptoError.cannotOpen` — never crashes.
    public static func open(_ sealed: Data, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SyncCryptoError.cannotOpen
        }
    }

    /// Lowercase hex SHA-256 — the `modelDigest` record field.
    public static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == keySizeBytes else {
            throw SyncCryptoError.invalidKeySize(data.count)
        }
        return SymmetricKey(data: data)
    }
}
