//
//  Keyboard+RootView.swift
//  KeyboardKit
//
//  Created by Daniel Saidi on 2022-02-04.
//  Copyright © 2022-2025 Daniel Saidi. All rights reserved.
//

import SwiftUI

extension Keyboard {
    
    /// This view is used as a wrapper view, to make sure it
    /// binds to state that affects your layout.
    struct RootView<ViewType: View>: View {
        
        init(@ViewBuilder _ view: @escaping () -> ViewType) {
            self.view = view
        }
        
        var view: () -> ViewType
    
        // Lyklaborð fork: upstream also declares the autocomplete context
        // here without using it. Observing it re-ran `view()` on every
        // suggestion update, handing SwiftUI a brand-new `KeyboardView`
        // (new closures, so nothing can be skipped) once per keystroke.
        @EnvironmentObject var externalContext: ExternalKeyboardContext
        @EnvironmentObject var keyboardContext: KeyboardContext
        @EnvironmentObject var themeContext: KeyboardThemeContext

        var body: some View {
            view()
                .keyboardDockEdge(keyboardContext.settings.keyboardDockEdge)
                .onChange(of: externalContext.isExternalKeyboardConnected) { newValue in
                    guard keyboardContext.settings.isKeyboardAutoCollapseEnabled else { return }
                    keyboardContext.isKeyboardCollapsed = newValue
                }
        }
    }
}
