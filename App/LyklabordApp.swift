//
//  LyklabordApp.swift
//  Lyklabord
//
//  M2: containing app shell. Owns the single `AppModel` instance (personal
//  learning store, App Group-backed) and the `SubscriptionManager`
//  (Lyklaborð+ StoreKit 2 layer — app-only, the extension never talks to
//  StoreKit), both injected into the view tree via `.environment`.
//

import SwiftUI

@main
struct LyklabordApp: App {
    @State private var appModel = AppModel()
    @State private var subscriptions = SubscriptionManager()
    @Environment(\.scenePhase) private var scenePhase

    /// Release-only measurement host selected by `devicectl` through a
    /// process environment variable. Normal app launches never take this
    /// branch and remain byte-for-byte behaviorally unchanged.
    private var isColdStartProbe: Bool {
        ProcessInfo.processInfo.environment["LYKLABORD_COLD_START_PROBE"] == "1"
    }

    /// Present the Lyklaborð+ paywall directly on launch, for capturing the
    /// App Store IAP review screenshot in the simulator. Tooling-only; a
    /// normal launch never takes this branch.
    private var isPaywallCapture: Bool {
        ProcessInfo.processInfo.environment["LYKLABORD_SHOW_PAYWALL"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            if isColdStartProbe {
                ColdStartProbeView()
            } else if isPaywallCapture {
                SubscriptionView()
                    .environment(subscriptions)
                    .task { await subscriptions.start() }
            } else {
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
}

/// Deterministic physical-device host for Wave 39. Focus activates whichever
/// keyboard is already selected; rapid host mutations create request pressure
/// without an independently provisioned UI-test runner. No text is logged by
/// the cold-start journal.
private struct ColdStartProbeView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Cold-start probe", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(false)
            .focused($focused)
            .padding()
            .onAppear {
                focused = true
                Task { @MainActor in
                    for value in ["h", "he", "hes", "hest"] {
                        try? await Task.sleep(for: .milliseconds(20))
                        text = value
                    }
                }
            }
    }
}
