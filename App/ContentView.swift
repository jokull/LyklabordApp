//
//  ContentView.swift
//  BetterKeyboard
//
//  Minimal M0 screen: explains how to enable the keyboard extension, and
//  gives a text field to try it out in. Real onboarding/settings UI is a
//  later milestone.
//

import SwiftUI

struct ContentView: View {
    @State private var sampleText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Better Keyboard")
                            .font(.largeTitle.bold())
                        Text("A privacy-first Icelandic + English keyboard. Zero network code in the keyboard extension — everything runs on your device.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Set up the keyboard")
                            .font(.title2.bold())

                        stepRow(number: 1, text: "Open Settings → General → Keyboard → Keyboards")
                        stepRow(number: 2, text: "Tap \"Add New Keyboard…\" and choose Better Keyboard")
                        stepRow(number: 3, text: "Tap Better Keyboard again and enable \"Allow Full Access\" (optional — the keyboard works fully without it; Full Access only enables iCloud sync of your personal dictionary in a later version)")

                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Open Settings", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Try it out")
                            .font(.title2.bold())
                        Text("Switch to Better Keyboard with the globe key (🌐) and type here:")
                            .foregroundStyle(.secondary)

                        TextField("Skrifaðu eitthvað…", text: $sampleText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($isTextFieldFocused)
                            .lineLimit(4...8)
                    }
                }
                .padding()
            }
            .navigationTitle("Better Keyboard")
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}
