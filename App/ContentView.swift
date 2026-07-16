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
    @State private var keycapPressed = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Title comes from `.navigationTitle` (large nav title),
                    // matching the Orðasafn/Stillingar tabs. No in-view title
                    // Text here — that would duplicate the nav title.
                    hero

                    Text(Strings.Onboarding.subtitle)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(Strings.Onboarding.setupHeading)
                            .font(.title2.bold())

                        stepRow(number: 1, text: Strings.Onboarding.step1)
                        stepRow(number: 2, text: Strings.Onboarding.step2)
                        stepRow(number: 3, text: Strings.Onboarding.step3)

                        Text(Strings.Onboarding.step3Detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                            .fixedSize(horizontal: false, vertical: true)

                        NavigationLink {
                            FullAccessExplainer()
                        } label: {
                            Label(Strings.Onboarding.fullAccessMoreLink, systemImage: "info.circle")
                                .font(.subheadline)
                        }
                        .padding(.leading, 36)

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

    // Branded hero: the Wave-6 keycap mark over the site's tagline. Tapping the
    // keycap springs it down and back — a small delightful echo of the press
    // interaction on lyklabord.solberg.is. Centered, restrained, Apple-like.
    private var hero: some View {
        VStack(spacing: 16) {
            Image("KeycapHero")
                .resizable()
                .scaledToFit()
                .frame(width: 152, height: 152)
                .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
                .scaleEffect(keycapPressed ? 0.93 : 1)
                .offset(y: keycapPressed ? 4 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: keycapPressed)
                .contentShape(Rectangle())
                .onTapGesture {
                    keycapPressed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        keycapPressed = false
                    }
                }
                .accessibilityLabel(Strings.Onboarding.heroAccessibilityLabel)

            Text(Strings.Onboarding.tagline)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
