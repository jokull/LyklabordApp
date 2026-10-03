import Foundation
import Learning

/// The kind of text field the session is typing into. UIKit-free mirror of
/// the field types that must never auto-correct (PLAN.md "Verbatim escape
/// hatch + URL handling", layer 2): URL/email/web-search fields keep their
/// suggestions (tap-only), but no suggestion may carry `isAutocorrect`.
/// `.secure` additionally covers password fields (`isSecureTextEntry`).
public enum FieldKind: String, Equatable, Sendable {
    case standard
    case url
    case email
    case webSearch
    case secure

    /// Whether autocorrect (auto-apply on delimiter) is suppressed.
    public var suppressesAutocorrect: Bool { self != .standard }

    /// HARD privacy gate (Learning invariant #3): learning events may only
    /// be buffered/emitted from plain standard fields — never URL, email,
    /// web-search or secure ones.
    public var allowsLearning: Bool { self == .standard }
}

/// Proxy edit the extension (or harness) must perform to undo the last
/// '.'-triggered auto-replacement when the user keeps typing letters after
/// the dot (PLAN.md layer 4, revert-on-continuation): delete `deleteCount`
/// characters backward, then insert `text` (the originally typed token,
/// including its dot). The continuation character is inserted afterwards by
/// the normal keystroke path.
public struct RevertInstruction: Equatable, Sendable {
    public let deleteCount: Int
    public let text: String

    public init(deleteCount: Int, text: String) {
        self.deleteCount = deleteCount
        self.text = text
    }
}

/// UIKit-free typing session over a `TypeEngine`.
///
/// This is the single shared implementation of the "text before cursor" →
/// suggestions pipeline used by BOTH the keyboard extension
/// (`LyklabordAutocompleteService`) and the macOS `type-repl` harness,
/// so the two always run the identical path:
///
/// 1. parse the full text before the cursor into (committed context,
///    word currently being typed) — where '.' and '@' are word-internal
///    when flanked by letters/digits (URLs, domains, e-mails, "e.g.",
///    file.ext), and a '.' typed right after a word is DEFERRED: it only
///    becomes a committing delimiter once the next event shows whitespace/
///    another delimiter after it ("word. " commits; "word.t" keeps growing
///    one dotted token),
/// 2. classify how the window changed since the previous call and only
///    treat a delimiter-completed word as committed when the change is a
///    valid single-keystroke evolution. The classification is ledger-first
///    (azooKey's expected-edit pattern, research/oss-harvest.md §2): an
///    embedder that reports every proxy edit it performs via
///    `noteSelfEdit(before:after:)` gets EXACT self-vs-external attribution
///    — an observed window matching a recorded expectation is certainly our
///    own edit, anything unexplained is certainly external (cursor jump,
///    host mutation, autofill) and resets pending-word state. The legacy
///    shape heuristics (append / word-replacement / shrink / truncation
///    slide) remain as (a) the shape classifier for explained changes and
///    (b) the whole classifier for embedders that never record self-edits,
/// 3. feed genuinely committed words to `TypeEngine.confirmWord` (language
///    posterior update),
/// 4. apply the ≥2-typed-characters gate before completion/correction-style
///    suggestions (single-letter prefixes hit the 20k-entry completion scan
///    cap on is.lex, ~2.8 ms/call; 2+ char prefixes have far smaller
///    ranges; an empty current word is next-word prediction, which is
///    cheap),
/// 5. ask the engine for suggestions, then apply the verbatim/URL layers:
///    the literal typed token always leads the bar (verbatim escape hatch,
///    mapped to KeyboardKit's quoted `.unknown` type by the extension),
///    dotted/@ tokens are verbatim-class (never auto-corrected; only the
///    trailing dot-free segment gets tap-only suggestions), and URL/email/
///    web-search fields never emit `isAutocorrect` at all.
///
/// Not thread-safe (it owns mutable per-call state and TypeEngine's
/// posterior); confine it to one queue, exactly like `TypeEngine` itself.
public final class TypingSession {

    public let engine: TypeEngine

    /// The kind of field being typed into (PLAN.md layer 2). Settable by
    /// the embedder whenever the host field changes; `.url`, `.email` and
    /// `.webSearch` suppress `isAutocorrect` on every suggestion
    /// (suggestions stay available, tap-only).
    public var fieldKind: FieldKind = .standard

    /// Number of word commits detected so far (i.e. `confirmWord` calls).
    public private(set) var committedWordCount = 0
    /// Number of commits that actually moved the lane posterior. Words with
    /// no attributable language evidence leave a neutral posterior unchanged
    /// (from a non-neutral one they still apply the lane model's gentle
    /// decay toward 0.5, which counts as movement).
    public private(set) var posteriorUpdateCount = 0
    /// The most recently committed word, as read back out of the committed
    /// text (so it reflects an applied autocorrect, not the raw fragment).
    public private(set) var lastCommittedWord: String?

    /// The full window seen by the previous `suggestions(for:)` call;
    /// nil when there is no trusted last-seen state (fresh session, reset,
    /// or just after an external change).
    private var lastSeenWindow: String?
    /// Proxy-edit ledger (azooKey `ExpectedEditTracker` pattern,
    /// research/oss-harvest.md §2): the expectations recorded by
    /// `noteSelfEdit(before:after:)`, matched against every window
    /// observation by `classifyChange`.
    private var ledger = ExpectedEditLedger()
    /// The exact window string the previous `suggestions(for:)` call
    /// observed — the ledger's anchor. Unlike `lastSeenWindow` it is NEVER
    /// patched by the revert/attachment memo fixups (those adjust the shape
    /// DIFF's anchor; the ledger is anchored at real observed windows) and
    /// never nils out on external changes (external adopts the new window).
    private var lastObservedWindow: String?
    /// True once the embedder has recorded at least one self-edit. From
    /// then on the embedder is contractually telling us about EVERY proxy
    /// mutation it performs, so a changed window with NO pending
    /// expectation is external by definition — no shape guessing. Cleared
    /// only by `reset()` (a fresh harness scenario), never by external
    /// changes (the embedder keeps instrumenting).
    private var ledgerRecordsSelfEdits = false
    /// The `currentWord` parsed from the previous `suggestions(for:)` call,
    /// used by the word-commit transition check.
    private var previousCurrentWord = ""
    /// Bigram context carried across a proxy sentence-truncation reset:
    /// when the window collapses to empty right after a sentence terminator
    /// (iOS proxies cut the before-window at ". "), the words the user just
    /// typed are still on screen — keep the last committed word as bigram
    /// context for the first word of the new sentence. Cleared by external
    /// changes, reset, and as soon as the new window has its own context.
    private var carriedContext: String?
    /// The `isAutocorrect` suggestion text emitted by the previous
    /// `suggestions(for:)` call (nil when none). Used to (a) read back the
    /// corrected form when a ". "-commit collapses the proxy window in the
    /// same keystroke, and (b) recognize a host-side '.'-triggered
    /// auto-replacement of the pending token (revert-on-continuation).
    private var lastEmittedAutocorrect: String?
    /// All non-verbatim suggestion texts emitted by the previous
    /// `suggestions(for:)` call. A window change that appends SEVERAL words
    /// in one keystroke is normally a host paste (never committed) — except
    /// when it is exactly one of these texts being applied (a split
    /// correction like "smellir á", via autocorrect-on-delimiter or a tap):
    /// then each word is committed in order.
    private var lastEmittedSuggestionTexts: [String] = []
    /// Punctuation-attachment memo (PLAN.md "Space-miss correction" #3):
    /// armed when a '.' keystroke lands exactly one space after a word
    /// ("word ␣."). If the very next keystroke is a space, the session
    /// orders a proxy edit that attaches the period to the word
    /// ("word ␣.␣" → "word.␣"); any other character discards the memo (a
    /// letter after the dot is a token like ".net" — never touched).
    private var punctuationAttachmentArmed = false
    /// Revert-on-continuation memo (PLAN.md layer 4): set when the window
    /// diff shows the pending token was auto-replaced on a '.' keystroke
    /// ("teh" → "the."). One-keystroke-lived: consumed by
    /// `continuationRevert(for:)` between keystrokes, or discarded at the
    /// start of the next `suggestions(for:)` call.
    private var dotReplacement: (original: String, corrected: String)?
    /// Verbatim-choice memo (PLAN.md layer 1): the token the user committed
    /// via the verbatim suggestion slot. While the pending word equals it,
    /// no autocorrect is emitted, so an immediate delimiter can't re-correct
    /// the token the user explicitly chose. Cleared on commit/external
    /// change/reset.
    private var verbatimChoice: String?
    /// Attached-dot memo (2026-10 seam audit, bug (a)): the deferred-dot
    /// token the window shows as PENDING although its word was already
    /// committed — the extension's space-commit dot attachment ("hestur␣"
    /// + "." → "hestur.") rewrites the committed delimiter into a trailing
    /// dot, and the session must not read the next delimiter as a second
    /// commit of the same word (a double `confirmWord`, a self-bigram
    /// `wordCommitted`). While the pending word equals it, the next
    /// delimiter only notes the sentence boundary and no autocorrect is
    /// emitted for it. Cleared as soon as the pending word is anything else,
    /// on external change and reset.
    private var committedDotToken: String?
    /// Backspace-revert memo (wave 36, the iOS "revert autocorrect" escape
    /// hatch): armed the moment an autocorrect AUTO-APPLIES on a delimiter
    /// commit. `literal` is the byte-exact pre-correction typed token (the
    /// same string the proxy-edit ledger's before-window carries — never
    /// re-derived from the correction), `corrected` is what the engine
    /// committed. The user's instinct on a wrong force-correction is to press
    /// backspace: deleting the commit's trailing delimiter REVEALS the
    /// corrected word, and at THAT moment the bar's reserved left slot offers
    /// `literal` (verbatim/`.unknown`), so one tap swaps the corrected word
    /// back to exactly what was typed. The memo survives duplicate no-op
    /// autocomplete passes and repeated delimiter/backspace cycles at that
    /// same correction boundary. See
    /// `resolveBackspaceRevert`/`revertToLiteral` and the reserved-slot branch
    /// of `buildSuggestions`. Cleared once consumed, when editing enters the
    /// corrected word, or on a new word / cursor move / field change /
    /// external change / reset — never a stale literal slot.
    private var backspaceRevert: (literal: String, corrected: String)?
    /// True only on the pass that armed `backspaceRevert` (the autocorrect
    /// commit), so `resolveBackspaceRevert` evaluates the memo from the NEXT
    /// pass onward. Once armed, the memo owns the correction boundary until
    /// the user leaves or edits it; harmless refreshes must not spend it.
    private var backspaceRevertJustArmed = false
    /// Whether the last built bar led with the reserved literal-revert slot
    /// (the memo was armed AND the cursor sat right after the corrected
    /// word). Read by the embedder — via `hasArmedLiteralRevert` — to route a
    /// tap on that slot to `revertToLiteral` rather than the ordinary
    /// verbatim path.
    private var literalSlotShowing = false
    /// Characters of the pending word entered via long-press/callout — the
    /// strongest deliberateness signal in the lane-relaxation hierarchy
    /// (PLAN.md "Lane relaxation profiles", triple gate part 3a). The
    /// extension's action handler calls `noteLongPressInsertion(_:)` for
    /// every callout-selected character; the engine then vetoes accent
    /// folding for that word and never auto-applies a candidate that drops
    /// one of these characters (a long-pressed accent is never folded
    /// away). Only characters still present in the pending word count
    /// (backspacing one away retires its veto); cleared when the word
    /// commits or is abandoned, on external change and reset.
    private var longPressedCharacters: [Character] = []

    // MARK: - Per-tap touch record (PLAN.md "Touch decoding", stage 1)

    /// Touch samples aligned position-by-position with the pending word
    /// (`previousCurrentWord` between calls): the coordinate evidence the
    /// corrector's `PerTapCostProvider` consumes. nil entries are positions
    /// typed without a captured point (callout-selected characters, host
    /// insertions, drift) — those fall back to static pricing. Maintained
    /// by `reconcileTapRecord` with the same backspace/external-change
    /// discipline as the long-press memos: backspacing a character retires
    /// its tap, a replacement/external change clears the record.
    private var pendingTapRecord: [TapSample?] = []
    /// Samples noted since the last `suggestions(for:)` call, in arrival
    /// order; consumed by the reconcile step. Bounded (one keystroke
    /// produces one tap; anything beyond a small queue is a desync).
    private var incomingTaps: [TapSample] = []
    private static let incomingTapQueueLimit = 8

    // MARK: - Learning-event state (M2)

    /// Learning events buffered since the last drain. Only ever appended to
    /// while `fieldKind.allowsLearning` (HARD privacy gate — URL/email/
    /// web-search/secure fields emit nothing); the embedder drains and
    /// flushes batches to the App Group `EventLog` at word-commit
    /// boundaries, never per keystroke.
    private var pendingEvents: [LearningEvent] = []
    /// The word that preceded the next commit, for `wordCommitted
    /// .previousWord` bigram evidence. Cleared across sentence boundaries,
    /// external changes and resets so a pair never spans a discontinuity.
    private var previousCommittedForEvents: String?
    /// The token most recently learned via an explicit signal (verbatim tap
    /// / `learnWordImmediately`). Its imminent commit must not ALSO emit a
    /// `wordCommitted` — the tap already carries the stronger signal, and a
    /// double event would double-count in the model. Cleared once consumed,
    /// and on external change/reset.
    private var tapLearnedWord: String?

    public init(engine: TypeEngine) {
        self.engine = engine
    }

    /// Convenience passthrough: the engine's running P(Icelandic).
    public var probabilityIcelandic: Double { engine.probabilityIcelandic }

    // MARK: - Main entry point

    /// Suggestions for the full text before the input cursor
    /// (`documentContextBeforeInput` on device; the harness buffer on
    /// macOS). Call this once per text change — it is stateful (commit
    /// detection compares against the previous call).
    @discardableResult
    public func suggestions(
        for textBeforeCursor: String, limit: Int = 3, trace: CorrectionTrace? = nil
    ) -> [Suggestion] {
        // A revert or attachment memo not consumed before the next keystroke
        // landed is dead: its one-keystroke window has passed. An observation
        // of the UNCHANGED window is not a keystroke — a duplicate autocomplete
        // request must never spend a one-shot memo (fuzz seed 17: a no-op
        // refresh between "with ␣." and the space lost the attachment; the
        // same refresh after a '.'-apply lost the URL self-heal).
        if textBeforeCursor != lastObservedWindow {
            dotReplacement = nil
            punctuationAttachmentArmed = false
        }

        let (context, currentWord) = Self.splitCurrentWord(of: textBeforeCursor)

        // Fresh state (nil window: session start, reset, or a just-noted
        // external change) also classifies `.external` — but there the
        // keystroke that caused THIS call is genuine typing whose tap is
        // already queued, so only a genuinely inconsistent window clears
        // the tap queue below.
        let hadTrustedWindow = lastSeenWindow != nil

        // Did the observed window shrink since the last pass? The reserved
        // literal-revert slot arms only when the corrected word was reached
        // BY DELETION (backspacing the commit's trailing delimiter), never by
        // typing the same letters afresh — this is the discriminator.
        let windowShrank = lastSeenWindow.map { textBeforeCursor.count < $0.count } ?? false

        var change = classifyChange(to: textBeforeCursor)
        // The edit the ledger matched this observation to (nil for stale,
        // unexplained, legacy and heuristic-only observations).
        let selfEdit = ledger.matchedEdit
        // A reported replacement that the visible window does not show did
        // not land as described (an apply across an active selection over-
        // deletes: "ok hest|r|" + space → "ok hhestur ", ProxyFidelity
        // seam audit). Whatever is there now is not text we can account
        // for — never commit or learn it. External is the safe reading.
        if case .evolution = change, let replacement = selfEdit?.replacement,
            !Self.replacementLanded(replacement, in: textBeforeCursor)
        {
            change = .external
        }

        switch change {
        case .evolution(let appendedAfterContext):
            noteDotReplacementIfAny(currentWord: currentWord)
            confirmIfCommitted(
                context: context,
                currentWord: currentWord,
                appendedAfterContext: appendedAfterContext
            )
            armPunctuationAttachmentIfAny(
                window: textBeforeCursor,
                currentWord: currentWord,
                appendedAfterContext: appendedAfterContext
            )
        case .newSentenceStart:
            // Lagging boundary cut: the previous sentence/paragraph left the
            // window one keystroke late and this window is the first text of
            // the new one. Nothing was pending (the boundary keystroke was
            // observed in full), so no commit can occur; the whole window is
            // the appended text — the same keystroke bookkeeping as an
            // evolution, with the last committed word carried as bigram
            // context exactly like the immediate-collapse path does.
            carriedContext = lastCommittedWord
            armPunctuationAttachmentIfAny(
                window: textBeforeCursor,
                currentWord: currentWord,
                appendedAfterContext: textBeforeCursor
            )
        case .collapse(let sentenceBoundary):
            // Window collapsed to empty because the host cut it at the
            // delimiter our own edit inserted: the ". " sentence cut, or a
            // newline cut after a Return that the embedder described.
            confirmPendingWordAfterCollapse(sentenceBoundary: sentenceBoundary, edit: selfEdit)
        case .delimiterRewrite(let sentenceBoundary):
            // Only the trailing delimiters of an already-committed word
            // changed (the extension's dot attachment, KeyboardKit's auto-
            // space removal/reinsertion around a '.', the double-space
            // sentence ender). Nothing new to commit; a deferred dot left
            // pending on the committed word is remembered so the next
            // delimiter does not commit it again, and a sentence boundary
            // that appeared relaxes the lane — once, here, since no commit
            // will observe it.
            if !currentWord.isEmpty {
                committedDotToken = currentWord
            }
            if sentenceBoundary {
                engine.noteSentenceBoundary()
                previousCommittedForEvents = nil
            }
        case .external:
            carriedContext = nil
            verbatimChoice = nil
            committedDotToken = nil
            // A cursor jump / host mutation / field switch dissolves the
            // "right after the corrected word" adjacency the reserved slot
            // depends on — never offer a stale literal after one.
            backspaceRevert = nil
            // Expectations recorded against the pre-discontinuity world can
            // never confirm; the next observation starts from the adopted
            // window.
            ledger.clear()
            // Coordinate evidence never survives a discontinuity. The
            // queued taps survive only the fresh-state shape (see
            // `hadTrustedWindow`); the reconcile step still refuses any
            // queued tap whose character doesn't match the appended text.
            pendingTapRecord = []
            if hadTrustedWindow {
                incomingTaps = []
            }
        }
        if !context.isEmpty {
            // The new window has its own committed context; stop carrying.
            carriedContext = nil
        }

        // Backspace-revert lifecycle (wave 36 / issue #15). The arming pass
        // is skipped. Later passes retain the literal while the cursor remains
        // at the same correction boundary, either after its delimiter or with
        // that delimiter backspaced away. Duplicate autocomplete requests are
        // observations, not user intent, and must never consume the memo.
        if backspaceRevertJustArmed {
            backspaceRevertJustArmed = false
        } else {
            resolveBackspaceRevert(textBeforeCursor: textBeforeCursor, windowShrank: windowShrank)
        }

        // Align the touch record with the new pending word (AFTER commit
        // handling, which consumes the record aligned to the OLD word, and
        // BEFORE previousCurrentWord is replaced).
        reconcileTapRecord(with: currentWord)

        // The attached-dot memo belongs to exactly one pending token.
        if committedDotToken != currentWord {
            committedDotToken = nil
        }

        previousCurrentWord = currentWord
        lastSeenWindow = textBeforeCursor
        lastObservedWindow = textBeforeCursor

        // Long-press deliberateness memos belong to the pending word: once
        // it commits or is abandoned (no word in progress), they retire.
        if currentWord.isEmpty {
            longPressedCharacters = []
        }

        let bar = buildSuggestions(
            context: context,
            currentWord: currentWord,
            textBeforeCursor: textBeforeCursor,
            limit: limit,
            trace: trace
        )
        lastEmittedAutocorrect = bar.first(where: { $0.isAutocorrect })?.text
        lastEmittedSuggestionTexts = bar.filter { !$0.isVerbatim }.map(\.text)
        return bar
    }

    /// Replace the autocorrect identity emitted by `suggestions(for:)` when
    /// the embedder arms a provider that lives outside TypeEngine. The iOS
    /// system text-replacement table is such a provider: it is injected by
    /// the keyboard extension after the engine pass, but its spacebar commit
    /// still needs the same byte-exact backspace-revert contract.
    ///
    /// This is ephemeral session state only. The extension deliberately does
    /// not log the replacement table or uncommitted expansions.
    public func noteExternallyArmedAutocorrect(_ text: String) {
        guard !text.isEmpty else { return }
        lastEmittedAutocorrect = text
        if !lastEmittedSuggestionTexts.contains(text) {
            lastEmittedSuggestionTexts.insert(text, at: 0)
        }
    }

    /// Tell the session a character of the pending word was entered via a
    /// LONG-PRESS callout (accents á é í ó ú ý, apostrophes, long-press
    /// symbols) — an explicit input act, the strongest deliberateness
    /// signal (PLAN.md lane-relaxation triple gate, part 3a). Call BEFORE
    /// or right after inserting the character through the proxy; the memo
    /// rides with the pending word and vetoes accent folding for it.
    /// (KeyboardExt wiring is a one-liner in the action handler for
    /// callout-selected characters — owned by the extension wave; the
    /// harness `LONGPRESS` directive drives this API meanwhile.)
    public func noteLongPressInsertion(_ character: Character) {
        guard let lowered = String(character).lowercased().first else { return }
        longPressedCharacters.append(lowered)
    }

    /// Tell the session a character keystroke was resolved from a touch at
    /// (`dx`, `dy`) — within-key normalized offsets from the released key's
    /// center, −0.5…+0.5 at the key's touch-cell edges, x right / y down
    /// (the ReplayRig TSI convention; see `TapSample`). Call BEFORE (or in
    /// the same turn as) the keystroke's `suggestions(for:)` pass, exactly
    /// like the extension's action handler and the harness `TAP` directive
    /// do; the next pass aligns the sample with the pending word's new
    /// character. Callout-selected characters must NOT be reported here
    /// (their touch belongs to the callout, not the key) — use
    /// `noteLongPressInsertion(_:)` instead. O(1).
    public func noteTap(char: Character, dx: Double, dy: Double) {
        guard let lowered = String(char).lowercased().first else { return }
        if incomingTaps.count >= Self.incomingTapQueueLimit {
            incomingTaps.removeFirst()
        }
        incomingTaps.append(TapSample(char: lowered, dxNorm: dx, dyNorm: dy))
    }

    /// Tell the session the user committed a token via the verbatim
    /// suggestion slot (the extension's action handler forwards taps on
    /// `.unknown` suggestions; the harness Typist does the same). While the
    /// pending word equals this token, no autocorrect is emitted for it —
    /// an immediately following delimiter can never re-correct the exact
    /// token the user just chose verbatim.
    public func noteVerbatimChoice(_ token: String) {
        verbatimChoice = token
        // The verbatim tap is the strongest explicit "this is a real word"
        // signal: session-immediate learn + a wordTapped event (both gated
        // on field kind and learnability inside learnWordImmediately).
        learnWordImmediately(token)
    }

    /// Explicit learn signal (verbatim tap, or KeyboardKit's `learnWord`
    /// forwarded by the extension): the word becomes valid + suggestible in
    /// this session immediately (engine overlay), and a `wordTapped` event
    /// is buffered so the app-side model learns it permanently (no
    /// day-threshold — explicit signals skip it, see `PersonalModel`).
    ///
    /// Gates (all HARD):
    /// - `fieldKind.allowsLearning` — nothing from URL/email/webSearch/
    ///   secure fields, not even the in-session overlay (an email address
    ///   must not become suggestible in other fields mid-session),
    /// - `EventLog.isLearnableWord` — no whitespace/emoji/letterless junk,
    /// - ≥2 characters — single-letter tokens are either base-lexicon
    ///   words (á, í, a, I) that need no personal slot, or stray-tap noise
    ///   (mirrors the SwiftKey-import rule, see `isEventWord`),
    /// - not verbatim-class (internal '.'/'@') — URL/email-shaped tokens
    ///   are never learned even in standard fields.
    public func learnWordImmediately(_ word: String) {
        guard fieldKind.allowsLearning else { return }
        let token = Self.strippedEventToken(word)
        guard Self.isEventWord(token) else { return }
        guard token != tapLearnedWord else { return }  // duplicate signal for one tap
        engine.learnSessionWord(token)
        tapLearnedWord = token
        pendingEvents.append(.wordTapped(word: token))
    }

    // MARK: - Learning-event buffer (M2)

    /// Whether any learning events await a flush.
    public var hasPendingLearningEvents: Bool { !pendingEvents.isEmpty }

    /// Hand over (and clear) the buffered learning events. The embedder
    /// appends them to the App Group `EventLog` inside ONE short
    /// `CoordinatedFileAccess.coordinateWrite` block — batched at word
    /// boundaries, never per keystroke (events only accrue at commits,
    /// taps and reverts, so "drain when non-empty" IS that batching).
    public func drainLearningEvents() -> [LearningEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    /// Revert-on-continuation decision (PLAN.md layer 4). The embedder
    /// calls this BEFORE inserting a typed character: when the previous
    /// keystroke was a '.' that auto-replaced the pending token (host-side
    /// autocorrect-on-period, e.g. stock KeyboardKit behavior) and the new
    /// character continues the word (letter/digit, no intervening space),
    /// the replacement must be undone so URLs/domains self-heal
    /// ("profilmynd." → "prófílmynd." reverts to "profilmynd.t…").
    ///
    /// Returns the proxy edit to perform (delete the corrected token,
    /// re-insert the original) or nil. Consuming the memo also fixes up the
    /// session's own last-seen window so the revert is not misread as an
    /// external change. Any non-continuation character discards the memo.
    /// Whether a revert-on-continuation memo is currently armed (i.e. the
    /// last observed keystroke was a '.'-triggered auto-replacement).
    /// Embedders can use this to skip the `continuationRevert(for:)`
    /// round-trip on the overwhelmingly common keystrokes where no memo
    /// exists.
    public var hasPendingContinuationRevert: Bool { dotReplacement != nil }

    public func continuationRevert(for character: Character) -> RevertInstruction? {
        guard let memo = dotReplacement else { return nil }
        dotReplacement = nil
        guard character.isLetter || character.isNumber else { return nil }
        if let window = lastSeenWindow, window.hasSuffix(memo.corrected) {
            lastSeenWindow = String(window.dropLast(memo.corrected.count)) + memo.original
        }
        previousCurrentWord = memo.original
        // The user rejected our correction — a correctionReverted event
        // (the model counts the original as a plain, non-explicit commit).
        // Same gates as every event; the original is usually a URL stem in
        // progress, so the verbatim-class filter often drops it later —
        // here both tokens are still dot-free stems.
        if fieldKind.allowsLearning {
            let original = Self.strippedEventToken(memo.original)
            let applied = Self.strippedEventToken(memo.corrected)
            if original != applied, Self.isEventWord(original), Self.isEventWord(applied) {
                pendingEvents.append(.correctionReverted(original: original, applied: applied))
            }
        }
        return RevertInstruction(deleteCount: memo.corrected.count, text: memo.original)
    }

    /// Whether a punctuation-attachment memo is armed (the last keystroke
    /// was a '.' typed exactly one space after a word). Same embedder
    /// fast-path role as `hasPendingContinuationRevert`.
    public var hasPendingPunctuationAttachment: Bool { punctuationAttachmentArmed }

    /// Punctuation-attachment decision (PLAN.md "Space-miss correction" #3).
    /// The embedder calls this BEFORE inserting a typed character: when the
    /// previous keystroke was a '.' typed exactly one space after a word
    /// ("word ␣.") and the new character is a space, the stray space is
    /// removed so the sentence reads "word.␣" — the space-before-period
    /// swap. Any other character discards the memo (letters keep dotted
    /// tokens like ".net" intact).
    ///
    /// Returns the proxy edit to perform (delete the " ." tail, re-insert
    /// ".") or nil; the delimiter character is inserted afterwards by the
    /// normal keystroke path. Consuming the memo fixes up the session's
    /// last-seen window so the edit is not misread as an external change.
    public func punctuationAttachment(for character: Character) -> RevertInstruction? {
        guard punctuationAttachmentArmed else { return nil }
        punctuationAttachmentArmed = false
        guard character == " " else { return nil }
        if let window = lastSeenWindow, window.hasSuffix(" .") {
            lastSeenWindow = String(window.dropLast(2)) + "."
        }
        // The ". " this normalizes into existence is a sentence boundary
        // the commit path never observes (the word was already committed by
        // the earlier plain space): relax the lane here instead.
        engine.noteSentenceBoundary()
        return RevertInstruction(deleteCount: 2, text: ".")
    }

    // MARK: - Backspace-revert (wave 36, the iOS "revert autocorrect" slot)

    /// Whether the reserved literal-revert slot currently leads the bar (an
    /// autocorrect committed and the first backspace revealed the corrected
    /// word). The embedder mirrors this into a lock-guarded flag so a tap on
    /// the `.unknown` slot can be routed to `revertToLiteral` synchronously,
    /// exactly like `hasPendingContinuationRevert` gates the revert consult.
    public var hasArmedLiteralRevert: Bool { literalSlotShowing }

    /// Keep or drop the backspace-revert memo for THIS pass. It survives while
    /// the cursor remains at the correction boundary in either of two shapes:
    /// `corrected + delimiter` (hidden) or `corrected` reached by backspacing
    /// that delimiter (revealed). Repeated observations of either shape are
    /// no-ops. Editing into the word, typing a new word, or arriving at the
    /// corrected spelling by any unrelated route drops it.
    private func resolveBackspaceRevert(textBeforeCursor: String, windowShrank: Bool) {
        guard let memo = backspaceRevert else { return }

        // An observation of the unchanged window is not a user action and
        // never spends the memo — including the EMPTY window a sentence-cut
        // host shows right after the autocorrect commit, which neither shape
        // below recognizes (real seed 20009: a duplicate pass between
        // "Gtet." + space and the backspace lost the escape hatch).
        if textBeforeCursor == lastObservedWindow { return }

        if textBeforeCursor.hasSuffix(memo.corrected) {
            if windowShrank || literalSlotShowing {
                // Backspacing an unwanted correction is an explicit rejection
                // even when the user edits manually instead of tapping the
                // quoted slot. If they recreate the original literal, keep it
                // offer-only for the rest of this token so space cannot apply
                // the same correction again.
                verbatimChoice = memo.literal
                return
            }
            backspaceRevert = nil
            return
        }

        // Hidden boundary: the correction is still followed by exactly the
        // delimiter whose deletion reveals it. Keep this across duplicate
        // service refreshes and after the user re-inserts that delimiter.
        if let delimiter = textBeforeCursor.last, Self.isDelimiter(delimiter),
            textBeforeCursor.dropLast().hasSuffix(memo.corrected)
        {
            return
        }

        backspaceRevert = nil
    }

    /// Extra characters KeyboardKit must delete before inserting an armed
    /// literal revert. Its stock suggestion replacement deletes only the
    /// trailing current word; a missed-space correction can span several
    /// words ("smellir á"), so the bridge must additionally delete the
    /// corrected phrase's preceding words and spaces.
    public func literalRevertAdditionalDeleteCount(matching text: String) -> Int {
        guard literalSlotShowing, let memo = backspaceRevert, memo.literal == text else {
            return 0
        }
        let trailingWordCount = Self.splitCurrentWord(of: memo.corrected).currentWord.count
        return max(memo.corrected.count - trailingWordCount, 0)
    }

    /// Consume the reserved literal-revert slot: the user tapped it to swap
    /// the corrected word back to the byte-exact token they typed. Returns
    /// true (and applies the session-side bookkeeping) only when a memo is
    /// armed whose literal equals `text`; any other `.unknown` tap (the
    /// ordinary verbatim escape hatch) is a no-op returning false.
    ///
    /// The proxy edit itself (delete the corrected word, insert the literal)
    /// is performed by the embedder's tap handling — this method only records
    /// intent: it (a) suppresses re-correction of the restored literal by the
    /// next delimiter (`verbatimChoice`), (b) buffers a `correctionReverted`
    /// learning event — the SAME rejection signal as revert-on-continuation,
    /// so the model counts the literal as a plain non-explicit commit, NOT a
    /// strong "this is a real word" learn — and (c) primes `tapLearnedWord`
    /// so the imminent commit pass does not ALSO buffer a wordCommitted for
    /// the restored token. The user's revert is thus never misattributed as
    /// an engine correction, and never arms a fresh autocorrect.
    @discardableResult
    public func revertToLiteral(matching text: String) -> Bool {
        // Only while the reserved slot is actually being offered (the device
        // embedder gates on `hasArmedLiteralRevert` too): a memo armed at the
        // commit but not yet revealed by a backspace is not tappable.
        guard literalSlotShowing, let memo = backspaceRevert, memo.literal == text
        else { return false }
        backspaceRevert = nil
        verbatimChoice = memo.literal
        if fieldKind.allowsLearning {
            let original = Self.strippedEventToken(memo.literal)
            let applied = Self.strippedEventToken(memo.corrected)
            if original != applied, Self.isEventWord(original), Self.isEventWord(applied) {
                pendingEvents.append(.correctionReverted(original: original, applied: applied))
            }
        }
        tapLearnedWord = Self.strippedEventToken(memo.literal)
        return true
    }

    /// Tell the session about one self-caused proxy edit BEFORE its window
    /// observation arrives (the proxy-edit ledger; azooKey
    /// `ExpectedEditTracker` pattern, research/oss-harvest.md §2): `before`
    /// and `after` are the truncated before-cursor windows snapshotted
    /// immediately around the proxy mutation(s) of one logical action — a
    /// keystroke and everything it triggered (autocorrect apply, sentence
    /// ender), a suggestion tap, a revert-on-continuation or punctuation-
    /// attachment edit, a mode-2 prediction insert, one backspace.
    ///
    /// Once an embedder records self-edits, window classification runs on
    /// the ledger: an observation matching a recorded expectation is
    /// certainly self-caused (its shape is then diffed exactly as before);
    /// an observation matching the oldest expectation's `before` is a stale
    /// proxy read (state carries, the edit confirms later); anything else —
    /// including a changed window with NO pending expectation — is external
    /// and resets pending-word state. Expectations the host swallows expire
    /// after `ExpectedEditLedger.expiryObservations` observations, after
    /// which the legacy shape heuristics take over again (graceful
    /// degradation; the session must never wedge).
    ///
    /// No-op windows (`before == after`) are ignored, so embedders may call
    /// this unconditionally around actions that might not edit the proxy.
    ///
    /// `keystroke` / `replacement` (2026-10 seam audit) describe the edit
    /// beyond its window shape, for the cases where the observed window
    /// CANNOT show what happened — the host cut the window at the very
    /// delimiter the edit inserted (". " sentence cut, newline cut):
    ///  * `keystroke` is the character the user typed when the edit was a
    ///    keystroke (space, '.', '\n', letters); nil for taps, backspaces
    ///    and other edits. It tells a Return that committed the pending word
    ///    ("hestur" → "") from a backspace that deleted it, and the
    ///    double-space sentence ender ("hestur␣" → "") from a newline;
    ///  * `replacement` is the text the embedder replaced the pending token
    ///    with — the applied autocorrect, or a tapped non-verbatim bar
    ///    suggestion — exactly as the bar showed it (deferred dot included);
    ///    nil when the token was committed as typed (plain delimiter, stale
    ///    apply skipped by `AutocorrectApplyGuard`, verbatim tap).
    /// A record carrying a `keystroke` is fully described: a nil
    /// `replacement` then MEANS nothing was replaced, and a collapsed window
    /// commits the typed token. Records without either field are legacy
    /// window-only records and keep the historical reconstruction (an armed
    /// autocorrect is assumed applied on a ". " collapse). When the window
    /// does show the committed text, the window wins and a reported
    /// replacement that is not there classifies the change as external.
    public func noteSelfEdit(
        before: String, after: String, keystroke: Character? = nil, replacement: String? = nil
    ) {
        guard before != after else { return }
        ledgerRecordsSelfEdits = true
        ledger.record(
            before: before, after: after, anchor: lastObservedWindow,
            edit: ExpectedEditLedger.SelfEdit(keystroke: keystroke, replacement: replacement))
    }

    /// Does `window` show `replacement` as the text just before the cursor
    /// (trailing delimiters allowed, a deferred dot on the replacement
    /// ignored)? A whole-token match: the character before it, if any, must
    /// be a delimiter — "hhestur" does not show "hestur".
    private static func replacementLanded(_ replacement: String, in window: String) -> Bool {
        let stem = strippedEventToken(replacement)
        guard !stem.isEmpty else { return true }
        var end = window.endIndex
        while end > window.startIndex, isDelimiter(window[window.index(before: end)]) {
            end = window.index(before: end)
        }
        let core = window[..<end]
        guard core.hasSuffix(stem) else { return false }
        let start = core.index(core.endIndex, offsetBy: -stem.count)
        guard start > core.startIndex else { return true }
        return !isWordable(core[core.index(before: start)])
    }

    /// Tell the session the text before the cursor changed for a reason
    /// other than typing — cursor jump, host-app mutation (autofill, undo),
    /// switching fields. This clears the pending word-in-progress so the
    /// commit detector doesn't misread the new window as "the user just
    /// finished a word" (spurious `confirmWord`) or attribute a host-inserted
    /// word to the user. The session also detects external changes
    /// internally (exactly, via the proxy-edit ledger, for embedders that
    /// record their self-edits; heuristically otherwise — see
    /// `classifyChange`); this is the belt-and-braces path.
    public func noteExternalTextChange() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        lastObservedWindow = nil
        ledger.clear()
        carriedContext = nil
        dotReplacement = nil
        verbatimChoice = nil
        committedDotToken = nil
        backspaceRevert = nil
        backspaceRevertJustArmed = false
        longPressedCharacters = []
        pendingTapRecord = []
        incomingTaps = []
        punctuationAttachmentArmed = false
        lastEmittedSuggestionTexts = []
        // Bigram evidence never spans a discontinuity, and a pending tap
        // memo can no longer be matched to its commit. Already-buffered
        // events stay: they were validated genuine commits when buffered.
        previousCommittedForEvents = nil
        tapLearnedWord = nil
    }

    /// Window-aware variant, safe to forward from the extension's
    /// `textDidChange`/`selectionDidChange` — which ALSO fire after our own
    /// insertions. Idempotent: the note is ignored when `window` is
    /// consistent with the session's own last-seen state — explained by a
    /// pending ledger expectation (checked WITHOUT consuming it: the
    /// keystroke's own `suggestions(for:)` observation still gets the exact
    /// match), unchanged, or a valid typing evolution the next
    /// `suggestions(for:)` call will handle. Only a genuinely inconsistent
    /// window clears the pending word. Deliberately judged by the LENIENT
    /// heuristic (not the strict ledger rule): these callbacks can fire at
    /// odd moments relative to our own edit batches, and a mid-batch or
    /// pre-record window must never clobber state — the strict judgment
    /// belongs to the observation stream, where ordering is guaranteed.
    public func noteExternalTextChange(window: String) {
        guard lastSeenWindow != nil else { return }
        if ledger.wouldExplain(observed: window, anchor: lastObservedWindow) { return }
        if case .external = heuristicChange(to: window, selfEdit: nil) {
            noteExternalTextChange()
        }
    }

    /// Forget all per-session state and reset the language posterior to the
    /// 50/50 prior. Harness use (e.g. `:reset`, scenario isolation); the
    /// extension currently keeps one session for its whole lifetime.
    public func reset() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        lastObservedWindow = nil
        ledger.clear()
        ledgerRecordsSelfEdits = false
        carriedContext = nil
        dotReplacement = nil
        verbatimChoice = nil
        committedDotToken = nil
        backspaceRevert = nil
        backspaceRevertJustArmed = false
        literalSlotShowing = false
        longPressedCharacters = []
        pendingTapRecord = []
        incomingTaps = []
        punctuationAttachmentArmed = false
        lastEmittedAutocorrect = nil
        lastEmittedSuggestionTexts = []
        committedWordCount = 0
        posteriorUpdateCount = 0
        lastCommittedWord = nil
        pendingEvents = []
        previousCommittedForEvents = nil
        tapLearnedWord = nil
        engine.resetLanguagePosterior()
        engine.clearSessionVocabulary()
    }

    // MARK: - Touch-record reconciliation (PLAN.md "Touch decoding")

    /// Re-align `pendingTapRecord` with the pending word after a window
    /// change, consuming the taps that arrived since the previous pass:
    ///
    ///  * appended characters pop queued taps in arrival order, but only
    ///    when the resolved character matches (a host insertion or an IME
    ///    surprise appends nil — no per-tap claim about keys we did not
    ///    see pressed),
    ///  * backspacing truncates the record with the word (same discipline
    ///    as the long-press memos),
    ///  * a replacement / external shape clears to all-nil — static
    ///    fallback, never stale evidence.
    private func reconcileTapRecord(with currentWord: String) {
        defer { incomingTaps.removeAll(keepingCapacity: true) }
        let target = Array(currentWord.lowercased())
        guard !target.isEmpty else {
            pendingTapRecord = []
            return
        }
        let previous = Array(previousCurrentWord.lowercased())
        var record = pendingTapRecord
        if record.count != previous.count {
            // Drift (reset, missed pass): keep positions, drop claims.
            record = Array(repeating: nil, count: previous.count)
        }
        if target.count >= previous.count, target.starts(with: previous) {
            for char in target[previous.count...] {
                if let first = incomingTaps.first, first.char == char {
                    record.append(first)
                    incomingTaps.removeFirst()
                } else {
                    record.append(nil)
                }
            }
        } else if previous.starts(with: target) {
            record = Array(record.prefix(target.count))
        } else {
            record = Array(repeating: nil, count: target.count)
        }
        pendingTapRecord = record
    }

    // MARK: - Suggestion building (verbatim + URL layers)

    /// Assemble the suggestion bar for the parsed window: engine suggestions
    /// with the deferral/verbatim-class/field-gate rules applied, led by the
    /// verbatim escape-hatch slot.
    private func buildSuggestions(
        context: String,
        currentWord: String,
        textBeforeCursor: String,
        limit: Int,
        trace: CorrectionTrace? = nil
    ) -> [Suggestion] {
        // Reset the reserved-slot flag up front so every early return leaves
        // it false; the reserved-slot branch below re-arms it when offered.
        literalSlotShowing = false
        guard limit > 0 else { return [] }

        // Empty current word: next-word prediction (no verbatim slot).
        if currentWord.isEmpty {
            let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
            return Self.titleCaseNameSuggestions(
                engine.suggestions(
                    context: effectiveContext,
                    currentWord: "",
                    limit: limit,
                    trace: trace
                ),
                context: effectiveContext
            )
        }

        // A pending token has at most one trailing deferred dot (a second
        // '.' makes both dots delimiters). Correction/completion runs on
        // the dot-free stem; the pending dot is re-appended to every
        // suggestion so applying one replaces the whole pending token.
        let pendingDot = currentWord.hasSuffix(".")
        let stem = pendingDot ? String(currentWord.dropLast()) : currentWord

        var engineSuggestions: [Suggestion] = []
        if Self.isVerbatimClassToken(stem) {
            // Dotted/@ token (URL, domain, e-mail, file.ext, e.g.): never
            // auto-corrected. The dot-free trailing segment may still get
            // suggestions, tap-only, mapped back onto the full token.
            let segment = Self.trailingSegment(of: stem)
            if segment.count >= 2 {
                let prefix = String(stem.dropLast(segment.count))
                engineSuggestions = engine.suggestions(
                    context: "",
                    currentWord: segment,
                    limit: limit
                ).compactMap {
                    // Space-miss splits never apply inside a verbatim-class
                    // token: "tilvinstri" → "til vinstri" is a fine split,
                    // "profilmynd.til vinstri" is a broken URL.
                    guard !$0.text.contains(" ") else { return nil }
                    return Suggestion(
                        text: prefix + $0.text + (pendingDot ? "." : ""),
                        isAutocorrect: false,
                        confidence: $0.confidence,
                        isRestoration: $0.isRestoration
                    )
                }
            }
            // Dotted-token space-miss escape (dogfood "sem.er" → "sem er"):
            // the '.' key sits right of the spacebar, so the dot may BE a
            // missed space. Escape hatch out of the verbatim class, only in
            // standard fields, only for word.word shapes that are not
            // URL-shaped (one dot, all-letter halves, no known TLD, no
            // www — see `spaceEscapeHalves`), and only when the engine
            // finds both halves genuinely common (real domains like
            // "tilvinstri.is" never reach the engine call at all).
            if fieldKind == .standard, let halves = Self.spaceEscapeHalves(of: stem) {
                let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
                if let escape = engine.dottedSpaceMiss(
                    left: halves.left,
                    right: halves.right,
                    context: effectiveContext
                ) {
                    engineSuggestions.insert(
                        Suggestion(
                            text: escape.text + (pendingDot ? "." : ""),
                            isAutocorrect: escape.isAutocorrect,
                            confidence: escape.confidence
                        ),
                        at: 0
                    )
                }
            }
        } else if stem.count >= 2 || Corrector.hasSingleLetterAccentEscape(stem) {
            // ≥2-char gate (see type doc, point 4) — with the single-letter
            // accent-escape exception (a e i o u y): the engine's dedicated
            // 1-char path is a couple of point lookups, not the 1-char
            // completion scan the gate exists to avoid.
            let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
            // Long-press deliberateness memos still present in the pending
            // stem (backspaced-away characters retire their veto).
            let stemChars = Array(stem.lowercased())
            let deliberate = longPressedCharacters.filter { stemChars.contains($0) }
            // Touch record for the stem: the record aligns with the whole
            // pending token, so a trailing deferred dot's tap is sliced off
            // with the dot. Length mismatch (drift) → no coordinate claims.
            let stemTaps: [TapSample?] =
                pendingTapRecord.count >= stemChars.count
                ? Array(pendingTapRecord.prefix(stemChars.count))
                : []
            engineSuggestions = engine.suggestions(
                context: effectiveContext,
                currentWord: stem,
                limit: limit,
                deliberateCharacters: deliberate,
                taps: stemTaps,
                trace: trace
            )
            if pendingDot {
                engineSuggestions = engineSuggestions.map {
                    Suggestion(
                        text: $0.text + ".",
                        isAutocorrect: $0.isAutocorrect,
                        confidence: $0.confidence,
                        isRestoration: $0.isRestoration
                    )
                }
            }
        }

        // Numeric guard (issue #8, dogfood 2026-07-19): a digit-leading token
        // is a number in progress — "21.000,5" tokenizes to stem "5" — and
        // letter vocabulary must not compete with digits there ("5" offered
        // curated "5G" and it won over the intended "50"). Keep only
        // suggestions that stay purely numeric (digits + number separators).
        // Deliberately typed letter-tokens like "5G" are unaffected: typed
        // characters are never replaced by this filter, it only stops the bar
        // from PROPOSING letters after digits.
        if let first = stem.first, first.isNumber {
            engineSuggestions.removeAll { suggestion in
                !suggestion.text.allSatisfy { $0.isNumber || ".,:".contains($0) }
            }
        }

        // Lane-relaxation field gate (PLAN.md invariant "URL/email/secure
        // fields: no restoration at all"): restoration-class suggestions
        // are DROPPED, not just de-flagged — domains, e-mail localparts and
        // search tokens are unaccented by convention, so decorating them is
        // noise at best ("bud" in a URL bar must not surface "búð").
        if fieldKind.suppressesAutocorrect {
            engineSuggestions.removeAll(where: \.isRestoration)
        }

        // Field-type gate (layer 2) + verbatim-choice memo (layer 1): keep
        // the suggestions, strip the auto-apply flag.
        // The attached-dot memo joins them: the word under that pending dot
        // is already committed text, never re-corrected by the next space.
        if fieldKind.suppressesAutocorrect || verbatimChoice == currentWord
            || verbatimChoice == stem || committedDotToken == currentWord
        {
            if engineSuggestions.contains(where: \.isAutocorrect) {
                trace?.note(
                    fieldKind.suppressesAutocorrect
                        ? "auto-apply flag stripped: field kind \(fieldKind.rawValue)"
                        : committedDotToken == currentWord
                            ? "auto-apply flag stripped: attached dot on a committed word"
                            : "auto-apply flag stripped: verbatim-choice memo")
            }
            engineSuggestions = engineSuggestions.map {
                $0.isAutocorrect
                    ? Suggestion(
                        text: $0.text, isAutocorrect: false, confidence: $0.confidence,
                        isRestoration: $0.isRestoration)
                    : $0
            }
        }

        // Quoted-term relaxation (issue #3): a token typed immediately after
        // an opening double quote — „ (Icelandic low-9), " (straight) or
        // " (curly, U+201C) — is very often a deliberate foreign/technical
        // term or a quoted sletta ("deployaðu „feature branch" núna"), and
        // force-correcting it into an unrelated Icelandic word is exactly
        // wrong (dogfood: „vold [c→v miss for "cold"] auto-applied to „völd
        // at confidence 1.0). The quote characters became word delimiters in
        // the tokenization pass (see `delimiterPunctuation`), so the quote
        // sits at the END of the committed context and the check is one
        // character. Suggestions stay OFFERED — ranking, confidence and the
        // bar are untouched — only the auto-apply flag is stripped, so the
        // spacebar never force-replaces a quoted token; legitimate quoted
        // Icelandic words are equally left alone (offer, don't force).
        // Learning paths are untouched: a quoted term the user keeps commits
        // and learns exactly as before. A closing quote directly before a
        // token doesn't occur in real text (closing quotes end quotations),
        // and U+201D would be caught by the same "adjacent to a quote"
        // reasoning if a host ever produced it — the set below covers the
        // three openers iOS smart punctuation / the IS layout actually emit.
        if Self.isQuotedTermContext(context) {
            if engineSuggestions.contains(where: \.isAutocorrect) {
                trace?.note("auto-apply flag stripped: quoted term (opening quote before token)")
            }
            engineSuggestions = engineSuggestions.map {
                $0.isAutocorrect
                    ? Suggestion(
                        text: $0.text, isAutocorrect: false, confidence: $0.confidence,
                        isRestoration: $0.isRestoration)
                    : $0
            }
        }

        // Own-learned flag (wave 37, long-press eject): mark every non-
        // verbatim suggestion whose text is a word the user's personal
        // vocabulary alone taught the engine (not is.lex/en.lex/BÍN/compound),
        // so the toolbar can offer a long-press "forget" affordance. The
        // verbatim escape-hatch / literal-revert slots are the typed literal
        // (`.unknown`) and are never ejectable, so they are left unflagged.
        engineSuggestions = engineSuggestions.map {
            guard !$0.isVerbatim, engine.isPersonalLearnedWord($0.text) else { return $0 }
            return $0.markingPersonalLearned()
        }

        // Reserved literal-revert slot (wave 36): right after an autocorrect
        // commit, the first backspace reveals the corrected word — lead the
        // bar with the byte-exact pre-correction literal (verbatim/`.unknown`)
        // so one tap swaps the corrected word back to what was typed. The
        // ordinary verbatim slot (which would show the corrected word itself,
        // already in the document) yields the left slot to it here.
        var bar: [Suggestion] = []
        if let memo = backspaceRevert, textBeforeCursor.hasSuffix(memo.corrected) {
            literalSlotShowing = true
            bar.append(
                Suggestion(text: memo.literal, isAutocorrect: false, confidence: 0, isVerbatim: true)
            )
            bar.append(contentsOf: engineSuggestions.filter { $0.text != memo.literal })
            return Array(bar.prefix(limit))
        }

        // Verbatim escape-hatch slot (layer 1): the literal typed token
        // always leads the bar — unless it IS the top engine suggestion
        // (no duplicate).
        if engineSuggestions.first?.text != currentWord {
            bar.append(
                Suggestion(text: currentWord, isAutocorrect: false, confidence: 0, isVerbatim: true)
            )
            // A lower-ranked engine suggestion can still equal the typed token
            // (real fuzz seed 256: "I" after backspacing "Is" — the single-
            // letter path's capitalized "i" meets the typed "I"); the verbatim
            // slot already shows it, so it is dropped rather than duplicated.
            bar.append(contentsOf: engineSuggestions.filter { $0.text != currentWord })
        } else {
            bar.append(contentsOf: engineSuggestions)
        }
        return Self.titleCaseNameSuggestions(Array(bar.prefix(limit)), context: context)
    }

    // MARK: - Patronymic title-casing (issue #9)

    /// Title-case patronymic suggestions after a capitalized word: "Katrín" →
    /// suggest "Jakobsdóttir", not the corpus-lowercased "jakobsdóttir".
    ///
    /// Deliberately narrow: the previous committed word must start uppercase
    /// AND the suggestion must be an unambiguous Icelandic patronymic/
    /// matronymic — suffix "sson" or "dóttir" (genitive + son/dóttir:
    /// Jónsson, Jakobsdóttir). Bare "-son" is excluded on purpose: it would
    /// wrongly capitalize English "season"/"person"/"reason" after any
    /// sentence-start capital. Verbatim slots keep the user's typed casing.
    static func titleCaseNameSuggestions(
        _ suggestions: [Suggestion], context: String
    ) -> [Suggestion] {
        guard
            let previous = wordTokens(in: context).last,
            previous.first?.isUppercase == true
        else { return suggestions }
        return suggestions.map { suggestion in
            guard
                !suggestion.isVerbatim,
                suggestion.text.first?.isLowercase == true,
                isPatronymic(suggestion.text)
            else { return suggestion }
            return Suggestion(
                text: suggestion.text.prefix(1).uppercased() + suggestion.text.dropFirst(),
                isAutocorrect: suggestion.isAutocorrect,
                confidence: suggestion.confidence,
                isVerbatim: suggestion.isVerbatim,
                isRestoration: suggestion.isRestoration,
                isPersonalLearned: suggestion.isPersonalLearned
            )
        }
    }

    /// Unambiguous Icelandic patronymic/matronymic shape ("Jónsson",
    /// "Jakobsdóttir"): long enough to carry a name stem + the genitive
    /// -sson / -dóttir suffix.
    static func isPatronymic(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.count >= 6 && (lower.hasSuffix("sson") || lower.hasSuffix("dóttir"))
    }

    // MARK: - Window-change classification

    private enum WindowChange {
        /// The window is consistent with our last-seen state: unchanged,
        /// appended-to, current word replaced (autocorrect / suggestion
        /// tap), shrunk by deletion, or slid by proxy truncation.
        /// `appendedAfterContext` is the text that appeared after the
        /// previous committed context ("" when nothing was added there).
        case evolution(appendedAfterContext: String)
        /// The window collapsed to empty because the host cut it at the
        /// delimiter our own edit inserted: the iOS proxy's ". " sentence
        /// cut (`sentenceBoundary` true), or a newline cut after a Return
        /// the embedder described (`sentenceBoundary` false — a paragraph
        /// break commits the word but is not a sentence end for the lane).
        case collapse(sentenceBoundary: Bool)
        /// Only the trailing delimiters of the previous window were
        /// rewritten by our own edit ("hestur␣" → "hestur." / "hestur.␣"):
        /// the committed text is unchanged, nothing new commits.
        /// `sentenceBoundary` is true when the rewrite ENDED the sentence
        /// where the previous window had not.
        case delimiterRewrite(sentenceBoundary: Bool)
        /// Lagging boundary cut: the previous window ended with a sentence
        /// boundary or newline and the host dropped it from the window only
        /// now, with the new sentence's first keystroke ("hestur. " → "o").
        /// The whole window is new text after a fully observed boundary.
        case newSentenceStart
        /// The window cannot be explained by typing since the last call:
        /// cursor jump, host mutation, field switch.
        case external
    }

    /// Ledger-first window classification (see the type doc, point 2).
    ///
    /// The proxy-edit ledger answers WHOSE change this is with certainty
    /// whenever the embedder records its self-edits; the shape heuristics
    /// below (`heuristicChange`) answer WHAT the change looks like. The
    /// conservative resolutions, in order:
    ///  * ledger says external (unexplained observation, broken chain,
    ///    anchor drift) → external, no shape guessing,
    ///  * ledger says stale (the proxy has not echoed our edit yet) → a
    ///    no-op evolution: state carries, nothing commits, the edit
    ///    confirms on a later observation,
    ///  * ledger says matched → the change is certainly ours; its shape is
    ///    diffed by the heuristics. A matched change whose shape still
    ///    cannot be explained is ambiguous → external (never guess),
    ///  * ledger has nothing pending: for a self-edit-recording embedder a
    ///    CHANGED window is then external by definition (every own edit
    ///    would have been recorded); an unchanged window — and every window
    ///    from an embedder that never records — falls through to the
    ///    legacy heuristics unchanged.
    private func classifyChange(to window: String) -> WindowChange {
        switch ledger.explain(observed: window, anchor: lastObservedWindow) {
        case .unexplained:
            return .external
        case .stale:
            return .evolution(appendedAfterContext: "")
        case .matched:
            let shape = heuristicChange(to: window, selfEdit: ledger.matchedEdit ?? .legacy)
            if case .external = shape { return .external }
            return shape
        case .noRecords:
            if ledgerRecordsSelfEdits, let anchor = lastObservedWindow,
                window != anchor
            {
                return .external
            }
            return heuristicChange(to: window, selfEdit: nil)
        }
    }

    /// Shape heuristics: is `window` a plausible typing evolution of
    /// `lastSeenWindow` (append / word replacement / shrink / truncation
    /// slide / sentence cut), judged from the strings alone? For embedders
    /// that record self-edits this only ever runs on changes the ledger has
    /// already attributed (or on unchanged windows); for everyone else it
    /// is the whole classifier, exactly as before the ledger existed.
    ///
    /// `selfEdit` is non-nil ONLY when the ledger has proven the change is
    /// our own edit (`.matched`). The 2026-10 seam-audit shapes — trailing-
    /// delimiter rewrite, slide-plus-replace at a length cap, keystroke-
    /// described collapse, lagging boundary cut — are gated on it: each
    /// would be a plausible host mutation when read from the strings alone,
    /// and for un-instrumented embedders (and the lenient window note)
    /// external stays the safe default.
    private func heuristicChange(
        to window: String, selfEdit: ExpectedEditLedger.SelfEdit?
    ) -> WindowChange {
        guard let previous = lastSeenWindow else {
            // No trusted state: adopt the window without committing anything.
            return .external
        }
        if window == previous {
            return .evolution(appendedAfterContext: "")
        }

        let previousContext = Self.splitCurrentWord(of: previous).context

        // Window shrank to a prefix of what we saw: backspacing (possibly
        // past the word boundary), a jump back, or the proxy's ". "
        // sentence cut. Checked BEFORE the append branch: with a pending
        // deferred-dot token the previous context is empty, and every
        // window trivially has prefix "" — a shrink must not be misread as
        // an append there.
        if previous.hasPrefix(window) {
            // The proxy's ". " sentence cut collapses the window to empty.
            // Two commit-relevant shapes reach it: the previous window had
            // already committed a word ("stór. " with "stór" confirmed one
            // keystroke earlier via an untruncated host — legacy shape), or
            // the previous window ended in a PENDING deferred-dot token
            // ("stór." whose commit was deferred to this very keystroke).
            // A host clearing the field right after "word." is
            // indistinguishable from that space keystroke — an inherent
            // one-word ambiguity we accept (bounded: one posterior nudge).
            if window.isEmpty, Self.endsWithSentenceTerminator(previous),
                lastCommittedWord != nil || !previousCurrentWord.isEmpty
            {
                return .collapse(sentenceBoundary: true)
            }
            // Our own keystroke collapsed a window with no terminator in
            // it: only a described keystroke can tell this from deleting
            // the whole word (a repeat-backspace step, a one-letter word).
            //  * Return commits the pending word (if any) and the newline
            //    cut hides it — a paragraph break, not a sentence end;
            //  * a space or '.' with NO word pending is KeyboardKit's
            //    double-space ender / the '.' after a tap's auto-space:
            //    ". " was written and cut away — a sentence boundary the
            //    plain path would have seen as "hestur. ".
            if window.isEmpty, let keystroke = selfEdit?.keystroke {
                if keystroke.isNewline {
                    return .collapse(sentenceBoundary: false)
                }
                if keystroke == " " || keystroke == ".", previousCurrentWord.isEmpty {
                    return .collapse(sentenceBoundary: true)
                }
            }
            return .evolution(appendedAfterContext: "")
        }

        // Change confined to at/after the previous word boundary: plain
        // typing, or the current word being replaced by an applied
        // suggestion/autocorrect (KeyboardKit inserts word + delimiter).
        if window.hasPrefix(previousContext) {
            return .evolution(appendedAfterContext: String(window.dropFirst(previousContext.count)))
        }

        if selfEdit != nil {
            // Trailing-delimiter rewrite of a committed word (ours only):
            // the space-commit dot attachment "hestur␣" → "hestur.", the
            // tap-then-'.' auto-space dance "hestur␣" → "hestur.␣", the
            // double-space ender. The text up to the committed word is
            // unchanged and only delimiters follow it.
            let core = Self.droppingTrailingDelimiters(previous)
            if !core.isEmpty, core.count < previous.count, window.count > core.count,
                window.hasPrefix(core), window.dropFirst(core.count).allSatisfy(Self.isDelimiter)
            {
                return .delimiterRewrite(
                    sentenceBoundary: Self.endsWithSentenceBoundary(window)
                        && !Self.endsWithSentenceBoundary(previous))
            }
        }

        // Sliding window (length-capped proxy): the front of the previous
        // window was truncated away while the user kept typing. Align the
        // longest suffix of `previous` that is a prefix of `window`; accept
        // only keystroke-sized growth past the overlap.
        var index = previous.index(after: previous.startIndex)
        while index < previous.endIndex {
            let candidate = previous[index...]
            if window.hasPrefix(candidate) {
                let appended = window.count - candidate.count
                if appended <= 4 {
                    let context = Self.splitCurrentWord(of: String(candidate)).context
                    return .evolution(appendedAfterContext: String(window.dropFirst(context.count)))
                }
                break
            }
            index = previous.index(after: index)
        }

        guard selfEdit != nil else { return .external }

        // Slide + replace (ours only): at the length cap the delimiter that
        // APPLIED an autocorrect both slid the window and replaced the
        // pending word (" ok hestr" → "k hestur "), so no suffix of the
        // whole previous window survives. Align a suffix of the previous
        // COMMITTED CONTEXT instead; what follows it is the committed word
        // (plus delimiters) — or an emitted multi-word split.
        // (An empty previous context never reaches here: every window has
        // prefix "" and the append branch above takes it.)
        var contextIndex = previousContext.isEmpty
            ? previousContext.endIndex : previousContext.index(after: previousContext.startIndex)
        while contextIndex < previousContext.endIndex {
            let candidate = previousContext[contextIndex...]
            if window.hasPrefix(candidate) {
                let appended = String(window.dropFirst(candidate.count))
                let tokens = Self.wordTokens(in: appended)
                let joined = tokens.joined(separator: " ")
                if tokens.count <= 1
                    || lastEmittedSuggestionTexts.contains(where: { $0 == joined || $0 == joined + "." })
                {
                    return .evolution(appendedAfterContext: appended)
                }
                break
            }
            contextIndex = previousContext.index(after: contextIndex)
        }

        // Lagging boundary cut (ours only): hosts whose window still shows
        // "hestur. " / "hestur\n" right after the delimiter drop the old
        // sentence only with the next keystroke, so the window becomes just
        // that keystroke ("o"). The boundary was fully observed (nothing is
        // pending) and the new window is one token at most — a keystroke
        // or one tapped prediction, never a paste.
        if previousCurrentWord.isEmpty,
            Self.endsWithSentenceBoundary(previous) || previous.last?.isNewline == true,
            !window.isEmpty, !window.contains(where: \.isNewline),
            Self.wordTokens(in: window).count <= 1
        {
            return .newSentenceStart
        }

        return .external
    }

    /// `text` without its trailing run of delimiter characters (whitespace
    /// and delimiter punctuation, judged by character class).
    private static func droppingTrailingDelimiters(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, isDelimiter(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }

    /// Does `text` END with a sentence boundary — its last non-whitespace
    /// character is a terminator that is a delimiter at its position? A
    /// deferred trailing dot ("hestur.") is not one yet; "hestur. " and
    /// "hestur!" are.
    private static func endsWithSentenceBoundary(_ text: String) -> Bool {
        guard let index = text.lastIndex(where: { !$0.isWhitespace }) else { return false }
        return isSentenceTerminator(text[index]) && isDelimiter(at: index, in: text)
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return isSentenceTerminator(last)
    }

    /// Does `text` contain a sentence terminator that is ACTUALLY a
    /// delimiter at its position ('!'/'?' always; '.' only when not
    /// word-internal/deferred)? Keeps URL commits ("…tilvinstri.is ") from
    /// being mistaken for sentence boundaries.
    private static func containsSentenceBoundary(_ text: String) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "!" || ch == "?" { return true }
            if ch == ".", isDelimiter(at: index, in: text) { return true }
            index = text.index(after: index)
        }
        return false
    }

    // MARK: - Word commit

    /// Minimal word-commit detection for the language posterior (full
    /// learning integration is M2): a word counts as committed when the
    /// previous call had a word in progress, this call doesn't — i.e. the
    /// user just typed a delimiter (space/period-then-space/…) after it, or
    /// applied a toolbar suggestion / autocorrect (both insert the word + a
    /// space) — AND the window change actually added that word+delimiter
    /// after the previous context. Backspacing a word-in-progress away adds
    /// nothing (no commit), and a change that introduced several words at
    /// once is a host paste/autofill, not a user keystroke (no commit). The
    /// confirmed word is read back out of the committed text so it reflects
    /// any applied correction, not the raw typed fragment.
    private func confirmIfCommitted(
        context: String,
        currentWord: String,
        appendedAfterContext: String
    ) {
        guard currentWord.isEmpty, !previousCurrentWord.isEmpty else { return }
        guard !appendedAfterContext.isEmpty else { return }
        let boundary = Self.containsSentenceBoundary(appendedAfterContext)
        // Attached dot on an already-committed word (bug (a)): the word
        // committed at the earlier space; this delimiter only ends the
        // sentence. No second confirmWord, no self-bigram event.
        if previousCurrentWord == committedDotToken {
            if boundary {
                engine.noteSentenceBoundary()
                previousCommittedForEvents = nil
            }
            return
        }
        let appendedTokens = Self.wordTokens(in: appendedAfterContext)
        // A single keystroke commits at most one word — a change that
        // introduced several words at once is a host paste/autofill, never
        // a user keystroke. The one exception: the appended words are
        // exactly a multi-word (space-miss split) suggestion from the
        // previous bar being applied by the delimiter/tap that caused this
        // change ("smelirna" + space → "smellir á "); then each word is a
        // genuine commit, in order, with the final word carrying any
        // sentence boundary.
        if appendedTokens.count > 1 {
            let joined = appendedTokens.joined(separator: " ")
            guard
                lastEmittedSuggestionTexts.contains(where: {
                    $0 == joined || $0 == joined + "."
                })
            else { return }
            // A split correction commits each word in order; each is logged
            // as a wordCommitted (chaining previousWord), which is exactly
            // the pair evidence the personal model wants ("smellir á"). No
            // suggestionAccepted here: the event schema is single-word.
            for (index, token) in appendedTokens.enumerated() {
                confirm(token, sentenceBoundary: boundary && index == appendedTokens.count - 1)
            }
            // The ordinary commit path below arms backspace-revert for a
            // single corrected word. Preserve the same escape hatch for an
            // AUTO-APPLIED missed-space split, retaining the entire phrase
            // so the first backspace can offer the original unsplit token.
            if joined == lastEmittedAutocorrect, previousCurrentWord != joined {
                backspaceRevert = (literal: previousCurrentWord, corrected: joined)
                backspaceRevertJustArmed = true
            }
            return
        }
        guard let committed = Self.lastWord(in: context) else { return }
        // Committed text differing from the pending token, matching a
        // suggestion the previous bar offered = that suggestion was applied
        // (tap or autocorrect-on-delimiter) — a suggestionAccepted event
        // (the raw typed token is a typo by definition, never learned).
        // Bar texts for a deferred-dot token carry the pending dot
        // ("hestur.") while the committed word read back from "hestur. " does
        // not — match either spelling, exactly as the split path above does
        // (fuzz seeds 121/140: a host whose window stays visible at ". "
        // logged such an acceptance as a plain wordCommitted and never armed
        // the backspace-revert slot).
        let typedToken = Self.strippedEventToken(previousCurrentWord)
        let accepted =
            committed != previousCurrentWord && committed != typedToken
            && lastEmittedSuggestionTexts.contains(where: { $0 == committed || $0 == committed + "." })
        // Arm the reserved literal-revert slot only when the committed form
        // is exactly the AUTOCORRECT the previous bar armed (an engine
        // force-correction the user may want to reject) — not a manual tap of
        // an alternative, nor a verbatim tap. The literal is the raw typed
        // token, byte-exact (quote/casing/accents preserved), taken from the
        // session's own record of the pending word — never re-derived.
        let revertLiteral =
            accepted && Self.isSameEmittedText(committed, lastEmittedAutocorrect)
            ? previousCurrentWord : nil
        confirm(
            committed, sentenceBoundary: boundary,
            acceptedFromTyped: accepted ? typedToken : nil,
            revertLiteral: revertLiteral)
    }

    /// The host cut the window at the delimiter our own edit inserted (the
    /// ". " sentence cut; the newline cut after a described Return), in the
    /// same keystroke that committed the pending token: the commit must be
    /// recovered from session state, because the committed text is no
    /// longer visible in any window. What committed, in order of evidence:
    ///  * the replacement the embedder reported for this edit (an applied
    ///    autocorrect, a tapped suggestion) — the text that landed;
    ///  * the typed token when the user chose it via the verbatim slot
    ///    (`verbatimChoice`), or when the embedder described the edit and
    ///    reported no replacement (a plain delimiter, a stale apply skipped
    ///    by the apply guard — fuzz seed 20054 logged a suggestionAccepted
    ///    for an autocorrect nothing ever applied);
    ///  * legacy window-only records: the historical reconstruction — if the
    ///    previous call armed an autocorrect, the delimiter applied it (the
    ///    auto-apply contract of embedders that report nothing more).
    /// A word that was already committed before an attached dot
    /// (`committedDotToken`) is not committed again; only the sentence
    /// boundary is noted.
    private func confirmPendingWordAfterCollapse(
        sentenceBoundary: Bool, edit: ExpectedEditLedger.SelfEdit?
    ) {
        func noteBoundaryIfNew() {
            // The legacy shape ("stór. " → "") noted its boundary when the
            // ". " was observed; the ender/tap-dot collapse ("hestur " → "")
            // is the first and only sight of this one.
            guard sentenceBoundary, !Self.endsWithSentenceBoundary(lastSeenWindow ?? "") else {
                return
            }
            engine.noteSentenceBoundary()
            previousCommittedForEvents = nil
        }
        guard !previousCurrentWord.isEmpty else {
            // Nothing was pending: the word was committed one keystroke
            // earlier (or the collapse was a sentence ender after it); carry
            // it as bigram context across the cut.
            noteBoundaryIfNew()
            carriedContext = lastCommittedWord
            return
        }
        if previousCurrentWord == committedDotToken {
            noteBoundaryIfNew()
            carriedContext = lastCommittedWord
            return
        }
        let typedStem = Self.strippedEventToken(previousCurrentWord)
        let token: String
        let replaced: Bool
        if let replacement = edit?.replacement {
            token = replacement
            replaced = true
        } else if verbatimChoice == previousCurrentWord || verbatimChoice == typedStem
            || edit?.isFullyDescribed == true
        {
            token = previousCurrentWord
            replaced = false
        } else {
            token = lastEmittedAutocorrect ?? previousCurrentWord
            replaced = lastEmittedAutocorrect != nil
        }
        let stem = Self.strippedEventToken(token)
        // A split autocorrect ("smellir á.") recovers as multiple words;
        // ordinary tokens as one.
        let words = Self.wordTokens(in: stem)
        guard !words.isEmpty else {
            carriedContext = lastCommittedWord
            return
        }
        // Single word recovered from a replacement = a suggestion acceptance
        // (same event mapping as the visible-window commit path); the
        // reserved literal-revert slot arms only for the armed AUTOCORRECT,
        // never for a tapped alternative.
        if words.count == 1, replaced, words[0] != typedStem {
            // The reserved slot won't actually show here until the window
            // re-expands past a backspace, but arming keeps the escape hatch
            // available.
            confirm(
                words[0], sentenceBoundary: sentenceBoundary, acceptedFromTyped: typedStem,
                revertLiteral: Self.isSameEmittedText(token, lastEmittedAutocorrect)
                    ? previousCurrentWord : nil)
        } else {
            for (index, word) in words.enumerated() {
                confirm(word, sentenceBoundary: sentenceBoundary && index == words.count - 1)
            }
        }
        carriedContext = words.last
    }

    /// Two bar/committed spellings of one text, a deferred dot apart
    /// ("hestur" ~ "hestur."). nil never matches.
    private static func isSameEmittedText(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a == b || strippedEventToken(a) == strippedEventToken(b)
    }

    /// Arm the punctuation-attachment memo (see `punctuationAttachment`)
    /// when THIS keystroke was a '.' typed exactly one space after a word:
    /// the window ends "word ␣." (single space) and the change appended
    /// exactly that dot — cursor jumps and pastes never arm it.
    private func armPunctuationAttachmentIfAny(
        window: String,
        currentWord: String,
        appendedAfterContext: String
    ) {
        guard currentWord.isEmpty, appendedAfterContext == "." else { return }
        guard window.hasSuffix(" .") else { return }
        guard let beforeSpace = window.dropLast(2).last, Self.isWordable(beforeSpace) else {
            return
        }
        // Only a CURRENT observation may arm a one-shot memo: a window that
        // is still one recorded edit behind shows the '.' as the latest
        // keystroke while the user has typed on (fuzz seed 106, stale read:
        // "sa .x" read as "sa ." armed the memo and the next space deleted
        // the x).
        guard ledger.isCurrent else { return }
        punctuationAttachmentArmed = true
    }

    private func confirm(
        _ committed: String,
        sentenceBoundary: Bool,
        acceptedFromTyped: String? = nil,
        revertLiteral: String? = nil
    ) {
        let before = engine.probabilityIcelandic
        engine.confirmWord(committed)
        committedWordCount += 1
        lastCommittedWord = committed
        verbatimChoice = nil
        // Backspace-revert arming (wave 36): an autocorrect auto-applied on
        // this delimiter commit. Remember the byte-exact literal so the next
        // backspace can offer the one-tap revert; `backspaceRevertJustArmed`
        // keeps the reserved slot off THIS pass (the slot only arms on the
        // backspace that immediately follows the commit).
        if let literal = revertLiteral, literal != committed {
            backspaceRevert = (literal: literal, corrected: committed)
            backspaceRevertJustArmed = true
        }
        if engine.probabilityIcelandic != before {
            posteriorUpdateCount += 1
        }
        bufferCommitEvent(for: committed, acceptedFromTyped: acceptedFromTyped)
        // The delimiter that committed this word is the only place a
        // sentence boundary is observable (the ". " proxy truncation fires
        // one keystroke later, on the space — same boundary, so decaying
        // there too would double-count): relax the lane toward neutral.
        if sentenceBoundary {
            engine.noteSentenceBoundary()
        }
        // Bigram evidence never spans a sentence boundary.
        previousCommittedForEvents = sentenceBoundary ? nil : committed
    }

    /// Learning-event mapping for one genuine word commit. Exactly ONE of
    /// wordCommitted / suggestionAccepted / (nothing, after a verbatim tap
    /// whose wordTapped already covers this commit) is buffered per commit —
    /// never two, so the app-side model never double-counts a word.
    /// Everything is gated on `fieldKind.allowsLearning` plus per-word
    /// validation (see `isEventWord`).
    private func bufferCommitEvent(for committed: String, acceptedFromTyped typed: String?) {
        guard fieldKind.allowsLearning else { return }
        let word = Self.strippedEventToken(committed)
        guard Self.isEventWord(word) else { return }
        // Autocap-artifact stripping at capture (wave 26, session
        // 2026-07-16T22-45-30 — the learning-side half of the leading-cap
        // guard): a SENTENCE-INITIAL commit (no previous word: field start
        // or right after . ! ? — exactly where iOS autocapitalizes) whose
        // leading cap is the only casing on a common base-vocabulary word
        // carries no casing information, so it is learned lowercase and
        // can never title-case future mid-sentence corrections. Genuine
        // proper nouns keep their caps (rare/OOV lowercase fails the
        // artifact test), as does everything mid-sentence.
        let sentenceInitial = previousCommittedForEvents == nil
        func neutralizedAutocap(_ token: String) -> String {
            guard sentenceInitial else { return token }
            return engine.autocapArtifactLowercased(token) ?? token
        }
        if let typed, typed != word, Self.isEventWord(typed) {
            // An accepted suggestion means the typed keys were (by the
            // engine's own judgment) errors — their touch offsets must NOT
            // train the per-key model. No touchSample events here.
            pendingEvents.append(
                .suggestionAccepted(
                    typed: neutralizedAutocap(typed),
                    accepted: neutralizedAutocap(word)
                )
            )
        } else if word == tapLearnedWord {
            // Verbatim tap: wordTapped was already buffered by
            // learnWordImmediately; consuming the memo here keeps this a
            // single event per tap. The verbatim commit IS the literal
            // typed token, so its taps are honest key-intent evidence —
            // and its casing is byte-exact by contract (never neutralized).
            tapLearnedWord = nil
            bufferTouchSamples(forCommittedTypedWord: word)
        } else {
            let previous = previousCommittedForEvents
                .map(Self.strippedEventToken)
                .flatMap { Self.isEventWord($0) ? $0 : nil }
            pendingEvents.append(
                .wordCommitted(
                    word: neutralizedAutocap(word),
                    previousWord: previous,
                    languageHint: languageHint(for: word)
                )
            )
            bufferTouchSamples(forCommittedTypedWord: word)
        }
    }

    /// touchSample emission (PLAN.md "Touch decoding" — the M2 stage-2
    /// groundwork: PersonalModel's TouchKeyStats accumulate per-user
    /// Gaussians from these). Emitted ONLY:
    ///  * alongside a wordCommitted/wordTapped of the token AS TYPED — an
    ///    applied correction means the taps were errors (only confirmed
    ///    text trains the touch model, PLAN stage 2),
    ///  * under the same privacy gates as every event (the caller is
    ///    already inside the `fieldKind.allowsLearning` + `isEventWord`
    ///    gate — committed words in standard fields only),
    ///  * for positions whose recorded resolved character matches the
    ///    committed word's character (alignment paranoia).
    private func bufferTouchSamples(forCommittedTypedWord word: String) {
        guard !pendingTapRecord.isEmpty else { return }
        let typedStem = Array(
            Self.strippedEventToken(previousCurrentWord).lowercased())
        guard !typedStem.isEmpty, typedStem == Array(word.lowercased()) else { return }
        guard pendingTapRecord.count >= typedStem.count else { return }
        for (index, tap) in pendingTapRecord.prefix(typedStem.count).enumerated() {
            guard let tap, tap.char == typedStem[index] else { continue }
            pendingEvents.append(.touchSample(keyChar: tap.char, dx: tap.dxNorm, dy: tap.dyNorm))
        }
        // Consumed: a same-pass multi-word recovery can't double-emit.
        pendingTapRecord = []
    }

    /// Per-word language attribution for wordCommitted events, from the
    /// word's own graded lane evidence (calibrated per-lexicon z-margin) —
    /// NOT from the running lane posterior: attribution must reflect what
    /// the word itself says, or a sletta typed in a strong lane would be
    /// mislabeled and later feed wrong lane statistics back.
    private func languageHint(for word: String) -> LanguageHint {
        let evidence = engine.laneDiagnostics(for: word).evidence
        if evidence > 0 { return .icelandic }
        if evidence < 0 { return .english }
        return .unknown
    }

    /// A word admissible into the learning log: passes EventLog's own
    /// validation (single token, has a letter, no emoji/control), is at
    /// least 2 characters (single-character entries are either already in
    /// the base lexicons — á, í, a, I — at extreme frequency, so learning
    /// them personally adds no ranking value — or stray-tap noise like
    /// "e"/"s" that would otherwise become boosted personal vocabulary;
    /// the same rule the SwiftKey vocabulary import applies, see
    /// `SwiftKeyImport.isImportableWord`), AND is not verbatim-class
    /// (internal '.'/'@' — URL/domain/e-mail-shaped tokens are never
    /// logged, an extra privacy layer on top of the field gate).
    static func isEventWord(_ word: String) -> Bool {
        word.count >= 2
            && EventLog.isLearnableWord(word)
            && !isVerbatimClassToken(word)
    }

    /// Strip the single trailing deferred dot a pending token may carry
    /// ("hestur." → "hestur") so events store clean words.
    static func strippedEventToken(_ token: String) -> String {
        token.hasSuffix(".") ? String(token.dropLast()) : token
    }

    /// Record a host-side '.'-triggered auto-replacement of the pending
    /// token (revert-on-continuation, layer 4): the window evolved from a
    /// pending word ("teh") to a DIFFERENT pending deferred-dot token
    /// ("the.") matching the autocorrect we emitted — i.e. the host applied
    /// the correction on the period keystroke instead of deferring it.
    private func noteDotReplacementIfAny(currentWord: String) {
        guard currentWord.hasSuffix("."), !previousCurrentWord.isEmpty else { return }
        guard currentWord != previousCurrentWord else { return }
        guard currentWord != previousCurrentWord + "." else { return }
        let stem = String(currentWord.dropLast())
        guard stem == lastEmittedAutocorrect else { return }
        // Same currency rule as the attachment memo: a revert instruction
        // built from a lagging observation would undo text the document has
        // already moved past.
        guard ledger.isCurrent else { return }
        dotReplacement = (original: previousCurrentWord + ".", corrected: currentWord)
    }

    // MARK: - Text parsing

    /// Word-delimiter punctuation, mirroring KeyboardKit's canonical
    /// `String.wordDelimiters` set (punctuation, brackets, guillemets,
    /// Tibetan marks, zero-width space); whitespace/newlines are handled via
    /// `Character.isWhitespace`/`isNewline` below. Kept KeyboardKit-free so
    /// the harness and the extension share one definition — this type is now
    /// the single source of truth. Note apostrophes and hyphens are NOT
    /// delimiters, so English contractions ("don't") and hyphenated words
    /// stay one word. '@' is not a delimiter either (e-mail addresses stay
    /// one token), and '.' is only a delimiter position-dependently — see
    /// `isDelimiter(at:in:)`.
    /// Double-quote characters are delimiters (straight, Icelandic „ ", and
    /// English curly " ") so quoted words tokenize cleanly — `„orð` is the
    /// token `orð`, not `„orð`. Single quotes/apostrophes are deliberately NOT
    /// delimiters: they are word-internal in English ("don't", "it's").
    private static let delimiterPunctuation: Set<Character> = Set(".,:;!¡?¿()[]{}<>«»་།\u{200B}\"\u{201E}\u{201C}\u{201D}")

    /// Opening double quotes that mark the pending token as a quoted term
    /// (issue #3): the Icelandic low-9 „ (U+201E, what the IS layout and
    /// iOS smart punctuation open Icelandic quotations with), the straight
    /// " (U+0022, hardware keyboards / smart punctuation off), and the
    /// English curly " (U+201C — the CLOSER of an Icelandic „…" pair, but
    /// the OPENER of an English "…" pair, so before a token it reads as an
    /// opener). All three are already word delimiters (see
    /// `delimiterPunctuation`), which is what puts them at the end of the
    /// committed context when a quoted token is being typed.
    private static let quotedTermOpeners: Set<Character> = ["\u{201E}", "\"", "\u{201C}"]

    /// Whether the committed context ends with an opening double quote —
    /// i.e. the pending token is being typed IMMEDIATELY inside quotes
    /// („orð / "orð). Only adjacency counts: a quotation closed earlier in
    /// the sentence („orð" næsta) leaves a delimiter/space before the new
    /// token and does not suppress anything.
    static func isQuotedTermContext(_ context: String) -> Bool {
        guard let last = context.last else { return false }
        return quotedTermOpeners.contains(last)
    }

    /// Is this character a word delimiter, judged by character class alone?
    /// NOTE: '.' is context-dependent — inside a token ("tilvinstri.is",
    /// "e.g", "3.14") or pending at the end of the text ("word.", commit
    /// deferred to the next keystroke) it is NOT a delimiter. Use
    /// `isDelimiter(at:in:)` / `splitCurrentWord` / `wordTokens` for
    /// position-aware parsing; this predicate answers the class question
    /// only (all callers that need "could this keystroke commit a word?"
    /// semantics, like the harness Typist, combine it with the deferral
    /// rule).
    public static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace
            || character.isNewline
            || delimiterPunctuation.contains(character)
    }

    /// Characters that can be word-internal around a '.'/'@' (URL, domain,
    /// e-mail, file.ext, "e.g.", "3.14").
    private static func isWordable(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Position-aware delimiter test: like `isDelimiter(_:)` except that a
    /// '.' directly after a letter/digit is NOT a delimiter when it is
    /// followed by another letter/digit (word-internal dot) or by the end
    /// of the text (trailing dot whose commit decision is deferred to the
    /// next keystroke — "word. " commits, "word.t" grows one dotted token).
    public static func isDelimiter(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        guard isDelimiter(character) else { return false }
        guard character == "." else { return true }
        guard index > text.startIndex, isWordable(text[text.index(before: index)]) else {
            return true
        }
        let next = text.index(after: index)
        if next == text.endIndex { return false }  // deferred trailing dot
        return !isWordable(text[next])
    }

    /// Is this pending token verbatim-class (layer 3)? True when it
    /// contains a word-internal '.' or '@' — letter/digit on both sides —
    /// i.e. it has URL/domain/e-mail/file shape, OR when it BEGINS with a
    /// non-letter/non-digit ("/goal", "#tag", "~/path", "-flag"): a leading
    /// symbol marks a command/tag/path-like token, and "correcting" it would
    /// eat the prefix (issue #6: "/goal" must never become "goal"). Verbatim-
    /// class tokens are never auto-corrected.
    public static func isVerbatimClassToken(_ token: String) -> Bool {
        if let first = token.first, !isWordable(first) { return true }
        var index = token.startIndex
        while index < token.endIndex {
            let ch = token[index]
            if ch == "." || ch == "@",
                index > token.startIndex,
                isWordable(token[token.index(before: index)])
            {
                let next = token.index(after: index)
                if next < token.endIndex, isWordable(token[next]) {
                    return true
                }
            }
            index = token.index(after: index)
        }
        return false
    }

    /// Smallest useful TLD list for the dotted space-miss escape: a dotted
    /// token whose final segment is one of these is URL-shaped and stays
    /// fully verbatim-class, whatever its halves score ("tilvinstri.is").
    /// Deliberately small — generic + the locally relevant ccTLDs (IS,
    /// Nordics, the usual suspects). Obscure ccTLDs that are also common
    /// word-halves in neither language (e.g. ".er", Eritrea) are left out
    /// on purpose: "sem.er" is overwhelmingly a missed spacebar, not a URL.
    /// Note some entries shadow real English words ("is", "no", "me", "to",
    /// "us") — URL protection wins that conflict by design.
    static let knownTLDs: Set<String> = [
        "is", "com", "net", "org", "io", "app", "dev", "co", "uk", "de",
        "dk", "no", "se", "fi", "fo", "gl", "eu", "us", "edu", "gov",
        "info", "me", "tv", "ai", "to", "fm", "gg", "xyz",
    ]

    /// Shape check for the dotted space-miss escape (dogfood "sem.er"):
    /// the token must be word.word — EXACTLY one dot, no '@', all-letter
    /// halves (digits mean version numbers / filenames), final segment not
    /// a known TLD, and not a "www" stem. Word-COMMONNESS is the engine's
    /// half of the decision (`TypeEngine.dottedSpaceMiss`); this is only
    /// the URL-shape gate.
    static func spaceEscapeHalves(of token: String) -> (left: String, right: String)? {
        guard !token.contains("@") else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }  // exactly one dot
        let left = String(parts[0])
        let right = String(parts[1])
        guard !left.isEmpty, !right.isEmpty else { return nil }
        guard left.allSatisfy(\.isLetter), right.allSatisfy(\.isLetter) else { return nil }
        guard left.lowercased() != "www" else { return nil }
        guard !knownTLDs.contains(right.lowercased()) else { return nil }
        return (left, right)
    }

    /// Trailing segment of a verbatim-class token: the part after the last
    /// non-wordable character ("profilmynd.tilvinstri" → "tilvinstri",
    /// "/goal" → "goal", "#tag" → "tag"). Suggestions for it may still be
    /// offered, tap-only, mapped back onto the full token.
    static func trailingSegment(of token: String) -> String {
        guard let index = token.lastIndex(where: { !isWordable($0) }) else {
            return token
        }
        return String(token[token.index(after: index)...])
    }

    /// Split the text before the cursor into (committed context, word
    /// currently being typed). The current word is the trailing run of
    /// position-aware non-delimiter characters — so it can contain internal
    /// dots/'@' ("tilvinstri.is", "jokull@…") and a single trailing
    /// deferred dot ("word.", commit decision postponed until the next
    /// keystroke reveals what follows). Empty when the text ends with a
    /// definite delimiter (word just committed / sentence start).
    public static func splitCurrentWord(of text: String) -> (context: String, currentWord: String) {
        var wordStart = text.endIndex
        while wordStart > text.startIndex {
            let previous = text.index(before: wordStart)
            if isDelimiter(at: previous, in: text) { break }
            wordStart = previous
        }
        return (
            context: String(text[..<wordStart]),
            currentWord: String(text[wordStart...])
        )
    }

    /// Position-aware word tokens of `text` (delimiters per
    /// `isDelimiter(at:in:)`, so dotted/'@' tokens stay whole).
    static func wordTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            if isDelimiter(at: index, in: text) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(text[index])
            }
            index = text.index(after: index)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Trailing word of committed text, with surrounding delimiters
    /// stripped (position-aware: internal dots survive — "e.g. " → "e.g",
    /// "tilvinstri.is " → the full dotted token); nil if there is none.
    /// A trailing dot at the very end of the text is deferred, hence kept
    /// ("hestur." → "hestur." — not yet a finished word).
    public static func lastWord(in text: String) -> String? {
        wordTokens(in: text).last
    }
}
