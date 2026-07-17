//
//  SettingsView.swift
//  BetterKeyboard
//
//  "Stillingar": spacebar-mode picker (persisted to the App Group
//  UserDefaults suite for a later keyboard-extension wave), the iCloud sync
//  section (opt-out toggle, status, delete-from-iCloud), a data-lifecycle
//  section (export my data / delete ALL data — v1-blockers), a Full Access
//  explainer link, and an "Um Lyklaborð" section with tappable trust links
//  (source, privacy policy, BÍN).
//

import Sync
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SubscriptionManager.self) private var subscriptions
    @State private var showDeleteConfirmation = false

    // Lyklaborð+ paywall sheet (opened from the subscription section and
    // the gated sync section).
    @State private var showingPaywall = false
    @State private var showingRedeemSheet = false

    // Data export
    @State private var exportDocument: ExportDataDocument?
    @State private var showingExporter = false
    @State private var showExportError = false

    // Delete-all (double confirmation)
    @State private var showDeleteAllConfirm1 = false
    @State private var showDeleteAllConfirm2 = false
    @State private var isDeletingAll = false
    @State private var deleteAllMessage: String?

    // Þróunarhamur: shown unconditionally in DEBUG; in a dev-signed release
    // build it stays hidden until the version row is long-pressed (see
    // `aboutSection`). Trivial, zero end-user surface.
    @State private var devModeRevealed = false
    private var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    private var showsDeveloperSection: Bool { isDebugBuild || devModeRevealed }

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
                spacebarSection
                subscriptionSection
                syncSection
                dataSection
                fullAccessSection
                aboutSection
                if showsDeveloperSection {
                    developerSection
                }
            }
            .navigationTitle(Strings.Settings.navigationTitle)
            .sheet(isPresented: $showingPaywall) {
                SubscriptionView()
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: appModel.exportFilename()
            ) { _ in
                exportDocument = nil
            }
            .alert(Strings.DataExport.failed, isPresented: $showExportError) {
                Button(Strings.DeleteAll.ok, role: .cancel) {}
            }
            .alert(
                Strings.DeleteAll.doneTitle,
                isPresented: Binding(
                    get: { deleteAllMessage != nil },
                    set: { if !$0 { deleteAllMessage = nil } }
                )
            ) {
                Button(Strings.DeleteAll.ok, role: .cancel) {}
            } message: {
                Text(deleteAllMessage ?? "")
            }
        }
    }

    // MARK: - Spacebar

    private var spacebarSection: some View {
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
    }

    // MARK: - Lyklaborð+ (subscription)

    private var subscriptionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.Plus.statusRowTitle).bold()
                Text(subscriptionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if DEBUG
                Text(Strings.Plus.statusDebugNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                #endif
            }

            switch subscriptions.status {
            case .entitled:
                // Manage/cancel deep link into the App Store subscription
                // management screen (required affordance).
                Link(destination: SubscriptionManager.manageSubscriptionsURL) {
                    Label(Strings.Plus.manageButton, systemImage: "creditcard")
                }
            case .notEntitled, .unknown:
                Button {
                    showingPaywall = true
                } label: {
                    Label(Strings.Plus.learnMoreButton, systemImage: "plus.circle")
                }
                Button(Strings.Plus.restoreButton) {
                    Task { await subscriptions.restorePurchases() }
                }
                Button {
                    showingRedeemSheet = true
                } label: {
                    Label(Strings.Plus.redeemButton, systemImage: "ticket")
                }
                .offerCodeRedemption(isPresented: $showingRedeemSheet)
                if let error = subscriptions.lastActionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(Strings.Plus.settingsSectionTitle)
        } footer: {
            Text(Strings.Plus.settingsFooter)
        }
    }

    private var subscriptionStatusText: String {
        switch subscriptions.status {
        case .unknown:
            return Strings.Plus.statusUnknown
        case .notEntitled:
            return Strings.Plus.statusNotEntitled
        case .entitled(let expiry):
            guard let expiry else { return Strings.Plus.statusEntitled }
            return Strings.Plus.statusEntitledUntil(
                expiry.formatted(date: .abbreviated, time: .omitted))
        }
    }

    // MARK: - iCloud sync

    private var syncSection: some View {
        Section {
            if subscriptions.isEntitled {
                Toggle(Strings.Settings.syncToggleTitle, isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, isOn in
                        if isOn {
                            Task { await appModel.syncCoordinator.syncNow() }
                        }
                    }
            } else {
                // Lyklaborð+ gate: sync is paused without the subscription
                // (SyncCoordinator's engine checks the same gate per round).
                // The toggle state itself is preserved for when it unlocks.
                Button {
                    showingPaywall = true
                } label: {
                    Label(Strings.Plus.lockedSyncFooter, systemImage: "lock")
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
            // TODO(provisioning): enabled once the CloudKit container goes
            // live — see SyncActivation.
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
    }

    // MARK: - Data lifecycle (export + delete all)

    private var dataSection: some View {
        Section {
            Button {
                exportData()
            } label: {
                Label(Strings.DataExport.button, systemImage: "square.and.arrow.up")
            }
            .disabled(appModel.containerState == .unavailable || !appModel.hasAnyWords)

            Button(role: .destructive) {
                showDeleteAllConfirm1 = true
            } label: {
                if isDeletingAll {
                    ProgressView()
                } else {
                    Label(Strings.DeleteAll.button, systemImage: "trash")
                }
            }
            .disabled(isDeletingAll)
            // First confirmation.
            .confirmationDialog(
                Strings.DeleteAll.confirm1Title,
                isPresented: $showDeleteAllConfirm1,
                titleVisibility: .visible
            ) {
                Button(Strings.DeleteAll.confirm1Action, role: .destructive) {
                    showDeleteAllConfirm2 = true
                }
                Button(Strings.DeleteAll.cancel, role: .cancel) {}
            } message: {
                Text(Strings.DeleteAll.confirm1Message)
            }
            // Second confirmation — the actual destructive commit.
            .confirmationDialog(
                Strings.DeleteAll.confirm2Title,
                isPresented: $showDeleteAllConfirm2,
                titleVisibility: .visible
            ) {
                Button(Strings.DeleteAll.confirm2Action, role: .destructive) {
                    deleteAllData()
                }
                Button(Strings.DeleteAll.cancel, role: .cancel) {}
            } message: {
                Text(Strings.DeleteAll.confirm2Message)
            }
        } header: {
            Text(Strings.Settings.dataSectionTitle)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.DataExport.footer)
                Text(Strings.DeleteAll.footer)
            }
        }
    }

    private func exportData() {
        if let data = appModel.exportedData() {
            exportDocument = ExportDataDocument(data: data)
            showingExporter = true
        } else {
            showExportError = true
        }
    }

    private func deleteAllData() {
        isDeletingAll = true
        Task {
            let result = await appModel.deleteAllData()
            isDeletingAll = false
            deleteAllMessage = result.isFullSuccess ? Strings.DeleteAll.done : Strings.DeleteAll.remoteFailed
        }
    }

    // MARK: - Full Access

    private var fullAccessSection: some View {
        Section {
            NavigationLink {
                FullAccessExplainer()
            } label: {
                Label(Strings.FullAccess.title, systemImage: "lock.open")
            }
        }
    }

    // MARK: - Um Lyklaborð (trust surface)

    private var aboutSection: some View {
        Section(Strings.Settings.aboutSectionTitle) {
            if let url = URL(string: Strings.Links.website) {
                Link(destination: url) {
                    linkRow(
                        title: Strings.Settings.aboutWebsiteTitle,
                        detail: Strings.Settings.aboutWebsiteDetail,
                        systemImage: "globe"
                    )
                }
            }
            if let url = URL(string: Strings.Links.githubRepo) {
                Link(destination: url) {
                    linkRow(
                        title: Strings.Settings.aboutGithubTitle,
                        detail: Strings.Settings.aboutGithubDetail,
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
            }
            if let url = URL(string: Strings.Links.privacyPolicy) {
                Link(destination: url) {
                    linkRow(
                        title: Strings.Settings.aboutPrivacyTitle,
                        detail: Strings.Settings.aboutPrivacyDetail,
                        systemImage: "hand.raised"
                    )
                }
            }
            if let url = URL(string: Strings.Links.bin) {
                Link(destination: url) {
                    linkRow(
                        title: Strings.Settings.aboutBinTitle,
                        detail: Strings.Settings.aboutBinDetail,
                        systemImage: "character.book.closed"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.Settings.aboutNoTelemetryTitle).bold()
                Text(Strings.Settings.aboutNoTelemetryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            versionRow
        }
    }

    /// App version row. Doubles as the hidden affordance that reveals
    /// Þróunarhamur on dev-signed release builds (long-press) — in DEBUG the
    /// section is already visible, so this is a no-op there.
    private var versionRow: some View {
        HStack {
            Text("Útgáfa")
            Spacer()
            Text(appVersion)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.5) {
            devModeRevealed = true
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - Þróunarhamur (dev-mode session recorder)

    private var developerSection: some View {
        Section {
            NavigationLink {
                RecordingPadView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Strings.Developer.recorderRow)
                        Text(Strings.Developer.recorderRowDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.badge.mic")
                }
            }
        } header: {
            Text(Strings.Developer.sectionTitle)
        } footer: {
            Text(Strings.Developer.sectionFooter)
        }
    }

    private func linkRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Decorative (VoiceOver otherwise reads the SF Symbol's English
            // description before the Icelandic row title).
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title).bold()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
        .environment(SubscriptionManager())
}
