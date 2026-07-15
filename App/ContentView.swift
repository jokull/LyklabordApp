//
//  ContentView.swift
//  BetterKeyboard
//
//  "Byrjun" tab: explains how to enable the keyboard extension, and gives a
//  text field to try it out in. Lives inside `RootView`'s TabView.
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
                        Text(Strings.Onboarding.title)
                            .font(.largeTitle.bold())
                        Text(Strings.Onboarding.subtitle)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(Strings.Onboarding.setupHeading)
                            .font(.title2.bold())

                        stepRow(number: 1, text: Strings.Onboarding.step1)
                        stepRow(number: 2, text: Strings.Onboarding.step2)
                        stepRow(number: 3, text: Strings.Onboarding.step3)

                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label(Strings.Onboarding.openSettingsButton, systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(Strings.Onboarding.tryHeading)
                            .font(.title2.bold())
                        Text(Strings.Onboarding.tryBody)
                            .foregroundStyle(.secondary)

                        TextField(Strings.Onboarding.tryPlaceholder, text: $sampleText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($isTextFieldFocused)
                            .lineLimit(4...8)
                    }
                }
                .padding()
            }
            .navigationTitle(Strings.Onboarding.title)
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
