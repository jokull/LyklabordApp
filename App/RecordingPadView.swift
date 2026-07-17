//
//  RecordingPadView.swift
//  BetterKeyboard
//
//  DEV-MODE "Upptökusvæði": the ONLY place a typing session can be recorded.
//  Recording captures ground truth ONLY from this pad — never any third-party
//  app — which is what keeps the privacy story absolute (see RecordingStore
//  and docs/PRIVACY.md "Developer mode"). Reached from Stillingar →
//  Þróunarhamur (DEBUG, or dev-signed release via the hidden version long-press).
//

import SwiftUI

struct RecordingPadView: View {
    @State private var store = RecordingStore()
    @State private var showSessions = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            recordBar
            Divider()
            if store.isAvailable {
                TextEditor(text: $store.padText)
                    .font(.body)
                    .padding(8)
                    .onChange(of: store.padText) { store.noteTextChanged() }
            } else {
                ContentUnavailableView(
                    Strings.Developer.unavailableTitle,
                    systemImage: "externaldrive.badge.xmark",
                    description: Text(Strings.Developer.unavailableBody))
            }
        }
        .navigationTitle(Strings.Developer.padTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.refreshSessions()
                    showSessions = true
                } label: {
                    Label(Strings.Developer.sessionsButton, systemImage: "list.bullet.rectangle")
                }
            }
        }
        .sheet(isPresented: $showSessions) {
            SessionsListView(store: store)
        }
        .onChange(of: scenePhase) { _, phase in
            // Residual-risk mitigation: disarm the keyboard the instant the app
            // leaves the foreground, re-arm on return (see RecordingStore).
            if phase == .active {
                store.noteScenePhaseActive()
            } else {
                store.noteScenePhaseInactive()
            }
        }
        .onDisappear {
            // Never leave the keyboard armed behind our back.
            if store.isRecording { store.stopRecording() }
        }
        .task {
            // Retroactively push any finished-but-unexported sessions to the
            // user's iCloud Drive (and write any missing manifests).
            store.exportPendingSessions()
        }
    }

    // MARK: - Record control bar

    private var recordBar: some View {
        HStack(spacing: 12) {
            if store.isRecording {
                RecordingDot()
                Text(Strings.Developer.recordingActive)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Button(role: .destructive) {
                    store.stopRecording()
                } label: {
                    Label(Strings.Developer.stopButton, systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Image(systemName: "record.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Strings.Developer.recordingIdle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.startRecording()
                } label: {
                    Label(Strings.Developer.startButton, systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isAvailable)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Pulsing red recording indicator.
private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .opacity(on ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityLabel(Strings.Developer.recordingActive)
    }
}

// MARK: - Sessions list (share + delete)

private struct SessionsListView: View {
    @Bindable var store: RecordingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        Strings.Developer.sessionsEmptyTitle,
                        systemImage: "waveform",
                        description: Text(Strings.Developer.sessionsEmptyBody))
                } else {
                    if store.iCloudAvailable == false {
                        Label(Strings.Developer.syncUnavailableNote, systemImage: "icloud.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(session))
                                    .font(.body.monospacedDigit())
                                Text(subtitle(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            SyncBadge(state: store.syncState(for: session.id))
                            ShareLink(items: session.fileURLs) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel(Strings.Developer.shareButton)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.sessions[$0] }.forEach(store.delete)
                    }
                }
            }
            .navigationTitle(Strings.Developer.sessionsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Strings.Developer.doneButton) { dismiss() }
                }
            }
        }
    }

    private func displayName(_ session: Session) -> String {
        Self.display.string(from: session.startedAt)
    }

    private typealias SyncState = RecordingStore.SyncState

    /// Per-session iCloud sync indicator.
    private struct SyncBadge: View {
        let state: SyncState

        var body: some View {
            switch state {
            case .uploaded:
                icon("checkmark.icloud", .green, Strings.Developer.syncUploaded)
            case .syncing:
                icon("arrow.clockwise.icloud", .secondary, Strings.Developer.syncPending)
            case .localOnly:
                icon("icloud.slash", .secondary, Strings.Developer.syncLocalOnly)
            case .unavailable:
                icon("icloud.slash", .secondary, Strings.Developer.syncUnavailable)
            }
        }

        private func icon(_ name: String, _ color: Color, _ label: String) -> some View {
            Image(systemName: name)
                .foregroundStyle(color)
                .accessibilityLabel(label)
                .help(label)
        }
    }

    private func subtitle(_ session: Session) -> String {
        let kb = Double(session.totalBytes) / 1024
        let size = String(format: "%.1f KB", kb)
        return "\(session.fileURLs.count) skrár · \(size)"
    }

    private typealias Session = RecordingStore.Session

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}
