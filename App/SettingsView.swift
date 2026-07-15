//
//  SettingsView.swift
//  BetterKeyboard
//
//  "Stillingar" scaffold: spacebar-mode picker (persisted to the App Group
//  UserDefaults suite for a later keyboard-extension wave to consume), the
//  iCloud sync section (M2 wave 3: opt-out toggle, status line, delete-all
//  action), and an "Um Lyklaborð" section (open source / BÍN attribution /
//  no-telemetry statement).
//

import Sync
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showDeleteConfirmation = false

    /// Backed by the App Group's shared `UserDefaults` suite (not the
    /// standard suite) so the keyboard extension can read the same value in
    /// a later wave. See `AppModel.spacebarModeDefaultsKey` for the key and
    /// `AppModel.appGroupIdentifier` for the suite name.
    @AppStorage(AppModel.spacebarModeDefaultsKey, store: UserDefaults(suiteName: AppModel.appGroupIdentifier))
    private var spacebarModeRaw: String = SpacebarMode.completeCurrentWord.rawValue

    /// iCloud sync opt-out flag, default ON (PLAN decision #5: transparent,
    /// zero-config sync). Same App Group suite; the coordinator's engine
    /// reads the same key at each sync call, so a flipped toggle takes
    /// effect on the very next round without restarting anything.
    @AppStorage(SyncCoordinator.syncEnabledDefaultsKey, store: UserDefaults(suiteName: AppModel.appGroupIdentifier))
    private var syncEnabled: Bool = true

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

                Section {
                    Toggle(Strings.Settings.syncToggleTitle, isOn: $syncEnabled)
                        .onChange(of: syncEnabled) { _, isOn in
                            if isOn {
                                // Immediate round on opt-in so the status
                                // line reflects reality right away.
                                Task { await appModel.syncCoordinator.syncNow() }
                            }
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.Settings.syncStatusTitle)
                        Text(appModel.syncCoordinator.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let date = appModel.syncCoordinator.statusDate {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Text(Strings.Settings.syncDeleteButton)
                    }
                    // TODO(provisioning): enabled once the CloudKit
                    // container goes live — see SyncActivation.
                    .disabled(!SyncActivation.isCloudKitProvisioned)
                    .confirmationDialog(
                        Strings.Settings.syncDeleteConfirmTitle,
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(Strings.Settings.syncDeleteConfirmAction, role: .destructive) {
                            Task { await appModel.syncCoordinator.deleteRemoteData() }
                        }
                        Button(Strings.Settings.syncDeleteCancel, role: .cancel) {}
                    } message: {
                        Text(Strings.Settings.syncDeleteConfirmMessage)
                    }
                } header: {
                    Text(Strings.Settings.syncSectionTitle)
                } footer: {
                    Text(Strings.Settings.syncSectionFooter)
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
