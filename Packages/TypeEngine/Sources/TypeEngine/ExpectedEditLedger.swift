import Foundation

/// Ledger of the proxy edits the keyboard itself performed — the azooKey
/// "expected-edit tracker" pattern (research/oss-harvest.md §2:
/// `ExpectedEditTracker.swift` + `DisplayedTextManager.swift` in
/// azooKey/azooKey, MIT; the *pattern* is the harvest, not the code).
///
/// Every proxy mutation the embedder issues (keystroke insert, backspace,
/// autocorrect apply, suggestion tap, revert-on-continuation edit,
/// punctuation attachment, mode-2 prediction insert) is recorded as one
/// expected before → after transform of the truncated before-cursor window.
/// When the next window observation arrives (`TypingSession.suggestions
/// (for:)`), it is matched against the pending expectations:
///
///  * observation == a pending record's `after`  → the change is exactly
///    what we did ourselves (possibly several back-to-back edits confirmed
///    at once); the confirmed records are consumed,
///  * observation == the oldest record's `before` → a stale proxy read
///    (the host has not echoed our edit yet); nothing consumed, the edit
///    should confirm on a later observation,
///  * anything else → EXTERNAL: cursor jump, host mutation, autofill — or
///    an ambiguity resolved conservatively. The session resets pending-word
///    state exactly as `noteExternalTextChange()` would.
///
/// Degradation rules (a keyboard extension must never wedge):
///  * a record unconfirmed after `expiryObservations` observations means
///    the host swallowed the edit — the whole chain is unconfirmable and is
///    dropped (the session falls back to its heuristic window classifier),
///  * a recorded edit whose `before` does not chain onto the previous
///    record (or onto the last observation) means something external
///    happened between our own edits — the next observation is classified
///    external,
///  * more than `capacity` unobserved edits means the observation pipeline
///    is broken — same conservative external-once-then-adopt outcome.
struct ExpectedEditLedger {

    /// One self-caused edit: the truncated before-cursor window snapshotted
    /// immediately before and after the proxy mutation(s) of one logical
    /// action (a keystroke and everything it triggered, a suggestion tap,
    /// a repeat-backspace step, …).
    struct Record {
        let before: String
        let after: String
        /// What the embedder says the edit WAS, beyond its window shape —
        /// consulted only when the observed window cannot show it (the
        /// host cut the window at the delimiter the edit inserted).
        let edit: SelfEdit
        /// Observations that have come and gone without confirming this
        /// record (see `expiryObservations`).
        var unconfirmedObservations = 0
    }

    /// Optional description of one self-caused edit (2026-10 seam audit).
    /// A record that carries a `keystroke` is FULLY DESCRIBED: the
    /// embedder is then on the full reporting contract, so a nil
    /// `replacement` means the pending token was committed as typed. A
    /// record with neither field is a legacy window-only record and the
    /// session reconstructs collapsed commits the historical way.
    struct SelfEdit: Equatable {
        /// The character the user typed when the edit was a keystroke
        /// (space, '.', '\n', letters…); nil for taps, backspaces and
        /// other non-keystroke edits.
        var keystroke: Character?
        /// The text the embedder replaced the pending token with — an
        /// applied autocorrect or a tapped (non-verbatim) suggestion, as
        /// the bar showed it (a deferred-dot token's dot included); nil
        /// when the token was not replaced.
        var replacement: String?

        static let legacy = SelfEdit(keystroke: nil, replacement: nil)
        /// Whether the embedder described this edit (see the type doc).
        var isFullyDescribed: Bool { keystroke != nil || replacement != nil }
    }

    /// How the ledger explains one observed window.
    enum Explanation: Equatable {
        /// No pending expectations (un-instrumented embedder, or everything
        /// already consumed): the caller decides on its own.
        case noRecords
        /// The observation is one of our own recorded edits (everything up
        /// to and including the matched record was consumed).
        case matched
        /// The observation still shows the state from BEFORE our oldest
        /// pending edit — a stale proxy read. Nothing consumed; the edit
        /// should confirm on a later observation ("self-edit confirmed
        /// late").
        case stale
        /// The observation cannot be explained by our pending edits:
        /// external change — or an ambiguity resolved conservatively.
        /// The ledger has been cleared.
        case unexplained
    }

    /// Bounded like azooKey's tracker (ring cap 32): more unobserved edits
    /// than this means observations stopped arriving — degrade, never grow.
    static let capacity = 32
    /// A record still unconfirmed after this many observations expired (the
    /// host swallowed the edit): the chain is unconfirmable and is dropped.
    static let expiryObservations = 3

    private(set) var records: [Record] = []
    /// Set when a recorded edit's `before` did not chain onto the previous
    /// record / the last observation: something external happened between
    /// our own edits ("interleaved self-edit + external change"). The next
    /// observation is classified external, then the flag clears.
    private var chainBroken = false
    /// The description carried by the record the most recent `explain`
    /// MATCHED (nil after any other explanation). When several back-to-back
    /// records confirmed at once this is the LATEST one — the edit whose
    /// `after` is the observed window, i.e. the edit the window shows.
    private(set) var matchedEdit: SelfEdit?

    var isEmpty: Bool { records.isEmpty && !chainBroken }

    /// Whether the last observation caught up with every recorded edit: no
    /// record is still waiting for its window. A one-shot memo (punctuation
    /// attachment, revert-on-continuation) may only arm from a CURRENT
    /// observation — a window that is one edit behind describes a document
    /// the user has already typed past (fuzz seed 106: an attachment armed
    /// from a stale read deleted the user's next letter).
    var isCurrent: Bool { records.isEmpty }

    mutating func clear() {
        records.removeAll()
        chainBroken = false
        matchedEdit = nil
    }

    /// Record one expected self-caused edit. `anchor` is the window the
    /// session last observed (nil before the first observation) — used to
    /// detect edits that do not chain onto known reality. `edit` is the
    /// embedder's optional description of the edit (see `SelfEdit`).
    mutating func record(
        before: String, after: String, anchor: String?, edit: SelfEdit = .legacy
    ) {
        guard before != after else { return }  // proxy no-op: nothing to expect
        if chainBroken { return }  // already condemned; next observation resets
        if let tail = records.last {
            guard before == tail.after else {
                // Our own edits stopped chaining: an external mutation
                // slipped in between. Conservative: condemn the chain.
                records.removeAll()
                chainBroken = true
                return
            }
        } else if let anchor, before != anchor {
            if after == anchor {
                // Retro-confirmed: the observation for this edit was
                // processed before the record landed (device timing race —
                // the autocomplete pass can beat the record onto the engine
                // queue). Nothing left to expect.
                return
            }
            records.removeAll()
            chainBroken = true
            return
        }
        if records.count >= Self.capacity {
            // Observations stopped arriving; nothing pending can be trusted.
            clear()
            chainBroken = true
            return
        }
        records.append(Record(before: before, after: after, edit: edit))
    }

    /// Match one observed window against the pending expectations.
    /// `anchor` is the previous observation's window (nil when fresh).
    mutating func explain(observed: String, anchor: String?) -> Explanation {
        matchedEdit = nil
        if chainBroken {
            clear()
            return .unexplained
        }
        // Retro-drop: records whose outcome the PREVIOUS observation
        // already saw (record landed after its own observation).
        if let anchor {
            while let first = records.first, first.after == anchor {
                records.removeFirst()
            }
        }
        guard !records.isEmpty else { return .noRecords }
        // Anchor consistency: the oldest pending edit must start from the
        // window the session last observed; anything else means the world
        // moved between that observation and our edit.
        if let anchor, records[0].before != anchor {
            clear()
            return .unexplained
        }
        // Matched: largest index wins — several back-to-back edits confirm
        // at once, and when a window string recurs in the chain the latest
        // occurrence is taken (deterministic; the session-visible window is
        // identical either way).
        if let index = records.lastIndex(where: { $0.after == observed }) {
            matchedEdit = records[index].edit
            records.removeSubrange(0...index)
            tickExpiry()
            return .matched
        }
        // Stale read: the observation still shows the pre-edit state.
        if records[0].before == observed {
            tickExpiry()
            return .stale
        }
        clear()
        return .unexplained
    }

    /// Non-consuming variant of `explain` for the belt-and-braces window
    /// note (`TypingSession.noteExternalTextChange(window:)`): would this
    /// observation be explained by the pending expectations?
    func wouldExplain(observed: String, anchor: String?) -> Bool {
        guard !chainBroken else { return false }
        var start = records.startIndex
        if let anchor {
            while start < records.endIndex, records[start].after == anchor {
                start += 1
            }
        }
        guard start < records.endIndex else { return false }
        if let anchor, records[start].before != anchor { return false }
        if records[start].before == observed { return true }
        return records[start...].contains { $0.after == observed }
    }

    /// Age the surviving records by one observation; drop the whole chain
    /// once its oldest record has waited out its expiry (a chained-on edit
    /// can never confirm without its predecessor).
    private mutating func tickExpiry() {
        for index in records.indices {
            records[index].unconfirmedObservations += 1
        }
        if let first = records.first,
            first.unconfirmedObservations >= Self.expiryObservations
        {
            clear()
        }
    }
}
