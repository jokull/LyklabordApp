import Foundation

/// One captured keystroke touch point (PLAN.md "Touch decoding", stage 1).
///
/// `dxNorm`/`dyNorm` are within-key normalized offsets from the RESOLVED
/// key's center: −0.5…+0.5 at the key's touch-cell edges (the cell spans
/// the full key pitch, visual insets included), x growing rightward and y
/// growing DOWNWARD (toward the spacebar) — the same convention as the
/// ReplayRig TSI traces (`tsi-distributions.json`) and
/// `Learning.LearningEvent.touchSample`.
///
/// `char` is the resolved character, lowercased by the producer
/// (`TypingSession.noteTap`).
public struct TapSample: Equatable, Sendable {
    public let char: Character
    public let dxNorm: Double
    public let dyNorm: Double

    public init(char: Character, dxNorm: Double, dyNorm: Double) {
        self.char = char
        self.dxNorm = dxNorm
        self.dyNorm = dyNorm
    }
}

/// The coordinate-evidence `PositionCostProvider` (PLAN.md "Touch
/// decoding", stage 1 — the provider the `BeamDecoder` seam was built for).
///
/// Substitution pricing: a 2D Gaussian at the ACTUAL tap point. STAGE 1
/// (always available): an axis-aligned Gaussian at every key's center, σ
/// seeded from the Google TSI within-key distributions
/// (`EngineConfig.tapSigmaX`/`tapSigmaY`; tunable). Costs are LOG-LIKELIHOOD
/// RATIOS against the resolved key, so the protocol's "0 when equal"
/// convention holds and the price works BOTH ways (the bidirectional
/// evidence principle):
///
///  * a tap near the boundary toward a neighbor makes that neighbor's
///    substitution cheap — down to the `minSubstitution` floor, well below
///    the ~1-nat static key-distance price (corrections get ENABLED),
///  * a dead-center tap prices every neighbor substitution near the
///    Gaussian exponent of a full key pitch (≈ 7 nats at the TSI σx),
///    capped at `maxSubstitution` — the correction VETO: believe the user.
///
/// STAGE 2 (this wave — the per-user adaptive touch model): when a
/// `PersonalTouchSnapshot` is injected, every key whose effective sample
/// count clears `EngineConfig.touchPersonalMinSamples` is priced against
/// its PERSONAL Gaussian — mean-shifted center, per-key covariance —
/// shrunk toward the TSI prior by w = n/(n + touchPriorStrength):
///
///   mean_blend = w·mean_personal        var_blend = w·var + (1−w)·σ_TSI²
///   cov_blend  = w·cov_personal
///
/// Because per-key Gaussians now differ, the ½·ln|Σ| normalizer no longer
/// cancels between keys; it is carried per key RELATIVE to the prior's
/// (so prior-priced keys keep the exact stage-1 numbers). Numerical
/// safety, per key: blended σ floored at `touchSigmaFloor`, correlation
/// clamped to |ρ| ≤ 0.9, and any non-finite/degenerate aggregate drops the
/// key back to the static prior — a corrupt personal model can never
/// poison pricing, and every priced cost still passes the existing
/// `minSubstitution`/`maxSubstitution` clamps. With no snapshot, or no key
/// past the gate, the arithmetic is the stage-1 code path, byte-identical.
///
/// Deliberate carve-outs:
///  * positions with no usable tap (nil sample, char/alignment drift, or a
///    character with no key position) fall back to the static
///    `SpatialModel` cost — absent evidence must not change behavior,
///  * orthographic-confusion pairs (d→ð, t→þ, o→ö, ð↔þ) keep the static
///    confusion constant regardless of the tap: those are COGNITIVE slips —
///    the user deliberately hit the key they (wrongly) believed right, so
///    the tap point carries no information about the confusion,
///  * accent twins share their base key's center AND its personal
///    statistics (long-press callouts carry no tap sample, so the physical
///    key is the only touch target that trains), so their likelihood ratio
///    is 0 and the `minSubstitution` floor applies — identical to the
///    static model by construction.
///
/// `confidence(position:)` is the tap's NORMALIZED likelihood of the
/// resolved key over all physical keys (dead-center → ≈1, mid-boundary
/// between two keys → ≈0.5) under the same blended per-key distributions;
/// positions without a tap report 1.0 exactly (the static provider's
/// constant), so no-tap words aggregate to a neutral margin factor. The
/// corrector aggregates these into the autocorrect-margin veto and the
/// fold-pricing evidence penalty.
struct PerTapCostProvider: PositionCostProvider {

    /// Precomputed per-position evidence; nil where no usable tap exists.
    private struct Evidence {
        /// The resolved character the tap was recorded for (alignment guard).
        let char: Character
        /// Tap point in key-grid units (key center + normalized offsets).
        let point: SIMD2<Double>
        /// The resolved key's center (cached — the near-miss lean test
        /// sits on the beam's substitution hot path).
        let center: SIMD2<Double>
        /// −log likelihood of the tap under the RESOLVED key's (blended)
        /// Gaussian, up to the shared prior constant.
        let nllResolved: Double
        /// Normalized likelihood of the resolved key at this tap.
        let confidence: Double
    }

    /// One key's blended Gaussian (stage 2): quadratic-form coefficients of
    /// the exponent ½·dᵀΣ⁻¹d around the mean-shifted center, plus the
    /// normalizer ½·ln|Σ| RELATIVE to the prior's (0 for the prior itself,
    /// so mixing personal and prior keys stays a coherent likelihood).
    private struct KeyGaussian {
        let center: SIMD2<Double>
        /// exponent = qxx·dx² + qxy·dx·dy + qyy·dy²  (d = point − center)
        let qxx: Double
        let qxy: Double
        let qyy: Double
        /// ½·ln(|Σ| / |Σ_prior|).
        let logWeight: Double
    }

    private let spatial: SpatialModel
    private let evidence: [Evidence?]
    private let invTwoSigmaX2: Double
    private let invTwoSigmaY2: Double
    private let minSubstitution: Double
    private let maxSubstitution: Double
    private let orthographicConfusion: Double
    /// Near-miss enabling cap (wave 30): a tap leaning at least this far
    /// toward the intended key caps its substitution at the static price
    /// and exempts the position from the margin veto.
    private let nearMissMinLean: Double
    private let nearMissCapEnabled: Bool
    /// Edge-key undershoot carve-out (wave 30): directional aim-error
    /// pairs (p→ð, l→æ, æ→ö, m→þ) price static, tap-blind.
    private let edgeUndershootEnabled: Bool
    /// Per-key personal Gaussians (keys past the min-samples gate, plus
    /// their accent twins); nil when no personal key is eligible — the
    /// stage-1 byte-identical path.
    private let personalGaussians: [Character: KeyGaussian]?

    /// Mean confidence over the positions that HAVE taps; nil when none
    /// do. The corrector's margin-veto aggregate.
    let meanTapConfidence: Double?

    /// Correlation clamp for the blended cross-covariance term (numerical
    /// safety: |ρ| → 1 makes Σ singular and the exponent explode along the
    /// anti-diagonal; genuine tap clouds measure well below this).
    private static let maxAbsCorrelation = 0.9

    /// - Parameters:
    ///   - taps: per typed-position samples, aligned with the (lowercased)
    ///     typed word; nil entries fall back to static pricing.
    ///   - personalTouch: the injected per-user touch snapshot (stage 2);
    ///     nil — or a snapshot with no key past the min-samples gate —
    ///     reproduces stage-1 pricing byte-identically.
    init(
        taps: [TapSample?],
        spatial: SpatialModel,
        config: EngineConfig,
        personalTouch: PersonalTouchSnapshot? = nil
    ) {
        self.spatial = spatial
        let costs = config.spatialCosts
        self.minSubstitution = costs.minSubstitution
        self.maxSubstitution = costs.maxSubstitution
        self.orthographicConfusion = costs.orthographicConfusion
        self.nearMissMinLean = config.tapNearMissMinLean
        self.nearMissCapEnabled = config.tapNearMissCapEnabled
        self.edgeUndershootEnabled = config.edgeUndershootEnabled
        let ix = 1.0 / (2.0 * config.tapSigmaX * config.tapSigmaX)
        let iy = 1.0 / (2.0 * config.tapSigmaY * config.tapSigmaY)
        self.invTwoSigmaX2 = ix
        self.invTwoSigmaY2 = iy

        let personalGaussians = Self.blendGaussians(
            personalTouch: personalTouch, spatial: spatial, config: config)
        self.personalGaussians = personalGaussians

        /// −log likelihood of `point` under `key`'s effective Gaussian
        /// (personal-blend when eligible, else the shared prior), up to the
        /// prior's shared constant. Exactly the stage-1 arithmetic when the
        /// key has no personal Gaussian.
        func nll(from point: SIMD2<Double>, key: Character, center: SIMD2<Double>) -> Double {
            if let g = personalGaussians?[key] {
                let d = point - g.center
                return d.x * d.x * g.qxx + d.x * d.y * g.qxy + d.y * d.y * g.qyy + g.logWeight
            }
            let d = point - center
            return d.x * d.x * ix + d.y * d.y * iy
        }

        var evidence: [Evidence?] = []
        evidence.reserveCapacity(taps.count)
        var confidenceSum = 0.0
        var confidenceCount = 0
        for tap in taps {
            guard let tap, let center = spatial.keyCenter(of: tap.char) else {
                evidence.append(nil)
                continue
            }
            let point = center + SIMD2(tap.dxNorm, tap.dyNorm)
            let nllResolved = nll(from: point, key: tap.char, center: center)
            // Normalized likelihood of the resolved key over the physical
            // key set (accent twins share centers and are not separate
            // targets — summing them would double-count their base key).
            var total = 0.0
            for key in SpatialModel.physicalKeys {
                guard let keyCenter = spatial.keyCenter(of: key) else { continue }
                total += exp(-nll(from: point, key: key, center: keyCenter))
            }
            let confidence =
                total > 0 ? min(max(exp(-nllResolved) / total, 0), 1) : 1.0
            evidence.append(
                Evidence(
                    char: tap.char,
                    point: point,
                    center: center,
                    nllResolved: nllResolved,
                    confidence: confidence
                )
            )
            confidenceSum += confidence
            confidenceCount += 1
        }
        self.evidence = evidence
        self.meanTapConfidence =
            confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : nil
    }

    /// Build the per-key blended Gaussians (see the type doc's stage-2
    /// shrinkage). Returns nil when no key is eligible so the caller can
    /// keep the stage-1 arithmetic byte-identical. Per key, in order:
    /// min-samples gate → shrinkage blend → finiteness guard → σ floor →
    /// correlation clamp → determinant guard; any failure drops THAT key to
    /// the prior.
    private static func blendGaussians(
        personalTouch: PersonalTouchSnapshot?,
        spatial: SpatialModel,
        config: EngineConfig
    ) -> [Character: KeyGaussian]? {
        guard let personalTouch, !personalTouch.isEmpty else { return nil }
        let priorVarX = config.tapSigmaX * config.tapSigmaX
        let priorVarY = config.tapSigmaY * config.tapSigmaY
        let floorVar = config.touchSigmaFloor * config.touchSigmaFloor
        var gaussians: [Character: KeyGaussian] = [:]
        for key in SpatialModel.physicalKeys {
            guard
                let stats = personalTouch.stats(for: key),
                let meanOffset = personalTouch.blendedMeanOffset(for: key, config: config),
                let center = spatial.keyCenter(of: key),
                // Degenerate/corrupt raw aggregates (negative variance from
                // a mangled Welford M2, non-finite values) → this key stays
                // on the prior. `blendedMeanOffset` already vetoed
                // non-finite means/counts and the min-samples gate.
                stats.varianceX.isFinite, stats.varianceX >= 0,
                stats.varianceY.isFinite, stats.varianceY >= 0,
                stats.covarianceXY.isFinite
            else { continue }
            let weight = stats.count / (stats.count + config.touchPriorStrength)
            var varX = weight * stats.varianceX + (1 - weight) * priorVarX
            var varY = weight * stats.varianceY + (1 - weight) * priorVarY
            var cov = weight * stats.covarianceXY
            guard varX.isFinite, varY.isFinite, cov.isFinite, varX > 0, varY > 0 else {
                continue  // blend overflow paranoia — prior for this key
            }
            varX = max(varX, floorVar)
            varY = max(varY, floorVar)
            let maxCov = Self.maxAbsCorrelation * (varX * varY).squareRoot()
            cov = min(max(cov, -maxCov), maxCov)
            let det = varX * varY - cov * cov
            guard det > 0, det.isFinite else { continue }
            let gaussian = KeyGaussian(
                center: center + meanOffset,
                qxx: varY / (2 * det),
                qxy: -cov / det,
                qyy: varX / (2 * det),
                logWeight: 0.5 * log(det / (priorVarX * priorVarY))
            )
            gaussians[key] = gaussian
            // Accent twins share the physical key — and its personal cloud.
            for (accented, base) in SpatialModel.accentBase where base == key {
                gaussians[accented] = gaussian
            }
        }
        return gaussians.isEmpty ? nil : gaussians
    }

    /// −log likelihood of `point` under `intendedCenter`'s key Gaussian —
    /// the instance-side twin of the init-local `nll` (same arithmetic).
    private func nllIntended(
        point: SIMD2<Double>, intended: Character, intendedCenter: SIMD2<Double>
    ) -> Double {
        if let g = personalGaussians?[intended] {
            let d = point - g.center
            return d.x * d.x * g.qxx + d.x * d.y * g.qxy + d.y * d.y * g.qyy + g.logWeight
        }
        let d = point - intendedCenter
        return d.x * d.x * invTwoSigmaX2 + d.y * d.y * invTwoSigmaY2
    }

    func substitutionCost(position: Int, typed: Character, intended: Character) -> Double {
        if typed == intended { return 0 }
        // Cognitive, not spatial (see type doc): the static constant.
        if SpatialModel.confusionPairs.contains(String(typed) + String(intended)) {
            return orthographicConfusion
        }
        // Edge-key undershoot (wave 30): an aim error onto the neighbour's
        // center — the tap lands where the (wrong) motor plan aimed, so it
        // carries no information about the slip. Static geometry price,
        // exactly like the tapless engine.
        if edgeUndershootEnabled,
            SpatialModel.edgeUndershootPairs.contains(String(typed) + String(intended))
        {
            return spatial.substitutionCost(typed: typed, intended: intended)
        }
        guard
            position >= 0, position < evidence.count,
            let evidence = evidence[position],
            evidence.char == typed,
            let intendedCenter = spatial.keyCenter(of: intended)
        else {
            return spatial.substitutionCost(typed: typed, intended: intended)
        }
        let nllIntended = nllIntended(
            point: evidence.point, intended: intended, intendedCenter: intendedCenter)
        // Log-likelihood ratio vs the resolved key ("0 when equal" holds by
        // construction), clamped into the static cost band so the beam's
        // caps/gates keep their calibrated meaning.
        let ratio = nllIntended - evidence.nllResolved
        let clamped = min(max(ratio, minSubstitution), maxSubstitution)
        // Near-miss enabling cap (wave 30, the doctrine's ENABLING half):
        // a tap leaning toward the intended key must never price the
        // substitution WORSE than static geometry (with tight TSI σ the
        // raw LLR taxes even a tap 78% of the way to the boundary — fatal
        // in the multi-substitution mash regime, where the taxes compound
        // past every cost cap). Dead-center and wrong-direction taps keep
        // the full LLR — the veto half is untouched. The lean test runs
        // only when the cap could matter (LLR above the floor).
        if nearMissCapEnabled, clamped > minSubstitution,
            tapLean(of: evidence, towards: intendedCenter) >= nearMissMinLean
        {
            return min(clamped, spatial.substitutionCost(typed: typed, intended: intended))
        }
        return clamped
    }

    /// Projection of the tap's within-key offset onto the unit vector from
    /// the resolved key's center toward `intendedCenter`, in key-pitch
    /// units — how far the tap physically leans toward the intended key.
    private func tapLean(of evidence: Evidence, towards intendedCenter: SIMD2<Double>) -> Double {
        let direction = intendedCenter - evidence.center
        let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        guard length > 0 else { return 0 }
        let offset = evidence.point - evidence.center
        return (offset.x * direction.x + offset.y * direction.y) / length
    }

    /// True when the tap at `position` SUPPORTS reading the typed character
    /// as `intended` (wave 30): either an edge-undershoot pair (the tap
    /// carries no information) or a near-miss lean past the threshold (the
    /// tap leans toward the key the candidate says was intended). Such a
    /// tap cannot simultaneously contradict the rewrite, so the corrector's
    /// margin veto skips the position — mirroring the restoration-pair
    /// exemption. Positions without a usable tap report false (the
    /// whole-word aggregate rules keep their existing semantics).
    func tapSupports(position: Int, typed: Character, intended: Character) -> Bool {
        guard typed != intended else { return false }
        if edgeUndershootEnabled,
            SpatialModel.edgeUndershootPairs.contains(String(typed) + String(intended))
        {
            return true
        }
        guard nearMissCapEnabled,
            position >= 0, position < evidence.count,
            let evidence = evidence[position],
            evidence.char == typed,
            let intendedCenter = spatial.keyCenter(of: intended)
        else { return false }
        return tapLean(of: evidence, towards: intendedCenter) >= nearMissMinLean
    }

    func confidence(position: Int) -> Double {
        guard position >= 0, position < evidence.count, let evidence = evidence[position] else {
            return 1.0
        }
        return evidence.confidence
    }

    /// Whether the position carries usable tap evidence (vs the static
    /// fallback). The margin veto only aggregates over these.
    func hasTap(at position: Int) -> Bool {
        position >= 0 && position < evidence.count && evidence[position] != nil
    }
}

extension PositionCostProvider {
    /// Evidence penalty a tap's confidence MULTIPLIES into the fold-pricing
    /// likelihood (−ln confidence in nats, capped): 0 for tapless positions
    /// and dead-center taps, up to `cap` for sloppy ones. See
    /// `FoldPricing`'s composition doc and `EngineConfig
    /// .tapFoldConfidenceMaxPenalty`.
    func foldEvidencePenalty(position: Int, cap: Double) -> Double {
        let confidence = self.confidence(position: position)
        guard confidence < 1 else { return 0 }
        return min(-log(max(confidence, 1e-9)), cap)
    }
}
