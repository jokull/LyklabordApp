//
//  BetterKeyboardApp.swift
//  BetterKeyboard
//
//  M2: containing app shell. Owns the single `AppModel` instance (personal
//  learning store, App Group-backed) and the `SubscriptionManager`
//  (Lyklaborð+ StoreKit 2 layer — app-only, the extension never talks to
//  StoreKit), both injected into the view tree via `.environment`.
//

import SwiftUI

@main
struct BetterKeyboardApp: App {
    @State private var appModel = AppModel()
    @State private var subscriptions = SubscriptionManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(subscriptions)
                .task {
                    // `.onChange(of:)` below only fires on a *transition*,
                    // not the initial value, so cold launch needs its own
                    // explicit compaction — `AppModel.init` loads the model
                    // but does not compact.
                    appModel.compact()
                    // Settle the Lyklaborð+ entitlement (verified
                    // Transaction.currentEntitlements scan) and mirror it
                    // into the App Group for the keyboard extension.
                    await subscriptions.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-run compaction whenever the app comes back to the
                    // foreground, so the dictionary editor reflects any
                    // typing done since the app was last active (see
                    // `AppModel.compact()`). Re-check the subscription too —
                    // renewals/cancellations/refunds land while we're
                    // backgrounded, and the extension only sees what the
                    // app writes into the App Group.
                    if newPhase == .active {
                        appModel.compact()
                        Task { await subscriptions.refreshEntitlement() }
                    }
                }
        }
    }
}
