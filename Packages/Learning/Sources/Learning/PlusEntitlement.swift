//
//  PlusEntitlement.swift
//  Learning
//
//  Shared Lyklaborð+ entitlement state — the single seam between the
//  containing app's StoreKit layer and the keyboard extension's personal-
//  layer gating. Lives in Learning because it IS the switch for the
//  personal layer (personal vocabulary + PersonalTouch), both targets
//  already depend on this package, and the pure state logic is unit-
//  testable here with `swift test` (no StoreKit runtime).
//
//  Architecture (docs/WAVES.md standing doctrine): StoreKit runs in the
//  CONTAINING APP only — the extension has zero network entitlements,
//  forever. The app observes `Transaction.currentEntitlements` and writes
//  this plain state into the App Group `UserDefaults` suite; the extension
//  reads it at bootstrap and on every keyboard presentation. This is
//  deliberately honor-system client state in an open-source app (anyone can
//  build from source without it) — plain keys, no signing, no DRM.
//
//  DEBUG note: the `#if DEBUG` always-entitled override lives at the CALL
//  SITES (app + extension), NOT here — `swift test` builds this package in
//  debug configuration, and baking the override in would make the
//  non-entitled paths untestable.
//

import Foundation

public enum PlusEntitlement {

    /// App Group `UserDefaults` key: whether a verified Lyklaborð+
    /// entitlement was current the last time the containing app checked
    /// `Transaction.currentEntitlements`.
    public static let entitledDefaultsKey = "is.solberg.lyklabord.plus.entitled"

    /// App Group `UserDefaults` key: the entitlement's expiration date
    /// (`Transaction.expirationDate`), stored as `timeIntervalSince1970`.
    /// Absent when the app has never written state or the transaction
    /// carried no expiry.
    public static let expiryDefaultsKey = "is.solberg.lyklabord.plus.expiry"

    /// How far past the recorded expiry the extension keeps honoring the
    /// flag. Covers (a) App Store billing-retry/grace periods and (b) the
    /// structural gap that only the containing app can refresh the flag —
    /// a user who renews but never opens the app again would otherwise be
    /// cut off at the recorded expiry. After the lenience the extension
    /// falls back to the free tier until the app runs and re-verifies.
    /// 30 days is a product decision, not a security boundary (honor-box).
    public static let expiryLenience: TimeInterval = 30 * 24 * 60 * 60

    /// The propagated entitlement state. Plain and honest by design.
    public struct State: Equatable {
        public var isEntitled: Bool
        public var expiry: Date?

        public init(isEntitled: Bool, expiry: Date? = nil) {
            self.isEntitled = isEntitled
            self.expiry = expiry
        }

        /// The gate the personal layer actually keys off: the flag, with
        /// expiry lenience applied (see `expiryLenience`). A `nil` expiry
        /// with the flag set is honored indefinitely — the app rewrites the
        /// state on every launch/foreground, so stale-forever state only
        /// happens when the app is never opened again, which the recorded
        /// expiry normally bounds.
        public func isEffectivelyEntitled(now: Date = Date()) -> Bool {
            guard isEntitled else { return false }
            guard let expiry else { return true }
            return now < expiry.addingTimeInterval(PlusEntitlement.expiryLenience)
        }
    }

    /// Persist `state` into `defaults` (the App Group suite). Called by the
    /// containing app only — the extension is read-only on these keys.
    public static func write(_ state: State, to defaults: UserDefaults) {
        defaults.set(state.isEntitled, forKey: entitledDefaultsKey)
        if let expiry = state.expiry {
            defaults.set(expiry.timeIntervalSince1970, forKey: expiryDefaultsKey)
        } else {
            defaults.removeObject(forKey: expiryDefaultsKey)
        }
    }

    /// Read the propagated state. Missing keys read as not entitled — the
    /// safe default for a fresh install (free tier) and for the extension
    /// without App Group access (no Full Access ⇒ no personal layer anyway).
    public static func read(from defaults: UserDefaults) -> State {
        let entitled = defaults.object(forKey: entitledDefaultsKey) as? Bool ?? false
        let expiry = (defaults.object(forKey: expiryDefaultsKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return State(isEntitled: entitled, expiry: expiry)
    }
}
