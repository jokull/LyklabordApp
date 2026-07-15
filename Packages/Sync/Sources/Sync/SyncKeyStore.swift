import Foundation
import Security

/// Where the sync envelope key lives. Abstracted behind a protocol because
/// the real Keychain is unavailable in SPM unit tests — tests use
/// `InMemoryKeyStore`, the app uses `ICloudKeychainStore`.
///
/// Contract: `saveKeyData` is **add-if-absent** — it must never overwrite an
/// existing key (two devices bootstrapping simultaneously must converge on
/// one key, first writer wins). Callers that just saved MUST re-`loadKeyData`
/// and use whatever comes back (see `SyncEngine`).
public protocol SyncKeyStore {
    /// The stored key bytes, or nil if no key exists yet.
    func loadKeyData() throws -> Data?
    /// Store `data` if and only if no key exists yet (add-if-absent).
    func saveKeyData(_ data: Data) throws
    /// Remove the key. Missing key is not an error.
    func deleteKeyData() throws
}

public enum SyncKeyStoreError: Error, Equatable {
    case unexpectedStatus(Int32)
}

/// Keychain constants, documented for auditability:
///
/// - `kSecClass` = `kSecClassGenericPassword`
/// - `kSecAttrService` = `"is.lyklabord.sync"`
/// - `kSecAttrAccount` = `"personal-model-key.v1"` (`.v1` so a future
///   envelope-format change can mint a new item without deleting this one)
/// - `kSecAttrSynchronizable` = `true` — the item lives in the **iCloud
///   Keychain** and roams to all of the user's devices transparently; this
///   is the entire "no passphrase UX" story from PLAN decision #5.
/// - `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlock` — sync can
///   run in the background after a reboot+unlock; deliberately NOT the
///   `...ThisDeviceOnly` variant, which would silently break iCloud
///   Keychain synchronization.
public enum SyncKeychainConstants {
    public static let service = "is.lyklabord.sync"
    public static let account = "personal-model-key.v1"
}

/// Real iCloud-Keychain-backed store. The key never leaves the Keychain
/// item other than as in-memory bytes handed to CryptoKit; it is never
/// written to disk, never logged, and never included in any snapshot.
public final class ICloudKeychainStore: SyncKeyStore {

    public init() {}

    /// `kSecAttrSynchronizableAny` on queries so we find the item whether
    /// or not iCloud Keychain is currently enabled on this device.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SyncKeychainConstants.service,
            kSecAttrAccount as String: SyncKeychainConstants.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    public func loadKeyData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SyncKeyStoreError.unexpectedStatus(status)
        }
    }

    public func saveKeyData(_ data: Data) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SyncKeychainConstants.service,
            kSecAttrAccount as String: SyncKeychainConstants.account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        attributes[kSecAttrLabel as String] = "Lyklaborð sync key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Add-if-absent contract: a key already exists (possibly just
            // synced in from another device racing our bootstrap). Keep it —
            // the caller re-loads and uses the winner.
            return
        default:
            throw SyncKeyStoreError.unexpectedStatus(status)
        }
    }

    public func deleteKeyData() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncKeyStoreError.unexpectedStatus(status)
        }
    }
}

/// Test/preview fake. Mirrors the add-if-absent contract exactly.
public final class InMemoryKeyStore: SyncKeyStore {
    public private(set) var stored: Data?
    /// When set, every call throws it (keychain-outage simulation).
    public var errorToThrow: Error?

    public init(initialKey: Data? = nil) {
        stored = initialKey
    }

    public func loadKeyData() throws -> Data? {
        if let errorToThrow { throw errorToThrow }
        return stored
    }

    public func saveKeyData(_ data: Data) throws {
        if let errorToThrow { throw errorToThrow }
        if stored == nil { stored = data }
    }

    public func deleteKeyData() throws {
        if let errorToThrow { throw errorToThrow }
        stored = nil
    }
}
