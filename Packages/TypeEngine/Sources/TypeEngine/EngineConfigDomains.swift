import Foundation

/// Read-only subsystem views over the flat, source-compatible `EngineConfig`.
///
/// The flat properties remain the shipping API and the single source of
/// defaults. These snapshots make ownership visible to engine code and tools
/// without introducing a second configuration store or changing call sites.
public struct EngineConfigDomains: Sendable {
    public let search: SearchConfiguration
    public let ranking: RankingConfiguration
    public let action: ActionPolicyConfiguration
    public let touch: TouchConfiguration
    public let lane: LaneConfiguration
    public let morphology: MorphologyConfiguration

    init(_ config: EngineConfig) {
        search = SearchConfiguration(config)
        ranking = RankingConfiguration(config)
        action = ActionPolicyConfiguration(config)
        touch = TouchConfiguration(config)
        lane = LaneConfiguration(config)
        morphology = MorphologyConfiguration(config)
    }
}

public extension EngineConfig {
    /// Snapshot the current values grouped by the subsystem that consumes
    /// them. Mutate the existing flat properties, then take a new snapshot.
    var domains: EngineConfigDomains { EngineConfigDomains(self) }
}

/// Candidate discovery and bounded-search budgets.
public struct SearchConfiguration: Sendable {
    public let disabledCandidateProviders: CandidateProviderSet
    public let completionPoolLimit: Int
    public let contextContinuationPoolLimit: Int
    public let contextContinuationMaxCost: Double
    public let beamCostCap: Double
    public let beamMultiEditCostCap: Double
    public let beamMaxEdits: Int
    public let beamMaxExpansions: Int
    public let beamMaxCandidates: Int
    public let beamTimeBudget: TimeInterval
    public let splitTimeBudget: TimeInterval
    public let compoundRepairMaxLookups: Int
    public let foldedMorphologyMinLength: Int
    public let foldedMorphologyNeighborMaxCost: Double
    public let foldedMorphologyMaxCandidates: Int

    init(_ config: EngineConfig) {
        disabledCandidateProviders = config.disabledCandidateProviders
        completionPoolLimit = config.completionPoolLimit
        contextContinuationPoolLimit = config.contextContinuationPoolLimit
        contextContinuationMaxCost = config.contextContinuationMaxCost
        beamCostCap = config.beamCostCap
        beamMultiEditCostCap = config.beamMultiEditCostCap
        beamMaxEdits = config.beamMaxEdits
        beamMaxExpansions = config.beamMaxExpansions
        beamMaxCandidates = config.beamMaxCandidates
        beamTimeBudget = config.beamTimeBudget
        splitTimeBudget = config.splitTimeBudget
        compoundRepairMaxLookups = config.compoundRepairMaxLookups
        foldedMorphologyMinLength = config.foldedMorphologyMinLength
        foldedMorphologyNeighborMaxCost = config.foldedMorphologyNeighborMaxCost
        foldedMorphologyMaxCandidates = config.foldedMorphologyMaxCandidates
    }
}

/// Additive score composition after candidates have been admitted.
public struct RankingConfiguration: Sendable {
    public let languageWeight: Double
    public let calibrationTemperature: Double
    public let bigramInterpolation: Double
    public let compoundCompletionHeadZWeight: Double
    public let morphBackoffWeight: Double
    public let personalBoostBase: Double
    public let personalBoostScale: Double
    public let personalBoostCap: Double

    init(_ config: EngineConfig) {
        languageWeight = config.languageWeight
        calibrationTemperature = config.calibrationTemperature
        bigramInterpolation = config.bigramInterpolation
        compoundCompletionHeadZWeight = config.compoundCompletionHeadZWeight
        morphBackoffWeight = config.morphBackoffWeight
        personalBoostBase = config.personalBoostBase
        personalBoostScale = config.personalBoostScale
        personalBoostCap = config.personalBoostCap
    }
}

/// Every flat knob read directly by the post-ranking autocorrect decision.
public struct ActionPolicyConfiguration: Sendable {
    public let minAutocorrectLength: Int
    public let autocorrectMaxSpatialCost: Double
    public let autocorrectMargin: Double
    public let autocorrectMinZ: Double
    public let autocorrectJunkWinnerZ: Double
    public let autocorrectJunkWinnerMarginScale: Double
    public let autocorrectFarRepairEdits: Int
    public let autocorrectFarRepairMinZ: Double
    public let autocorrectShortLengthMax: Int
    public let autocorrectShortMinZ: Double
    public let autocorrectContextLengthMax: Int
    public let autocorrectContextShortMinZ: Double
    public let autocorrectContextLiftFloor: Double
    public let archaicTwinRestorationEnabled: Bool
    public let archaicTwinShortMinZ: Double
    public let deepShortFoldEnabled: Bool
    public let deepShortFoldMinPosterior: Double
    public let deepShortFoldMaxLength: Int
    public let deepShortFoldMinZ: Double
    public let deepShortFoldAutoApplyMargin: Double
    public let vacuumAutoApplyEnabled: Bool
    public let vacuumAutoApplyMargin: Double
    public let properNounGuardEnabled: Bool
    public let closeCandidateGate: Double
    public let compoundLinkingRepairYieldEnabled: Bool
    public let splitAutocorrectMargin: Double
    public let splitAutoApplySingleWordCutoff: Double
    public let restorationAutoApplyMargin: Double
    public let bigramMarginRelief: Double
    public let bigramMarginReliefMinLift: Double
    public let beamMultiEditCostCap: Double
    public let foldedMorphologyAutocorrectEnabled: Bool
    public let foldedMorphologyAutocorrectMinPosterior: Double
    public let foldedMorphologyAutocorrectMargin: Double

    init(_ config: EngineConfig) {
        minAutocorrectLength = config.minAutocorrectLength
        autocorrectMaxSpatialCost = config.autocorrectMaxSpatialCost
        autocorrectMargin = config.autocorrectMargin
        autocorrectMinZ = config.autocorrectMinZ
        autocorrectJunkWinnerZ = config.autocorrectJunkWinnerZ
        autocorrectJunkWinnerMarginScale = config.autocorrectJunkWinnerMarginScale
        autocorrectFarRepairEdits = config.autocorrectFarRepairEdits
        autocorrectFarRepairMinZ = config.autocorrectFarRepairMinZ
        autocorrectShortLengthMax = config.autocorrectShortLengthMax
        autocorrectShortMinZ = config.autocorrectShortMinZ
        autocorrectContextLengthMax = config.autocorrectContextLengthMax
        autocorrectContextShortMinZ = config.autocorrectContextShortMinZ
        autocorrectContextLiftFloor = config.autocorrectContextLiftFloor
        archaicTwinRestorationEnabled = config.archaicTwinRestorationEnabled
        archaicTwinShortMinZ = config.archaicTwinShortMinZ
        deepShortFoldEnabled = config.deepShortFoldEnabled
        deepShortFoldMinPosterior = config.deepShortFoldMinPosterior
        deepShortFoldMaxLength = config.deepShortFoldMaxLength
        deepShortFoldMinZ = config.deepShortFoldMinZ
        deepShortFoldAutoApplyMargin = config.deepShortFoldAutoApplyMargin
        vacuumAutoApplyEnabled = config.vacuumAutoApplyEnabled
        vacuumAutoApplyMargin = config.vacuumAutoApplyMargin
        properNounGuardEnabled = config.properNounGuardEnabled
        closeCandidateGate = config.closeCandidateGate
        compoundLinkingRepairYieldEnabled = config.compoundLinkingRepairYieldEnabled
        splitAutocorrectMargin = config.splitAutocorrectMargin
        splitAutoApplySingleWordCutoff = config.splitAutoApplySingleWordCutoff
        restorationAutoApplyMargin = config.restorationAutoApplyMargin
        bigramMarginRelief = config.bigramMarginRelief
        bigramMarginReliefMinLift = config.bigramMarginReliefMinLift
        beamMultiEditCostCap = config.beamMultiEditCostCap
        foldedMorphologyAutocorrectEnabled = config.foldedMorphologyAutocorrectEnabled
        foldedMorphologyAutocorrectMinPosterior =
            config.foldedMorphologyAutocorrectMinPosterior
        foldedMorphologyAutocorrectMargin = config.foldedMorphologyAutocorrectMargin
    }
}

/// Coordinate likelihood, confidence veto, and personalization controls.
public struct TouchConfiguration: Sendable {
    public let sigmaX: Double
    public let sigmaY: Double
    public let vetoBaseline: Double
    public let vetoStrength: Double
    public let vetoMaxFactor: Double
    public let nearMissMinLean: Double
    public let nearMissCapEnabled: Bool
    public let edgeUndershootEnabled: Bool
    public let personalMinSamples: Double
    public let priorStrength: Double
    public let sigmaFloor: Double

    init(_ config: EngineConfig) {
        sigmaX = config.tapSigmaX
        sigmaY = config.tapSigmaY
        vetoBaseline = config.tapVetoBaseline
        vetoStrength = config.tapVetoStrength
        vetoMaxFactor = config.tapVetoMaxFactor
        nearMissMinLean = config.tapNearMissMinLean
        nearMissCapEnabled = config.tapNearMissCapEnabled
        edgeUndershootEnabled = config.edgeUndershootEnabled
        personalMinSamples = config.touchPersonalMinSamples
        priorStrength = config.touchPriorStrength
        sigmaFloor = config.touchSigmaFloor
    }
}

/// Bilingual posterior and restoration-profile controls.
public struct LaneConfiguration: Sendable {
    public let switchProbability: Double
    public let boundaryDecay: Double
    public let emissionTemperature: Double
    public let emissionMaxLogRatio: Double
    public let posteriorFloor: Double
    public let posteriorCeiling: Double
    public let evidenceFloor: Double
    public let evidenceDeadZone: Double
    public let foldBaseCost: Double
    public let foldProfileISEnabled: Bool
    public let foldProfileENEnabled: Bool

    init(_ config: EngineConfig) {
        switchProbability = config.laneSwitchProbability
        boundaryDecay = config.laneBoundaryDecay
        emissionTemperature = config.laneEmissionTemperature
        emissionMaxLogRatio = config.laneEmissionMaxLogRatio
        posteriorFloor = config.posteriorFloor
        posteriorCeiling = config.posteriorCeiling
        evidenceFloor = config.laneEvidenceFloor
        evidenceDeadZone = config.laneEvidenceDeadZone
        foldBaseCost = config.foldBaseCost
        foldProfileISEnabled = config.foldProfileISEnabled
        foldProfileENEnabled = config.foldProfileENEnabled
    }
}

/// Inflection backoff, case completion, and lemma-level learning controls.
public struct MorphologyConfiguration: Sendable {
    public let backoffWeight: Double
    public let minGovernorMass: Double
    public let minPosterior: Double
    public let caseFitFloor: Double
    public let wrongFormMinAdvantage: Double
    public let completionPoolLimit: Int
    public let caseCompletionEnabled: Bool
    public let caseCompletionMaxTrim: Int
    public let caseCompletionMinLength: Int
    public let caseSplitSecondMinProbability: Double
    public let lemmaLiftBoost: Double

    init(_ config: EngineConfig) {
        backoffWeight = config.morphBackoffWeight
        minGovernorMass = config.morphMinGovernorMass
        minPosterior = config.morphBackoffMinPosterior
        caseFitFloor = config.morphCaseFitFloor
        wrongFormMinAdvantage = config.morphWrongFormMinAdvantage
        completionPoolLimit = config.morphCompletionPoolLimit
        caseCompletionEnabled = config.caseCompletionEnabled
        caseCompletionMaxTrim = config.caseCompletionMaxTrim
        caseCompletionMinLength = config.caseCompletionMinLength
        caseSplitSecondMinProbability = config.caseSplitSecondMinProbability
        lemmaLiftBoost = config.lemmaLiftBoost
    }
}
