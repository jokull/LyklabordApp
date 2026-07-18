import Foundation

/// Bounded source that can place a word hypothesis into the correction pool.
///
/// The raw values are a stable diagnostics/evaluation contract: traces and
/// `type-eval ab --disable-family …` print them verbatim. Keep a provider
/// separate when it has its own search bound or can be ablated independently.
public enum CandidateProvider: String, CaseIterable, Sendable {
    case shortBeam = "short-beam"
    case edits1Residue = "edits1-residue"
    case diacriticRestoration = "diacritic-restoration"
    case gemination = "gemination"
    case geminationRestoration = "gemination-restoration"
    case shortDoubleSubstitution = "short-double-substitution"
    case contextContinuation = "context-continuation"
    case possessiveRestoration = "possessive-restoration"
    case lexiconCompletion = "lexicon-completion"
    case personalCompletion = "personal-completion"
    case caseCompletion = "case-completion"
    case caseSibling = "case-sibling"
    case shorterPrefixCompletion = "shorter-prefix-completion"
    case diacriticPrefixCompletion = "diacritic-prefix-completion"
    case deepBeam = "deep-beam"
    case mashRecoveryBeam = "mash-recovery-beam"
    case compoundRepair = "compound-repair"
    case compoundCompletion = "compound-completion"
    case spaceMissSplit = "space-miss-split"

    fileprivate var bit: UInt64 {
        switch self {
        case .shortBeam: 1 << 0
        case .edits1Residue: 1 << 1
        case .diacriticRestoration: 1 << 2
        case .gemination: 1 << 3
        case .geminationRestoration: 1 << 4
        case .shortDoubleSubstitution: 1 << 5
        case .contextContinuation: 1 << 6
        case .possessiveRestoration: 1 << 7
        case .lexiconCompletion: 1 << 8
        case .personalCompletion: 1 << 9
        case .caseCompletion: 1 << 10
        case .caseSibling: 1 << 11
        case .shorterPrefixCompletion: 1 << 12
        case .diacriticPrefixCompletion: 1 << 13
        case .deepBeam: 1 << 14
        case .mashRecoveryBeam: 1 << 15
        case .compoundRepair: 1 << 16
        case .compoundCompletion: 1 << 17
        case .spaceMissSplit: 1 << 18
        }
    }
}

/// Allocation-free provider mask used by the engine's evaluation ablations.
/// The default empty mask keeps every provider enabled.
public struct CandidateProviderSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ provider: CandidateProvider) {
        self.init(rawValue: provider.bit)
    }

    public static let all = CandidateProviderSet(
        rawValue: CandidateProvider.allCases.reduce(0) { $0 | $1.bit })

    public func contains(_ provider: CandidateProvider) -> Bool {
        contains(CandidateProviderSet(provider))
    }

    public var providers: [CandidateProvider] {
        CandidateProvider.allCases.filter(contains)
    }
}

/// Coarse A/B switches. Families are intentionally about candidate sourcing,
/// not ranking or action policy, so disabling one answers “what coverage and
/// safety did this search family buy?” without retuning another subsystem.
public enum CandidateProviderFamily: String, CaseIterable, Sendable {
    case beam
    case lexicalRepair = "lexical-repair"
    case restoration
    case context
    case completion
    case morphology
    case compound
    case split

    public var providers: CandidateProviderSet {
        switch self {
        case .beam:
            return [.shortBeam, .deepBeam, .mashRecoveryBeam]
        case .lexicalRepair:
            return [.edits1Residue, .gemination, .shortDoubleSubstitution]
        case .restoration:
            return [
                .diacriticRestoration, .geminationRestoration,
                .possessiveRestoration, .diacriticPrefixCompletion,
            ]
        case .context:
            return [.contextContinuation]
        case .completion:
            return [
                .lexiconCompletion, .personalCompletion,
                .shorterPrefixCompletion,
            ]
        case .morphology:
            return [.caseCompletion, .caseSibling]
        case .compound:
            return [.compoundRepair, .compoundCompletion]
        case .split:
            return [.spaceMissSplit]
        }
    }
}

extension CandidateProviderSet: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: CandidateProvider...) {
        self.init(rawValue: elements.reduce(0) { $0 | $1.bit })
    }
}

/// First-wins candidate admission, preserving the decoder's historic channel
/// cost while optionally collecting every provider that reached the word.
/// Provenance storage is nil on the extension hot path unless a trace exists.
struct CandidateAdmissionPool: Sequence {
    private(set) var costs: [String: ChannelCost] = [:]
    private var provenance: [String: CandidateProviderSet]?

    init(captureProvenance: Bool) {
        provenance = captureProvenance ? [:] : nil
    }

    subscript(word: String) -> ChannelCost? { costs[word] }

    var keys: Dictionary<String, ChannelCost>.Keys { costs.keys }

    @discardableResult
    mutating func admit(
        _ word: String,
        cost: @autoclosure () -> ChannelCost,
        provider: CandidateProvider
    ) -> Bool {
        if costs[word] != nil {
            provenance?[word, default: []].formUnion(CandidateProviderSet(provider))
            return false
        }
        costs[word] = cost()
        provenance?[word] = CandidateProviderSet(provider)
        return true
    }

    func providers(for word: String) -> CandidateProviderSet {
        provenance?[word] ?? []
    }

    func makeIterator() -> Dictionary<String, ChannelCost>.Iterator {
        costs.makeIterator()
    }
}

/// Ranker's additive signal ledger. `score` is still assembled in the exact
/// historic operation order; the named fields explain that number without
/// asking callers to reverse-engineer morphology or precedence from it.
struct RankedCandidate {
    let word: String
    let cost: ChannelCost
    let providers: CandidateProviderSet
    let languageScore: Double
    let channelContribution: Double
    let languageContribution: Double
    var morphologyContribution: Double
    var compoundContribution: Double
    var precedenceContribution: Double
    var score: Double
}
