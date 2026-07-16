//
//  BetterKeyboardAutocompleteService.swift
//  BetterKeyboardExt
//
//  M1: bridges TypeEngine (bilingual IS/EN corrector + predictor) into
//  KeyboardKit's `AutocompleteService`. KeyboardKit calls
//  `autocomplete(_:)` with all text before the input cursor
//  (`documentContextBeforeInput`) on every text change; the returned
//  `Autocomplete.ServiceResult` is synced into `AutocompleteContext`, which
//  the standard `Autocomplete.Toolbar` renders, and suggestions marked
//  `.autocorrect` are auto-applied by `KeyboardAction.StandardActionHandler`
//  when the user types a word/sentence delimiter (space etc.).
//
//  All session logic (context/current-word parsing, the ≥2-char gate,
//  word-commit detection feeding the language posterior) lives in
//  `TypeEngine.TypingSession`, shared verbatim with the macOS `type-repl`
//  harness — this file only owns threading, artifact bootstrap, and the
//  KeyboardKit suggestion mapping.
//
//  Privacy: no networking, no typed content in logs (only timings/counts).
//

import Foundation
import KeyboardKit
import Learning
import LemmaCore
import Lexicon
import TypeEngine

final class BetterKeyboardAutocompleteService: AutocompleteService {

    // MARK: - Threading

    /// All engine access is funneled through this serial queue:
    ///
    /// - `TypingSession`/`TypeEngine` are NOT thread-safe (running language
    ///   posterior + commit detection state), so every call — bootstrap,
    ///   suggestions, commit detection — happens on this one queue.
    /// - Utility QoS keeps the mmap bootstrap and per-keystroke work off the
    ///   main thread. This is the launch-flicker mitigation recorded in
    ///   PLAN.md: `viewDidLoad` only enqueues the loader; no mmap open or
    ///   file I/O ever runs on the main thread.
    private let queue = DispatchQueue(
        label: "is.betterkeyboard.typeengine",
        qos: .utility
    )

    // MARK: - Queue-confined state (touch ONLY on `queue`)

    private var session: TypingSession?
    private var bootstrapFailed = false
    /// Latest known field kind, kept even while the session is still
    /// bootstrapping so it can be applied the moment the session exists.
    private var fieldKind: FieldKind = .standard

    // Personal learning (M2). All nil/absent when the App Group container
    // is unavailable (Full Access denied, simulator oddities): the engine
    // then runs with no personal model and no event logging — never a crash.
    private let appGroupId: String?
    private var engine: TypeEngine?
    private var personalModelURL: URL?
    private var eventLogURL: URL?
    /// mtime of the personal-model file at the last (re)load, so the
    /// viewWillAppear re-stat only re-reads a genuinely changed file.
    private var personalModelDate: Date?

    // MARK: - Cross-queue fast path (lock-guarded, NOT queue-confined)

    /// Mirror of `session.hasPendingContinuationRevert`, updated on `queue`
    /// after every autocomplete pass and read from the main thread by the
    /// action handler, so the per-keystroke revert consult can skip the
    /// queue round-trip on the overwhelmingly common keystrokes where no
    /// '.'-replacement memo exists.
    private let revertMemoLock = NSLock()
    private var revertMemoArmed = false
    private var attachmentMemoArmed = false

    /// Cached spacebar behavior mode (PLAN.md "Spacebar behavior — three
    /// user-selectable modes"). Written from the controller on the main
    /// thread (`viewWillAppear`, and once at init) and read from BOTH the
    /// engine `queue` (the mode-3 autocorrect demotion in
    /// `performAutocomplete`) and the main thread (the mode-2 space
    /// interception in `BetterKeyboardActionHandler`), so it lives under the
    /// same lightweight lock as the revert/attachment memos rather than being
    /// confined to a single thread. Defaults to mode 1 — the M1 behavior —
    /// until the first read of the App Group suite (which may be unavailable
    /// without Full Access; see `SpacebarMode.current`).
    private var _spacebarMode: SpacebarMode = .completeCurrentWord

    private func setRevertMemoArmed(_ armed: Bool) {
        revertMemoLock.lock()
        revertMemoArmed = armed
        revertMemoLock.unlock()
    }

    private var isRevertMemoArmed: Bool {
        revertMemoLock.lock()
        defer { revertMemoLock.unlock() }
        return revertMemoArmed
    }

    private func setAttachmentMemoArmed(_ armed: Bool) {
        revertMemoLock.lock()
        attachmentMemoArmed = armed
        revertMemoLock.unlock()
    }

    private var isAttachmentMemoArmed: Bool {
        revertMemoLock.lock()
        defer { revertMemoLock.unlock() }
        return attachmentMemoArmed
    }

    /// The user's current spacebar behavior (PLAN.md "Spacebar behavior").
    /// Read by the mode-3 bridge on `queue` and by the mode-2 action handler
    /// on the main thread.
    var spacebarMode: SpacebarMode {
        revertMemoLock.lock()
        defer { revertMemoLock.unlock() }
        return _spacebarMode
    }

    /// Re-read the spacebar mode from the App Group suite and cache it.
    /// Called once at init and again on every `viewWillAppear` so a change
    /// made in the containing app's settings screen (a different process)
    /// takes effect the next time the keyboard is presented, without needing
    /// KVO on a cross-process `UserDefaults`. Cheap (one suite read).
    func refreshSpacebarMode() {
        let mode = SpacebarMode.current(appGroupId: appGroupId)
        revertMemoLock.lock()
        _spacebarMode = mode
        revertMemoLock.unlock()
    }

    // MARK: - Constants

    /// `additionalInfo` key carrying the pending token a suggestion
    /// replaces. `BetterKeyboardActionHandler` uses it to (a) allow the
    /// deferred '.'-apply even though KeyboardKit considers the cursor "at
    /// a new word" after the dot, and (b) verify against the live proxy
    /// text that the suggestion is not stale before applying.
    static let pendingTokenInfoKey = "is.betterkeyboard.pendingToken"

    /// Filenames inside the App Group container. MUST match the app-side
    /// constants in `App/AppModel.swift` (`personalModelFileName` /
    /// `learningEventLogFileName`) — the extension appends events to the
    /// log and reads the model; the app compacts the log into the model.
    static let personalModelFileName = "personal-model.json"
    static let learningEventLogFileName = "learning-events.log"

    // MARK: - Init

    /// - Parameter appGroupId: the shared App Group
    ///   (`KeyboardApp.betterKeyboard.appGroupId`, "group.is.lyklabord");
    ///   nil disables personal learning entirely (tests).
    init(appGroupId: String? = nil) {
        self.appGroupId = appGroupId
        // Seed the spacebar mode from the App Group suite before the first
        // keystroke (cheap; independent of the engine bootstrap). Re-read on
        // every viewWillAppear via `refreshSpacebarMode()`.
        refreshSpacebarMode()
        // Kick the bootstrap immediately (but asynchronously, off-main) so
        // the engine is usually ready by the first keystroke. Until it is,
        // `autocomplete(_:)` just returns empty suggestions.
        queue.async { [weak self] in
            self?.bootstrapIfNeeded()
        }
    }

    // MARK: - AutocompleteService

    /// Single Icelandic layout; mixed IS/EN typing is handled inside
    /// TypeEngine's bilingual blender, not via locale switching.
    var locale: Locale = .init(identifier: "is")

    func autocomplete(_ text: String) async throws -> Autocomplete.ServiceResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    return continuation.resume(
                        returning: .init(inputText: text, suggestions: [])
                    )
                }
                continuation.resume(returning: self.performAutocomplete(text))
            }
        }
    }

    /// Forward a host text/selection change (`textDidChange` /
    /// `selectionDidChange` on the controller) to the typing session, so
    /// cursor jumps and host-app mutations never masquerade as word commits.
    /// Safe to call for changes caused by our own insertions too: the
    /// session's window-aware note is idempotent — it ignores any window
    /// that is a valid typing evolution of its own last-seen state and only
    /// resets on genuinely inconsistent windows (the session also detects
    /// most external changes internally; this is belt-and-braces).
    func noteTextContextChange(_ textBeforeCursor: String) {
        queue.async { [weak self] in
            self?.session?.noteExternalTextChange(window: textBeforeCursor)
        }
    }

    /// Update the field-type gate (PLAN.md verbatim/URL layer 2): in
    /// URL/email/web-search fields the session strips `isAutocorrect` from
    /// every suggestion (they stay available, tap-only). Forwarded by the
    /// controller whenever the host field/context changes.
    func updateFieldKind(_ kind: FieldKind) {
        queue.async { [weak self] in
            guard let self else { return }
            // Flush BEFORE the kind changes: any buffered events were
            // gated under the field they were typed in; flushing them under
            // a later (possibly sensitive) field kind would trip the
            // privacy assertion for events that are actually legitimate.
            self.flushLearningEventsOnQueue()
            self.fieldKind = kind
            self.session?.fieldKind = kind
        }
    }

    /// Re-stat the personal-model file and reload the engine's snapshot if
    /// it changed (the app compacts on its own schedule). Called from the
    /// controller's `viewWillAppear` — one stat per keyboard presentation.
    func refreshPersonalSnapshotIfNeeded() {
        queue.async { [weak self] in
            self?.reloadPersonalSnapshotIfChanged()
        }
    }

    /// Flush any buffered learning events (e.g. from `viewWillDisappear`,
    /// so a verbatim tap right before dismissal isn't lost).
    func flushPendingLearningEvents() {
        queue.async { [weak self] in
            self?.flushLearningEventsOnQueue()
        }
    }

    /// The user tapped the verbatim (quoted `.unknown`) suggestion:
    /// remember the choice so an immediately following delimiter cannot
    /// re-correct the token (layer 1 escape hatch). Forwarded by
    /// `BetterKeyboardActionHandler.handle(_ suggestion:)`.
    func noteVerbatimChoice(_ token: String) {
        queue.async { [weak self] in
            self?.session?.noteVerbatimChoice(token)
        }
    }

    /// Revert-on-continuation decision (layer 4 fallback), consulted by
    /// `BetterKeyboardActionHandler` BEFORE a letter/digit keystroke is
    /// inserted: when the previous keystroke was a '.' that auto-replaced
    /// the pending token, the returned proxy edit undoes the replacement so
    /// URLs/domains self-heal. Synchronous by necessity (the keystroke
    /// cannot proceed until the decision is known), but gated on the
    /// lock-guarded memo flag so ordinary keystrokes never block on the
    /// engine queue.
    func pendingContinuationRevert(for character: Character) -> RevertInstruction? {
        guard isRevertMemoArmed else { return nil }
        return queue.sync {
            defer { setRevertMemoArmed(session?.hasPendingContinuationRevert == true) }
            return session?.continuationRevert(for: character)
        }
    }

    /// Punctuation-attachment decision ("word . " → "word. "), consulted by
    /// `BetterKeyboardActionHandler` BEFORE a keystroke is inserted — same
    /// synchronous memo-gated pattern as `pendingContinuationRevert`: the
    /// lock-guarded armed flag keeps ordinary keystrokes off the engine
    /// queue; the session consumes or discards the memo per keystroke
    /// (space attaches, anything else discards — ".net" survives).
    func pendingPunctuationAttachment(for character: Character) -> RevertInstruction? {
        guard isAttachmentMemoArmed else { return nil }
        return queue.sync {
            defer { setAttachmentMemoArmed(session?.hasPendingPunctuationAttachment == true) }
            return session?.punctuationAttachment(for: character)
        }
    }

    // MARK: - Word learning (M2)

    // KeyboardKit's `StandardActionHandler.tryAutolearnSuggestion` calls
    // `learn(suggestion)` → `learnWord(text)` when a tapped suggestion
    // `isUnknown` — i.e. exactly our verbatim escape-hatch slot — gated on
    // `AutocompleteSettings.isAutolearnEnabled` (enabled in
    // KeyboardViewController.viewDidLoad). Our own action handler ALSO
    // forwards the tap via `noteVerbatimChoice`; the session deduplicates
    // the two signals into one wordTapped event + one session-learn.
    var canLearnWords: Bool { true }

    func learnWord(_ word: String) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            session.learnWordImmediately(word)
            self.flushLearningEventsOnQueue()
        }
    }

    /// Deliberate no-op (documented decision, M2 wave 2): un-learning is
    /// deletion, and deletion must tombstone — a durable, synced user
    /// decision that lives in the containing app's dictionary editor
    /// (`PersonalModel.remove(word:)`), not in a keyboard-side callback.
    /// The event log has no tombstone event by design (the extension can
    /// only ever ADD evidence); KeyboardKit never calls this from any UI we
    /// ship, so a silent no-op is safe.
    func unlearnWord(_ word: String) {}

    // The learned-word listing lives in the app's dictionary editor (the
    // PersonalModel is the source of truth); KeyboardKit never renders
    // these in our setup, and answering would require a cross-queue hop.
    var learnedWords: [String] { [] }
    func hasLearnedWord(_ word: String) -> Bool { false }

    // Word ignoring stays off: our conservatism rules (valid words are
    // never auto-replaced; tombstones live in the app) cover its purpose.
    var canIgnoreWords: Bool { false }
    var ignoredWords: [String] { [] }
    func hasIgnoredWord(_ word: String) -> Bool { false }
    func ignoreWord(_ word: String) {}
    func removeIgnoredWord(_ word: String) {}

    // MARK: - Bootstrap (on `queue`)

    /// Open the language artifacts from the extension bundle and build the
    /// engine. mmap-backed (`.alwaysMapped`) — file pages are clean/lazily
    /// paged, so this is fast (~1ms per artifact) and nearly free against
    /// the extension's dirty-memory jetsam cap (see data/README.md).
    private func bootstrapIfNeeded() {
        guard session == nil, !bootstrapFailed else { return }
        let bundle = Bundle(for: Self.self)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            guard
                let enURL = bundle.url(forResource: "en", withExtension: "lex"),
                let isURL = bundle.url(forResource: "is", withExtension: "lex")
            else {
                bootstrapFailed = true
                NSLog("[better-keyboard] autocomplete bootstrap FAILED: .lex artifacts missing from extension bundle")
                return
            }
            let english = try FrequencyLexicon(contentsOf: enURL)
            let icelandic = try FrequencyLexicon(contentsOf: isURL)

            // BÍN morphology is optional for the engine; degrade gracefully
            // (frequency-only validation) if the binary is missing/corrupt.
            var morphology: BinaryLemmatizer?
            if let binURL = bundle.url(forResource: "lemma-is", withExtension: "bin") {
                morphology = try? BinaryLemmatizer(contentsOf: binURL)
                if morphology == nil {
                    NSLog("[better-keyboard] lemma-is.bin failed to load; continuing without morphology")
                }
            } else {
                NSLog("[better-keyboard] lemma-is.bin missing from extension bundle; continuing without morphology")
            }

            let engine = TypeEngine(
                icelandic: icelandic,
                english: english,
                morphology: morphology
            )
            // Touch representative pages of the mmap-ed artifacts (spread
            // unigram/bigram/morphology lookups) so the first real
            // keystrokes don't pay page-fault costs (PLAN.md cold-start
            // quirk). Runs on this queue, before the session is published.
            engine.warmUp()
            self.engine = engine
            // Personal learning (M2): resolve the App Group container and
            // load the personal snapshot. Fully graceful — no container,
            // no model file, or a corrupt file all degrade to a nil
            // snapshot + no event logging.
            setupPersonalLearning()
            let newSession = TypingSession(engine: engine)
            newSession.fieldKind = fieldKind
            session = newSession
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            NSLog(
                "[better-keyboard] TypeEngine ready in %.1f ms (is: %d unigrams, en: %d unigrams, morphology: %@)",
                ms,
                icelandic.unigramCount,
                english.unigramCount,
                morphology == nil ? "off" : "on"
            )
        } catch {
            bootstrapFailed = true
            NSLog("[better-keyboard] autocomplete bootstrap FAILED: %@", String(describing: error))
        }
    }

    // MARK: - Personal learning (on `queue`)

    /// Resolve the App Group container and do the initial snapshot load.
    /// Missing container (Full Access denied / entitlement oddity) leaves
    /// every URL nil: the engine runs personal-model-free and the event
    /// flush becomes a silent drop — no crash, no retry storm.
    private func setupPersonalLearning() {
        guard let appGroupId else { return }
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId
            )
        else {
            NSLog("[better-keyboard] App Group container unavailable; personal learning off")
            return
        }
        personalModelURL = container.appendingPathComponent(Self.personalModelFileName)
        eventLogURL = container.appendingPathComponent(Self.learningEventLogFileName)
        reloadPersonalSnapshotIfChanged()
    }

    /// Stat the model file; (re)load and inject a fresh snapshot when its
    /// mtime differs from the last load. The app writes the file atomically
    /// and the extension loads its own exclusive `PersonalModel` copy, so a
    /// short coordinated read is all the synchronization needed.
    private func reloadPersonalSnapshotIfChanged() {
        guard let engine, let personalModelURL else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: personalModelURL.path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified != personalModelDate else { return }
        personalModelDate = modified
        guard modified != nil else {
            // Model file disappeared (user reset / first run): clear.
            engine.setPersonalVocabulary(nil)
            return
        }
        do {
            let model = try CoordinatedFileAccess.coordinateRead(at: personalModelURL) { url in
                try PersonalModel(contentsOf: url)
            }
            engine.setPersonalVocabulary(PersonalSnapshot(model: model))
            NSLog("[better-keyboard] personal snapshot loaded (%d words)", engine.personalSnapshotWords.count)
        } catch {
            // Corrupt/unreadable model: keep typing, drop personal ranking.
            engine.setPersonalVocabulary(nil)
            NSLog("[better-keyboard] personal model load failed: %@", String(describing: error))
        }
    }

    /// Drain the session's buffered events and append them to the App Group
    /// event log inside ONE short coordinated write. Events only accrue at
    /// word commits / verbatim taps / correction reverts, so this is the
    /// batch-at-word-boundaries flush the EventLog contract requires (never
    /// per keystroke). Failures drop the batch — learning data is
    /// lossy-tolerant by design (CoordinatedFileAccess docs).
    private func flushLearningEventsOnQueue() {
        guard let session, session.hasPendingLearningEvents else { return }
        let events = session.drainLearningEvents()
        guard let eventLogURL else { return }  // no App Group: drop silently
        // Belt-and-braces: the session only buffers in standard fields, so
        // this assertion firing would mean the session-side gate broke.
        LearningPrivacy.assertLoggableFieldContext(
            isSecureTextEntry: fieldKind == .secure,
            isSensitiveKeyboardType: fieldKind == .url || fieldKind == .email
                || fieldKind == .webSearch
        )
        guard fieldKind.allowsLearning else { return }
        do {
            try CoordinatedFileAccess.coordinateWrite(at: eventLogURL) { url in
                try EventLog(url: url).append(contentsOf: events)
            }
        } catch {
            NSLog(
                "[better-keyboard] learning-event flush failed (%d events dropped): %@",
                events.count, String(describing: error)
            )
        }
    }

    // MARK: - Autocomplete (on `queue`)

    private func performAutocomplete(_ text: String) -> Autocomplete.ServiceResult {
        bootstrapIfNeeded()
        // Engine still loading (or permanently failed): stay silent. The
        // toolbar simply shows no suggestions for the first keystroke(s).
        guard let session else {
            return .init(inputText: text, suggestions: [])
        }
        let suggestions = session.suggestions(for: text, limit: 3)
        setRevertMemoArmed(session.hasPendingContinuationRevert)
        setAttachmentMemoArmed(session.hasPendingPunctuationAttachment)
        // Word-commit boundary flush: the pass that detected a commit (or a
        // tap/revert) is the pass whose drain carries those events.
        flushLearningEventsOnQueue()
        let pendingToken = TypingSession.splitCurrentWord(of: text).currentWord
        let mapped = suggestions.map { Self.bridge($0, pendingToken: pendingToken) }
        // Spacebar mode 3 ("always insert a space", PLAN.md "Spacebar
        // behavior"): the bar still shows every suggestion, but nothing may
        // auto-commit on space — so demote every `.autocorrect` to `.regular`
        // (KeyboardKit's own `withAutocorrectEnabled(false)` helper). The
        // action handler's space-commit path (which auto-applies the FIRST
        // `.isAutocorrect` suggestion) then finds none and just inserts a
        // space; corrections apply only when the user taps the bar. Verified
        // against `StandardActionHandler.tryApplyAutocorrectSuggestion`,
        // which keys off the suggestion TYPE — exactly how mode 1 works.
        // Modes 1 and 2 keep the autocorrect type untouched.
        let modeAdjusted = mapped.withAutocorrectEnabled(spacebarMode != .alwaysInsertSpace)
        return .init(inputText: text, suggestions: modeAdjusted)
    }

    /// Map a TypeEngine suggestion onto KeyboardKit's model.
    ///
    /// - `.autocorrect` is what makes the action handler auto-apply the
    ///   suggestion when the user types a word delimiter (space-commit);
    ///   TypeEngine only sets `isAutocorrect` on its top candidate under
    ///   its conservatism rules, so the mapping is direct.
    /// - The verbatim escape-hatch slot maps to `.unknown`, which native
    ///   keyboards (and our toolbar, via the quoted `title`) render quoted.
    /// - `additionalDeleteCount` bridges the token-boundary difference:
    ///   TypeEngine suggestions replace the session's WHOLE pending token
    ///   (which can span dots/'@' — "profilmynd.tilvinstri", "teh."), while
    ///   KeyboardKit's `replaceCurrentWordPreCursorPart` only deletes its
    ///   own current word (which never spans a dot). The extra count covers
    ///   the difference so a tap or a deferred '.'-apply replaces the whole
    ///   token instead of shearing it at the last dot.
    private static func bridge(
        _ suggestion: Suggestion,
        pendingToken: String
    ) -> Autocomplete.Suggestion {
        let kkWordCount = Self.keyboardKitCurrentWord(of: pendingToken).count
        return Autocomplete.Suggestion(
            text: suggestion.text,
            type: suggestion.isVerbatim
                ? .unknown
                : (suggestion.isAutocorrect ? .autocorrect : .regular),
            title: suggestion.isVerbatim
                ? "\u{201C}\(suggestion.text)\u{201D}"
                : suggestion.text,
            additionalDeleteCount: max(pendingToken.count - kkWordCount, 0),
            additionalInfo: [
                "confidence": String(format: "%.3f", suggestion.confidence),
                Self.pendingTokenInfoKey: pendingToken,
            ]
        )
    }

    /// KeyboardKit's view of the current word within our pending token: the
    /// trailing run of non-word-delimiter characters (mirrors
    /// `UITextDocumentProxy.currentWordPreCursorPart` /
    /// `String.wordFragmentAtEnd`, where '.' is always a delimiter).
    private static func keyboardKitCurrentWord(of token: String) -> Substring {
        token.suffix(while: { !"\($0)".isWordDelimiter })
    }
}

private extension String {

    /// Trailing run of characters satisfying `predicate`.
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var start = endIndex
        while start > startIndex {
            let previous = index(before: start)
            guard predicate(self[previous]) else { break }
            start = previous
        }
        return self[start...]
    }
}

// MARK: - Field-kind mapping (UIKit/KeyboardKit → TypeEngine)

extension BetterKeyboardAutocompleteService {

    /// TypeEngine field kind for the active keyboard context, combining
    /// KeyboardKit's own keyboard type with the host field's `UIKeyboardType`
    /// (the same dual sourcing as `KeyboardContext.prefersAutocomplete`,
    /// since many native field types never map to a KeyboardKit type).
    /// Secure text entry wins over everything: password fields must never
    /// autocorrect and never feed learning.
    static func fieldKind(for context: KeyboardContext) -> FieldKind {
        if context.textDocumentProxy.isSecureTextEntry == true {
            return .secure
        }
        switch context.keyboardType {
        case .url: return .url
        case .email: return .email
        case .webSearch: return .webSearch
        default: break
        }
        switch context.textDocumentProxy.keyboardType {
        case .URL?: return .url
        case .emailAddress?: return .email
        case .webSearch?: return .webSearch
        default: return .standard
        }
    }
}
