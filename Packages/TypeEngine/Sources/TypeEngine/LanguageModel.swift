import Foundation
import Lexicon

/// Anything that can validate word forms morphologically (BÍN via LemmaCore's
/// BinaryLemmatizer in production; a fake in tests).
public protocol MorphologyProviding: AnyObject {
    func isKnown(_ word: String) -> Bool
}

/// All engine tunables in one place. Defaults documented inline; every value
/// is expected to move once the micro-eval corpus grows.
public struct EngineConfig: Sendable {
    /// Spatial model constants (see SpatialModel.Costs).
    public var spatialCosts = SpatialModel.Costs()

    /// λ: weight of the language score relative to log P_spatial in the
    /// corrector score. 1.0 = classic noisy channel.
    public var languageWeight: Double = 1.0

    /// Add-k smoothing constant for unigram probabilities.
    public var addK: Double = 0.5
    /// Assumed vocabulary size V for add-k smoothing (P = (f+k)/(N+kV)).
    public var assumedVocabularySize: Double = 100_000
    /// Frequency assigned to a word that is BÍN-valid (isKnown) but missing
    /// from the Icelandic frequency table. Rare inflected forms should be
    /// suggestible but never outrank attested words.
    public var binFloorFrequency: UInt32 = 2

    /// β: weight of the bigram MLE vs the unigram probability when a previous
    /// word is available: P(w|prev) = β·(bf/f_prev) + (1-β)·P_uni(w).
    public var bigramInterpolation: Double = 0.6

    /// τ: temperature of the cross-language calibration, in nats per
    /// within-lexicon standard deviation. Each lexicon's log-probabilities
    /// are z-scored against that lexicon's own log-frequency distribution
    /// before blending, so differently-scaled corpora become comparable
    /// (see LexiconCalibration); τ converts those σ-units back into nats.
    public var calibrationTemperature: Double = 1.0

    /// Cost per not-yet-typed character when a candidate is a strict-prefix
    /// completion of the typed word (completion-as-suggestion).
    public var completionCharCost: Double = 0.5
    /// How many prefix completions to pull from each lexicon while correcting.
    public var completionPoolLimit: Int = 8
    /// How many top unigrams per lexicon feed next-word prediction fallback.
    public var unigramPoolLimit: Int = 50
    /// How many bigram continuations per lexicon feed next-word prediction.
    public var continuationPoolLimit: Int = 24

    /// Auto-replace only fires when the top candidate beats the runner-up by
    /// this many nats (conservatism: under-correct rather than over-correct).
    public var autocorrectMargin: Double = 1.25
    /// Auto-replace never fires when the top candidate's spatial cost exceeds
    /// this (wild rewrites are suggestion-bar-only).
    public var autocorrectMaxSpatialCost: Double = 6.0
    /// Never auto-replace very short inputs.
    public var minAutocorrectLength: Int = 3

    /// Edits-distance-2 candidates are generated only when the typed word has
    /// at least 5 characters AND the best edits1 candidate's spatial cost is
    /// above this gate (i.e. no good close hit exists).
    public var edits2Gate: Double = 4.5
    /// edits2 is skipped entirely for typed words longer than this (the
    /// expansion count grows quadratically with length and long words are
    /// served well enough by edits1 + completions).
    public var edits2MaxLength: Int = 16
    /// Hard cap on edits2 expansions (protects the extension's CPU budget;
    /// on the real mmap-ed artifacts the wall-clock budget below binds long
    /// before this does — the cap mainly bounds fast in-memory lexicons).
    public var maxEdits2Expansions: Int = 120_000
    /// Wall-clock budget for the edits2 expansion walk, in seconds. When it
    /// runs out the corrector falls back to whatever edits1/completion
    /// candidates it already has (worst-case latency gate; see PLAN.md
    /// "edits2 latency landmine").
    public var edits2TimeBudget: TimeInterval = 0.008

    // --- Space-miss split correction (PLAN.md "Space-miss correction"):
    // an unknown all-letter token may really be two words with a missed or
    // mis-hit spacebar tap ("smelirna" = "smellir á"). Splits only run when
    // the typed token is unknown everywhere AND the single-word passes found
    // no good close candidate (same gating philosophy as edits2).

    /// Minimum typed length before split hypotheses are generated.
    public var splitMinLength: Int = 5
    /// Cap on explored split positions per class (insertion positions are
    /// walked center-out, so the cap sheds the least plausible edges).
    public var splitMaxPositions: Int = 12
    /// Splits are generated only when the best single-word candidate's
    /// spatial cost is above this (i.e. no high-confidence one-word fix).
    /// Same shape (and default) as `edits2Gate`.
    public var splitGate: Double = 4.5
    /// Channel penalty for a pure space-insertion split (the user omitted a
    /// spacebar tap between the halves). The spatial model's omitted-
    /// character (deletion) constant plus one nat: the spacebar is the
    /// largest target on the keyboard, so skipping it outright is RARER
    /// than skipping a letter key — and the extra nat is what keeps
    /// two-common-word junk splits ("publically" → "public allt") from
    /// outranking an honest one-word fix ("publicly").
    public var splitInsertionPenalty: Double = 5.0
    /// Channel penalty for a space-substitution split (a letter adjacent to
    /// the spacebar consumed as the space: "smelirna" → "smelir"+"a" via
    /// the n). Cheaper than insertion — the tap evidence supports it: a tap
    /// DID land where the space belongs, one key-row off.
    public var splitSubstitutionPenalty: Double = 1.5
    /// A split half that is not itself valid may be repaired by the cheap
    /// targeted passes (diacritics, gemination, edits1) at up to this
    /// spatial cost; anything dearer disqualifies the half. This cap
    /// applies to SUBSTITUTION splits, whose mis-tap evidence earns them
    /// the full repair budget ("smelirna": gemination-repaired "smellir"
    /// costs the 4.0 omitted-letter constant).
    public var splitHalfRepairMaxCost: Double = 4.0
    /// Repair cap for INSERTION-split halves. Pure insertion splits carry
    /// no tap evidence, so their halves must be pristine or nearly so —
    /// only floor-cost repairs (diacritics ≤ ~1.9, orthographic slips 1.5)
    /// qualify. Keeps "helloworld"→"hello world" and "godandag"→"góðan dag"
    /// while pricing out "publically"→"public"+"ally→all"-style junk,
    /// where a real one-word fix exists.
    public var splitInsertionHalfRepairMaxCost: Double = 2.0
    /// How many repaired forms per half are combined into candidates.
    public var splitHalfHypothesisLimit: Int = 3
    /// A single-character half must be attested at at least this calibrated
    /// z-score in one of the lexicons. Genuine one-letter words are always
    /// extreme-frequency function words (IS "á" +3.3 / "í" +3.4, EN "a"
    /// +2.7 / "i" +2.2), while corpus tokenization noise sits mid-tier
    /// ("s" +1.4, "e" +0.9) — the threshold keeps "smelir a"/"smellir á"
    /// reachable and junk like "s leirna" out of the bar.
    public var splitSingleCharHalfMinZ: Double = 2.0
    /// Wall-clock budget for the whole split pass, in seconds. Split
    /// positions are explored best-evidence-first (substitution before
    /// insertion, center-out), so an abort sheds the least likely splits.
    public var splitTimeBudget: TimeInterval = 0.006

    // --- Two-lane language switching model (PLAN.md "Bilingual blending —
    // lane model"). The posterior P(IS) is the forward probability of a
    // two-state (IS/EN) HMM over committed words: per commit,
    //   predict: p' = (1-s)·p + s·(1-p)              (lane stickiness/decay)
    //   update:  p  ∝ p'·e_IS(word) vs (1-p')·e_EN(word)   (graded evidence)
    // Emission likelihood ratios come from the calibrated per-lexicon
    // z-scores (see laneEvidence). Replaces the earlier flat EMA.

    /// s: per-word prior probability that the writer switched lanes.
    /// Low = sticky lanes — a single off-lane word (a sletta) cannot flip
    /// the lane, while 2–3 consecutive off-lane words can. Also acts as the
    /// natural distance decay: words with ~uniform emissions (OOV, junk,
    /// ambiguous) relax the posterior toward 0.5 at this rate.
    public var laneSwitchProbability: Double = 0.08
    /// Fraction of the lane posterior's distance to the neutral 0.5 prior
    /// that is shed at each sentence boundary (". ", "!", "?"): the lane
    /// relaxes but does not reset — 0.9 becomes 0.82 at the default.
    public var laneBoundaryDecay: Double = 0.2
    /// η: emission temperature — nats of emission log-likelihood ratio per σ
    /// of calibrated z-score margin between the two lexicons.
    public var laneEmissionTemperature: Double = 1.0
    /// Cap on a single word's emission log-likelihood ratio, in nats. Bounds
    /// how much any one word can move the lane: together with
    /// laneSwitchProbability this guarantees one strongly-off-lane word
    /// leaves a saturated lane above 0.6 while three flip it past 0.7.
    public var laneEmissionMaxLogRatio: Double = 1.1
    /// The posterior never saturates past 90/10 in either direction.
    public var posteriorFloor: Double = 0.1
    public var posteriorCeiling: Double = 0.9
    /// z floor for lane evidence: attestation at or below this calibrated
    /// z-score is indistinguishable from absence (junk/noise-tier entries —
    /// web scrapings, typos baked into the corpus — are not language
    /// evidence; the harness "dont" finding). Unattested words score exactly
    /// this floor, so junk-vs-absent comparisons cancel to zero evidence.
    /// BÍN validity never contributes (its 3M forms collide with junk).
    public var laneEvidenceFloor: Double = -1.25
    /// Soft dead zone subtracted from the |z_IS - z_EN| margin before it
    /// becomes emission evidence: weakly attributable words (known in both
    /// lexicons at comparable typicality, or barely above the noise floor in
    /// one) contribute ~uniform emissions and leave the lane to the
    /// stickiness prior. Evidence is graded above the dead zone, not binary.
    public var laneEvidenceDeadZone: Double = 1.0

    public init() {}
}

enum Language {
    case icelandic
    case english
}

/// Per-lexicon frequency-distribution statistics used to calibrate
/// cross-language comparisons.
///
/// Raw probabilities (f / totalTokens) from differently built corpora are
/// apples-to-oranges: a mid-tier Icelandic noun and a mid-tier English noun
/// can differ by several nats purely because of corpus size, scaling and
/// noise-floor differences (the PLAN.md "hus → his even at P(IS)=0.79"
/// finding). What autocorrect actually needs is *within-language
/// typicality*: how notable is this word inside its own language. So each
/// lexicon's log-frequencies are z-scored against that lexicon's own
/// distribution before blending across languages.
///
/// The distribution is estimated deterministically at engine init by
/// sampling the head of many two-letter prefix buckets via
/// `completions(of:limit:)` (the only enumeration the Lexicon protocol
/// offers). The sample is head-biased in the same way for both lexicons, so
/// the resulting z-scores stay comparable. Sampling also doubles as a page
/// warm-up of the mmap-ed unigram sections.
struct LexiconCalibration: Sendable {
    /// Mean of log(f + addK) over the sample.
    let meanLogFrequency: Double
    /// Standard deviation of log(f + addK) over the sample (≥ minSigma).
    let stdLogFrequency: Double
    /// A spread of sampled words, retained for `warmUp()` page touching.
    let sampleWords: [String]

    /// σ floor: degenerate distributions (tiny test dictionaries with a
    /// handful of equal frequencies) fall back to unit variance instead of
    /// exploding the z-scores.
    private static let minSigma = 0.25

    /// First letters of the sampled two-letter buckets (full engine
    /// alphabet, minus apostrophes).
    private static let bucketFirst: [Character] = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")
    /// Second letters — a spread of common vowels/consonants (plus accents
    /// and Icelandic letters) chosen to cover most head words without
    /// scanning every two-letter range of a 300k-word table.
    private static let bucketSecond: [Character] = Array("aáeéiíoóuúyýhnrstlðgkm")
    private static let bucketLimit = 12

    static func measure(_ lexicon: Lexicon, addK: Double) -> LexiconCalibration {
        var logs: [Double] = []
        var words: [String] = []
        logs.reserveCapacity(4096)
        for first in bucketFirst {
            for second in bucketSecond {
                let prefix = String([first, second])
                for entry in lexicon.completions(of: prefix, limit: bucketLimit) {
                    logs.append(log(Double(entry.frequency) + addK))
                    if words.count < 512 { words.append(entry.word) }
                }
            }
        }
        guard logs.count >= 4 else {
            // Effectively empty lexicon (bare test doubles): identity
            // calibration keeps z = log(f + k), which is monotone and
            // harmless when there is nothing to compare against.
            return LexiconCalibration(meanLogFrequency: 0, stdLogFrequency: 1, sampleWords: words)
        }
        let mean = logs.reduce(0, +) / Double(logs.count)
        let variance = logs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(logs.count)
        let sigma = max(sqrt(variance), minSigma)
        return LexiconCalibration(meanLogFrequency: mean, stdLogFrequency: sigma, sampleWords: words)
    }
}

/// Shared bilingual probability model: smoothed unigram + interpolated bigram
/// probabilities per language, calibrated per lexicon and blended by the
/// running language posterior.
struct BlendedLanguageModel {
    let icelandic: Lexicon
    let english: Lexicon
    let morphology: MorphologyProviding?
    let config: EngineConfig
    let icelandicCalibration: LexiconCalibration
    let englishCalibration: LexiconCalibration

    init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding?,
        config: EngineConfig
    ) {
        self.icelandic = icelandic
        self.english = english
        self.morphology = morphology
        self.config = config
        self.icelandicCalibration = LexiconCalibration.measure(icelandic, addK: config.addK)
        self.englishCalibration = LexiconCalibration.measure(english, addK: config.addK)
    }

    func lexicon(for language: Language) -> Lexicon {
        language == .icelandic ? icelandic : english
    }

    func calibration(for language: Language) -> LexiconCalibration {
        language == .icelandic ? icelandicCalibration : englishCalibration
    }

    /// Is the word attested anywhere (either frequency table, or BÍN-valid)?
    func isKnownAnywhere(_ word: String) -> Bool {
        icelandic.frequency(of: word) != nil
            || english.frequency(of: word) != nil
            || morphology?.isKnown(word) == true
    }

    /// Effective unigram frequency, applying the BÍN floor for Icelandic
    /// forms that are morphologically valid but absent from the table.
    func effectiveFrequency(of word: String, language: Language) -> UInt32? {
        if let f = lexicon(for: language).frequency(of: word) { return f }
        if language == .icelandic, morphology?.isKnown(word) == true {
            return config.binFloorFrequency
        }
        return nil
    }

    /// Add-k smoothed unigram probability (uncalibrated, within-language).
    func unigramProbability(of word: String, language: Language) -> Double {
        let f = Double(effectiveFrequency(of: word, language: language) ?? 0)
        let total = Double(lexicon(for: language).totalUnigramTokens)
        let k = config.addK
        return (f + k) / (total + k * config.assumedVocabularySize)
    }

    /// P(word | previous) with bigram/unigram interpolation. Falls back to
    /// the pure unigram probability when there is no usable context.
    func contextualProbability(of word: String, previous: String?, language: Language) -> Double {
        let uni = unigramProbability(of: word, language: language)
        guard
            let previous,
            let prevFreq = lexicon(for: language).frequency(of: previous),
            prevFreq > 0
        else { return uni }
        let bigram = Double(lexicon(for: language).bigramFrequency(previous, word) ?? 0)
        let mle = bigram / Double(prevFreq)
        let beta = config.bigramInterpolation
        return beta * mle + (1 - beta) * uni
    }

    /// The lexicon's reference log-probability: what a word at the sampled
    /// mean log-frequency of language L would score as a smoothed unigram.
    private func referenceLogProbability(language: Language) -> Double {
        let cal = calibration(for: language)
        let total = Double(lexicon(for: language).totalUnigramTokens)
        return cal.meanLogFrequency - log(total + config.addK * config.assumedVocabularySize)
    }

    /// Calibrated contextual score: the word's log P(word | previous, L)
    /// z-scored against lexicon L's own log-frequency distribution.
    /// Affine in log-probability with positive slope, so ranking *within* a
    /// language is unchanged; only cross-language comparisons move.
    func calibratedScore(of word: String, previous: String?, language: Language) -> Double {
        let p = contextualProbability(of: word, previous: previous, language: language)
        let cal = calibration(for: language)
        return (log(p) - referenceLogProbability(language: language)) / cal.stdLogFrequency
    }

    /// Calibrated unigram-only score (no bigram context); used for posterior
    /// attribution of committed words.
    func calibratedUnigramScore(of word: String, language: Language) -> Double {
        calibratedScore(of: word, previous: nil, language: language)
    }

    /// Lane emission evidence for a committed word:
    /// log( e_IS(word) / e_EN(word) ), the emission log-likelihood ratio of
    /// the two-lane switching model, in nats. Positive = Icelandic evidence.
    ///
    /// Derivation from the calibrated z-scores (graded, not binary):
    ///   z̃_L = max(z_L, floor) when attested in L's frequency table,
    ///         floor when unattested (or junk-tier — same thing)
    ///   ℓ   = sign(Δz̃) · η · max(0, |Δz̃| - deadZone), clipped to ±cap
    /// Corpus attestation only: BÍN morphology validates 3M surface forms
    /// including English-looking junk, so it is never lane evidence.
    func laneEvidence(of word: String) -> Double {
        let floor = config.laneEvidenceFloor
        let zIS =
            icelandic.frequency(of: word) != nil
            ? max(calibratedUnigramScore(of: word, language: .icelandic), floor)
            : floor
        let zEN =
            english.frequency(of: word) != nil
            ? max(calibratedUnigramScore(of: word, language: .english), floor)
            : floor
        let margin = zIS - zEN
        let graded = max(0, abs(margin) - config.laneEvidenceDeadZone)
        guard graded > 0 else { return 0 }
        let nats = min(config.laneEmissionTemperature * graded, config.laneEmissionMaxLogRatio)
        return margin > 0 ? nats : -nats
    }

    /// Blended language score, in nats:
    /// log( P(IS)·exp(τ·z_IS) + P(EN)·exp(τ·z_EN) ).
    /// Replaces the raw probability blend — see LexiconCalibration.
    func blendedScore(of word: String, previous: String?, pIcelandic: Double) -> Double {
        let p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        let tau = config.calibrationTemperature
        let a = log(p) + tau * calibratedScore(of: word, previous: previous, language: .icelandic)
        let b = log(1 - p) + tau * calibratedScore(of: word, previous: previous, language: .english)
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m))
    }

    /// Blended language score of a two-word PHRASE, in nats:
    /// log( P(IS)·exp(τ·(z_IS(first|prev) + z_IS(second|first)))
    ///    + P(EN)·exp(τ·(z_EN(first|prev) + z_EN(second|first))) ).
    ///
    /// Both words are generated by ONE lane (the lane model: a phrase does
    /// not switch language mid-air), so the per-language scores are summed
    /// BEFORE blending. Blending each word independently would let a split
    /// like "public allt" cherry-pick English for one half and Icelandic
    /// for the other and outscore honest single-language candidates;
    /// jointly, a cross-language pair is priced as the junk it usually is
    /// — while remaining merely discounted, never blocked. The second
    /// word's score is conditioned on the first, so bigram coherence is
    /// included.
    func blendedPairScore(
        first: String,
        second: String,
        previous: String?,
        pIcelandic: Double
    ) -> Double {
        let p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        let tau = config.calibrationTemperature
        let a =
            log(p)
            + tau
                * (calibratedScore(of: first, previous: previous, language: .icelandic)
                    + calibratedScore(of: second, previous: first, language: .icelandic))
        let b =
            log(1 - p)
            + tau
                * (calibratedScore(of: first, previous: previous, language: .english)
                    + calibratedScore(of: second, previous: first, language: .english))
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m))
    }

    /// Touch representative pages of both lexicons and the morphology binary
    /// so the first real keystrokes don't pay mmap page-fault costs
    /// (PLAN.md "cold-start page faults"). The calibration sampling at init
    /// already walks the unigram sections; this adds point lookups, the
    /// bigram tables and BÍN probes. Idempotent, a few ms warm.
    func warmUp() {
        for (lexicon, cal) in [(icelandic, icelandicCalibration), (english, englishCalibration)] {
            var previous: String?
            for (index, word) in cal.sampleWords.enumerated() {
                _ = lexicon.frequency(of: word)
                if let previous {
                    _ = lexicon.bigramFrequency(previous, word)
                }
                if index % 8 == 0 {
                    _ = lexicon.continuations(of: word, limit: 2)
                }
                previous = word
            }
        }
        if let morphology {
            for word in icelandicCalibration.sampleWords {
                _ = morphology.isKnown(word)
            }
            // Spread probes across the whole key space: every two-letter
            // combination walks a distinct binary-search path through the
            // (large) morphology binary, faulting in the upper index levels
            // that every future lookup shares.
            let alphabet = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")
            for first in alphabet {
                for second in alphabet {
                    _ = morphology.isKnown(String([first, second]))
                }
            }
        }
    }
}
