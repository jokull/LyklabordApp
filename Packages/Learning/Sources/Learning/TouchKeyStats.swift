import Foundation

/// Online per-key touch statistics for the adaptive touch model (PLAN
/// "Touch decoding" stage 2): running mean offset from key center plus the
/// full 2×2 covariance, updated one sample at a time with Welford's
/// algorithm (numerically stable, no sample storage — individual taps are
/// never persisted, only these aggregates).
///
/// `dx`/`dy` are normalized offsets from the resolved key's center
/// (1.0 = one key width/height), matching `LearningEvent.touchSample`.
///
/// `count` is a `Double` so the model can apply exponential forgetting:
/// `decay(by:)` scales the effective sample count and the deviation sums
/// while preserving the means — old taps fade, the per-key Gaussian tracks
/// how the user taps *now*.
public struct TouchKeyStats: Codable, Equatable, Sendable {
    /// Effective sample count (decays; not necessarily an integer).
    public private(set) var count: Double
    public private(set) var meanDX: Double
    public private(set) var meanDY: Double
    /// Sums of squared deviations (Welford M2) and the cross-deviation sum.
    public private(set) var m2DX: Double
    public private(set) var m2DY: Double
    public private(set) var cDXDY: Double

    public init() {
        count = 0
        meanDX = 0
        meanDY = 0
        m2DX = 0
        m2DY = 0
        cDXDY = 0
    }

    /// Welford online update (bivariate):
    /// `C += (x − meanX_old)(y − meanY_new)` keeps the co-moment exact.
    ///
    /// A non-finite or absurd sample (`EventLog.isValidTouchOffset`) is
    /// ignored: one NaN would poison every aggregate for good and make the
    /// model file unencodable (`JSONEncoder` throws on non-finite floats).
    public mutating func update(dx: Double, dy: Double) {
        guard EventLog.isValidTouchOffset(dx: dx, dy: dy) else { return }
        count += 1
        let deltaXOld = dx - meanDX
        meanDX += deltaXOld / count
        let deltaXNew = dx - meanDX
        m2DX += deltaXOld * deltaXNew

        let deltaYOld = dy - meanDY
        meanDY += deltaYOld / count
        let deltaYNew = dy - meanDY
        m2DY += deltaYOld * deltaYNew

        cDXDY += deltaXOld * deltaYNew
    }

    /// Exponential forgetting: scales `count` and the deviation sums by
    /// `factor` (0 < factor < 1), preserving means, variances and covariance
    /// exactly while halving (for factor 0.5) the weight of history against
    /// future samples.
    public mutating func decay(by factor: Double) {
        precondition(factor > 0 && factor < 1, "decay factor must be in (0, 1)")
        count *= factor
        m2DX *= factor
        m2DY *= factor
        cDXDY *= factor
    }

    /// Unbiased sample variance of dx; nil until 2+ effective samples.
    public var varianceDX: Double? {
        count > 1 ? m2DX / (count - 1) : nil
    }

    public var varianceDY: Double? {
        count > 1 ? m2DY / (count - 1) : nil
    }

    /// Sample covariance of (dx, dy); nil until 2+ effective samples.
    public var covarianceDXDY: Double? {
        count > 1 ? cDXDY / (count - 1) : nil
    }
}
