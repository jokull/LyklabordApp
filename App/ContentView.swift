//
//  ContentView.swift
//  Lyklabord
//
//  "Byrjun" tab: the enable-the-keyboard walkthrough plus a try-it text
//  field. Built for the least technical user we can imagine, on an iPhone
//  whose iOS is in English (every Icelandic iPhone is — COPY RULE in
//  Strings.swift): numbered steps, each anchored by a mock Settings row
//  that looks like the real row to find, quoted English labels verbatim.
//
//  Detect-and-adapt: when the keyboard is already enabled (see
//  `KeyboardStatus`) the walkthrough collapses to a done-state card and the
//  steps tuck behind a DisclosureGroup. The check re-runs every time the
//  scene re-activates, so flipping the toggle in Settings and swiping back
//  flips this screen live.
//
//  The Full Access scare is preempted IN step 4, before the user can reach
//  iOS's "Full Access" warning dialog: one honest line (zero network code,
//  verifiable) plus the link into the shared `FullAccessExplainer` — the
//  single source of truth, deliberately not duplicated here.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sampleText: String = ""
    @State private var keycapPressed = false
    @State private var heroLoadFailed = false
    @State private var keyboardEnabled = KeyboardStatus.isKeyboardEnabled
    @State private var showingStepsWhileEnabled = false
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

                    if keyboardEnabled {
                        enabledCard
                        DisclosureGroup(isExpanded: $showingStepsWhileEnabled) {
                            setupSteps
                                .padding(.top, 12)
                        } label: {
                            Label(
                                Strings.Onboarding.showStepsButton,
                                systemImage: "list.number"
                            )
                            .font(.subheadline)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(Strings.Onboarding.setupHeading)
                                .font(.title2.bold())
                            setupSteps
                        }
                    }

                    tryItPad
                }
                .padding()
            }
            .navigationTitle(Strings.Onboarding.title)
        }
        .onAppear { refreshKeyboardStatus() }
        .onChange(of: scenePhase) { _, newPhase in
            // The user flips the toggle in Settings, swipes back — the
            // walkthrough must have collapsed by the time the app is
            // visible again.
            if newPhase == .active { refreshKeyboardStatus() }
        }
    }

    private func refreshKeyboardStatus() {
        keyboardEnabled = KeyboardStatus.isKeyboardEnabled
    }

    // MARK: - Hero

    // Branded hero: the Wave-6 Ð keycap (our mark) as a real interactive 3D
    // object — drag left/right to spin it on its Y axis, floating over a soft
    // contact shadow so it reads as suspended in mid-air. Mirrors the press-
    // and-spin brand interaction on lyklabord.solberg.is, natively in SceneKit.
    // Falls back to the flat KeycapHero image if the model can't load. See
    // KeycapHeroView for the model pipeline and render/battery notes.
    //
    // Interaction note: the old flat-image tap "spring press" is intentionally
    // dropped — a spun turntable is the interaction now; a tap-press over the
    // SCNView pan gesture added no clarity. keycapPressed remains only for the
    // fallback image below.
    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                // Suspended-in-mid-air contact shadow, drawn in SwiftUI so it is
                // theme-aware and always present regardless of the render loop.
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.28),
                                Color.black.opacity(0.10),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 62
                        )
                    )
                    .frame(width: 132, height: 34)
                    .blur(radius: 9)
                    .offset(y: 74)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if heroLoadFailed {
                    fallbackHeroImage
                } else {
                    KeycapHeroView(
                        reduceMotion: reduceMotion,
                        isActive: scenePhase == .active,
                        loadFailed: $heroLoadFailed
                    )
                    .frame(width: 220, height: 176)
                }
            }
            .frame(width: 220, height: 200)
            .accessibilityElement()
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

    /// Load/SceneKit-unavailable fallback: the original flat keycap image with
    /// its tap spring-press echo. Never a blank hero.
    private var fallbackHeroImage: some View {
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
    }

    // MARK: - Done-state (keyboard already enabled)

    private var enabledCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.Onboarding.enabledTitle)
                    .font(.headline)
                Text(Strings.Onboarding.enabledBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.1))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Walkthrough steps

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 20) {
            step(number: 1, text: Strings.Onboarding.step1)

            step(number: 2, text: Strings.Onboarding.step2) {
                settingsMockRow {
                    mockRowLabel(
                        icon: "keyboard",
                        iconColor: .gray,
                        title: Strings.Onboarding.mockKeyboardsRow
                    )
                }
            }

            step(number: 3, text: Strings.Onboarding.step3) {
                settingsMockRow {
                    Text(Strings.Onboarding.mockAddKeyboardRow)
                        .foregroundStyle(.tint)
                }
            }

            step(number: 4, text: Strings.Onboarding.step4) {
                settingsMockRow {
                    HStack {
                        Text(Strings.Onboarding.mockFullAccessRow)
                        Spacer()
                        // Non-interactive mock of the Settings toggle — a
                        // visual anchor, not a control.
                        Toggle("", isOn: .constant(true))
                            .labelsHidden()
                            .disabled(true)
                            .accessibilityHidden(true)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    // The honest preemption — read BEFORE iOS's own scary
                    // Full Access dialog appears.
                    Label {
                        Text(Strings.Onboarding.fullAccessPreempt)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.indigo)
                            .accessibilityHidden(true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text(Strings.Onboarding.step4Detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    NavigationLink {
                        FullAccessExplainer()
                    } label: {
                        Label(Strings.Onboarding.fullAccessMoreLink, systemImage: "info.circle")
                            .font(.subheadline)
                    }
                }
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(Strings.Onboarding.openSettingsButton, systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(Strings.Onboarding.openSettingsShortcutNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    /// One numbered step: circled number, Icelandic instruction with the
    /// English Settings labels quoted verbatim, optional visual anchors
    /// (mock Settings rows) below the text, indented to the text column.
    private func step(number: Int, text: String) -> some View {
        step(number: number, text: text) { EmptyView() }
    }

    private func step(
        number: Int,
        text: String,
        @ViewBuilder anchors: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepNumber(number)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                anchors()
            }
        }
        // NOTE: no `.accessibilityElement(children: .combine)` here — step 4
        // contains an interactive NavigationLink and would lose it. The
        // number circle is hidden instead; VoiceOver reads the instruction
        // text (which contains the quoted labels) in order.
    }

    /// Scales with Dynamic Type instead of a hard 24pt circle (the old
    /// fixed frame clipped the digit at accessibility text sizes).
    private func stepNumber(_ number: Int) -> some View {
        Text("\(number)")
            .font(.subheadline.bold())
            .monospacedDigit()
            .padding(6)
            .frame(minWidth: 28, minHeight: 28)
            .background(Circle().fill(Color.accentColor.opacity(0.15)))
            .accessibilityHidden(true)
    }

    /// A row styled to imitate the real (English) iOS Settings rows —
    /// recognizably "that thing you're looking for", never a screenshot.
    private func settingsMockRow(@ViewBuilder content: () -> some View) -> some View {
        HStack {
            content()
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
    }

    private func mockRowLabel(icon: String, iconColor: Color, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(iconColor))
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Try it now

    /// In-app success verification: switch to Lyklaborð with the globe and
    /// type right here — no need to leave the app to know the setup worked.
    private var tryItPad: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Strings.Onboarding.tryHeading)
                .font(.title2.bold())
            Text(Strings.Onboarding.tryBody)
                .foregroundStyle(.secondary)

            TextField(Strings.Onboarding.tryPlaceholder, text: $sampleText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .lineLimit(4...8)
                // The try-it field is the only focusable thing on this screen,
                // so once the keyboard is up it covers the app nav with no way
                // out. A "Lokið" button in the keyboard accessory bar (renders
                // above ANY keyboard, including Lyklaborð) resigns focus.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(Strings.Onboarding.tryDone) { isTextFieldFocused = false }
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
