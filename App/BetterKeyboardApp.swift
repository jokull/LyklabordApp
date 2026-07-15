//
//  BetterKeyboardApp.swift
//  BetterKeyboard
//
//  M2: containing app shell. Owns the single `AppModel` instance (personal
//  learning store, App Group-backed), injected into the view tree via
//  `.environment`. CloudKit sync lands in M3 (see PLAN.md).
//

import SwiftUI

@main
struct BetterKeyboardApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .task {
                    // `.onChange(of:)` below only fires on a *transition*,
                    // not the initial value, so cold launch needs its own
                    // explicit compaction — `AppModel.init` loads the model
                    // but does not compact.
                    appModel.compact()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Re-run compaction whenever the app comes back to the
                    // foreground, so the dictionary editor reflects any
                    // typing done since the app was last active (see
                    // `AppModel.compact()`).
                    if newPhase == .active {
                        appModel.compact()
                    }
                }
        }
    }
}
