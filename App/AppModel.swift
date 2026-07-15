//
//  AppModel.swift
//  BetterKeyboard
//
//  M2 app track: owns the app's copy of the personal learning store
//  (`Learning.PersonalModel`), compacts it against the keyboard extension's
//  event log, and exposes plain listings + mutation methods to the SwiftUI
//  layer. Kept thin and side-effect-explicit (no view logic) so it stays
//  testable once an App-target test target exists.
//

import Foundation
import Observation
import Learning

@MainActor
@Observable
final class AppModel {

    // MARK: - App Group

    /// Must match `App/BetterKeyboard.entitlements`,
    /// `KeyboardExt/BetterKeyboardExt.entitlements`, and
    /// `KeyboardApp.appGroupId` in `KeyboardExt/KeyboardViewController.swift`.
    static let appGroupIdentifier = "group.is.lyklabord"

    /// Filenames inside the App Group container. Chosen here because
    /// neither file exists on disk yet — the keyboard extension does not
    /// write learning events until its own M2 wave lands. If that wave picks
    /// different names, update these two constants to match (single source
    /// of truth for the app side).
    private static let personalModelFileName = "personal-model.json"
    private static let learningEventLogFileName = "learning-events.log"

    /// `UserDefaults` key (in the App Group suite) for the spacebar-mode
    /// setting written by `SettingsView`. Not consumed by the extension yet
    /// — this wave only writes the value so a later extension wave has a
    /// stable key to read. Raw value is `SpacebarMode.rawValue`.
    static let spacebarModeDefaultsKey = "is.lyklabord.settings.spacebarMode"

    // MARK: - State

    enum ContainerState: Equatable {
        case ready
        /// No App Group container URL (e.g. Simulator without entitlements
        /// wired up, or a provisioning-profile mismatch). The UI falls back
        /// to an explanatory empty state rather than crashing.
        case unavailable
    }

    private(set) var containerState: ContainerState
    private(set) var learnedWords: [String] = []
    private(set) var userAddedWords: [String] = []
    private(set) var lastErrorMessage: String?

    /// M2 wave 3: owns the CloudKit sync loop (app-only — the keyboard
    /// extension never syncs). Fed by `compact()` and every dictionary
    /// mutation via `noteLocalChange()` (coalesced ~5s in the coordinator).
    let syncCoordinator: SyncCoordinator

    private var model: PersonalModel?
    private let modelURL: URL?
    private let eventLogURL: URL?

    var hasAnyWords: Bool {
        !learnedWords.isEmpty || !userAddedWords.isEmpty
    }

    // MARK: - Init

    init() {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            containerState = .ready
            modelURL = container.appendingPathComponent(Self.personalModelFileName)
            eventLogURL = container.appendingPathComponent(Self.learningEventLogFileName)
        } else {
            containerState = .unavailable
            modelURL = nil
            eventLogURL = nil
        }
        syncCoordinator = SyncCoordinator(modelURL: modelURL)
        loadModel()
        // A pulled/merged model was written to `modelURL` by the
        // coordinator — reload our in-memory copy and listings from disk.
        syncCoordinator.onModelDataReplaced = { [weak self] in
            self?.loadModel()
        }
    }

    // MARK: - Loading & compaction

    private func loadModel() {
        guard let modelURL else { return }
        do {
            if FileManager.default.fileExists(atPath: modelURL.path) {
                model = try CoordinatedFileAccess.coordinateRead(at: modelURL) { url in
                    try PersonalModel(contentsOf: url)
                }
            } else {
                model = PersonalModel()
            }
        } catch {
            lastErrorMessage = "\(error)"
            model = PersonalModel()
        }
        refreshListings()
    }

    /// Merges any learning events the keyboard extension appended since the
    /// last compaction into the personal model, then saves. Cheap and safe
    /// to call repeatedly — a no-op when the log is empty/missing. Call on
    /// launch (`init` → `loadModel` does an initial load; call this too so a
    /// log written before first launch is picked up) and whenever
    /// `scenePhase` becomes `.active` (see `BetterKeyboardApp`), so the
    /// dictionary editor reflects typing done in other apps since the user
    /// last had this app foregrounded.
    ///
    /// Per `PersonalModel.compactAndSave` / `CoordinatedFileAccess` docs, the
    /// read-merge-truncate sequence runs inside one coordinated write on the
    /// *log* URL; the model file itself is app-owned and saved with a plain
    /// atomic write (already coordinated-safe against the extension, which
    /// never writes the model file).
    func compact() {
        guard let model, let modelURL, let eventLogURL else { return }
        do {
            try CoordinatedFileAccess.coordinateWrite(at: eventLogURL) { logURL in
                try model.compactAndSave(applying: EventLog(url: logURL), to: modelURL)
            }
            refreshListings()
            // Freshly compacted state on disk — schedule a (coalesced)
            // sync round so other devices see it.
            syncCoordinator.noteLocalChange()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    private func refreshListings() {
        learnedWords = model?.learnedWords ?? []
        userAddedWords = model?.userAddedWords ?? []
    }

    private func persist() {
        guard let model, let modelURL else { return }
        do {
            try model.save(to: modelURL)
            // Dictionary-editor mutation persisted — coalesced sync so
            // deletions (tombstones) and additions propagate promptly.
            syncCoordinator.noteLocalChange()
        } catch {
            lastErrorMessage = "\(error)"
        }
        refreshListings()
    }

    // MARK: - Dictionary editing

    /// Swipe-to-delete on a learned word. `PersonalModel.remove(word:)`
    /// drops its counts/day-history, removes any user-added flag, drops
    /// every bigram touching it, and tombstones it so ordinary typing can
    /// never silently relearn it. Pair with `undoRemove(_:)` for the brief
    /// undo affordance in `DictionaryView`.
    func removeLearned(_ word: String) {
        model?.remove(word: word)
        persist()
    }

    /// Best-effort undo for `removeLearned`. IMPORTANT: `remove(word:)`
    /// already discards the word's commit counts and day-history before
    /// tombstoning it — `PersonalModel` has no way to restore that state
    /// verbatim. The only ways back in are `removeTombstone(word:)` (clears
    /// the tombstone but leaves the word unlearned until ordinary typing
    /// re-crosses the day threshold) or `addUserWord(word:)` (clears the
    /// tombstone AND makes the word immediately valid again). We use
    /// `addUserWord` here: tapping "Afturkalla" is an explicit "keep this
    /// word" signal, exactly the kind of signal `PersonalModel` already
    /// treats as skip-the-threshold elsewhere (verbatim taps). The
    /// practical effect: the undone word reappears under "Mín orð", not
    /// back under "Lærð orð" — original commit counts are gone for good.
    func undoRemove(_ word: String) {
        try? model?.addUserWord(word)
        persist()
    }

    /// "Bæta við orði" flow. Trims surrounding whitespace, then delegates
    /// single-word validation to `PersonalModel.addUserWord` (backed by
    /// `EventLog.isLearnableWord`: non-empty, no internal whitespace/control
    /// characters, no emoji, at least one letter, under the length cap).
    /// Returns a user-facing error message on failure, `nil` on success.
    @discardableResult
    func addWord(_ rawText: String) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model else { return Strings.Dictionary.containerUnavailableBody }
        do {
            try model.addUserWord(trimmed)
            persist()
            return nil
        } catch {
            return Strings.Dictionary.addWordInvalid
        }
    }

    // MARK: - SwiftKey import

    /// Outcome of a SwiftKey `vocabulary.txt` import, pre-shaped for the UI.
    /// `skippedInvalid` folds together parse-level skips (comment/junk lines
    /// in the export file) and import-level rejects — to the user these are
    /// one category: "lines that weren't valid words".
    struct ImportOutcome: Equatable {
        var imported: Int
        var skippedInvalid: Int
        var skippedTombstoned: Int
    }

    enum ImportError: Error {
        /// `startAccessingSecurityScopedResource` failed — the picked URL
        /// can't be opened from our sandbox.
        case accessDenied
        /// The file couldn't be read/decoded as UTF-8 text.
        case unreadable
    }

    /// Import a SwiftKey export's `vocabulary.txt` (picked via
    /// `.fileImporter`). The URL from the file importer is security-scoped
    /// (outside our sandbox), so the read is bracketed with
    /// `startAccessingSecurityScopedResource` / `stop...`. Parsing +
    /// `PersonalModel.importLearnedWords` semantics: imported words become
    /// explicitly-accepted learned words immediately (they show up under
    /// "Lærð orð", not "Mín orð"); tombstones win — words the user deleted
    /// here stay deleted.
    func importSwiftKeyVocabulary(from url: URL) -> Result<ImportOutcome, ImportError> {
        guard let model else { return .failure(.accessDenied) }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        // `startAccessing...` returns false for URLs that aren't security-
        // scoped (rare with fileImporter, but possible for files already in
        // our container) — in that case reading may still succeed, so only
        // treat the *read* failing as fatal.
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        let parsed: (words: [String], skipped: Int)
        do {
            parsed = try SwiftKeyImport.parseVocabulary(at: url)
        } catch {
            return .failure(didStartAccess ? .unreadable : .accessDenied)
        }
        let summary = model.importLearnedWords(parsed.words)
        persist()
        return .success(
            ImportOutcome(
                imported: summary.imported,
                skippedInvalid: parsed.skipped + summary.skippedInvalid,
                skippedTombstoned: summary.skippedTombstoned
            )
        )
    }
}

/// Spacebar behavior modes (PLAN.md "Spacebar behavior — three
/// user-selectable modes", SwiftKey parity). Persisted to the App Group
/// `UserDefaults` suite under `AppModel.spacebarModeDefaultsKey` so a later
/// keyboard-extension wave can read the user's choice; the extension does
/// not consume this yet.
enum SpacebarMode: String, CaseIterable, Identifiable {
    /// Mid-word: space commits the center/autocorrect suggestion + a space.
    /// Cursor already at a word boundary: space is just a space. Current
    /// engine behavior (M1) regardless of this setting — this case is the
    /// documented default once the extension reads the key.
    case completeCurrentWord
    /// Space always injects the center prediction, even with zero letters
    /// typed — "sentence by spacebar". Needs next-word prediction to be
    /// useful.
    case alwaysInsertPrediction
    /// Space is always a literal space; corrections apply only via a tap on
    /// the suggestion bar.
    case alwaysInsertSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completeCurrentWord: return Strings.Settings.spacebarModeCompleteTitle
        case .alwaysInsertPrediction: return Strings.Settings.spacebarModePredictionTitle
        case .alwaysInsertSpace: return Strings.Settings.spacebarModeSpaceTitle
        }
    }

    var detail: String {
        switch self {
        case .completeCurrentWord: return Strings.Settings.spacebarModeCompleteDetail
        case .alwaysInsertPrediction: return Strings.Settings.spacebarModePredictionDetail
        case .alwaysInsertSpace: return Strings.Settings.spacebarModeSpaceDetail
        }
    }
}
