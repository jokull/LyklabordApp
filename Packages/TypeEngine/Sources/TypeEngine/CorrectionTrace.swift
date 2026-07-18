import Foundation

/// Decision trace of one `Corrector.correct` call — the `:why` debugging
/// surface (harness/REPL only; the extension never allocates one). Records,
/// for the last suggestions() pass: the scored candidate pool with the
/// channel-cost decomposition, which auto-apply rule was evaluated
/// (ordinary/restoration/split/skeleton-collision), and every gate's value
/// against its threshold — so a "why didn't X auto-apply?" question is
/// answered by numbers, not archaeology.
///
/// Reference type on purpose: the corrector threads it through value-type
/// methods and populates it in place. Passing nil (the default everywhere)
/// costs nothing on the hot path.
public final class CorrectionTrace {

    /// One scored candidate (top of the pool).
    public struct Candidate: Sendable {
        public let word: String
        /// Every bounded generation pass that reached this word. The first
        /// provider owns the channel cost; later providers only add
        /// provenance, so diagnostics never reprice a candidate.
        public let providers: [CandidateProvider]
        /// Lane-priced channel cost (nats).
        public let costTotal: Double
        /// Error-class ops on the optimal alignment.
        public let errorOps: Int
        /// Restoration-class ops (acute folds, directional confusions,
        /// apostrophe insertions).
        public let restorationOps: Int
        /// Additive channel contribution to the ranker (= -costTotal).
        public let channelContribution: Double
        /// Blended language score S_lang (calibrated, posterior-blended).
        public let languageScore: Double
        /// Additive weighted language contribution (= λ·S_lang).
        public let languageContribution: Double
        /// Context-free blended language score, exposed for comparison.
        public let unigramLanguageScore: Double?
        /// Contextual score minus the context-free score. Diagnostic evidence
        /// already included in `languageContribution`, not an extra addend.
        public let contextEvidence: Double?
        /// Additive personal prior before language weighting. Diagnostic
        /// evidence already included in `languageScore`.
        public let personalEvidence: Double
        /// Additive governor/case-fit contribution.
        public let morphologyContribution: Double
        /// Additive compound-head typicality contribution.
        public let compoundContribution: Double
        /// Additive hard-precedence adjustment (zero unless a compound
        /// completion is demoted behind a space split).
        public let precedenceContribution: Double
        /// Final ranking score. The additive contributions above (excluding
        /// the diagnostic context/personal evidence) reconstruct this value.
        public let score: Double
    }

    /// Pool-wide visibility into one provider, including an active ablation.
    public struct ProviderSummary: Sendable {
        public let provider: CandidateProvider
        public let admittedCandidateCount: Int
        public let disabled: Bool
    }

    /// One evaluated gate: value vs threshold, pass/fail.
    public struct Gate: Sendable {
        public let name: String
        public let detail: String
        public let pass: Bool
    }

    // Populated by Corrector.correct:
    public internal(set) var typed = ""
    public internal(set) var previousWord: String?
    public internal(set) var pIcelandic = 0.5
    public internal(set) var typedIsValid = false
    /// Which auto-apply rule the top candidate was judged under:
    /// "ordinary-unknown", "split", "skeleton-restoration", "single-letter",
    /// "valid-word (no auto-apply path)", "none".
    public internal(set) var rule = "none"
    /// Score margin of the winner over the runner-up (nats).
    public internal(set) var margin: Double?
    /// The margin threshold actually required (before the tap veto factor).
    public internal(set) var requiredMargin: Double?
    /// Aggregate tap-confidence veto multiplier on the margin (1 = no taps).
    public internal(set) var tapVetoFactor = 1.0
    public internal(set) var gates: [Gate] = []
    public internal(set) var autocorrect = false
    public internal(set) var notes: [String] = []
    public internal(set) var candidates: [Candidate] = []
    public internal(set) var providerSummaries: [ProviderSummary] = []

    public init() {}

    func gate(_ name: String, _ detail: String, pass: Bool) {
        gates.append(Gate(name: name, detail: detail, pass: pass))
    }

    func note(_ text: String) {
        notes.append(text)
    }

    /// Multi-line human-readable dump (the REPL `:why` output).
    public var report: String {
        var lines: [String] = []
        let prev = previousWord.map { "\"\($0)\"" } ?? "-"
        lines.append(
            "decide \"\(typed)\"  prev=\(prev)  P(IS)=\(String(format: "%.3f", pIcelandic))"
                + "  typedIsValid=\(typedIsValid)")
        if candidates.isEmpty {
            lines.append("  (no scored candidates)")
        }
        for (index, c) in candidates.enumerated() {
            let marginText: String
            if index == 0, let margin {
                marginText = "  margin=\(String(format: "%+.3f", margin))"
            } else {
                marginText = ""
            }
            lines.append(
                "  #\(index + 1) \(c.word)"
                    + "  via=\(c.providers.map(\.rawValue).joined(separator: ","))"
                    + "  cost=\(String(format: "%.3f", c.costTotal))"
                    + " (err=\(c.errorOps) rest=\(c.restorationOps))"
                    + "  lang=\(String(format: "%+.3f", c.languageScore))"
                    + "  score=\(String(format: "%+.3f", c.score))"
                    + marginText)
            lines.append(
                "       signals channel=\(String(format: "%+.3f", c.channelContribution))"
                    + " language=\(String(format: "%+.3f", c.languageContribution))"
                    + " morph=\(String(format: "%+.3f", c.morphologyContribution))"
                    + " compound=\(String(format: "%+.3f", c.compoundContribution))"
                    + " precedence=\(String(format: "%+.3f", c.precedenceContribution))"
                    + "  evidence context=\(c.contextEvidence.map { String(format: "%+.3f", $0) } ?? "-")"
                    + " personal=\(String(format: "%+.3f", c.personalEvidence))"
            )
        }
        let activeProviders = providerSummaries.filter { $0.admittedCandidateCount > 0 }
        if !activeProviders.isEmpty {
            lines.append(
                "  providers "
                    + activeProviders.map {
                        "\($0.provider.rawValue)=\($0.admittedCandidateCount)"
                    }.joined(separator: " "))
        }
        let disabled = providerSummaries.filter(\.disabled).map { $0.provider.rawValue }
        if !disabled.isEmpty {
            lines.append("  ablated \(disabled.joined(separator: ","))")
        }
        var decision = "  rule=\(rule)"
        if let requiredMargin {
            decision += "  requiredMargin=\(String(format: "%.3f", requiredMargin))"
            if tapVetoFactor != 1 {
                decision +=
                    " x tapVeto \(String(format: "%.2f", tapVetoFactor))"
                    + " = \(String(format: "%.3f", requiredMargin * tapVetoFactor))"
            }
        } else if tapVetoFactor != 1 {
            decision += "  tapVeto=\(String(format: "%.2f", tapVetoFactor))"
        }
        lines.append(decision)
        for gate in gates {
            lines.append("  \(gate.pass ? "PASS" : "FAIL")  \(gate.name): \(gate.detail)")
        }
        for note in notes {
            lines.append("  note  \(note)")
        }
        lines.append("  => autocorrect \(autocorrect ? "FIRES" : "does NOT fire")")
        return lines.joined(separator: "\n")
    }
}
