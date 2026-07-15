import Foundation

/// Keyboard-adjacency likelihood model for the Icelandic layout.
///
/// Key centers live on a unit grid (1.0 = one key width) with iOS-style row
/// stagger. P(typed char | intended char) follows a Gaussian over the distance
/// between key centers: exp(-d² / 2σ²), σ ≈ 0.7 key widths. The corrector
/// consumes -log of that as a substitution cost; insertions, deletions and
/// transpositions carry tuned constant costs. All costs are in nats.
public struct SpatialModel: Sendable {

    public struct Costs: Sendable {
        /// User typed an extra character that was not intended.
        public var insertion: Double = 4.0
        /// User omitted a character they intended.
        public var deletion: Double = 4.0
        /// Two adjacent characters swapped.
        public var transposition: Double = 2.0
        /// Floor for any substitution between distinct characters, even when
        /// they share a key position (accent variants reached by long-press:
        /// a→á etc.). Keeps missing-accent typos very cheap but never free.
        public var minSubstitution: Double = 0.35
        /// Cap so that far-apart keys don't produce unbounded costs; a capped
        /// substitution stays comparable to insertion+deletion.
        public var maxSubstitution: Double = 8.0
        /// Substitution involving a character with no key position at all.
        public var unknownCharSubstitution: Double = 5.0
        /// Orthographic (not spatial) confusion pairs: d↔ð, o↔ö, ð↔þ, t↔þ.
        /// These are spatially far on the layout but linguistically common
        /// Icelandic slips, so they get a flat moderate cost.
        public var orthographicConfusion: Double = 1.5
        /// Gaussian width in key widths.
        public var sigma: Double = 0.7
        public init() {}
    }

    /// Icelandic iOS layout rows.
    public static let icelandicRows: [String] = [
        "qwertyuiopð",
        "asdfghjklæö",
        "zxcvbnmþ",
    ]

    /// iOS-style row stagger: home row shifted +0.5, bottom row a further +0.25.
    static let rowOffsets: [Double] = [0.0, 0.5, 0.75]

    /// Horizontal span of the spacebar, in the same key-width units as the
    /// letter grid. On the iOS iPhone layout the bottom function row is
    /// `[123] [globe] [space...] [.] [return]`; the spacebar occupies
    /// roughly the middle five key widths of the ~10-key-wide keyboard.
    /// Bottom-row letters whose key centers fall inside this span sit
    /// directly above the spacebar — a tap intended for space can land on
    /// them (and vice versa). With the current geometry that derives
    /// c v b n m (z, x and þ sit over the 123/globe/./return keys instead).
    static let spacebarXSpan: ClosedRange<Double> = 2.5...7.5

    /// Accented characters are entered via long-press on their base key, so
    /// they share that key's position (the `minSubstitution` floor still
    /// applies between distinct characters).
    static let accentBase: [Character: Character] = [
        "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y",
    ]

    /// Common Icelandic orthographic confusions that are NOT spatially close.
    static let confusionPairs: Set<String> = {
        var set = Set<String>()
        for (a, b) in [("d", "ð"), ("o", "ö"), ("ð", "þ"), ("t", "þ")] {
            set.insert(a + b)
            set.insert(b + a)
        }
        return set
    }()

    public let costs: Costs
    /// Letters on the bottom letter row whose key centers lie within the
    /// spacebar's horizontal span (see `spacebarXSpan`) — derived from the
    /// layout geometry, not hardcoded. A tap on one of these may be a
    /// missed spacebar tap (space-substitution splits in the corrector).
    public let spaceAdjacentLetters: Set<Character>
    private let positions: [Character: SIMD2<Double>]

    public init(costs: Costs = Costs()) {
        self.costs = costs
        var pos: [Character: SIMD2<Double>] = [:]
        for (rowIndex, row) in Self.icelandicRows.enumerated() {
            for (colIndex, char) in row.enumerated() {
                pos[char] = SIMD2(Self.rowOffsets[rowIndex] + Double(colIndex), Double(rowIndex))
            }
        }
        for (accented, base) in Self.accentBase {
            pos[accented] = pos[base]
        }
        self.positions = pos
        let bottomRowIndex = Double(Self.icelandicRows.count - 1)
        self.spaceAdjacentLetters = Set(
            pos.filter { $0.value.y == bottomRowIndex && Self.spacebarXSpan.contains($0.value.x) }
                .keys
        )
    }

    /// -log P(typed | intended) for a single character substitution.
    /// 0 when the characters are equal.
    public func substitutionCost(typed: Character, intended: Character) -> Double {
        if typed == intended { return 0 }
        if Self.confusionPairs.contains(String(typed) + String(intended)) {
            return costs.orthographicConfusion
        }
        guard let p = positions[typed], let q = positions[intended] else {
            return costs.unknownCharSubstitution
        }
        let delta = p - q
        let d2 = delta.x * delta.x + delta.y * delta.y
        let gaussian = d2 / (2 * costs.sigma * costs.sigma)
        return min(max(gaussian, costs.minSubstitution), costs.maxSubstitution)
    }

    /// P(typed char | intended char) as a likelihood in [0, 1].
    public func likelihood(typed: Character, intended: Character) -> Double {
        exp(-substitutionCost(typed: typed, intended: intended))
    }

    /// -log P_spatial(typed | intended): restricted Damerau-Levenshtein
    /// distance where substitutions use key-distance costs and
    /// insert/delete/transpose use the tuned constants.
    public func typingCost(typed: [Character], intended: [Character]) -> Double {
        let n = typed.count
        let m = intended.count
        if n == 0 { return Double(m) * costs.deletion }
        if m == 0 { return Double(n) * costs.insertion }

        // dp[i][j] = cost of producing typed[0..<i] while intending intended[0..<j]
        let width = m + 1
        var dp = [Double](repeating: 0, count: (n + 1) * width)
        for i in 1...n { dp[i * width] = Double(i) * costs.insertion }
        for j in 1...m { dp[j] = Double(j) * costs.deletion }

        for i in 1...n {
            for j in 1...m {
                let sub = dp[(i - 1) * width + (j - 1)]
                    + substitutionCost(typed: typed[i - 1], intended: intended[j - 1])
                let ins = dp[(i - 1) * width + j] + costs.insertion
                let del = dp[i * width + (j - 1)] + costs.deletion
                var best = min(sub, ins, del)
                if i >= 2, j >= 2,
                    typed[i - 1] == intended[j - 2],
                    typed[i - 2] == intended[j - 1],
                    typed[i - 1] != typed[i - 2]
                {
                    best = min(best, dp[(i - 2) * width + (j - 2)] + costs.transposition)
                }
                dp[i * width + j] = best
            }
        }
        return dp[n * width + m]
    }

    /// Convenience overload over strings (assumed lowercased).
    public func typingCost(typed: String, intended: String) -> Double {
        typingCost(typed: Array(typed), intended: Array(intended))
    }
}
