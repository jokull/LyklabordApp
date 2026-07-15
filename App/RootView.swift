//
//  RootView.swift
//  BetterKeyboard
//
//  M2: three-tab shell — Byrjun (onboarding), Orðasafn (dictionary editor),
//  Stillingar (settings scaffold). Each tab owns its own NavigationStack.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab(Strings.Tab.onboarding, systemImage: "hand.wave") {
                ContentView()
            }
            Tab(Strings.Tab.dictionary, systemImage: "character.book.closed") {
                DictionaryView()
            }
            Tab(Strings.Tab.settings, systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
