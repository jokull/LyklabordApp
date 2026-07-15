import Foundation

/// The kind of text field the session is typing into. UIKit-free mirror of
/// the field types that must never auto-correct (PLAN.md "Verbatim escape
/// hatch + URL handling", layer 2): URL/email/web-search fields keep their
/// suggestions (tap-only), but no suggestion may carry `isAutocorrect`.
public enum FieldKind: String, Equatable, Sendable {
    case standard
    case url
    case email
    case webSearch

    /// Whether autocorrect (auto-apply on delimiter) is suppressed.
    public var suppressesAutocorrect: Bool { self != .standard }
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
/// (`BetterKeyboardAutocompleteService`) and the macOS `type-repl` harness,
/// so the two always run the identical path:
///
/// 1. parse the full text before the cursor into (committed context,
///    word currently being typed) — where '.' and '@' are word-internal
///    when flanked by letters/digits (URLs, domains, e-mails, "e.g.",
///    file.ext), and a '.' typed right after a word is DEFERRED: it only
///    becomes a committing delimiter once the next event shows whitespace/
///    another delimiter after it ("word. " commits; "word.t" keeps growing
///    one dotted token),
/// 2. classify how the window changed since the previous call (append /
///    word-replacement / shrink / truncation slide / external change) and
///    only treat a delimiter-completed word as committed when the change is
///    a valid single-keystroke evolution — cursor jumps and host-app
///    mutations are detected internally and never miscounted as commits,
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
    public func suggestions(for textBeforeCursor: String, limit: Int = 3) -> [Suggestion] {
        // A revert memo not consumed before the next keystroke landed is
        // dead: the continuation window has passed.
        dotReplacement = nil

        let (context, currentWord) = Self.splitCurrentWord(of: textBeforeCursor)

        switch classifyChange(to: textBeforeCursor) {
        case .evolution(let appendedAfterContext):
            noteDotReplacementIfAny(currentWord: currentWord)
            confirmIfCommitted(
                context: context,
                currentWord: currentWord,
                appendedAfterContext: appendedAfterContext
            )
        case .truncationReset:
            // Window collapsed to empty right after a sentence terminator —
            // the proxy's ". " sentence cut. Two shapes:
            confirmPendingWordAfterTruncationReset()
        case .external:
            carriedContext = nil
            verbatimChoice = nil
        }
        if !context.isEmpty {
            // The new window has its own committed context; stop carrying.
            carriedContext = nil
        }

        previousCurrentWord = currentWord
        lastSeenWindow = textBeforeCursor

        let bar = buildSuggestions(
            context: context,
            currentWord: currentWord,
            limit: limit
        )
        lastEmittedAutocorrect = bar.first(where: { $0.isAutocorrect })?.text
        return bar
    }

    /// Tell the session the user committed a token via the verbatim
    /// suggestion slot (the extension's action handler forwards taps on
    /// `.unknown` suggestions; the harness Typist does the same). While the
    /// pending word equals this token, no autocorrect is emitted for it —
    /// an immediately following delimiter can never re-correct the exact
    /// token the user just chose verbatim.
    public func noteVerbatimChoice(_ token: String) {
        verbatimChoice = token
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
        return RevertInstruction(deleteCount: memo.corrected.count, text: memo.original)
    }

    /// Tell the session the text before the cursor changed for a reason
    /// other than typing — cursor jump, host-app mutation (autofill, undo),
    /// switching fields. This clears the pending word-in-progress so the
    /// commit detector doesn't misread the new window as "the user just
    /// finished a word" (spurious `confirmWord`) or attribute a host-inserted
    /// word to the user. The session also detects most external changes
    /// internally (see `classifyChange`); this is the belt-and-braces path.
    public func noteExternalTextChange() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        carriedContext = nil
        dotReplacement = nil
        verbatimChoice = nil
    }

    /// Window-aware variant, safe to forward from the extension's
    /// `textDidChange`/`selectionDidChange` — which ALSO fire after our own
    /// insertions. Idempotent: the note is ignored when `window` is
    /// consistent with the session's own last-seen state (unchanged, or a
    /// valid typing evolution the next `suggestions(for:)` call will handle);
    /// only a genuinely inconsistent window clears the pending word.
    public func noteExternalTextChange(window: String) {
        guard lastSeenWindow != nil else { return }
        if case .external = classifyChange(to: window) {
            noteExternalTextChange()
        }
    }

    /// Forget all per-session state and reset the language posterior to the
    /// 50/50 prior. Harness use (e.g. `:reset`, scenario isolation); the
    /// extension currently keeps one session for its whole lifetime.
    public func reset() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        carriedContext = nil
        dotReplacement = nil
        verbatimChoice = nil
        lastEmittedAutocorrect = nil
        committedWordCount = 0
        posteriorUpdateCount = 0
        lastCommittedWord = nil
        engine.resetLanguagePosterior()
    }

    // MARK: - Suggestion building (verbatim + URL layers)

    /// Assemble the suggestion bar for the parsed window: engine suggestions
    /// with the deferral/verbatim-class/field-gate rules applied, led by the
    /// verbatim escape-hatch slot.
    private func buildSuggestions(
        context: String,
        currentWord: String,
        limit: Int
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }

        // Empty current word: next-word prediction (no verbatim slot).
        if currentWord.isEmpty {
            let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
            return engine.suggestions(
                context: effectiveContext,
                currentWord: "",
                limit: limit
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
                ).map {
                    Suggestion(
                        text: prefix + $0.text + (pendingDot ? "." : ""),
                        isAutocorrect: false,
                        confidence: $0.confidence
                    )
                }
            }
        } else if stem.count >= 2 {
            // ≥2-char gate (see type doc, point 4).
            let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
            engineSuggestions = engine.suggestions(
                context: effectiveContext,
                currentWord: stem,
                limit: limit
            )
            if pendingDot {
                engineSuggestions = engineSuggestions.map {
                    Suggestion(
                        text: $0.text + ".",
                        isAutocorrect: $0.isAutocorrect,
                        confidence: $0.confidence
                    )
                }
            }
        }

        // Field-type gate (layer 2) + verbatim-choice memo (layer 1): keep
        // the suggestions, strip the auto-apply flag.
        if fieldKind.suppressesAutocorrect || verbatimChoice == currentWord
            || verbatimChoice == stem
        {
            engineSuggestions = engineSuggestions.map {
                $0.isAutocorrect
                    ? Suggestion(text: $0.text, isAutocorrect: false, confidence: $0.confidence)
                    : $0
            }
        }

        // Verbatim escape-hatch slot (layer 1): the literal typed token
        // always leads the bar — unless it IS the top engine suggestion
        // (no duplicate).
        var bar: [Suggestion] = []
        if engineSuggestions.first?.text != currentWord {
            bar.append(
                Suggestion(text: currentWord, isAutocorrect: false, confidence: 0, isVerbatim: true)
            )
        }
        bar.append(contentsOf: engineSuggestions)
        return Array(bar.prefix(limit))
    }

    // MARK: - Window-change classification

    private enum WindowChange {
        /// The window is consistent with our last-seen state: unchanged,
        /// appended-to, current word replaced (autocorrect / suggestion
        /// tap), shrunk by deletion, or slid by proxy truncation.
        /// `appendedAfterContext` is the text that appeared after the
        /// previous committed context ("" when nothing was added there).
        case evolution(appendedAfterContext: String)
        /// The window collapsed to empty immediately after a sentence
        /// terminator — the iOS proxy's sentence cut (". " boundary).
        case truncationReset
        /// The window cannot be explained by typing since the last call:
        /// cursor jump, host mutation, field switch.
        case external
    }

    private func classifyChange(to window: String) -> WindowChange {
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
                return .truncationReset
            }
            return .evolution(appendedAfterContext: "")
        }

        // Change confined to at/after the previous word boundary: plain
        // typing, or the current word being replaced by an applied
        // suggestion/autocorrect (KeyboardKit inserts word + delimiter).
        if window.hasPrefix(previousContext) {
            return .evolution(appendedAfterContext: String(window.dropFirst(previousContext.count)))
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

        return .external
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
        // A single keystroke commits at most one word.
        guard Self.wordTokens(in: appendedAfterContext).count <= 1 else { return }
        guard let committed = Self.lastWord(in: context) else { return }
        confirm(
            committed,
            sentenceBoundary: Self.containsSentenceBoundary(appendedAfterContext)
        )
    }

    /// The proxy's ". " sentence cut collapsed the window in the same
    /// keystroke that committed the pending deferred-dot token: the commit
    /// must be recovered from session state, because the corrected text is
    /// no longer visible in any window. If the previous call armed an
    /// autocorrect, the embedder's delimiter keystroke applied it (that is
    /// the auto-apply contract), so the committed form is that suggestion's
    /// stem; otherwise it is the pending token's own stem.
    private func confirmPendingWordAfterTruncationReset() {
        guard !previousCurrentWord.isEmpty else {
            // Legacy shape: the word was already committed one keystroke
            // earlier; just carry it as bigram context across the cut.
            carriedContext = lastCommittedWord
            return
        }
        let token = lastEmittedAutocorrect ?? previousCurrentWord
        let stem = token.hasSuffix(".") ? String(token.dropLast()) : token
        guard let committed = Self.lastWord(in: stem + " ") else {
            carriedContext = lastCommittedWord
            return
        }
        confirm(committed, sentenceBoundary: true)
        carriedContext = committed
    }

    private func confirm(_ committed: String, sentenceBoundary: Bool) {
        let before = engine.probabilityIcelandic
        engine.confirmWord(committed)
        committedWordCount += 1
        lastCommittedWord = committed
        verbatimChoice = nil
        if engine.probabilityIcelandic != before {
            posteriorUpdateCount += 1
        }
        // The delimiter that committed this word is the only place a
        // sentence boundary is observable (the ". " proxy truncation fires
        // one keystroke later, on the space — same boundary, so decaying
        // there too would double-count): relax the lane toward neutral.
        if sentenceBoundary {
            engine.noteSentenceBoundary()
        }
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
    private static let delimiterPunctuation: Set<Character> = Set(".,:;!¡?¿()[]{}<>«»་།\u{200B}")

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
    /// i.e. it has URL/domain/e-mail/file shape. Verbatim-class tokens are
    /// never auto-corrected.
    public static func isVerbatimClassToken(_ token: String) -> Bool {
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

    /// Trailing segment of a verbatim-class token: the part after the last
    /// '.' or '@' ("profilmynd.tilvinstri" → "tilvinstri"). Suggestions for
    /// it may still be offered, tap-only.
    static func trailingSegment(of token: String) -> String {
        guard let index = token.lastIndex(where: { $0 == "." || $0 == "@" }) else {
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
