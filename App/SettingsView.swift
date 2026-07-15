//
//  SettingsView.swift
//  BetterKeyboard
//
//  "Stillingar" scaffold: spacebar-mode picker (persisted to the App Group
//  UserDefaults suite for a later keyboard-extension wave to consume), an
//  "Um Lyklaborð" section (open source / BÍN attribution / no-telemetry
//  statement), and a placeholder for iCloud sync status (wave 3).
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    /// Backed by the App Group's shared `UserDefaults` suite (not the
    /// standard suite) so the keyboard extension can read the same value in
    /// a later wave. See `AppModel.spacebarModeDefaultsKey` for the key and
    /// `AppModel.appGroupIdentifier` for the suite name.
    @AppStorage(AppModel.spacebarModeDefaultsKey, store: UserDefaults(suiteName: AppModel.appGroupIdentifier))
    private var spacebarModeRaw: String = SpacebarMode.completeCurrentWord.rawValue

    private var spacebarMode: Binding<SpacebarMode> {
        Binding(
            get: { SpacebarMode(rawValue: spacebarModeRaw) ?? .completeCurrentWord },
            set: { spacebarModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Strings.Settings.spacebarSectionTitle, selection: spacebarMode) {
                        ForEach(SpacebarMode.allCases) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.title)
                                Text(mode.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(Strings.Settings.spacebarSectionTitle)
                } footer: {
                    Text(Strings.Settings.spacebarSectionFooter)
                }

                Section(Strings.Settings.syncSectionTitle) {
                    LabeledContent(Strings.Settings.syncStatusTitle) {
                        Text(Strings.Settings.syncComingSoon)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section(Strings.Settings.aboutSectionTitle) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.Settings.aboutOpenSourceTitle).bold()
                        Text(Strings.Settings.aboutOpenSourceDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.Settings.aboutBinTitle).bold()
                        Text(Strings.Settings.aboutBinDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.Settings.aboutNoTelemetryTitle).bold()
                        Text(Strings.Settings.aboutNoTelemetryDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Strings.Settings.navigationTitle)
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
