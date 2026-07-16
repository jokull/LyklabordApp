//
//  RecordingStore.swift
//  BetterKeyboard
//
//  DEV-MODE typing-session recorder (containing-app half). Owns the recording
//  pad's authoritative timeline and the arming handshake with the keyboard
//  extension.
//
//  ┌─ PRIVACY INVARIANTS (HARD) ─────────────────────────────────────────────┐
//  │ • Recording is OFF by default and is a developer-only affordance         │
//  │   (DEBUG builds, or dev-signed release via a hidden long-press — see     │
//  │   SettingsView). End users never see it.                                 │
//  │ • Ground truth is captured ONLY from the app's own "Upptökusvæði" pad —  │
//  │   never from any third-party app. The keyboard-side capture is armed by  │
//  │   this store's App Group flag; because the extension cannot identify its │
//  │   host, we bound the residual risk by (a) disarming the instant the app  │
//  │   leaves the foreground (`noteScenePhaseInactive`), (b) a 10-minute      │
//  │   auto-expiry bumped by pad activity, and (c) an always-visible red      │
//  │   recording indicator in the pad.                                        │
//  │ • Sessions are LOCAL ONLY — App Group Documents/sessions/. They leave    │
//  │   the device only by explicit user share-sheet export or a developer    │
//  │   USB pull. Nothing is networked.                                        │
//  │ • The learning event log and the personal dictionary are UNAFFECTED —    │
//  │   these are separate files with a separate lifecycle.                    │
//  └──────────────────────────────────────────────────────────────────────────┘
//

import Foundation
import Observation

@MainActor
@Observable
final class RecordingStore {

    // MARK: - App Group contract (MUST match KeyboardExt/SessionRecorder.swift)

    static let sessionIdKey = "is.lyklabord.dev.recording.sessionId"
    static let armedUntilKey = "is.lyklabord.dev.recording.armedUntil"
    static let sessionsSubdirectory = "sessions"
    /// Auto-expiry window; re-stamped on every pad change while recording.
    static let armWindow: TimeInterval = 10 * 60

    // MARK: - A recorded session on disk

    struct Session: Identifiable, Equatable {
        let id: String
        /// Parsed from the id (see `makeSessionId`); falls back to file date.
        let startedAt: Date
        /// Files that exist for this session (app timeline + kb log).
        let fileURLs: [URL]
        let totalBytes: Int
    }

    // MARK: - Observable state

    /// Bound to the pad's `TextEditor`.
    var padText: String = ""
    private(set) var isRecording = false
    private(set) var currentSessionId: String?
    private(set) var sessions: [Session] = []
    private(set) var lastErrorMessage: String?

    // MARK: - Wiring

    private let defaults: UserDefaults?
    private let sessionsDir: URL?

    var isAvailable: Bool { sessionsDir != nil }

    init(appGroupId: String = AppModel.appGroupIdentifier) {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId)
        {
            defaults = UserDefaults(suiteName: appGroupId)
            sessionsDir = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.sessionsSubdirectory, isDirectory: true)
        } else {
            defaults = nil
            sessionsDir = nil
        }
        refreshSessions()
    }

    // MARK: - Recording lifecycle

    func startRecording() {
        guard !isRecording, let sessionsDir else { return }
        let id = Self.makeSessionId()
        currentSessionId = id
        padText = ""
        isRecording = true
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        appendAppRecord(kind: "start", text: "")
        arm(sessionId: id)
    }

    func stopRecording() {
        guard isRecording, let id = currentSessionId else { return }
        appendAppRecord(kind: "stop", text: padText)
        disarm()
        isRecording = false
        currentSessionId = nil
        _ = id
        refreshSessions()
    }

    /// Pad text changed — snapshot the full text (the authoritative timeline)
    /// and re-stamp the auto-expiry so the keyboard stays armed while typing.
    func noteTextChanged() {
        guard isRecording else { return }
        appendAppRecord(kind: "snapshot", text: padText)
        bumpArmExpiry()
    }

    // MARK: - Scene phase (residual-risk mitigation)

    /// Called when the app leaves the foreground: disarm the keyboard side
    /// immediately so recording cannot follow the user into another app. The
    /// session stays "recording" in the UI and re-arms on return.
    func noteScenePhaseInactive() {
        guard isRecording else { return }
        disarm()
    }

    /// Called when the app returns to the foreground while still recording.
    func noteScenePhaseActive() {
        guard isRecording, let id = currentSessionId else { return }
        arm(sessionId: id)
    }

    // MARK: - Session management

    func refreshSessions() {
        guard let sessionsDir else {
            sessions = []
            return
        }
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else {
            sessions = []
            return
        }
        // Group `<id>-app.jsonl` / `<id>-kb.jsonl` by id.
        var byId: [String: (urls: [URL], bytes: Int, date: Date)] = [:]
        for url in entries where url.pathExtension == "jsonl" {
            let name = url.deletingPathExtension().lastPathComponent  // "<id>-app"
            guard let dash = name.range(of: "-", options: .backwards) else { continue }
            let id = String(name[..<dash.lowerBound])
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            let bytes = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? Date.distantPast
            var entry = byId[id] ?? ([], 0, Date.distantPast)
            entry.urls.append(url)
            entry.bytes += bytes
            entry.date = max(entry.date, date)
            byId[id] = entry
        }
        sessions = byId.map { id, value in
            Session(
                id: id,
                startedAt: Self.date(fromSessionId: id) ?? value.date,
                fileURLs: value.urls.sorted { $0.lastPathComponent < $1.lastPathComponent },
                totalBytes: value.bytes)
        }
        .sorted { $0.startedAt > $1.startedAt }  // newest first
    }

    func delete(_ session: Session) {
        let fm = FileManager.default
        for url in session.fileURLs {
            try? fm.removeItem(at: url)
        }
        refreshSessions()
    }

    // MARK: - Arming (App Group flag)

    private func arm(sessionId: String) {
        defaults?.set(sessionId, forKey: Self.sessionIdKey)
        defaults?.set(Date().timeIntervalSince1970 + Self.armWindow, forKey: Self.armedUntilKey)
    }

    private func bumpArmExpiry() {
        defaults?.set(Date().timeIntervalSince1970 + Self.armWindow, forKey: Self.armedUntilKey)
    }

    private func disarm() {
        defaults?.removeObject(forKey: Self.sessionIdKey)
        defaults?.set(0.0, forKey: Self.armedUntilKey)
    }

    // MARK: - App-side timeline append

    private func appendAppRecord(kind: String, text: String) {
        guard let sessionsDir, let id = currentSessionId else { return }
        let url = sessionsDir.appendingPathComponent("\(id)-app.jsonl")
        let record = AppRecord(t: Date().timeIntervalSince1970, sid: id, kind: kind, text: text)
        guard var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            lastErrorMessage = "Ekki tókst að skrifa upptöku"
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Session id helpers

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    static func makeSessionId(date: Date = Date()) -> String {
        idFormatter.string(from: date)
    }

    static func date(fromSessionId id: String) -> Date? {
        idFormatter.date(from: id)
    }
}

// MARK: - On-disk record (app timeline; one JSON object per line)

private struct AppRecord: Encodable {
    let t: Double
    let sid: String
    let kind: String  // "start" | "snapshot" | "stop"
    let text: String
}
