import Foundation
import TypeEngine

/// Explicit key→setter map for the `type-eval ab --config <overrides.json>`
/// mode. Swift has no runtime reflection over stored properties, so the set
/// of A/B-tunable `EngineConfig` fields is enumerated here by hand. Only the
/// tunables that materially move autocorrect quality / conservatism / lane
/// behaviour are exposed — the ones a tuning wave would actually sweep
/// (documented in scores/README.md). Adding a knob is one line in the map.
///
/// Values are coerced from JSON scalars: number keys accept any JSON number,
/// bool keys accept `true`/`false`. An unknown key is a hard error (a typo in
/// an overrides file must never be silently ignored during a tuning run).
public enum ConfigOverrideError: Error, CustomStringConvertible, Equatable {
    case unknownKey(String)
    case wrongType(key: String, expected: String)

    public var description: String {
        switch self {
        case let .unknownKey(key):
            return "unknown config override key: \(key)"
        case let .wrongType(key, expected):
            return "config override \(key): expected \(expected)"
        }
    }
}

public enum ConfigOverrides {

    /// Double-valued tunables.
    public static let doubleSetters: [String: (inout EngineConfig, Double) -> Void] = [
        // Corrector core / conservatism
        "languageWeight": { $0.languageWeight = $1 },
        "addK": { $0.addK = $1 },
        "bigramInterpolation": { $0.bigramInterpolation = $1 },
        "calibrationTemperature": { $0.calibrationTemperature = $1 },
        "autocorrectMargin": { $0.autocorrectMargin = $1 },
        "autocorrectMinZ": { $0.autocorrectMinZ = $1 },
        "autocorrectJunkWinnerZ": { $0.autocorrectJunkWinnerZ = $1 },
        "autocorrectJunkWinnerMarginScale": { $0.autocorrectJunkWinnerMarginScale = $1 },
        "autocorrectMaxSpatialCost": { $0.autocorrectMaxSpatialCost = $1 },
        "autocorrectFarRepairMinZ": { $0.autocorrectFarRepairMinZ = $1 },
        "autocorrectShortMinZ": { $0.autocorrectShortMinZ = $1 },
        "shortDoubleSubMaxEditCost": { $0.shortDoubleSubMaxEditCost = $1 },
        "shortDoubleSubMinZ": { $0.shortDoubleSubMinZ = $1 },
        "shortDoubleSubContextMinZ": { $0.shortDoubleSubContextMinZ = $1 },
        "closeCandidateGate": { $0.closeCandidateGate = $1 },
        // Beam decoder
        "beamCostCap": { $0.beamCostCap = $1 },
        "beamMultiEditCostCap": { $0.beamMultiEditCostCap = $1 },
        "beamNeighborMaxCost": { $0.beamNeighborMaxCost = $1 },
        "beamDeepGate": { $0.beamDeepGate = $1 },
        // Space-miss split
        "splitAutocorrectMargin": { $0.splitAutocorrectMargin = $1 },
        "splitInsertionPenalty": { $0.splitInsertionPenalty = $1 },
        "splitSubstitutionPenalty": { $0.splitSubstitutionPenalty = $1 },
        "splitGate": { $0.splitGate = $1 },
        "splitAutoApplySingleWordCutoff": { $0.splitAutoApplySingleWordCutoff = $1 },
        "splitInsertionHalfRepairMaxCost": { $0.splitInsertionHalfRepairMaxCost = $1 },
        "splitSaturatedHalfMinZ": { $0.splitSaturatedHalfMinZ = $1 },
        "dottedEscapeMinHalfZ": { $0.dottedEscapeMinHalfZ = $1 },
        "dottedEscapeAutoApplyMinHalfZ": { $0.dottedEscapeAutoApplyMinHalfZ = $1 },
        // Lane relaxation (accent restoration + EN possessive derivation)
        "possessiveFrequencyFraction": { $0.possessiveFrequencyFraction = $1 },
        "possessiveOfferMinBaseZ": { $0.possessiveOfferMinBaseZ = $1 },
        "foldBaseCost": { $0.foldBaseCost = $1 },
        "foldEpsilon": { $0.foldEpsilon = $1 },
        "laneWeightRampLo": { $0.laneWeightRampLo = $1 },
        "laneWeightRampHi": { $0.laneWeightRampHi = $1 },
        "restorationAutoApplyMargin": { $0.restorationAutoApplyMargin = $1 },
        "restorationDominanceRatio": { $0.restorationDominanceRatio = $1 },
        "restorationDominanceMinZ": { $0.restorationDominanceMinZ = $1 },
        "restorationDominanceObliqueMinZ": { $0.restorationDominanceObliqueMinZ = $1 },
        "restorationContextMinAdvantage": { $0.restorationContextMinAdvantage = $1 },
        "slettaGuardBlendThreshold": { $0.slettaGuardBlendThreshold = $1 },
        "vacuumAutoApplyMargin": { $0.vacuumAutoApplyMargin = $1 },
        "accentAutoApplyMinPosterior": { $0.accentAutoApplyMinPosterior = $1 },
        // Coordinate margin veto (tap-veto asymmetry work)
        "tapVetoBaseline": { $0.tapVetoBaseline = $1 },
        "tapVetoStrength": { $0.tapVetoStrength = $1 },
        "tapVetoMaxFactor": { $0.tapVetoMaxFactor = $1 },
        "tapVetoCommonWinnerMinZ": { $0.tapVetoCommonWinnerMinZ = $1 },
        "tapVetoCommonMaxFactor": { $0.tapVetoCommonMaxFactor = $1 },
        // Two-lane switching model
        "laneSwitchProbability": { $0.laneSwitchProbability = $1 },
        "laneEmissionTemperature": { $0.laneEmissionTemperature = $1 },
        "laneBoundaryDecay": { $0.laneBoundaryDecay = $1 },
        // Inflection intelligence
        "morphBackoffWeight": { $0.morphBackoffWeight = $1 },
        "morphMinGovernorMass": { $0.morphMinGovernorMass = $1 },
        "morphBackoffMinPosterior": { $0.morphBackoffMinPosterior = $1 },
        // Compound acceptance (wave 22)
        "compoundRepairGate": { $0.compoundRepairGate = $1 },
        "compoundHeadMinZ": { $0.compoundHeadMinZ = $1 },
    ]

    /// Int-valued tunables.
    public static let intSetters: [String: (inout EngineConfig, Int) -> Void] = [
        "minAutocorrectLength": { $0.minAutocorrectLength = $1 },
        "autocorrectShortLengthMax": { $0.autocorrectShortLengthMax = $1 },
        "autocorrectFarRepairEdits": { $0.autocorrectFarRepairEdits = $1 },
        "beamMaxEdits": { $0.beamMaxEdits = $1 },
        "beamShortMaxEdits": { $0.beamShortMaxEdits = $1 },
        "beamLongMinLength": { $0.beamLongMinLength = $1 },
        "splitMinLength": { $0.splitMinLength = $1 },
        "completionPoolLimit": { $0.completionPoolLimit = $1 },
        "morphCompletionPoolLimit": { $0.morphCompletionPoolLimit = $1 },
        // Compound acceptance (wave 22)
        "compoundMinModifierLength": { $0.compoundMinModifierLength = $1 },
        "compoundMinHeadLength": { $0.compoundMinHeadLength = $1 },
        "compoundRepairMinLength": { $0.compoundRepairMinLength = $1 },
        "compoundRepairMaxModifiers": { $0.compoundRepairMaxModifiers = $1 },
        "compoundRepairMaxLookups": { $0.compoundRepairMaxLookups = $1 },
        "compoundFloorFrequency": { $0.compoundFloorFrequency = UInt32(max(0, $1)) },
    ]

    /// Bool-valued tunables (per-profile lane-relaxation toggles).
    public static let boolSetters: [String: (inout EngineConfig, Bool) -> Void] = [
        "foldProfileISEnabled": { $0.foldProfileISEnabled = $1 },
        "foldProfileENEnabled": { $0.foldProfileENEnabled = $1 },
        "properNounGuardEnabled": { $0.properNounGuardEnabled = $1 },
        "vacuumAutoApplyEnabled": { $0.vacuumAutoApplyEnabled = $1 },
        // Compound acceptance (wave 22)
        "compoundValidityEnabled": { $0.compoundValidityEnabled = $1 },
        "compoundRepairEnabled": { $0.compoundRepairEnabled = $1 },
        "compoundCompletionEnabled": { $0.compoundCompletionEnabled = $1 },
    ]

    /// All override keys, sorted — for `--help` / docs / diagnostics.
    public static var supportedKeys: [String] {
        (Array(doubleSetters.keys) + Array(intSetters.keys) + Array(boolSetters.keys)).sorted()
    }

    /// Apply a decoded `[key: value]` overrides object onto `config`.
    /// Returns the applied keys, sorted (for the A/B report). Throws on an
    /// unknown key or a value whose JSON type does not match the knob.
    @discardableResult
    public static func apply(_ overrides: [String: Any], to config: inout EngineConfig) throws
        -> [String]
    {
        for (key, value) in overrides {
            if let setter = doubleSetters[key] {
                guard let number = numeric(value) else {
                    throw ConfigOverrideError.wrongType(key: key, expected: "number")
                }
                setter(&config, number)
            } else if let setter = intSetters[key] {
                guard let number = numeric(value) else {
                    throw ConfigOverrideError.wrongType(key: key, expected: "integer")
                }
                setter(&config, Int(number.rounded()))
            } else if let setter = boolSetters[key] {
                guard let flag = boolean(value) else {
                    throw ConfigOverrideError.wrongType(key: key, expected: "boolean")
                }
                setter(&config, flag)
            } else {
                throw ConfigOverrideError.unknownKey(key)
            }
        }
        return overrides.keys.sorted()
    }

    /// Load an overrides JSON object from disk and apply it, returning the
    /// resulting config and the applied keys.
    public static func load(from url: URL) throws -> (config: EngineConfig, keys: [String]) {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let overrides = object as? [String: Any] else {
            throw ConfigOverrideError.wrongType(key: "<root>", expected: "JSON object")
        }
        var config = EngineConfig()
        let keys = try apply(overrides, to: &config)
        return (config, keys)
    }

    // JSON numbers/bools arrive as NSNumber via JSONSerialization; a Codable
    // path may hand us native Double/Int/Bool. Coerce both, and reject a
    // Bool masquerading as a number (NSNumber(bool:) reports objCType 'c').
    private static func numeric(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            if isBoolNumber(number) { return nil }
            return number.doubleValue
        }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func boolean(_ value: Any) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber, isBoolNumber(number) { return number.boolValue }
        return nil
    }

    private static func isBoolNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
