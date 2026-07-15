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

    // MARK: - Cross-queue fast path (lock-guarded, NOT queue-confined)

    /// Mirror of `session.hasPendingContinuationRevert`, updated on `queue`
    /// after every autocomplete pass and read from the main thread by the
    /// action handler, so the per-keystroke revert consult can skip the
    /// queue round-trip on the overwhelmingly common keystrokes where no
    /// '.'-replacement memo exists.
    private let revertMemoLock = NSLock()
    private var revertMemoArmed = false

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

    // MARK: - Constants

    /// `additionalInfo` key carrying the pending token a suggestion
    /// replaces. `BetterKeyboardActionHandler` uses it to (a) allow the
    /// deferred '.'-apply even though KeyboardKit considers the cursor "at
    /// a new word" after the dot, and (b) verify against the live proxy
    /// text that the suggestion is not stale before applying.
    static let pendingTokenInfoKey = "is.betterkeyboard.pendingToken"

    // MARK: - Init

    init() {
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
            self.fieldKind = kind
            self.session?.fieldKind = kind
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

    // Word learning/ignoring is M2 (LearningStore + personal dictionary).
    // `StandardActionHandler` auto-learns tapped `.unknown` suggestions via
    // `learnWord`, so these must exist but stay no-ops for now.
    var canIgnoreWords: Bool { false }
    var canLearnWords: Bool { false }
    var ignoredWords: [String] { [] }
    var learnedWords: [String] { [] }
    func hasIgnoredWord(_ word: String) -> Bool { false }
    func hasLearnedWord(_ word: String) -> Bool { false }
    func ignoreWord(_ word: String) {}
    func learnWord(_ word: String) {}
    func removeIgnoredWord(_ word: String) {}
    func unlearnWord(_ word: String) {}

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
        let pendingToken = TypingSession.splitCurrentWord(of: text).currentWord
        return .init(
            inputText: text,
            suggestions: suggestions.map { Self.bridge($0, pendingToken: pendingToken) }
        )
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
    static func fieldKind(for context: KeyboardContext) -> FieldKind {
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
