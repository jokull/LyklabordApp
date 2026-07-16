import Foundation
import Lexicon

// MARK: - Per-position cost seam

/// Per-position character-level likelihood seam for the beam decoder.
///
/// The decoder prices every hypothesized "the user tapped `typed` but meant
/// `intended`" substitution through this protocol instead of calling the
/// static `SpatialModel` directly, because coordinate evidence will later
/// flow in PER TAP (PLAN.md "Touch decoding", stage 1) — and it works both
/// directions:
///
///  * a tap that landed near a key BOUNDARY makes the neighbor substitution
///    cheap (enables corrections the static model prices at ~1 nat anyway),
///  * a tap that landed DEAD CENTER makes every substitution expensive — a
///    correction veto: believe the user, they hit exactly what they meant.
///
/// `confidence(position:)` exists for the same wave: the corrector will
/// aggregate per-word tap confidence to modulate the autocorrect margin
/// (a word typed with all-center taps should almost never auto-replace).
/// Today the only concrete provider is the static keyboard-geometry one
/// below, whose confidence is a constant — the seam exists so the
/// coordinate-plumbing wave swaps providers without touching the beam.
public protocol PositionCostProvider {
    /// -log P(typed char | intended char) at this typed-character position,
    /// in nats. 0 when equal.
    func substitutionCost(position: Int, typed: Character, intended: Character) -> Double
    /// How confidently the tap at `position` selects its resolved character,
    /// in [0, 1]. Constant 1 until per-tap coordinates flow.
    func confidence(position: Int) -> Double
}

/// The static provider: key-center Gaussian distances from `SpatialModel`,
/// identical at every position; no per-tap evidence, so confidence is 1.
struct StaticSpatialCostProvider: PositionCostProvider {
    let spatial: SpatialModel

    func substitutionCost(position: Int, typed: Character, intended: Character) -> Double {
        spatial.substitutionCost(typed: typed, intended: intended)
    }

    func confidence(position: Int) -> Double { 1.0 }
}

// MARK: - Beam decoder

/// Beam-search spatial decoder: finds lexicon words reachable from the typed
/// token by spatially-plausible edits, by walking typed characters and a
/// lexicon prefix cursor in lockstep (uniform-cost search over
/// (prefix range, chars consumed) states).
///
/// This replaces the edits1/edits2 generate-and-test passes as the PRIMARY
/// candidate source: instead of materializing ~500–150k candidate strings
/// and probing each against the lexicon (~30µs a probe — the koetip 31ms
/// landmine), the search only ever visits prefixes the lexicon actually
/// contains, so multi-position adjacent-key noise ("koetip" → "kortið",
/// two 1-nat substitutions) is found in well under a millisecond.
///
/// Walk representation: per typed CHARACTER (extended grapheme cluster; for
/// this alphabet always a single scalar, 1–2 UTF-8 bytes). Every descend
/// appends one whole character's UTF-8 to the byte-sorted pool cursor, so
/// cursors stay scalar-aligned by construction — the byte-sortedness of the
/// pool is an implementation detail the decoder never observes partially.
///
/// Ops per state (all costs in nats, same currency as `SpatialModel`):
///  * match          — consume typed char, descend by it, cost 0
///  * substitution   — consume typed char, descend by a NEIGHBOR character,
///                     priced per position by the `PositionCostProvider`;
///                     the first edit may substitute ANY alphabet character
///                     (parity with the old edits1), later edits only the
///                     precomputed cheap-neighbor set (≤ beamNeighborMaxCost
///                     from static key geometry — a slightly generous
///                     superset that stays valid when coordinate evidence
///                     shifts costs around a tap point, since taps are
///                     spatially local)
///  * transposition  — consume two typed chars, descend in swapped order
///  * deletion       — consume typed char without descending (user typed an
///                     unintended extra character; `Costs.insertion`)
///  * insertion      — descend without consuming (user omitted an intended
///                     character; `Costs.deletion`), including after the
///                     last typed char
///
/// States dedup on (range lower bound, byte depth, chars consumed) — that
/// triple identifies the prefix — keeping the min accumulated cost, so the
/// emitted cost is the minimum over alignments within the edit/cost bounds.
/// Uniform-cost order means candidates emit cheapest-first: budget or cap
/// exhaustion sheds only the least plausible tail.
final class BeamDecoder {
    let config: EngineConfig
    /// Full candidate alphabet with precomputed UTF-8 (insertions + the
    /// first edit's substitutions).
    private let alphabet: [(char: Character, bytes: [UInt8])]
    /// Cheap spatial neighbors per alphabet character (static geometry:
    /// keys within `beamNeighborMaxCost` nats ≈ 1.5 key widths, accent
    /// twins, orthographic-confusion pairs), for second/third edits.
    private let cheapNeighbors: [Character: [(char: Character, bytes: [UInt8])]]

    /// Memo for SHALLOW descends (byte depth ≤ 2 at the parent). The first
    /// two levels of the walk sit on huge ranges (the whole table, then a
    /// first-letter bucket), so their binary searches are the widest — and
    /// they repeat identically across states, keystrokes and words. The
    /// memo is bounded by construction (≤ alphabet² entries per level per
    /// lexicon) and lives for the corrector's lifetime; correctness is
    /// unaffected because descend is a pure function of (lexicon, cursor,
    /// bytes). Keyed per lexicon identity index (0 = IS, 1 = EN).
    private struct ShallowKey: Hashable {
        let lexicon: Int
        let lowerBound: Int
        let byteDepth: Int
        let char: Character
    }
    private var shallowCache: [ShallowKey: LexiconPrefixCursor] = [:]

    /// Ranges at or below this size are expanded by scanning their actual
    /// children (`childCursors`) instead of probing per character.
    static let childScanLimit = 48

    init(config: EngineConfig, spatial: SpatialModel) {
        self.config = config
        var alphabet: [(char: Character, bytes: [UInt8])] = []
        for ch in Corrector.alphabet {
            alphabet.append((ch, Array(String(ch).utf8)))
        }
        self.alphabet = alphabet
        var neighbors: [Character: [(char: Character, bytes: [UInt8])]] = [:]
        for typed in Corrector.alphabet {
            neighbors[typed] = alphabet.filter { entry in
                entry.char != typed
                    && spatial.substitutionCost(typed: typed, intended: entry.char)
                        <= config.beamNeighborMaxCost
            }
        }
        self.cheapNeighbors = neighbors
    }

    private struct State {
        var cursor: LexiconPrefixCursor
        var consumed: Int
        var cost: Double
        var edits: Int
    }

    private struct VisitKey: Hashable {
        let lowerBound: Int
        let byteDepth: Int
        let consumed: Int
    }

    /// Decode `typed` against one lexicon. Returns up to
    /// `beamMaxCandidates` (word, accumulated channel cost) pairs, cheapest
    /// first. The caller re-scores with the exact DP (`Corrector
    /// .spatialCost`) — the beam cost is a search/pruning currency only.
    func decode(
        typed: [Character],
        lexicon: PrefixSearchableLexicon,
        lexiconIndex: Int,
        costs positionCosts: PositionCostProvider,
        maxEdits: Int
    ) -> [(word: String, cost: Double)] {
        let n = typed.count
        guard n > 0, maxEdits >= 0 else { return [] }
        let start = ContinuousClock.now
        let costCap = config.beamCostCap
        let insertionCost = config.spatialCosts.deletion  // omitted intended char
        let deletionCost = config.spatialCosts.insertion  // extra typed char
        let transpositionCost = config.spatialCosts.transposition
        let typedBytes: [[UInt8]] = typed.map { Array(String($0).utf8) }

        /// Descend with the shallow-level memo (see `shallowCache`).
        func descend(
            _ cursor: LexiconPrefixCursor, char: Character, bytes: [UInt8]
        ) -> LexiconPrefixCursor {
            // Memo key soundness: distinct NON-empty prefix cursors at the
            // same depth occupy disjoint ranges, so (depth, lowerBound)
            // identifies the prefix; empty cursors (which could alias a
            // neighbor's lowerBound) are never memoized — expansion only
            // descends from non-empty cursors anyway.
            guard cursor.byteDepth <= 2, !cursor.isEmpty else {
                return lexicon.descend(cursor, appendingUTF8: bytes)
            }
            let key = ShallowKey(
                lexicon: lexiconIndex,
                lowerBound: cursor.lowerBound,
                byteDepth: cursor.byteDepth,
                char: char
            )
            if let cached = shallowCache[key] { return cached }
            let result = lexicon.descend(cursor, appendingUTF8: bytes)
            shallowCache[key] = result
            return result
        }

        var heap = BinaryHeap()
        var visited: [VisitKey: Double] = [:]
        var results: [(word: String, cost: Double)] = []
        var emitted = Set<String>()

        let multiEditCap = min(costCap, config.beamMultiEditCostCap)
        func push(_ state: State) {
            let cap = state.edits >= 2 ? multiEditCap : costCap
            guard state.cost <= cap, !state.cursor.isEmpty else { return }
            let key = VisitKey(
                lowerBound: state.cursor.lowerBound,
                byteDepth: state.cursor.byteDepth,
                consumed: state.consumed
            )
            if let best = visited[key], best <= state.cost { return }
            visited[key] = state.cost
            heap.push(state)
        }

        push(
            State(cursor: lexicon.prefixRootCursor(), consumed: 0, cost: 0, edits: 0)
        )

        let deadline = ContinuousClock.now + .seconds(config.beamTimeBudget)
        var expansions = 0
        while let state = heap.pop() {
            // Lazy-deletion check: a cheaper duplicate may have superseded
            // this entry after it was pushed.
            let key = VisitKey(
                lowerBound: state.cursor.lowerBound,
                byteDepth: state.cursor.byteDepth,
                consumed: state.consumed
            )
            if let best = visited[key], best < state.cost { continue }

            if state.consumed == n {
                if let entry = lexicon.exactEntry(in: state.cursor),
                    emitted.insert(entry.word).inserted
                {
                    results.append((entry.word, state.cost))
                    if results.count >= config.beamMaxCandidates { break }
                }
            }

            // Emit-margin early stop: states pop in cost order, so once the
            // frontier sits far above the best emitted candidate, nothing
            // it can still reach will survive the language re-rank (whose
            // swing is bounded by λ·τ·Δz, well under the margin).
            if let cheapest = results.first,
                state.cost > cheapest.cost + config.beamEmitCostMargin
            {
                break
            }

            expansions += 1
            if expansions > config.beamMaxExpansions { break }
            if expansions % 64 == 0, ContinuousClock.now >= deadline { break }

            let editsLeft = state.edits < maxEdits

            // Small ranges expand over their ACTUAL children (one linear
            // scan) instead of probing the alphabet with binary searches —
            // this is what keeps deep states nearly free. Large ranges
            // (near the root) fall back to probing, cushioned by the
            // shallow memo.
            var childMap: [Character: LexiconPrefixCursor]?
            if let children = lexicon.childCursors(
                of: state.cursor, scanLimit: Self.childScanLimit)
            {
                var map: [Character: LexiconPrefixCursor] = [:]
                map.reserveCapacity(children.count)
                for child in children { map[child.character] = child.cursor }
                childMap = map
            }

            func step(_ char: Character, _ bytes: [UInt8]) -> LexiconPrefixCursor? {
                if let childMap { return childMap[char] }
                return descend(state.cursor, char: char, bytes: bytes)
            }

            if state.consumed < n {
                let typedChar = typed[state.consumed]

                // match
                if let next = step(typedChar, typedBytes[state.consumed]) {
                    push(
                        State(
                            cursor: next,
                            consumed: state.consumed + 1,
                            cost: state.cost,
                            edits: state.edits
                        )
                    )
                }

                if editsLeft {
                    // substitution: the first edit may substitute ANY
                    // character up to the cost cap (edits1 parity — far-key
                    // single subs stay suggestible); later edits only the
                    // cheap-neighbor radius (beamNeighborMaxCost). With a
                    // child map the children themselves are iterated and
                    // priced through the provider — the same set, since
                    // membership is decided by the provider cost either
                    // way; without one, the static candidate lists bound
                    // the probes and cost is checked BEFORE each descend.
                    let subCap = state.edits == 0 ? costCap : min(costCap, config.beamNeighborMaxCost + state.cost)
                    if let childMap {
                        for (char, next) in childMap where char != typedChar {
                            let cost =
                                state.cost
                                + positionCosts.substitutionCost(
                                    position: state.consumed, typed: typedChar, intended: char)
                            guard cost <= subCap else { continue }
                            push(
                                State(
                                    cursor: next,
                                    consumed: state.consumed + 1,
                                    cost: cost,
                                    edits: state.edits + 1
                                )
                            )
                        }
                    } else {
                        let candidates =
                            state.edits == 0
                            ? alphabet
                            : cheapNeighbors[typedChar] ?? []
                        for entry in candidates where entry.char != typedChar {
                            let cost =
                                state.cost
                                + positionCosts.substitutionCost(
                                    position: state.consumed, typed: typedChar, intended: entry.char)
                            guard cost <= subCap else { continue }
                            push(
                                State(
                                    cursor: descend(
                                        state.cursor, char: entry.char, bytes: entry.bytes),
                                    consumed: state.consumed + 1,
                                    cost: cost,
                                    edits: state.edits + 1
                                )
                            )
                        }
                    }

                    // deletion: the typed char was unintended.
                    // (No descend, so the visit key changes only in
                    // `consumed`.)
                    if state.cost + deletionCost <= costCap {
                        push(
                            State(
                                cursor: state.cursor,
                                consumed: state.consumed + 1,
                                cost: state.cost + deletionCost,
                                edits: state.edits + 1
                            )
                        )
                    }

                    // transposition of two adjacent typed chars.
                    if state.consumed + 1 < n,
                        typed[state.consumed] != typed[state.consumed + 1],
                        state.cost + transpositionCost <= costCap,
                        let first = step(typed[state.consumed + 1], typedBytes[state.consumed + 1]),
                        !first.isEmpty
                    {
                        push(
                            State(
                                cursor: descend(
                                    first, char: typedChar, bytes: typedBytes[state.consumed]),
                                consumed: state.consumed + 2,
                                cost: state.cost + transpositionCost,
                                edits: state.edits + 1
                            )
                        )
                    }
                }
            }

            // insertion: the user omitted an intended character — legal at
            // any point INCLUDING after the last typed char (trailing
            // omissions; the DP re-score prices strict-prefix completions
            // down to completionCharCost, mirroring the old edits1).
            if editsLeft, state.cost + insertionCost <= costCap {
                if let childMap {
                    for (_, next) in childMap {
                        push(
                            State(
                                cursor: next,
                                consumed: state.consumed,
                                cost: state.cost + insertionCost,
                                edits: state.edits + 1
                            )
                        )
                    }
                } else {
                    for entry in alphabet {
                        push(
                            State(
                                cursor: descend(state.cursor, char: entry.char, bytes: entry.bytes),
                                consumed: state.consumed,
                                cost: state.cost + insertionCost,
                                edits: state.edits + 1
                            )
                        )
                    }
                }
            }
        }
        if Self.debugEnabled {
            let us = start.duration(to: .now)
            print(
                "beam: typed=\(String(typed)) lex=\(lexiconIndex) expansions=\(expansions) "
                    + "visited=\(visited.count) results=\(results.count) t=\(us)")
        }
        return results
    }

    private static let debugEnabled =
        ProcessInfo.processInfo.environment["TYPE_BEAM_DEBUG"] != nil

    /// Minimal binary min-heap on `State.cost` (ties broken arbitrarily —
    /// dedup and the final DP re-score make the order within a cost tie
    /// irrelevant).
    private struct BinaryHeap {
        private var storage: [State] = []

        mutating func push(_ element: State) {
            storage.append(element)
            var child = storage.count - 1
            while child > 0 {
                let parent = (child - 1) >> 1
                guard storage[child].cost < storage[parent].cost else { break }
                storage.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> State? {
            guard let first = storage.first else { return nil }
            let last = storage.removeLast()
            if !storage.isEmpty {
                storage[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    guard left < storage.count else { break }
                    let right = left + 1
                    var smallest = left
                    if right < storage.count, storage[right].cost < storage[left].cost {
                        smallest = right
                    }
                    guard storage[smallest].cost < storage[parent].cost else { break }
                    storage.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return first
        }
    }
}
