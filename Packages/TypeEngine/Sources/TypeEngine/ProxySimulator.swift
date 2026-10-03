import Foundation

/// Headless model of the iOS `UITextDocumentProxy` contract, for the macOS
/// harness (`type-repl`) and unit tests. Real keyboard extensions never see
/// the whole document: they get a truncated window (`documentContextBefore/
/// AfterInput`), can only `insertText`/`deleteBackward` at the cursor, and
/// must survive cursor jumps, host-app text mutation, and briefly-stale
/// context reads after inserts. This type reproduces those constraints so
/// `TypingSession` can be exercised against them off-device.
///
/// Modeled behaviors (every quirk is OFF by default; the defaults reproduce
/// the historical simulator exactly, so existing scenarios are unaffected):
/// - truncated `contextBeforeInput` (configurable policy; default mimics the
///   common iOS shape: cut at the most recent sentence terminator — ./!/?
///   followed by a space — or a newline, and cap at 200 characters,
///   whichever window is shorter)
///   - `holdsBoundaryUntilTextFollows`: the cut lags one keystroke — a
///     boundary sitting at the very end of the before-text does not cut yet
///     (the window after "stór. " is still "stór. "; after the next letter
///     it is just "ö"). This is the shape KeyboardKit's own
///     `isCursorAtNewSentence` / `isCursorAtNewLine` reads assume (they look
///     for a trailing ". " / "\n" in `documentContextBeforeInput` right
///     after the delimiter was typed).
///   - `capUnit: .utf16`: the length cap is measured in UTF-16 units and may
///     start the window inside a grapheme cluster (a leading combining mark
///     survives as its own `Character`; a lone low surrogate is dropped, as
///     NSString→String bridging would replace it anyway).
/// - `insertText` / `deleteBackward` at the cursor only
///   - `deletionGranularity: .unicodeScalar`: `deleteBackward` removes one
///     Unicode scalar instead of one grapheme (hosts that decompose combining
///     sequences / older emoji-ZWJ handling)
/// - selection: `select(_:)` models a non-empty selected range —
///   `contextBeforeInput` ends at the selection start, `contextAfterInput`
///   begins at its end, `insertText` replaces the selection and ONE
///   `deleteBackward` deletes the selection (UIKit semantics)
/// - cursor moves (`moveCursor`), `adjustTextPosition(byCharacterOffset:)`
///   (optionally measured in UTF-16 units, optionally with a one-read-late
///   effect — `asyncCursorAdjustments`), and wholesale host-app text
///   replacement
/// - optional stale reads: the first context read after an `insertText` /
///   `deleteBackward` returns the pre-insert state (real proxies are briefly
///   stale); `staleReadDepth` lets reads lag up to N edits behind
/// - optional swallowed edits: the host discards keyboard edits before the
///   next observation read (`swallowEdits` — the ledger's "self-edit never
///   confirmed" degradation case)
///
/// Documented out of scope (device-tested, host-app-specific): per-app
/// window sizes and boundary quirks (hosts differ wildly), multi-stage
/// asynchronous context refresh, marked text / IME composition,
/// `documentContextBeforeInput == nil` vs `""` (every KeyboardExt read
/// collapses nil to "" with `?? ""`, and KeyboardKit's `isCursorAtNewWord`
/// treats both identically, so nothing downstream can observe the
/// difference), and field kind (`UIKeyboardType` / `isSecureTextEntry` →
/// `FieldKind` is mapped in `LyklabordAutocompleteService.fieldKind(for:)`,
/// which lives in the extension; duplicating that mapping here would be a
/// second copy that can diverge — tests set `TypingSession.fieldKind`
/// directly instead).
public final class ProxySimulator {

    // MARK: - Truncation policy

    /// Unit in which `TruncationPolicy.maxBeforeLength` is measured.
    public enum CapUnit: Sendable {
        /// Swift `Character`s (grapheme clusters). The historical default:
        /// the window never starts inside a grapheme.
        case characters
        /// UTF-16 code units (NSString length). The window may start inside
        /// a grapheme cluster (leading combining mark) — a lone low surrogate
        /// at the cut is dropped.
        case utf16
    }

    /// How `contextBeforeInput` is cut down from the full text before the
    /// cursor. Real iOS behavior varies by host app; the default here is the
    /// common shape (current sentence, capped length). Use `custom` to model
    /// a specific host.
    public struct TruncationPolicy {
        /// Hard cap on the returned window (applied last), in `capUnit`s.
        public var maxBeforeLength: Int
        /// Cut at the most recent sentence terminator (". ", "! ", "? ") or
        /// newline, returning only the text after it.
        public var cutAtSentenceBoundary: Bool
        /// Full override: given the complete text before the cursor, return
        /// the window the proxy exposes. When set, the other fields are
        /// ignored.
        public var custom: ((String) -> String)?
        /// When true, a sentence/newline boundary at the very END of the
        /// before-text does not cut yet: the previous sentence stays in the
        /// window until the new sentence has at least one character. Off by
        /// default (immediate collapse — the historical simulator shape).
        public var holdsBoundaryUntilTextFollows: Bool
        /// Unit of `maxBeforeLength`. Default `.characters`.
        public var capUnit: CapUnit

        public init(
            maxBeforeLength: Int = 200,
            cutAtSentenceBoundary: Bool = true,
            custom: ((String) -> String)? = nil,
            holdsBoundaryUntilTextFollows: Bool = false,
            capUnit: CapUnit = .characters
        ) {
            self.maxBeforeLength = maxBeforeLength
            self.cutAtSentenceBoundary = cutAtSentenceBoundary
            self.custom = custom
            self.holdsBoundaryUntilTextFollows = holdsBoundaryUntilTextFollows
            self.capUnit = capUnit
        }

        /// The whole text before the cursor, no truncation (for tests).
        public static let none = TruncationPolicy(
            maxBeforeLength: .max,
            cutAtSentenceBoundary: false
        )

        func apply(to full: String) -> String {
            if let custom { return custom(full) }
            var window = Substring(full)
            if cutAtSentenceBoundary {
                window = Self.currentSentence(
                    of: window, holdBoundaryAtEnd: holdsBoundaryUntilTextFollows)
            }
            switch capUnit {
            case .characters:
                if window.count > maxBeforeLength {
                    window = window.suffix(maxBeforeLength)
                }
                return String(window)
            case .utf16:
                return Self.utf16Suffix(of: window, maxUnits: maxBeforeLength)
            }
        }

        /// Text after the most recent sentence terminator (./!/? followed by
        /// a space) or newline; the whole text when there is none. With
        /// `holdBoundaryAtEnd`, a boundary that ends the text is ignored
        /// (the cut only applies once text follows it).
        private static func currentSentence(
            of text: Substring, holdBoundaryAtEnd: Bool
        ) -> Substring {
            var boundary: Substring.Index?
            var previous: Character?
            var index = text.startIndex
            while index < text.endIndex {
                let ch = text[index]
                var candidate: Substring.Index?
                if ch.isNewline {
                    candidate = text.index(after: index)
                } else if ch == " ", let previous, ".!?".contains(previous) {
                    candidate = text.index(after: index)
                }
                if let candidate, !(holdBoundaryAtEnd && candidate == text.endIndex) {
                    boundary = candidate
                }
                previous = ch
                index = text.index(after: index)
            }
            guard let boundary else { return text }
            return text[boundary...]
        }

        /// Trailing `maxUnits` UTF-16 code units of `text`, cut without
        /// regard to grapheme boundaries (a lone low surrogate is dropped).
        private static func utf16Suffix(of window: Substring, maxUnits: Int) -> String {
            let text = String(window)
            let utf16 = text.utf16
            guard utf16.count > maxUnits else { return text }
            var cut = utf16.index(utf16.endIndex, offsetBy: -maxUnits)
            // Inside a surrogate pair: step past the orphaned low surrogate.
            while cut < utf16.endIndex, cut.samePosition(in: text.unicodeScalars) == nil {
                cut = utf16.index(after: cut)
            }
            guard let scalarIndex = cut.samePosition(in: text.unicodeScalars) else {
                return ""
            }
            // Build from scalars so a leading combining mark is preserved as
            // its own (defective) grapheme rather than re-attached.
            var result = String.UnicodeScalarView()
            result.append(contentsOf: text.unicodeScalars[scalarIndex...])
            return String(result)
        }
    }

    // MARK: - Deletion / cursor units

    /// What one `deleteBackward()` removes.
    public enum DeletionGranularity: Sendable {
        /// One grapheme cluster (Swift `Character`) — modern UIKit, default.
        case grapheme
        /// One Unicode scalar: a combining mark or one member of an
        /// emoji ZWJ sequence comes off first (some hosts / older emoji
        /// handling).
        case unicodeScalar
    }

    /// Unit of `adjustTextPosition(byCharacterOffset:)`.
    public enum CursorUnit: Sendable {
        /// Swift `Character`s (grapheme clusters) — default.
        case characters
        /// UTF-16 code units (`NSString` length — what UIKit actually counts;
        /// a landing inside a grapheme is rounded to the cluster boundary in
        /// the direction of travel).
        case utf16
    }

    // MARK: - State

    /// The full document (what the host app holds; the keyboard never sees
    /// all of it).
    public private(set) var document: String
    /// Caret position as a character offset into `document` (0...count).
    /// With a selection, this is the selection START (where
    /// `contextBeforeInput` ends).
    public private(set) var cursor: Int
    /// Number of selected characters starting at `cursor` (0 = plain caret).
    public private(set) var selectionLength: Int = 0

    public var truncation: TruncationPolicy

    /// What one `deleteBackward()` removes. Default `.grapheme`.
    public var deletionGranularity: DeletionGranularity = .grapheme
    /// Unit of `adjustTextPosition(byCharacterOffset:)`. Default `.characters`.
    public var cursorAdjustmentUnit: CursorUnit = .characters
    /// When true, `adjustTextPosition` takes effect one read late: the
    /// first context read after the call still shows the OLD caret (the
    /// well-known asynchronous-adjust quirk); any later read, or any edit,
    /// applies the move first. Off by default.
    public var asyncCursorAdjustments: Bool = false
    private var pendingCursorAdjustment: Int?

    /// When true, the first context read after each `insertText` /
    /// `deleteBackward` returns the pre-edit state — modeling the brief
    /// staleness of real proxies. Off by default.
    public var staleReads: Bool = false
    /// How far observation reads may lag while `staleReads` is on.
    /// Default 1 keeps the historical semantics: the first read after an
    /// edit returns the state before the MOST RECENT edit, once (for a
    /// multi-edit action such as an autocorrect apply that is a mid-action
    /// state). With N > 1 the host echoes whole ACTIONS late: one snapshot is
    /// taken per batch of edits — a batch is everything the keyboard edits
    /// between two of its own read-backs (`trueContextBeforeInput`) or
    /// observation reads, i.e. one embedder action — up to N batches are
    /// queued, and observation reads return them oldest first before a fresh
    /// read. N actions typed without an intervening observation then show up
    /// one action at a time, never mid-action.
    public var staleReadDepth: Int = 1
    /// Edits since the keyboard's last read-back / observation read (batch
    /// tracking for `staleReadDepth > 1`).
    private var editsSinceRead = 0
    /// Pending stale snapshots: (before, after) windows captured pre-edit,
    /// oldest first.
    private var staleSnapshots: [(before: String, after: String)] = []

    /// When true, edits are SWALLOWED by the host: they apply immediately
    /// (the editor's own synchronous read-back — `trueContextBeforeInput` —
    /// sees them, exactly like a real proxy's cache reflects self-issued
    /// edits), but the host discards them before the next observation read
    /// (`contextBeforeInput`/`contextWindows`), which restores and returns
    /// the pre-edit document. Models hosts that reject/undo keyboard input
    /// (read-only-ish fields, validation rollbacks) — the "self-edit never
    /// confirmed" ledger degradation case. Off by default.
    public var swallowEdits: Bool = false
    /// Pre-edit document state to restore at the next observation read
    /// while `swallowEdits` is on (the first edit of a batch captures it).
    private var swallowRestore: (document: String, cursor: Int)?

    public init(
        document: String = "",
        cursorAt cursor: Int? = nil,
        truncation: TruncationPolicy = TruncationPolicy()
    ) {
        self.document = document
        self.cursor = min(cursor ?? document.count, document.count)
        self.truncation = truncation
    }

    // MARK: - Context windows (what the keyboard sees)

    /// Truncated text before the cursor — the analogue of
    /// `documentContextBeforeInput`. Consumes the stale snapshot if one is
    /// pending, and applies a pending host swallow (see `swallowEdits`).
    public var contextBeforeInput: String {
        applySwallowRestoreIfPending()
        if let stale = takeStaleSnapshotIfPending() { return stale.before }
        settleCursorAdjustmentForObservation()
        return truncation.apply(to: fullTextBeforeCursor)
    }

    /// Text after the cursor (after the selection, when there is one) — the
    /// analogue of `documentContextAfterInput` (unbounded here; after-window
    /// truncation is not load-bearing for the engine, which only consumes
    /// the before-window).
    public var contextAfterInput: String {
        applySwallowRestoreIfPending()
        if let stale = takeStaleSnapshotIfPending() { return stale.after }
        settleCursorAdjustmentForObservation()
        return fullTextAfterCursor
    }

    /// Read both windows in one consistent snapshot (a single stale snapshot
    /// covers both, like one proxy read).
    public func contextWindows() -> (before: String, after: String) {
        applySwallowRestoreIfPending()
        if let stale = takeStaleSnapshotIfPending() { return stale }
        settleCursorAdjustmentForObservation()
        return (truncation.apply(to: fullTextBeforeCursor), fullTextAfterCursor)
    }

    /// The selected text — the analogue of `selectedText`; nil for a plain
    /// caret.
    public var selectedText: String? {
        guard selectionLength > 0 else { return nil }
        let start = characterIndex(at: cursor)
        let end = characterIndex(at: cursor + selectionLength)
        return String(document[start..<end])
    }

    /// Ground-truth truncated before-window: what the KEYBOARD ITSELF sees
    /// when it reads back around its own just-issued edits — a real proxy's
    /// cache reflects self-issued edits synchronously (the documented
    /// staleness class is proxy-vs-host divergence on OBSERVATION reads,
    /// not self-read-back; research/oss-harvest.md §2/§4 Hypothesis B).
    /// Bypasses the stale snapshot without consuming it and never triggers
    /// a pending host swallow. This is what the harness Typist snapshots
    /// around every proxy mutation for the session's expected-edit ledger.
    /// A pending asynchronous cursor adjustment IS applied here (the
    /// keyboard's next edit lands at the adjusted caret, so its read-back
    /// must agree with where the edit will go).
    public var trueContextBeforeInput: String {
        applyPendingCursorAdjustment()
        editsSinceRead = 0
        return truncation.apply(to: fullTextBeforeCursor)
    }

    // MARK: - Edits (all the keyboard can do)

    public func insertText(_ text: String) {
        applyPendingCursorAdjustment()
        captureStaleSnapshotIfEnabled()
        captureSwallowRestoreIfEnabled()
        if selectionLength > 0 {
            // Typing over a selection replaces it (UIKit semantics).
            removeSelection()
        }
        // Recount rather than `cursor += text.count`: an inserted combining
        // mark merges into the preceding grapheme ("e" + "\u{301}" is ONE
        // Character), so the caret must follow the composed text.
        let before = String(document.prefix(cursor)) + text
        let after = String(document.suffix(document.count - cursor))
        document = before + after
        cursor = before.count
    }

    public func deleteBackward() {
        applyPendingCursorAdjustment()
        if selectionLength > 0 {
            // One deleteBackward removes the whole selection, nothing else.
            captureStaleSnapshotIfEnabled()
            captureSwallowRestoreIfEnabled()
            removeSelection()
            return
        }
        guard cursor > 0 else { return }
        captureStaleSnapshotIfEnabled()
        captureSwallowRestoreIfEnabled()
        switch deletionGranularity {
        case .grapheme:
            let index = characterIndex(at: cursor - 1)
            document.remove(at: index)
            cursor -= 1
        case .unicodeScalar:
            var before = String(document.prefix(cursor))
            let after = String(document.suffix(document.count - cursor))
            var scalars = before.unicodeScalars
            scalars.removeLast()
            before = String(scalars)
            document = before + after
            // Recount: dropping a scalar can merge/split graphemes.
            cursor = before.count
        }
    }

    /// Move the caret by `offset` units (`cursorAdjustmentUnit`) — the
    /// analogue of `adjustTextPosition(byCharacterOffset:)`. Clamped to the
    /// document bounds; clears any selection. With `asyncCursorAdjustments`
    /// the move becomes visible one observation read late.
    public func adjustTextPosition(byCharacterOffset offset: Int) {
        applyPendingCursorAdjustment()
        selectionLength = 0
        if asyncCursorAdjustments {
            pendingCursorAdjustment = offset
            adjustmentReadsBeforeSettle = 1
        } else {
            performCursorAdjustment(offset)
        }
    }

    // MARK: - Things that happen TO the keyboard

    /// Move the caret to an absolute character offset (cursor jump: user
    /// tapped elsewhere in the text). Clamped to the document bounds; clears
    /// any selection.
    public func moveCursor(to offset: Int) {
        pendingCursorAdjustment = nil
        selectionLength = 0
        cursor = min(max(offset, 0), document.count)
        staleSnapshots.removeAll()
        swallowRestore = nil
    }

    /// Move the caret by a relative delta.
    public func moveCursor(by delta: Int) {
        moveCursor(to: cursor + delta)
    }

    /// The user selects a character range (double-tap / drag handles). The
    /// caret for `contextBeforeInput` purposes sits at the range start;
    /// `contextAfterInput` starts at the range end. An empty range is a
    /// plain caret move. Clamped to the document bounds.
    public func select(_ range: Range<Int>) {
        pendingCursorAdjustment = nil
        let start = min(max(range.lowerBound, 0), document.count)
        let end = min(max(range.upperBound, start), document.count)
        cursor = start
        selectionLength = end - start
        staleSnapshots.removeAll()
        swallowRestore = nil
    }

    /// The host app replaces the text under us (autofill, undo, programmatic
    /// set). Cursor goes to `cursorAt` (default: end of new text).
    public func hostReplaceText(_ newDocument: String, cursorAt: Int? = nil) {
        pendingCursorAdjustment = nil
        selectionLength = 0
        document = newDocument
        cursor = min(cursorAt ?? newDocument.count, newDocument.count)
        staleSnapshots.removeAll()
        swallowRestore = nil
    }

    // MARK: - Internals

    private var fullTextBeforeCursor: String {
        String(document.prefix(cursor))
    }

    private var fullTextAfterCursor: String {
        String(document.suffix(max(document.count - cursor - selectionLength, 0)))
    }

    private func characterIndex(at offset: Int) -> String.Index {
        document.index(document.startIndex, offsetBy: min(max(offset, 0), document.count))
    }

    private func removeSelection() {
        let start = characterIndex(at: cursor)
        let end = characterIndex(at: cursor + selectionLength)
        document.removeSubrange(start..<end)
        selectionLength = 0
    }

    private func performCursorAdjustment(_ offset: Int) {
        switch cursorAdjustmentUnit {
        case .characters:
            cursor = min(max(cursor + offset, 0), document.count)
        case .utf16:
            let utf16 = document.utf16
            let current = utf16.distance(
                from: utf16.startIndex, to: characterIndex(at: cursor).samePosition(in: utf16)!)
            let target = min(max(current + offset, 0), utf16.count)
            var index = utf16.index(utf16.startIndex, offsetBy: target)
            // Round to a Character boundary in the direction of travel.
            if offset >= 0 {
                while index < utf16.endIndex, index.samePosition(in: document) == nil {
                    index = utf16.index(after: index)
                }
            } else {
                while index > utf16.startIndex, index.samePosition(in: document) == nil {
                    index = utf16.index(before: index)
                }
            }
            let characterIndex = index.samePosition(in: document) ?? document.endIndex
            cursor = document.distance(from: document.startIndex, to: characterIndex)
        }
    }

    /// Observation reads still owed the OLD caret after an asynchronous
    /// adjust (see `asyncCursorAdjustments`).
    private var adjustmentReadsBeforeSettle = 0

    private func settleCursorAdjustmentForObservation() {
        guard pendingCursorAdjustment != nil else { return }
        if adjustmentReadsBeforeSettle > 0 {
            adjustmentReadsBeforeSettle -= 1
            return
        }
        applyPendingCursorAdjustment()
    }

    private func applyPendingCursorAdjustment() {
        guard let offset = pendingCursorAdjustment else { return }
        pendingCursorAdjustment = nil
        adjustmentReadsBeforeSettle = 0
        performCursorAdjustment(offset)
    }

    private func captureStaleSnapshotIfEnabled() {
        defer { editsSinceRead += 1 }
        guard staleReads else { return }
        let snapshot = (truncation.apply(to: fullTextBeforeCursor), fullTextAfterCursor)
        if staleReadDepth <= 1 {
            // Historical semantics: only the most recent pre-edit state.
            staleSnapshots = [snapshot]
        } else {
            // Per-action batches: only the first edit after a read opens a
            // new snapshot.
            guard editsSinceRead == 0 else { return }
            staleSnapshots.append(snapshot)
            if staleSnapshots.count > staleReadDepth {
                staleSnapshots.removeFirst(staleSnapshots.count - staleReadDepth)
            }
        }
    }

    /// First swallowed edit of a batch: remember the pre-edit document so
    /// the next observation read can restore it (the host discarding what
    /// the keyboard inserted). Later edits of the same batch keep the
    /// original restore point — the whole batch vanishes together.
    private func captureSwallowRestoreIfEnabled() {
        guard swallowEdits, swallowRestore == nil else { return }
        swallowRestore = (document, cursor)
    }

    private func applySwallowRestoreIfPending() {
        guard let restore = swallowRestore else { return }
        swallowRestore = nil
        document = restore.document
        cursor = restore.cursor
        selectionLength = 0
    }

    private func takeStaleSnapshotIfPending() -> (before: String, after: String)? {
        editsSinceRead = 0
        guard !staleSnapshots.isEmpty else { return nil }
        return staleSnapshots.removeFirst()
    }
}
