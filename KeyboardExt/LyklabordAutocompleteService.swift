//
//  LyklabordAutocompleteService.swift
//  LyklabordKeyboard
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
import os
import TypeEngine

final class LyklabordAutocompleteService: AutocompleteService {

    // MARK: - Cold-start observability

    /// Privacy-safe, device-inspectable launch milestones. These events carry
    /// no document-proxy text or suggestion content: they exist solely to
    /// answer whether a cold extension launch reaches a usable engine before
    /// the user begins typing. Inspect with Instruments' Points of Interest
    /// or Console, filtered to this subsystem/category.
    private static let coldStartSignposter = OSSignposter(
        subsystem: "is.solberg.lyklabord",
        category: "AutocompleteColdStart"
    )
    private static let coldStartLogger = Logger(
        subsystem: "is.solberg.lyklabord",
        category: "AutocompleteColdStart"
    )
    /// App Group metadata reads that do not belong on either the UI thread or
    /// the latency-sensitive engine queue. These are auxiliary settings/dev-
    /// recorder concerns; base typing starts with safe defaults while they
    /// resolve.
    private static let auxiliaryStateQueue = DispatchQueue(
        label: "is.solberg.lyklabord.auxiliary-state",
        qos: .utility
    )

    /// Captured before the bootstrap is enqueued. `init` is intentionally
    /// tiny and runs from `viewDidLoad`; all subsequent expensive work is
    /// measured from this point but remains on the engine queue.
    private let serviceCreatedAt: TimeInterval
    private let coldStartTracker: AutocompleteColdStartTracker
    private let coldStartRecorder: AutocompleteColdStartRecorder

    // MARK: - Threading

    /// All engine access is funneled through this serial queue:
    ///
    /// - `TypingSession`/`TypeEngine` are NOT thread-safe (running language
    ///   posterior + commit detection state), so every call — bootstrap,
    ///   suggestions, commit detection — happens on this one queue.
    /// - User-initiated QoS keeps mmap bootstrap and, crucially, active
    ///   keystrokes responsive under system contention. The queue is still
    ///   fully off-main: `viewDidLoad` only enqueues the loader, so no mmap
    ///   open or file I/O ever runs on the UI thread. `.utility` was a poor
    ///   fit here because it also governed work the user is actively waiting
    ///   to see in the suggestion bar.
    private let queue = DispatchQueue(
        label: "is.solberg.lyklabord.typeengine",
        qos: .userInitiated
    )

    // MARK: - Queue-confined state (touch ONLY on `queue`)

    private var session: TypingSession?
    private var bootstrapFailed = false
    /// One-shot cold-start telemetry state, confined to `queue`.
    private var hasRecordedFirstAutocompletePass = false
    private var hasRecordedFirstStableNonEmptyResult = false
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

    /// DEV-MODE typing-session recorder (see `SessionRecorder`). Confined to
    /// this `queue` exactly like `session`. OFF by default: a single App Group
    /// flag check per pass gates everything; the learning event log and the
    /// personal model are completely unaffected by it. nil-safe when there is
    /// no App Group container.
    private var recorder: SessionRecorder?
    /// mtime of the personal-model file at the last (re)load, so the
    /// viewWillAppear re-stat only re-reads a genuinely changed file.
    private var personalModelDate: Date?
    /// Lyklaborð+ entitlement observed at the last snapshot decision, so an
    /// entitlement flip (app-side purchase/expiry between presentations)
    /// forces a reload/clear even when the model file's mtime is unchanged.
    private var personalLayerEntitled: Bool?
    /// Always-on curated supplementary vocabulary ("head of the long tail":
    /// brands, tech, anglicisms, colloquial — ChatGPT, TikTok, deploya, Bónus).
    /// Loaded once from the bundled `extra-vocab.txt`; free base vocabulary,
    /// NOT gated behind Lyklaborð+, so it's composited into every personal
    /// snapshot (and injected alone when the personal layer is off). Nil only
    /// if the resource is missing, in which case the engine runs unchanged.
    private var curatedVocabulary: CuratedVocabulary?

    // MARK: - Cross-queue fast path (lock-guarded, NOT queue-confined)

    /// Mirror of `session.hasPendingContinuationRevert`, updated on `queue`
    /// after every autocomplete pass and read from the main thread by the
    /// action handler, so the per-keystroke revert consult can skip the
    /// queue round-trip on the overwhelmingly common keystrokes where no
    /// '.'-replacement memo exists.
    private let revertMemoLock = NSLock()
    private var revertMemoArmed = false
    private var attachmentMemoArmed = false
    /// Mirror of `session.hasArmedLiteralRevert` (wave 36): true while the
    /// reserved literal-revert slot leads the bar, so the action handler can
    /// route a tap on the `.unknown` slot to the revert path synchronously
    /// without a queue round-trip on the vastly common case where no such
    /// slot exists. Same lock as the revert/attachment memos.
    private var literalRevertArmed = false

    /// Cached spacebar behavior mode (PLAN.md "Spacebar behavior — three
    /// user-selectable modes"). Written from the controller on the main
    /// thread (`viewWillAppear`, and once at init) and read from BOTH the
    /// engine `queue` (the mode-3 autocorrect demotion in
    /// `performAutocomplete`) and the main thread (the mode-2 space
    /// interception in `LyklabordActionHandler`), so it lives under the
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

    private func setLiteralRevertArmed(_ armed: Bool) {
        revertMemoLock.lock()
        literalRevertArmed = armed
        revertMemoLock.unlock()
    }

    private var isLiteralRevertArmed: Bool {
        revertMemoLock.lock()
        defer { revertMemoLock.unlock() }
        return literalRevertArmed
    }

    // MARK: - Request sequencing (lock-guarded, NOT queue-confined)

    /// Monotonic request/delivery stamp (wave #28). This exact primitive is
    /// also driven by Wave 41's timed headless last-mile gate, so the replay
    /// exercises production sequencing rather than a second approximation.
    private let requestSequencer = AutocompleteRequestSequencer()

    /// The user's current spacebar behavior (PLAN.md "Spacebar behavior").
    /// Read by the mode-3 bridge on `queue` and by the mode-2 action handler
    /// on the main thread.
    var spacebarMode: SpacebarMode {
        revertMemoLock.lock()
        defer { revertMemoLock.unlock() }
        return _spacebarMode
    }

    /// Re-read the spacebar mode from the App Group suite off-main and cache
    /// it. Mode 1 is the immediate safe default until the auxiliary read
    /// finishes. Called once at init and again on every `viewWillAppear` so a
    /// change made in the containing app's settings screen (a different
    /// process) takes effect without synchronous cross-process defaults work
    /// on the keyboard's UI thread.
    func refreshSpacebarMode() {
        let appGroupId = appGroupId
        Self.auxiliaryStateQueue.async { [weak self] in
            let mode = SpacebarMode.current(appGroupId: appGroupId)
            self?.setSpacebarMode(mode)
        }
    }

    private func setSpacebarMode(_ mode: SpacebarMode) {
        revertMemoLock.lock()
        _spacebarMode = mode
        revertMemoLock.unlock()
    }

    // MARK: - Constants

    /// `additionalInfo` key carrying the pending token a suggestion
    /// replaces. `LyklabordActionHandler` uses it to (a) allow the
    /// deferred '.'-apply even though KeyboardKit considers the cursor "at
    /// a new word" after the dot, and (b) verify against the live proxy
    /// text that the suggestion is not stale before applying.
    static let pendingTokenInfoKey = "is.solberg.lyklabord.pendingToken"

    /// Filenames inside the App Group container. MUST match the app-side
    /// constants in `App/AppModel.swift` (`personalModelFileName` /
    /// `learningEventLogFileName`) — the extension appends events to the
    /// log and reads the model; the app compacts the log into the model.
    static let personalModelFileName = "personal-model.json"
    static let learningEventLogFileName = "learning-events.log"

    // MARK: - Init

    /// - Parameter appGroupId: the shared App Group
    ///   (`KeyboardApp.lyklabord.appGroupId`, "group.is.solberg.lyklabord");
    ///   nil disables personal learning entirely (tests).
    init(appGroupId: String? = nil, activationStartedAt: TimeInterval? = nil) {
        let createdAt = AutocompleteColdStartTracker.now
        self.serviceCreatedAt = createdAt
        self.coldStartTracker = AutocompleteColdStartTracker(
            serviceCreatedAt: createdAt,
            activationStartedAt: activationStartedAt,
            processServiceOrdinal: AutocompleteColdStartTracker.nextProcessServiceOrdinal()
        )
        self.coldStartRecorder = AutocompleteColdStartRecorder(appGroupId: appGroupId)
        self.appGroupId = appGroupId
        self.recorder = nil
        // Kick the bootstrap immediately (but asynchronously, off-main) so
        // the engine is usually ready by the first keystroke. Requests are
        // serialized behind this block and measured as cold backlog.
        Self.coldStartSignposter.emitEvent("Bootstrap queued")
        Self.coldStartLogger.notice("Autocomplete bootstrap queued")
        queue.async { [weak self] in
            self?.bootstrapIfNeeded()
        }
        // Neither concern is needed to construct the base engine. Resolve
        // their App Group state away from the UI and engine queues; the dev
        // recorder remains inert until preparation finishes.
        refreshSpacebarMode()
        prepareSessionRecorder()
    }

    private func prepareSessionRecorder() {
        let appGroupId = appGroupId
        Self.auxiliaryStateQueue.async { [weak self] in
            let recorder = SessionRecorder(appGroupId: appGroupId)
            self?.queue.async { [weak self] in
                self?.recorder = recorder
            }
        }
    }

    // MARK: - AutocompleteService

    /// Single Icelandic layout; mixed IS/EN typing is handled inside
    /// TypeEngine's bilingual blender, not via locale switching.
    var locale: Locale = .init(identifier: "is")

    func autocomplete(_ text: String) async throws -> Autocomplete.ServiceResult {
        // Delivery-side staleness drop (wave #28, defense in depth behind
        // the apply-time token guard in `LyklabordActionHandler`):
        // KeyboardKit spawns one unstructured Task per request, so an older
        // result can reach the main-actor `autocompleteContext` after a
        // newer one. Sequence-stamp the request now; at publish time a
        // result superseded by a newer request for DIFFERENT input text is
        // returned `isOutdated`, which `AutocompleteContext.update` drops
        // without clearing the bar. The engine pass itself still runs —
        // `TypingSession` must observe every window in order; only the
        // publish is suppressed.
        let ticket = requestSequencer.accept(text: text)
        coldStartTracker.requestAccepted(generation: ticket.generation)
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    return continuation.resume(
                        returning: .init(inputText: text, suggestions: [])
                    )
                }
                let result = self.performAutocomplete(text)
                let superseded = self.requestSequencer.isSuperseded(ticket)
                if !self.hasRecordedFirstStableNonEmptyResult,
                    !superseded,
                    !result.suggestions.isEmpty
                {
                    self.hasRecordedFirstStableNonEmptyResult = true
                    let elapsedMs = (AutocompleteColdStartTracker.now - self.serviceCreatedAt) * 1000
                    Self.coldStartSignposter.emitEvent("First stable non-empty result")
                    Self.coldStartLogger.notice(
                        "First stable non-empty autocomplete result completed \(elapsedMs, format: .fixed(precision: 1)) ms after service creation"
                    )
                }
                if let metrics = self.coldStartTracker.requestCompleted(
                    generation: ticket.generation,
                    wasSuperseded: superseded,
                    hadNonEmptySuggestions: !result.suggestions.isEmpty
                ) {
                    self.coldStartRecorder.record(metrics)
                }
                continuation.resume(
                    returning: superseded
                        ? .init(
                            inputText: result.inputText,
                            suggestions: result.suggestions,
                            emojiSuggestions: result.emojiSuggestions,
                            nextCharacterPredictions: result.nextCharacterPredictions,
                            isOutdated: true
                        )
                        : result
                )
            }
        }
    }

    /// Record one self-caused proxy edit into the session's proxy-edit
    /// ledger (azooKey expected-edit pattern, research/oss-harvest.md §2):
    /// `before`/`after` are `documentContextBeforeInput` snapshotted around
    /// the proxy mutation(s) of one action-handler `handle` call — see
    /// `LyklabordActionHandler`. MUST be enqueued before the
    /// autocomplete pass that observes the edit; the action handler records
    /// from its `tryPerformAutocomplete` override, which runs before
    /// KeyboardKit's `service.autocomplete` Task can enqueue onto `queue`,
    /// so the serial queue guarantees the order. (If an observation ever
    /// beats its record onto the queue, the session retro-drops the late
    /// record — degraded to heuristics for that keystroke, never wedged.)
    func noteSelfEdit(before: String, after: String) {
        guard before != after else { return }  // nothing was edited
        queue.async { [weak self] in
            self?.session?.noteSelfEdit(before: before, after: after)
        }
    }

    /// Forward a host text/selection change (`textDidChange` /
    /// `selectionDidChange` on the controller) to the typing session, so
    /// cursor jumps and host-app mutations never masquerade as word commits.
    /// Safe to call for changes caused by our own insertions too: the
    /// session's window-aware note is idempotent — it ignores windows
    /// explained by the proxy-edit ledger (without consuming the
    /// expectation) or consistent with its own last-seen state, and only
    /// resets on genuinely inconsistent windows (the session detects
    /// external changes exactly via the ledger; this is belt-and-braces).
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

    /// Per-keystroke coordinate forwarding (PLAN.md "Touch decoding",
    /// stage 1): the action handler sends each released character with its
    /// within-key normalized touch offsets (−0.5…+0.5 at the touch-cell
    /// edges, x right / y down — the ReplayRig TSI convention); the session
    /// aligns them with the pending word on the engine queue and the
    /// corrector prices substitutions from the actual tap points. O(1) on
    /// the caller's thread: one value capture + one queue enqueue, no
    /// allocation beyond the block.
    func noteKeyTap(_ character: Character, dx: Double, dy: Double) {
        queue.async { [weak self] in
            self?.session?.noteTap(char: character, dx: dx, dy: dy)
            // DEV-MODE recorder: no-op unless a session is armed (cached bool).
            self?.recorder?.captureTap(char: character, dx: dx, dy: dy)
        }
    }

    /// DEV-MODE recorder: buffer a backspace (forwarded from the action
    /// handler's `.backspace` release). No-op unless a session is armed.
    func noteRecordedBackspace() {
        queue.async { [weak self] in
            self?.recorder?.captureBackspace()
        }
    }

    /// DEV-MODE recorder: an autocorrect suggestion is about to be applied by
    /// the action handler (space-commit / deferred-dot). No-op unless armed.
    func noteRecordedAutocorrectApplied(_ text: String) {
        queue.async { [weak self] in
            self?.recorder?.captureApplied(.autocorrect(text))
        }
    }

    /// DEV-MODE recorder: the apply-time staleness guard SKIPPED an armed
    /// autocorrect (its recorded pending token no longer matched the live
    /// proxy token — wave #28). Recorded distinctly so the session analyzer
    /// can count how often the guard fires in the wild. No-op unless armed.
    func noteRecordedStaleAutocorrectSkip(_ text: String) {
        queue.async { [weak self] in
            self?.recorder?.captureApplied(.staleSkip(text))
        }
    }

    /// DEV-MODE recorder: the user tapped a suggestion in the bar. No-op
    /// unless a session is armed.
    func noteRecordedSuggestionTap(_ text: String) {
        queue.async { [weak self] in
            self?.recorder?.captureApplied(.suggestionTap(text))
        }
    }

    /// DEV-MODE recorder: the user tapped the reserved literal-revert slot
    /// (wave 36), swapping an autocorrected word back to the literal. Recorded
    /// as its own applied kind so the analyzer can see reverts distinctly from
    /// ordinary taps and count how often force-corrections get rejected. No-op
    /// unless a session is armed.
    func noteRecordedLiteralRevert(_ text: String) {
        queue.async { [weak self] in
            self?.recorder?.captureApplied(.literalRevert(text))
        }
    }

    /// Callout-selected (long-press) character: the strongest
    /// deliberateness signal (lane-relaxation triple gate part 3a — the
    /// session vetoes accent folding for the pending word and never
    /// auto-applies a candidate that drops the character). Forwarded by
    /// `LyklabordActionHandler` when the vendored fork marks the
    /// release as a callout selection; such characters carry NO tap sample
    /// (the finger's location belongs to the base key's gesture).
    func noteLongPressInsertion(_ character: Character) {
        queue.async { [weak self] in
            self?.session?.noteLongPressInsertion(character)
        }
    }

    /// The user tapped the verbatim (quoted `.unknown`) suggestion:
    /// remember the choice so an immediately following delimiter cannot
    /// re-correct the token (layer 1 escape hatch). Forwarded by
    /// `LyklabordActionHandler.handle(_ suggestion:)`.
    func noteVerbatimChoice(_ token: String) {
        queue.async { [weak self] in
            self?.session?.noteVerbatimChoice(token)
        }
    }

    /// Literal-revert tap (wave 36, the iOS "revert autocorrect" escape
    /// hatch): the user tapped the reserved left slot to swap an
    /// autocorrected word back to the byte-exact literal they typed. Returns
    /// true when this `.unknown` tap WAS the armed literal-revert slot (so the
    /// action handler logs it distinctly and skips the verbatim-choice/learn
    /// path); false for the ordinary verbatim escape-hatch slot, which the
    /// caller then handles as before. Synchronous by necessity (the tap's
    /// proxy edit is about to run), gated on the lock-guarded armed flag so
    /// the vastly common tap never blocks on the engine queue. The proxy edit
    /// (delete corrected, insert literal + space) is KeyboardKit's, wrapped by
    /// the action handler's ledger snapshot — so the revert is attributed as a
    /// self-edit, never misread as external or as an engine correction.
    func noteLiteralRevertChoice(_ token: String) -> Bool {
        guard isLiteralRevertArmed else { return false }
        return queue.sync {
            defer { setLiteralRevertArmed(session?.hasArmedLiteralRevert == true) }
            return session?.revertToLiteral(matching: token) ?? false
        }
    }

    /// Revert-on-continuation decision (layer 4 fallback), consulted by
    /// `LyklabordActionHandler` BEFORE a letter/digit keystroke is
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
    /// `LyklabordActionHandler` BEFORE a keystroke is inserted — same
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

    /// Running Icelandic-lane belief (P(IS) ≥ 0.5), for smart-punctuation
    /// gating (D1): Icelandic quotes „ " only fire in the Icelandic lane, so
    /// English passages keep straight/English quotes. Synchronous queue read —
    /// fine for the infrequent quote/comma keystrokes it gates; defaults to
    /// Icelandic (this is an Icelandic keyboard) when there's no session yet.
    var isIcelandicLane: Bool {
        queue.sync { (session?.probabilityIcelandic ?? 1.0) >= 0.5 }
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

    /// Deliberate no-op (documented decision, M2 wave 2): KeyboardKit's own
    /// `unlearnWord` hook is never called from any UI we ship. Deliberate
    /// keyboard-side removal now has its own explicit path — `ejectPersonalWord`
    /// (wave 37, the long-press eject affordance) — which tombstones via
    /// `PersonalModel.remove(word:)` exactly like the app's dictionary editor.
    func unlearnWord(_ word: String) {}

    /// Long-press eject (wave 37 — "tap teaches, long-press forgets"): the
    /// user long-pressed a bar suggestion that is their OWN learned personal
    /// vocabulary and confirmed removal. Tombstone it through the SAME
    /// `PersonalModel.remove(word:)` path the app's dictionary editor uses,
    /// persist the model, and refresh the engine's personal snapshot so the
    /// word disappears from the bar immediately and never silently relearns
    /// (tombstones stick — existing `remove` behavior). Local App Group file
    /// mutation only: no network, no new entitlement (extension privacy
    /// doctrine intact). No-op without an entitled, resolvable personal-model
    /// file — there is nothing to remove.
    func ejectPersonalWord(_ word: String) {
        queue.async { [weak self] in
            self?.ejectPersonalWordOnQueue(word)
        }
    }

    private func ejectPersonalWordOnQueue(_ word: String) {
        guard let engine, let personalModelURL else { return }
        // Same gate as the snapshot load: only touch the personal store when
        // the personal layer is entitled (DEBUG always is).
        guard Self.isPlusEntitled(appGroupId: appGroupId) else { return }
        do {
            // Coordinated read-modify-write on the model file: load the app-
            // owned model, tombstone the word, save atomically. The model is
            // app-owned (the app writes it with a plain atomic save), so this
            // is best-effort coordination against a concurrent app compaction
            // — a lost tombstone would merely let the word return, never a
            // crash. The removal itself is `PersonalModel.remove`, byte-for-
            // byte the dictionary editor's deletion (drops counts + bigrams,
            // inserts a permanent tombstone).
            let model = try CoordinatedFileAccess.coordinateWrite(
                at: personalModelURL
            ) { url -> PersonalModel in
                let model =
                    FileManager.default.fileExists(atPath: url.path)
                    ? try PersonalModel(contentsOf: url)
                    : PersonalModel()
                model.remove(word: word)
                try model.save(to: url)
                return model
            }
            // Immediate snapshot refresh so the ejected word leaves the bar
            // now. Forget any in-session overlay copy first (a word taught by
            // a verbatim tap earlier this session lives in the overlay, which
            // is not tombstone-aware), THEN inject the freshly-tombstoned
            // model as the new snapshot.
            engine.forgetSessionWord(word)
            engine.setPersonalVocabulary(
                combinedVocabulary(personal: PersonalSnapshot(model: model))
            )
            // Keep the mtime cache honest so the next viewWillAppear re-stat
            // does not needlessly reload a file we already reflect in memory.
            personalModelDate =
                (try? FileManager.default.attributesOfItem(
                    atPath: personalModelURL.path))?[.modificationDate] as? Date
            NSLog("[LyklaborÃ°] ejected personal word (tombstoned)")
        } catch {
            NSLog(
                "[LyklaborÃ°] personal eject failed: %@",
                String(describing: error))
        }
    }

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
        let start = AutocompleteColdStartTracker.now
        coldStartTracker.bootstrapStarted(at: start)
        let queueDelayMs = (start - serviceCreatedAt) * 1000
        Self.coldStartSignposter.emitEvent("Bootstrap started")
        Self.coldStartLogger.notice(
            "Autocomplete bootstrap started \(queueDelayMs, format: .fixed(precision: 1)) ms after service creation"
        )
        do {
            guard
                let enURL = bundle.url(forResource: "en", withExtension: "lex"),
                let isURL = bundle.url(forResource: "is", withExtension: "lex")
            else {
                bootstrapFailed = true
                NSLog("[LyklaborÃ°] autocomplete bootstrap FAILED: .lex artifacts missing from extension bundle")
                return
            }
            let english = try FrequencyLexicon(contentsOf: enURL)
            let icelandic = try FrequencyLexicon(contentsOf: isURL)
            let englishCalibration = bundle.url(
                forResource: "en-calibration", withExtension: "json"
            ).flatMap { try? LexiconCalibrationProfile(contentsOf: $0) }
            let icelandicCalibration = bundle.url(
                forResource: "is-calibration", withExtension: "json"
            ).flatMap { try? LexiconCalibrationProfile(contentsOf: $0) }

            // BÍN morphology is optional for the engine; degrade gracefully
            // (frequency-only validation) if the binary is missing/corrupt.
            var morphology: BinaryLemmatizer?
            if let binURL = bundle.url(forResource: "lemma-is", withExtension: "bin") {
                morphology = try? BinaryLemmatizer(contentsOf: binURL)
                if morphology == nil {
                    NSLog("[LyklaborÃ°] bin-morph.bin failed to load; continuing without morphology")
                }
            } else {
                NSLog("[LyklaborÃ°] bin-morph.bin missing from extension bundle; continuing without morphology")
            }

            let engine = TypeEngine(
                icelandic: icelandic,
                english: english,
                morphology: morphology,
                icelandicCalibration: icelandicCalibration,
                englishCalibration: englishCalibration
            )
            // Touch representative pages of the mmap-ed artifacts (spread
            // unigram/bigram/morphology lookups) so the first real
            // keystrokes don't pay page-fault costs (PLAN.md cold-start
            // quirk). Runs on this queue, before the session is published.
            engine.warmUp()
            self.engine = engine
            // Curated supplementary vocabulary (free base "head of the long
            // tail"): load once from the bundled resource and inject it as the
            // baseline personal vocabulary. This runs BEFORE personal-learning
            // setup so the curated layer is present even when the App Group /
            // personal model is unavailable; `reloadPersonalSnapshotIfChanged`
            // then composites the user's personal words on top when entitled.
            if let extraURL = bundle.url(forResource: "extra-vocab", withExtension: "txt") {
                curatedVocabulary = CuratedVocabulary(contentsOf: extraURL)
                NSLog("[LyklaborÃ°] curated vocabulary loaded (%d words)", curatedVocabulary?.count ?? 0)
            }
            engine.setPersonalVocabulary(combinedVocabulary(personal: nil))
            // Personal learning (M2): resolve the App Group container and
            // load the personal snapshot. Fully graceful — no container,
            // no model file, or a corrupt file all degrade to a nil
            // snapshot + no event logging.
            setupPersonalLearning()
            let newSession = TypingSession(engine: engine)
            newSession.fieldKind = fieldKind
            session = newSession
            coldStartTracker.engineReady()
            let ms = (AutocompleteColdStartTracker.now - start) * 1000
            let totalMs = (AutocompleteColdStartTracker.now - serviceCreatedAt) * 1000
            Self.coldStartSignposter.emitEvent("Engine ready")
            Self.coldStartLogger.notice(
                "Autocomplete engine ready in \(ms, format: .fixed(precision: 1)) ms (\(totalMs, format: .fixed(precision: 1)) ms from service creation)"
            )
            NSLog(
                "[LyklaborÃ°] TypeEngine ready in %.1f ms (is: %d unigrams, en: %d unigrams, morphology: %@)",
                ms,
                icelandic.unigramCount,
                english.unigramCount,
                morphology == nil ? "off" : "on"
            )
            // Inflection intelligence (Stage B): load the paradigms/governors
            // artifacts AFTER the session is published so the engine is
            // typable immediately; the ~40-150ms governors parse runs off the
            // engine queue and never sits in front of a first keystroke.
            scheduleInflectionLoad()
        } catch {
            bootstrapFailed = true
            Self.coldStartSignposter.emitEvent("Bootstrap failed")
            NSLog("[LyklaborÃ°] autocomplete bootstrap FAILED: %@", String(describing: error))
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
            NSLog("[LyklaborÃ°] App Group container unavailable; personal learning off")
            return
        }
        personalModelURL = container.appendingPathComponent(Self.personalModelFileName)
        eventLogURL = container.appendingPathComponent(Self.learningEventLogFileName)
        reloadPersonalSnapshotIfChanged()
    }

    /// Lyklaborð+ gate (the extension side of the entitlement flow). The
    /// containing app owns StoreKit entirely (this extension has zero
    /// network entitlements, forever) and mirrors the verified entitlement
    /// into the App Group via `Learning.PlusEntitlement`; this is the plain,
    /// honor-system read of that state. Without App Group access (Full
    /// Access denied) the suite is unavailable → not entitled — consistent,
    /// since the personal layer needs the container anyway. DEBUG builds
    /// are always entitled so dogfooding never fights the paywall.
    ///
    /// What the gate switches (and what it does NOT):
    ///   - OFF when unentitled: the personal vocabulary snapshot (no
    ///     personal boosts/surfaces) and the PersonalTouch per-key Gaussians
    ///     (TSI-seeded defaults still apply). With both nil the engine is
    ///     byte-identical to the free path with an empty personal model.
    ///   - STILL ON when unentitled: learning-event WRITES (`EventLog`) —
    ///     the keyboard keeps learning locally, so subscribing later
    ///     inherits the full history instead of starting cold.
    private static func isPlusEntitled(appGroupId: String?) -> Bool {
        #if DEBUG
        return true
        #else
        guard
            let appGroupId,
            let defaults = UserDefaults(suiteName: appGroupId)
        else { return false }
        return PlusEntitlement.read(from: defaults).isEffectivelyEntitled()
        #endif
    }

    /// Combine the always-on curated vocabulary with an optional personal
    /// snapshot into the single `PersonalVocabulary` the engine consumes:
    ///   - curated + personal → `CompositeVocabulary` (both layers)
    ///   - curated only       → curated (personal layer off / not entitled)
    ///   - no curated file     → personal (or nil) — original behavior preserved
    private func combinedVocabulary(personal: PersonalVocabulary?) -> PersonalVocabulary? {
        guard let curated = curatedVocabulary else { return personal }
        guard let personal else { return curated }
        return CompositeVocabulary(curated: curated, personal: personal)
    }

    /// Stat the model file; (re)load and inject a fresh snapshot when its
    /// mtime differs from the last load. The app writes the file atomically
    /// and the extension loads its own exclusive `PersonalModel` copy, so a
    /// short coordinated read is all the synchronization needed.
    ///
    /// Runs the Lyklaborð+ gate first: unentitled ⇒ clear both personal
    /// snapshots and skip the load entirely. Called at bootstrap and on
    /// every keyboard presentation (`viewWillAppear` →
    /// `refreshPersonalSnapshotIfNeeded`), so entitlement changes take
    /// effect the next time the keyboard comes up.
    private func reloadPersonalSnapshotIfChanged() {
        guard let engine, let personalModelURL else { return }
        let entitled = Self.isPlusEntitled(appGroupId: appGroupId)
        if entitled != personalLayerEntitled {
            personalLayerEntitled = entitled
            // Entitlement flipped: invalidate the mtime cache so the load
            // decision below can't be skipped by an unchanged file.
            personalModelDate = nil
        }
        guard entitled else {
            // Personal layer off, but the curated layer stays on (free base).
            engine.setPersonalVocabulary(combinedVocabulary(personal: nil))
            engine.setPersonalTouch(nil)
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: personalModelURL.path)
        let modified = attributes?[.modificationDate] as? Date
        guard modified != personalModelDate else { return }
        personalModelDate = modified
        guard modified != nil else {
            // Model file disappeared (user reset / first run): curated only.
            engine.setPersonalVocabulary(combinedVocabulary(personal: nil))
            engine.setPersonalTouch(nil)
            return
        }
        do {
            let model = try CoordinatedFileAccess.coordinateRead(at: personalModelURL) { url in
                try PersonalModel(contentsOf: url)
            }
            engine.setPersonalVocabulary(
                combinedVocabulary(personal: PersonalSnapshot(model: model))
            )
            // Personal touch model (PLAN.md "Touch decoding", stage 2):
            // extracted from the SAME model load — no extra I/O; it rides
            // this mtime re-stat path for refreshes exactly like the
            // vocabulary snapshot.
            let touch = PersonalTouchSnapshot(model: model)
            engine.setPersonalTouch(touch.isEmpty ? nil : touch)
            // QA-only aggregates (key identities and counts, never typed
            // content): how much adaptive-touch mass this device has and how
            // many keys are past the min-samples gate — the on-device signal
            // that personal Gaussians are (or are not yet) active.
            let eligible = touch.keys.filter {
                (touch.stats(for: $0)?.count ?? 0) >= engine.config.touchPersonalMinSamples
            }
            NSLog(
                "[LyklaborÃ°] personal snapshot loaded (%d words; touch: %d keys, %.0f effective taps, %d past gate)",
                engine.personalSnapshotWords.count,
                touch.keys.count,
                touch.totalEffectiveSamples,
                eligible.count
            )
        } catch {
            // Corrupt/unreadable model: keep typing, drop personal ranking —
            // but keep the curated layer on.
            engine.setPersonalVocabulary(combinedVocabulary(personal: nil))
            engine.setPersonalTouch(nil)
            NSLog("[LyklaborÃ°] personal model load failed: %@", String(describing: error))
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
                "[LyklaborÃ°] learning-event flush failed (%d events dropped): %@",
                events.count, String(describing: error)
            )
        }
    }

    // MARK: - Inflection intelligence (off `queue`, then a follow-on on `queue`)

    /// Load the Stage-B inflection artifacts and inject them into the engine.
    ///
    /// Sequencing (PLAN.md "Inflection intelligence" + the launch-flicker
    /// discipline): `paradigms.bin` is a cheap mmap open (file-backed pages,
    /// ~0 dirty), but `governors.json.gz` costs a one-time gunzip + byte-scan
    /// parse (~40-150ms). BOTH run here on a background utility queue — NOT
    /// the serial engine `queue` — precisely so that parse can never sit in
    /// front of a first keystroke (keystrokes are served on `queue`). Only the
    /// ~instant `setInflection` mutation hops back onto `queue`, honoring the
    /// engine's single-queue confinement contract (`setInflection` mutates the
    /// shared InflectionStore, same rule as every other engine call).
    ///
    /// Fully graceful: a missing OR corrupt artifact simply leaves inflection
    /// nil — every scoring seam is inert and the engine is byte-identical to
    /// the pre-inflection build (see `InflectionModel` doc). Never crashes.
    ///
    /// Memory QA: logs `phys_footprint` before the load and after
    /// `setInflection`, so on-device runs can confirm the documented budget
    /// (paradigms mmap ≈ 0 dirty + governors table ≈ 1-2MB; PLAN.md's ~4MB
    /// dirty ceiling includes the transient decompression buffer, which
    /// `withGunzipped` munmaps before this delta is measured).
    private func scheduleInflectionLoad() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let bundle = Bundle(for: Self.self)
            guard let paradigmsURL = bundle.url(forResource: "paradigms", withExtension: "bin") else {
                NSLog("[LyklaborÃ°] paradigms.bin missing from extension bundle; inflection stays off")
                return
            }
            guard
                let governorsURL = bundle.url(forResource: "governors.json", withExtension: "gz")
            else {
                NSLog("[LyklaborÃ°] governors.json.gz missing from extension bundle; inflection stays off")
                return
            }
            let before = Self.memoryFootprintMB()
            let start = CFAbsoluteTimeGetCurrent()
            let model: InflectionModel
            do {
                // mmap reader (cheap); then the gunzip+scan (the real cost).
                let paradigms = try ParadigmsReader(contentsOf: paradigmsURL)
                let governors = try GovernorsModel(gzippedJSONContentsOf: governorsURL)
                model = InflectionModel(paradigms: paradigms, governors: governors)
            } catch {
                NSLog(
                    "[LyklaborÃ°] inflection load FAILED (%@); inflection stays off",
                    String(describing: error))
                return
            }
            let loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            self.queue.async { [weak self] in
                guard let self, let engine = self.engine else { return }
                engine.setInflection(model)
                let after = Self.memoryFootprintMB()
                NSLog(
                    "[LyklaborÃ°] inflection ready in %.1f ms (%d governors; phys_footprint %.1f→%.1f MB, Δ%.1f MB)",
                    loadMs, model.governors.governorCount, before, after, after - before
                )
            }
        }
    }

    /// Process-wide resident footprint in MB (`task_vm_info`.phys_footprint —
    /// the same metric the jetsam cap watches and the TypeEngine governors
    /// regression test asserts against). QA-only; no typed content involved.
    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    // MARK: - Autocomplete (on `queue`)

    private func performAutocomplete(_ text: String) -> Autocomplete.ServiceResult {
        bootstrapIfNeeded()
        // The queued bootstrap normally completed before this pass. A nil
        // session therefore means bootstrap failed; stay silent and let the
        // keyboard remain usable without suggestions.
        guard let session else {
            return .init(inputText: text, suggestions: [])
        }
        let suggestions = session.suggestions(for: text, limit: 3)
        let elapsedMs = (AutocompleteColdStartTracker.now - serviceCreatedAt) * 1000
        if !hasRecordedFirstAutocompletePass {
            hasRecordedFirstAutocompletePass = true
            Self.coldStartSignposter.emitEvent("First autocomplete pass")
            Self.coldStartLogger.notice(
                "First autocomplete pass completed \(elapsedMs, format: .fixed(precision: 1)) ms after service creation"
            )
        }
        // DEV-MODE recorder: one flag check; writes a JSONL line ONLY when a
        // session is armed and the field is standard. Off by default, and
        // entirely independent of the learning event log below.
        recorder?.recordPass(
            window: text, fieldKind: fieldKind, suggestions: suggestions,
            pIcelandic: session.probabilityIcelandic)
        setRevertMemoArmed(session.hasPendingContinuationRevert)
        setAttachmentMemoArmed(session.hasPendingPunctuationAttachment)
        setLiteralRevertArmed(session.hasArmedLiteralRevert)
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
                // Wave 37: mark own-learned personal vocabulary so the toolbar
                // can offer a long-press eject (tap teaches, long-press
                // forgets). Only TypingSession's non-verbatim, personal-only
                // suggestions carry the flag; base-lexicon words never do.
                Autocomplete.Suggestion.isPersonalLearnedInfoKey:
                    suggestion.isPersonalLearned ? "1" : "0",
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

extension LyklabordAutocompleteService {

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
