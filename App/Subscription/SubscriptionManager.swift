//
//  SubscriptionManager.swift
//  BetterKeyboard
//
//  StoreKit 2 wrapper for the Lyklaborð+ subscription — the app-side half
//  of the entitlement flow. Architecture (docs/WAVES.md standing doctrine):
//  StoreKit runs in the CONTAINING APP only; the keyboard extension ships
//  zero network code, forever. This manager observes
//  `Transaction.currentEntitlements` (on-device StoreKit 2 verification —
//  no accounts, no receipt server, no server of ours) and mirrors the
//  result into the App Group via `Learning.PlusEntitlement`, where the
//  extension reads it at bootstrap and on every keyboard presentation.
//
//  Honor-box reality: Lyklaborð is open source — anyone can build from
//  source without the paywall. The gating is deliberately plain and
//  unobfuscated (a UserDefaults flag, no DRM); the subscription is how
//  App Store users support the project and unlock the personal layer.
//
//  DEBUG builds are always entitled (`isEntitled` override below) so
//  dogfooding never fights the paywall. The purchase UI stays reachable in
//  DEBUG for manual/sandbox testing; `status` always reflects the real
//  StoreKit state.
//

import Foundation
import Learning
import Observation
import StoreKit

@MainActor
@Observable
final class SubscriptionManager {

    // MARK: - Product constants

    /// App Store Connect product id for the annual subscription. Must match
    /// the ASC product AND `App/Subscription/Lyklabord.storekit` (the local
    /// testing configuration) — see docs/SUBSCRIPTION.md for the full ASC
    /// setup checklist.
    static let productID = "is.solberg.lyklabord.plus.annual"

    /// ASC subscription group reference name.
    static let subscriptionGroupName = "Lyklaborð+"

    /// Manage/cancel deep link into the App Store subscription management
    /// screen (required App Review affordance next to any subscription UI).
    static let manageSubscriptionsURL = URL(
        string: "itms-apps://apps.apple.com/account/subscriptions")!

    /// Apple's standard EULA — the Terms of Use for the subscription (we
    /// use the standard agreement, no custom EULA; ASC metadata note in
    /// docs/SUBSCRIPTION.md).
    static let standardEULAURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    // MARK: - State

    enum EntitlementStatus: Equatable {
        /// Not determined yet (cold launch, before the first
        /// `currentEntitlements` scan completes).
        case unknown
        case notEntitled
        /// Verified current entitlement; `expiry` is
        /// `Transaction.expirationDate` (the renewal date while the
        /// subscription auto-renews).
        case entitled(expiry: Date?)
    }

    /// Real StoreKit entitlement state (no DEBUG override) — what the
    /// settings status row shows.
    private(set) var status: EntitlementStatus = .unknown

    /// The loaded App Store product; nil until `loadProductIfNeeded()`
    /// succeeds (price is ALWAYS displayed from `product.displayPrice`,
    /// never hardcoded — it's locale/storefront dependent).
    private(set) var product: Product?

    private(set) var isPurchasing = false

    /// Transient user-facing error from the last purchase/restore attempt.
    var lastActionError: String?

    /// A purchase came back `.pending` (Ask to Buy / SCA) — surfaced so the
    /// paywall can explain the wait instead of looking broken.
    private(set) var hasPendingPurchase = false

    /// Lifetime listener for `Transaction.updates`. The manager is created
    /// once by `BetterKeyboardApp` and lives for the process — no deinit
    /// cancellation needed (and `@Observable`'s synthesized accessors make
    /// stored-property access from a nonisolated deinit ill-formed anyway).
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    /// The gate every Plus feature in the APP keys off. DEBUG builds are
    /// always entitled (dogfood/TestFlight-internal never fights the
    /// paywall). The extension applies the same DEBUG override on its side.
    var isEntitled: Bool {
        #if DEBUG
        return true
        #else
        if case .entitled = status { return true }
        return false
        #endif
    }

    // MARK: - Lifecycle

    init() {
        // Transaction.updates delivers purchases/renewals/revocations made
        // outside the in-app flow (renewal, refund, Ask to Buy approval,
        // purchase on another device). Listen for the app's lifetime.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self?.refreshEntitlement()
            }
        }
    }

    /// Launch-time bootstrap: load the product and settle the entitlement
    /// status. Called from the app root's `.task`; safe to call repeatedly.
    func start() async {
        await refreshEntitlement()
        await loadProductIfNeeded()
    }

    // MARK: - Product loading

    func loadProductIfNeeded() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    // MARK: - Purchase / restore

    func purchase() async {
        lastActionError = nil
        await loadProductIfNeeded()
        guard let product else {
            lastActionError = Strings.Plus.priceUnavailable
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                // On-device StoreKit 2 verification: only act on `.verified`
                // (an `.unverified` payload is ignored — refresh below will
                // simply find no entitlement).
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await refreshEntitlement()
            case .pending:
                hasPendingPurchase = true
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastActionError = Strings.Plus.purchaseFailed
        }
    }

    /// "Restore purchases" — REQUIRED by App Review wherever purchases are
    /// offered. `AppStore.sync()` forces a re-sync with the App Store
    /// (prompts for authentication), then the entitlement scan settles it.
    func restorePurchases() async {
        lastActionError = nil
        do {
            try await AppStore.sync()
        } catch {
            // User cancelled the auth prompt or network failed — the
            // refresh below still reports whatever local state exists.
            lastActionError = Strings.Plus.restoreFailed
        }
        await refreshEntitlement()
        if case .notEntitled = status, lastActionError == nil {
            lastActionError = Strings.Plus.restoreNothingFound
        }
    }

    // MARK: - Entitlement observation + App Group propagation

    /// Scan `Transaction.currentEntitlements` (verified, on-device) and
    /// mirror the result into the App Group for the keyboard extension.
    /// Called at launch, on every foreground activation, after purchases/
    /// restores, and from the `Transaction.updates` listener.
    func refreshEntitlement() async {
        var entitled = false
        var expiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                transaction.productID == Self.productID,
                transaction.revocationDate == nil
            else { continue }
            entitled = true
            expiry = transaction.expirationDate
        }
        status = entitled ? .entitled(expiry: expiry) : .notEntitled
        publishToAppGroup(entitled: entitled, expiry: expiry)
    }

    private func publishToAppGroup(entitled: Bool, expiry: Date?) {
        guard let defaults = UserDefaults(suiteName: AppModel.appGroupIdentifier) else { return }
        PlusEntitlement.write(.init(isEntitled: entitled, expiry: expiry), to: defaults)
    }
}

// MARK: - Non-isolated gate (for closures off the main actor)

/// Cheap, non-isolated read of the propagated entitlement — for call sites
/// that can't touch the `@MainActor` manager (e.g. `SyncEngine`'s
/// `isEnabled` closure). Reads the same App Group state the manager writes;
/// same DEBUG override as everywhere else.
enum PlusGate {
    static func isEntitled(now: Date = Date()) -> Bool {
        #if DEBUG
        return true
        #else
        guard let defaults = UserDefaults(suiteName: AppModel.appGroupIdentifier) else {
            return false
        }
        return PlusEntitlement.read(from: defaults).isEffectivelyEntitled(now: now)
        #endif
    }
}
