import Foundation
import Lexicon

/// Anything that can validate word forms morphologically (BÍN via LemmaCore's
/// BinaryLemmatizer in production; a fake in tests).
public protocol MorphologyProviding: AnyObject {
    func isKnown(_ word: String) -> Bool

    /// Grammatical cases ("nf"/"þf"/"þgf"/"ef") of the word's noun/adjective
    /// analyses — the inflection backoff's FALLBACK when a form is absent
    /// from the frequency-filtered paradigms.bin (PLAN.md "Inflection
    /// intelligence" Stage B #1: "fall back to lemmatizeWithMorph where
    /// absent"). Default: none (validation-only conformers stay valid).
    func nounAdjectiveCases(of word: String) -> [String]

    /// Distinct lemma candidates of a surface form (`lemmatize` semantics;
    /// [] for unknown words). The personal lemma lift's unambiguity gate —
    /// exactly one candidate — runs on this (PLAN.md "Lemma-level learning
    /// constraint"). Default: none (no form ever lifts).
    func lemmaCandidates(of word: String) -> [String]
}

public extension MorphologyProviding {
    func nounAdjectiveCases(of word: String) -> [String] { [] }
    func lemmaCandidates(of word: String) -> [String] { [] }
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
    /// Typicality floor for a single-word auto-replacement: the winning
    /// candidate must be ATTESTED in a frequency table (personal words are
    /// exempt — personal attestation is stronger evidence) with a calibrated
    /// z-score at or above this. BÍN-only forms (z pinned at the BÍN floor,
    /// ≈ −2.9 on the real artifacts) are never auto-applied: BÍN's 3M
    /// surface forms sit one edit from everything, and replacing a typo
    /// with morphology-validated junk is the dogfood "faralega → garalega"
    /// landmine. Suggestions are unaffected — this gates the flag only.
    public var autocorrectMinZ: Double = -2.5
    /// Auto-replace never fires when the top candidate's spatial cost exceeds
    /// this (wild rewrites are suggestion-bar-only).
    public var autocorrectMaxSpatialCost: Double = 6.0
    /// FAR-repair discipline (beam-decoder wave): a winner at unit edit
    /// distance >= this from the typed token is a big intervention —
    /// keyboard mash is often within 3 substitutions of some rare word
    /// ("awgke" → "aegis"), which must never auto-apply.
    public var autocorrectFarRepairEdits: Int = 3
    /// Typicality floor for far repairs: a >= `autocorrectFarRepairEdits`
    /// rewrite may auto-apply only when the winner is COMMON vocabulary
    /// (calibrated z at/above this; personal words exempt as always).
    /// Rare-but-attested words ("aegis" at −1.0) stay bar-only there,
    /// while 2-edit repairs keep the ordinary `autocorrectMinZ` floor
    /// ("koetip" → "kortið" at z −0.19 still fires).
    public var autocorrectFarRepairMinZ: Double = 0.0
    /// Never auto-replace very short inputs.
    public var minAutocorrectLength: Int = 3

    /// Fallback passes (shorter-prefix completions, splits, diacritic
    /// completions) run only when the best candidate found by the cheap
    /// passes has a spatial cost above this gate — i.e. no good close hit
    /// exists. (Formerly `edits2Gate`; the gating philosophy survives the
    /// generate-and-test edits2 walk it was named after.)
    public var closeCandidateGate: Double = 4.5

    // --- Beam-search spatial decoder (PRIMARY candidate source; replaced
    // the edits1+edits2 generate-and-test walks). The decoder explores
    // (lexicon prefix range, typed chars consumed, accumulated cost) states
    // in uniform-cost order over both frequency lexicons — see BeamDecoder.

    /// Prune any beam state whose accumulated channel cost exceeds this
    /// (nats). 8 keeps edits1 parity: a single substitution between ANY two
    /// keys (spatial cost capped at `maxSubstitution` = 8) stays
    /// suggestible.
    public var beamCostCap: Double = 8.0
    /// Tighter cost cap for MULTI-edit states (2+ non-match ops): the
    /// multi-edit shapes worth finding are substitution chains (~1 nat per
    /// adjacent key, ≤ ~3 for triple noise), accent/orthographic
    /// restorations (0.35–1.5 each) and one omission/extra combined with
    /// accent-tier repairs (4 + ≤1) — all ≤ 5. Deliberately excluded: an
    /// indel PLUS an ordinary adjacent-key sub (4 + ~1.05 ≈ 5.06) — those
    /// "varlega/farþega from faralega" readings were unreachable under the
    /// old pipeline too and only crowd honest repairs out of the bar — and
    /// indel pairs (4+4), whose frontier explodes the uniform-cost walk
    /// into thousands of states ranking would discard anyway (measured 3k
    /// expansions/5 ms on "koetip" at cap 8).
    public var beamMultiEditCostCap: Double = 5.0
    /// Max non-match ops per word for the DEEP decode (unknown tokens of
    /// length >= beamLongMinLength with no close candidate — see
    /// `beamDeepGate`). 3 (vs the old edits2's 2) is what makes
    /// triple-noise words reachable; the cost caps and neighbor sets keep
    /// the fan-out honest.
    public var beamMaxEdits: Int = 3
    /// Edit budget of the ALWAYS-ON shallow decode (every keystroke, both
    /// lexicons — a few hundred expansions): 1 reproduces the old edits1
    /// coverage, and is also the ceiling for short (< beamLongMinLength)
    /// tokens, where every word is within 2 edits of everything.
    public var beamShortMaxEdits: Int = 1
    /// Typed length at which the deep beamMaxEdits budget unlocks (same
    /// threshold the old edits2 pass used).
    public var beamLongMinLength: Int = 5
    /// Static-geometry neighbor radius for SECOND and later substitutions,
    /// in nats: keys within ~1.5 key widths (≈ 2.3 nats at σ = 0.7), accent
    /// twins (0.35) and orthographic confusions (1.5) qualify. The FIRST
    /// substitution may use the whole alphabet (edits1 parity for far-key
    /// single-sub typos).
    public var beamNeighborMaxCost: Double = 2.5
    /// Hard cap on beam state expansions per (word, lexicon) — protects the
    /// extension's CPU budget; uniform-cost order means overflow sheds only
    /// the least plausible states.
    public var beamMaxExpansions: Int = 6000
    /// Stop after this many emitted candidate words per lexicon (they emit
    /// cheapest-first).
    public var beamMaxCandidates: Int = 40
    /// Stop the search once the cost frontier exceeds the BEST emitted
    /// candidate by this many nats: anything still reachable is too far
    /// behind to win the language re-rank (λ·τ·Δz swings stay well under
    /// this). Bounds the expensive tail of the uniform-cost walk.
    public var beamEmitCostMargin: Double = 5.0
    /// Wall-clock budget for one beam decode, in seconds.
    public var beamTimeBudget: TimeInterval = 0.006
    /// The DEEP (multi-edit) decode runs only when the typed token is not
    /// valid anywhere and the best ATTESTED-or-personal candidate from the
    /// cheap passes costs more than this. Deliberately BELOW the omitted/
    /// extra-character constant (4.0): a lone single-indel reading
    /// ("eirld" → "eiröld") must not suppress the multi-substitution decode
    /// that is this decoder's reason to exist ("eirld" → "world" at ~2
    /// nats) — while transpositions (2.0), cheap subs and short
    /// completions (≤ ~3 × completionCharCost) still do, which is what
    /// keeps words-in-progress off the deep path. BÍN-only forms never
    /// suppress it (junk one edit from everything — the 4b rationale).
    public var beamDeepGate: Double = 3.5

    // --- Coordinate (per-tap) decoding (PLAN.md "Touch decoding", stage 1).
    // When the embedder threads touch points through TypingSession.noteTap,
    // the corrector swaps the static PositionCostProvider for a
    // PerTapCostProvider: substitutions are priced from a 2D Gaussian at the
    // ACTUAL tap point, and per-tap confidence feeds the bidirectional
    // evidence principle — near-boundary taps make the neighbor reading
    // cheap (enable corrections), dead-center taps make every substitution
    // expensive AND raise the autocorrect margin (the correction veto).
    // With no taps the static provider runs and every value below is inert
    // (eval/bench byte-parity).

    /// Within-key tap σ in key-pitch units, x axis. Seeded from the Google
    /// TSI human traces (ReplayRig/traces/tsi-distributions.json:
    /// dxNorm std 0.263 over 41k kept taps).
    public var tapSigmaX: Double = 0.263
    /// Within-key tap σ in key-pitch units, y axis (TSI dyNorm std 0.188 —
    /// vertical taps are tighter than horizontal ones).
    public var tapSigmaY: Double = 0.188
    /// Cap on the evidence penalty −ln(confidence) that a low-confidence
    /// (boundary/sloppy) tap MULTIPLIES into the fold-pricing likelihood
    /// (see FoldPricing's composition doc: a dead-center base-vowel tap is
    /// the lazy-input signal, folds stay at the lane price; a sloppy tap is
    /// weaker evidence of deliberate base-letter input, so the fold price
    /// rises — never past the provider's error-class base cost, which the
    /// min() composition still bounds).
    public var tapFoldConfidenceMaxPenalty: Double = 2.5
    /// Space-substitution split evidence (PLAN stage 1: "the space-miss
    /// penalty becomes a function of tap-to-spacebar distance"): with a tap
    /// present on the consumed letter, the split penalty becomes
    ///   splitSubstitutionPenalty + slope · (neutralDy − dyNorm)
    /// (dyNorm +0.5 = the key's bottom edge, i.e. AT the spacebar): taps
    /// hugging the spacebar edge price the split BELOW the static constant
    /// (the miss is nearly certain), dead-center/top-edge taps price it up
    /// (the user really meant the letter). Clamped to
    /// [tapSpaceSplitMinPenalty, splitInsertionPenalty].
    public var tapSpaceSplitSlope: Double = 2.0
    /// dyNorm at which the tap-scaled split penalty equals the static
    /// constant (below-center: the static penalty already assumes the tap
    /// leaned toward the spacebar).
    public var tapSpaceSplitNeutralDy: Double = 0.25
    /// Floor of the tap-scaled space-substitution penalty, in nats.
    public var tapSpaceSplitMinPenalty: Double = 1.0
    /// Autocorrect-margin modulation from aggregate word tap confidence
    /// (the VETO half of the bidirectional principle):
    ///   margin × min(1 + strength · max(0, meanConfidence − baseline),
    ///                maxFactor)
    /// v1 SAFETY CHOICE (deliberate, documented): the max(0, …) means
    /// coordinate evidence only ever RAISES the margin — an all-dead-center
    /// word (mean confidence ≈ 1) needs ~maxFactor× today's margin and
    /// essentially never auto-replaces, while sloppy words bottom out at
    /// exactly today's margins (never below — auto-apply is only ever
    /// HARDER than the static engine or equal; the enabling half of the
    /// principle acts through the cheaper per-tap substitution costs, not
    /// through the margin).
    public var tapVetoBaseline: Double = 0.5
    /// Nats-per-unit-confidence slope of the veto curve.
    public var tapVetoStrength: Double = 6.0
    /// Clamp on the veto factor.
    public var tapVetoMaxFactor: Double = 4.0

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
    /// Same shape (and default) as `closeCandidateGate`.
    public var splitGate: Double = 4.5
    /// Saturated-lane split discipline (dogfood koetip: "joe tip" junk at
    /// P(IS)=0.9): when the lane posterior is at/beyond this saturation
    /// point, BOTH split halves must be attested in the LANE language (or
    /// personal vocabulary) — no cherry-picking the other language for a
    /// junk half. Below saturation the joint blendedPairScore alone prices
    /// cross-language pairs.
    public var splitSaturatedLanePosterior: Double = 0.8
    /// Calibrated-z floor each half must clear IN THE LANE LANGUAGE when
    /// the lane is saturated. Set just below genuine-but-modest vocabulary
    /// ("smellir" sits at −1.33 in is.lex) and above the deep noise tier;
    /// unattested-in-lane halves fail outright regardless.
    public var splitSaturatedHalfMinZ: Double = -1.5
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
    /// Raised auto-apply margin for SPLIT candidates (vs the ordinary
    /// `autocorrectMargin`): rewriting one token into two words is a bigger
    /// intervention than repairing it, so the evidence bar is higher
    /// (dogfood "fara lega" tightening). Splits below this margin stay
    /// bar-only.
    public var splitAutocorrectMargin: Double = 2.5
    /// A split may auto-apply only when NO attested (or personal)
    /// single-word candidate exists at spatial cost at or below this
    /// generous bound — if a plausible one-word repair exists, the split is
    /// offered but never auto-applied. BÍN-only forms don't count (junk one
    /// edit from everything must not veto genuine splits like
    /// "helloworld").
    public var splitAutoApplySingleWordCutoff: Double = 2.5

    // --- Dotted-token space-miss escape (dogfood "sem.er"): the '.' key
    // sits directly right of the spacebar, so '.' is a space-adjacent miss
    // target. A dotted token of shape word.word where BOTH halves are
    // common valid words IN THE SAME language, that is not URL-shaped (no
    // known-TLD final segment, no "www" stem, exactly one dot — shape
    // checks live in TypingSession), may be offered as "word word".
    // Real URLs/domains stay verbatim-class protected.

    /// Both halves must be attested with a calibrated z-score at or above
    /// this, in one common language, for the escape to be OFFERED. z ≈ 1σ
    /// above the lexicon mean keeps it to genuinely common words (IS "sem"
    /// +3.1, "er" +3.1) — rare words next to a dot are far more likely a
    /// real domain/file token. One-letter halves must additionally clear
    /// `splitSingleCharHalfMinZ` (genuine one-letter words only).
    public var dottedEscapeMinHalfZ: Double = 1.0
    /// Stricter half-typicality bar for AUTO-APPLYING the escape (the
    /// item-2 raised-margin rule instantiated for the dotted channel):
    /// both halves at z ≥ 2σ — extreme-frequency words like "sem er".
    /// Between the two bars the escape is offered tap-only.
    public var dottedEscapeAutoApplyMinHalfZ: Double = 2.0
    /// Channel penalty of reading the '.' as a missed spacebar tap. Kept
    /// near `splitSubstitutionPenalty`: the tap evidence is the same kind
    /// (a tap landed one key off the spacebar), slightly dearer because
    /// the '.' key is smaller and farther into the corner.
    public var dottedEscapePenalty: Double = 2.0

    // --- Single-letter accent restoration (dogfood "giskar a allt"): the
    // accent vowels live behind long-press, and a→á / i→í are among the
    // most frequent Icelandic words. A committed bare vowel whose accented
    // twin is a genuinely frequent IS word gets the twin offered — and
    // auto-applied only when the lane is confidently Icelandic AND the
    // bare letter is not itself Icelandic vocabulary ("a" is not an IS
    // word; in an EN lane "a" is never touched).

    /// The accented one-letter word must be attested in is.lex at or above
    /// this calibrated z ("á" +3.3, "í" +3.4 qualify; "é" −0.7, "ý" −1.1
    /// are corpus noise and never offered).
    public var accentRestoreMinZ: Double = 1.5
    /// Offer the accent suggestion only when P(IS) is at least this —
    /// in a strongly English lane the accented variant is noise.
    public var accentOfferMinPosterior: Double = 0.35
    /// Auto-apply (the one sanctioned exception to `minAutocorrectLength`)
    /// only when P(IS) is at least this AND the bare letter is not genuine
    /// Icelandic vocabulary. Never fires in an English or uncertain lane.
    public var accentAutoApplyMinPosterior: Double = 0.65

    // --- Lane relaxation profiles (PLAN.md "Lane relaxation profiles" —
    // "diacritics are an input method, not an error"). Inside a confident
    // Icelandic lane a missing acute accent is not a typo: the long-press
    // costs ~400 ms, tapping the base letter ~80 ms, so the engine restores
    // what the fast typist rationally skipped. Restoration-class edits are
    // therefore priced and margined SEPARATELY from error-class edits:
    //   foldCost = max(foldEpsilon, foldBaseCost · (1 − laneWeight(P_lane)))
    // with laneWeight a smoothstep ramp over the lane posterior. The fold
    // set is exactly the six long-press-gated acute vowels (á é í ó ú ý) —
    // ð þ æ ö have dedicated keys and NEVER fold (d→ð etc. stay in the
    // error-class confusion table, merely lane-discounted). The English
    // mirror folds apostrophes (dont→don't) and capitalizes lone i.

    /// Base price of an acute-vowel fold at a NEUTRAL lane, in nats. Equal
    /// to `SpatialModel.Costs.minSubstitution` on purpose: at P(lane) at or
    /// below `laneWeightRampLo` the relaxation is a no-op and today's
    /// accent-twin floor applies unchanged.
    public var foldBaseCost: Double = 0.35
    /// Fold price floor at a fully saturated lane, in nats. Strictly > 0 so
    /// exact input always wins by ε: a deliberately typed accent is never
    /// tied by its folded reading, and restoration candidates never price
    /// below the exact word.
    public var foldEpsilon: Double = 0.02
    /// Lane posterior at which the fold ramp starts (laneWeight = 0 — the
    /// neutral prior and everything below it get no relaxation at all).
    public var laneWeightRampLo: Double = 0.5
    /// Lane posterior at which the fold ramp saturates (laneWeight = 1 —
    /// folds cost `foldEpsilon`).
    public var laneWeightRampHi: Double = 0.85
    /// Per-profile toggles (eval A/B): the Icelandic acute-vowel profile and
    /// the English apostrophe/lone-i profile.
    public var foldProfileISEnabled = true
    public var foldProfileENEnabled = true
    /// Lane discount applied to the orthographic-confusion constants (d→ð,
    /// t→þ, o→ö, ð↔þ) inside a confident Icelandic lane: cost is scaled by
    /// (1 − laneWeight·discount). Error-class — discounted, never ~free
    /// (these letters have dedicated keys; typing d for ð is a real slip,
    /// just a lane-common one).
    public var confusionLaneDiscount: Double = 0.5
    /// Lane discount for gemination-shaped indels (dropping one of a
    /// doubled letter / omitting a doubling: ll nn tt kk …) inside a
    /// confident Icelandic lane, same (1 − laneWeight·discount) scaling.
    /// Gemination is phonemic — a real error, but the classic lane-common
    /// one, so it is discounted rather than freed.
    public var geminationLaneDiscount: Double = 0.35
    /// Auto-apply margin for RESTORATION-ONLY candidates (every edit is
    /// restoration-class: acute folds / orthographic confusions /
    /// apostrophe insertions) once the lane ramp is open (laneWeight > 0).
    /// Lower than `autocorrectMargin`: restoration serves an input method
    /// and must not compete for the error budget. At/below the neutral
    /// prior the ordinary margin applies unchanged.
    public var restorationAutoApplyMargin: Double = 0.5
    /// Skeleton-collision dominance gate (triple gate, part 1): when the
    /// typed skeleton is itself a valid word, the accented form may only
    /// auto-apply past the valid-word rule when it is at least this many
    /// times more frequent than the skeleton in the lane lexicon (fór ≫ for
    /// passes; víst vs vist does not — offer-only).
    public var restorationDominanceRatio: Double = 10
    /// Dominance fallback when the skeleton is BÍN-valid but absent from
    /// the lane frequency table (real word of UNKNOWN frequency — the ratio
    /// machinery has no denominator): only accented forms attested at or
    /// above this calibrated z may claim dominance. fór (+1.77 on the real
    /// artifacts) clears it; víst (+0.78) does not.
    public var restorationDominanceMinZ: Double = 1.0
    /// Context gate (triple gate, part 2): the accented reading's
    /// calibrated contextual score must beat the skeleton's by at least
    /// this many σ in the lane language ("ég for heim" → fór overwhelmingly).
    public var restorationContextMinAdvantage: Double = 0.0
    /// Sletta guard: auto-restoration additionally requires the lane-blend
    /// log-odds advantage of the accented lane reading over the OTHER
    /// language's reading of the skeleton,
    ///   log(P_lane/(1−P_lane)) + τ·(z_lane(accented) − z_other(skeleton)),
    /// to be at least this many nats. An EN-attested word inside an IS lane
    /// ("for", "van") never gets decorative accents unless the lane is
    /// saturated enough to overwhelm its English typicality.
    public var slettaGuardBlendThreshold: Double = 0.5

    // --- Diacritic-restored prefix completions (dogfood "faralega"):
    // an unknown token may combine missing accents in its PREFIX with an
    // ordinary omission/typo in its tail ("faralega" = "fáránlega" minus
    // the n and both accents) — reachable by completing diacritic variants
    // of typed prefixes ("fárá" → "fáránlega"), never by edits1/edits2.

    /// The pass runs only when no ATTESTED (or personal) candidate exists
    /// at spatial cost at or below this after the cheap passes — same
    /// philosophy (and default) as `closeCandidateGate`; typos with a real
    /// close fix never pay for it. BÍN-only candidates don't suppress it.
    public var diacriticCompletionGate: Double = 4.5
    /// Cap on diacritic prefix variants expanded (each costs one bounded
    /// lexicon completions() range scan).
    public var diacriticCompletionMaxLookups: Int = 24

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

    // --- Inflection intelligence (PLAN.md "Inflection intelligence",
    // Stage B). All inert unless an InflectionModel (paradigms.bin +
    // governors.json.gz) is injected via TypeEngine.setInflection. The
    // morph term is a BACKOFF:
    //   score += λ_morph · log(P(case(candidate) | governor) / 0.25)
    // added only when the exact (governor, candidate) bigram is NOT
    // attested in is.lex — attested bigram evidence must keep dominating
    // (see GovernorFit docs). Gated to the Icelandic lane: governors are an
    // Icelandic phenomenon.

    /// λ_morph: weight of the case-government backoff term. 0 disables the
    /// whole inflection scoring path (baseline A/B switch). Tuned on the
    /// DEV region of the `inflect` eval (sweep 0.5–2.0): 0.6 maximizes the
    /// top-1 delta with the fewest morph-caused regressions; ≥1.5 lets the
    /// case prior steamroll frequency and goes net-negative.
    public var morphBackoffWeight: Double = 0.6
    /// Minimum bigram mass a governor needs before its case distribution is
    /// trusted for scoring — the artifact's own floor is 50; the engine
    /// demands more (thin governors carry noisy marginals).
    public var morphMinGovernorMass: Double = 200
    /// Lane gate: the backoff (and the wrong-form offers) apply only at
    /// P(IS) at or above this. At the neutral prior and below, English
    /// typing is byte-identical to the pre-inflection engine.
    public var morphBackoffMinPosterior: Double = 0.5
    /// Floor of the per-case log-likelihood ratio log(P(case|gov)/0.25),
    /// in nats — also the price of a case the governor was never observed
    /// with (P = 0). Bounds how hard a wrong-case form can be pushed down
    /// (the positive side is naturally capped at log(4) ≈ +1.39).
    public var morphCaseFitFloor: Double = -2.0
    /// Wrong-form offer threshold (offer-only machinery): the governor's
    /// dominant case must beat the typed word's best reading by at least
    /// this many nats of case log-ratio before a sibling form is offered
    /// ("dramatically better" — ~e^1.5 ≈ 4.5× in probability ratio).
    /// The offer is NEVER auto-applied (valid→valid of one lemma: absolute
    /// rule), and never fires when the typed (governor, word) bigram is
    /// itself corpus-attested (grammar-offer precision: attested usage is
    /// never "corrected").
    public var morphWrongFormMinAdvantage: Double = 1.5
    /// Prefix-completion pool width while a governor context is active
    /// (replaces `completionPoolLimit` for the base lexicons there). The
    /// frequency-ranked top-8 often simply does not CONTAIN the governed
    /// form (rare oblique forms sit below the nominative flood) — the
    /// backoff can only reorder what is pooled, so the pool widens exactly
    /// where frequency-only ranking fails.
    public var morphCompletionPoolLimit: Int = 24
    /// Personal lemma lift, in nats: paradigm siblings of a learned surface
    /// form with UNAMBIGUOUS lemma attribution get this additive prior
    /// (consumed as a multiplicative LemmaBoostProviding — see
    /// PersonalLemmaLift). MUST stay below `personalBoostBase` so a sibling
    /// never outranks the learned form itself; ambiguous forms never lift.
    public var lemmaLiftBoost: Double = 1.0

    // --- Personal vocabulary (M2 learning; PLAN.md "Learning" +
    // "Lemma-level learning constraint"). Personal words get an ADDITIVE
    // score prior, never a probability blend: `PersonalLexicon
    // .totalUnigramTokens` is thousands of tokens against the base corpora's
    // hundreds of millions, so normalized personal probabilities would be
    // exactly the apples-to-oranges trap LexiconCalibration exists to fix.
    // boost = min(cap, base + scale·log(1 + personalCount)) for any valid
    // (learned/user-added/session-learned, non-tombstoned) word, plus
    // min(bigramCap, bigramScale·log(1 + pairCount)) when the personal store
    // attests the (previous, word) pair — the "blend, don't hard-prepend"
    // weight that lets personal continuations outrank base continuations
    // proportionally to how often the user actually typed the pair.

    /// Flat additive prior for any valid personal word (nats). Ensures a
    /// just-learned word (count 1) is already competitively suggestible.
    public var personalBoostBase: Double = 2.0
    /// Additional nats per log(1 + personal unigram count).
    public var personalBoostScale: Double = 0.75
    /// Cap on the total personal unigram boost (keeps a heavily-typed
    /// personal word from steamrolling exact-typed base words).
    public var personalBoostCap: Double = 6.0
    /// Nats per log(1 + personal bigram count) for (previous, word) pairs.
    public var personalBigramBoostScale: Double = 2.0
    /// Cap on the personal bigram boost.
    public var personalBigramBoostCap: Double = 6.0
    /// Calibrated-z floor applied per language to any personally-attested
    /// candidate (valid personal word, or follower of a personal bigram)
    /// before blending. Rationale: an OOV personal word otherwise pays the
    /// full corpus-junk penalty (z ≈ −4σ on the real artifacts) that no
    /// sane additive boost should have to bridge — personal attestation is
    /// evidence the word is real vocabulary, so its typicality is floored
    /// near the base lexicons' noise tier and the additive boosts do the
    /// RANKING on top. Base-attested words above the floor are unaffected
    /// (max, not override).
    public var personalScoreFloor: Double = -0.5
    /// How many personal prefix completions feed correction candidates.
    public var personalCompletionPoolLimit: Int = 8
    /// How many personal bigram followers feed next-word prediction.
    public var personalContinuationPoolLimit: Int = 8

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
    /// Personal vocabulary holder, shared BY REFERENCE with the engine and
    /// every corrector/predictor copy of this struct — a snapshot swap on
    /// the engine queue is visible everywhere without any rebuild.
    let personal: PersonalStore
    /// Inflection-intelligence holder (paradigms + governors + personal
    /// lemma lift), shared by reference exactly like `personal` — inert
    /// (nil model) unless the embedder injects one.
    let inflection: InflectionStore

    init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding?,
        config: EngineConfig,
        personal: PersonalStore = PersonalStore(),
        inflection: InflectionStore = InflectionStore()
    ) {
        self.icelandic = icelandic
        self.english = english
        self.morphology = morphology
        self.config = config
        self.personal = personal
        self.inflection = inflection
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

    /// Valid personal vocabulary: learned, user-added or session-learned —
    /// suggestible and protected from autocorrect.
    func isPersonalValid(_ word: String) -> Bool {
        personal.isValidWord(word)
    }

    /// Deleted in the dictionary editor: never suggest, never predict.
    func isPersonalTombstoned(_ word: String) -> Bool {
        personal.isTombstoned(word)
    }

    /// Validity for the TYPED word (autocorrect conservatism): base-known,
    /// personal-valid, or tombstoned. Tombstoned words count as valid here
    /// on purpose — deleting a word means "stop suggesting it", never
    /// "start correcting it when I type it" (PLAN.md learning semantics).
    func isValidTypedWord(_ word: String) -> Bool {
        isKnownAnywhere(word) || personal.isValidWord(word) || personal.isTombstoned(word)
    }

    /// Additive personal-source prior for a candidate (see the
    /// `personalBoost*` tunables): unigram part for valid personal words,
    /// bigram part when the personal store attests the (previous, word)
    /// pair. Zero for everything else — and always zero for tombstoned
    /// words, which never reach scoring anyway.
    func personalBoost(of word: String, previous: String?) -> Double {
        guard personal.isActive else { return 0 }
        var boost = 0.0
        if personal.isValidWord(word), !personal.isTombstoned(word) {
            let count = Double(personal.count(of: word))
            boost = min(
                config.personalBoostCap,
                config.personalBoostBase + config.personalBoostScale * log(1 + count)
            )
        } else if let lift = inflection.lift, !personal.isTombstoned(word) {
            // Personal lemma lift (PLAN.md "Inflection intelligence" Stage B
            // #4 + the lemma-level learning constraint): a paradigm sibling
            // of a learned form with UNAMBIGUOUS lemma attribution gets a
            // small additive prior — strictly smaller than any learned
            // form's own boost (lemmaLiftBoost < personalBoostBase), never
            // a merge of counts. The LemmaBoostProviding seam is
            // multiplicative (1.0 = neutral); consumed here as log-nats.
            boost = log(lift.lemmaBoost(forCandidate: word))
        }
        if let previous, let pairCount = personal.bigramCount(previous, word),
            !personal.isTombstoned(word)
        {
            boost += min(
                config.personalBigramBoostCap,
                config.personalBigramBoostScale * log(1 + Double(pairCount))
            )
        }
        return boost
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
    /// log( P(IS)·exp(τ·z_IS) + P(EN)·exp(τ·z_EN) ) + personalBoost.
    /// Replaces the raw probability blend — see LexiconCalibration. The
    /// additive personal-source prior rides on top of the calibrated blend
    /// (see `personalBoost(of:previous:)`); it deliberately does NOT touch
    /// the lane posterior or the per-language z-scores.
    func blendedScore(of word: String, previous: String?, pIcelandic: Double) -> Double {
        let p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        let tau = config.calibrationTemperature
        let boost = personalBoost(of: word, previous: previous)
        var zIS = calibratedScore(of: word, previous: previous, language: .icelandic)
        var zEN = calibratedScore(of: word, previous: previous, language: .english)
        if boost > 0 {
            // Personally-attested: don't pay the OOV corpus-junk penalty
            // (see personalScoreFloor docs).
            zIS = max(zIS, config.personalScoreFloor)
            zEN = max(zEN, config.personalScoreFloor)
        }
        let a = log(p) + tau * zIS
        let b = log(1 - p) + tau * zEN
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m)) + boost
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
        let firstBoost = personalBoost(of: first, previous: previous)
        let secondBoost = personalBoost(of: second, previous: first)
        // Personally-attested halves skip the OOV corpus-junk penalty,
        // exactly like blendedScore (see personalScoreFloor docs).
        func z(_ word: String, _ prev: String?, _ language: Language, floored: Bool) -> Double {
            let score = calibratedScore(of: word, previous: prev, language: language)
            return floored ? max(score, config.personalScoreFloor) : score
        }
        let a =
            log(p)
            + tau
                * (z(first, previous, .icelandic, floored: firstBoost > 0)
                    + z(second, first, .icelandic, floored: secondBoost > 0))
        let b =
            log(1 - p)
            + tau
                * (z(first, previous, .english, floored: firstBoost > 0)
                    + z(second, first, .english, floored: secondBoost > 0))
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m)) + firstBoost + secondBoost
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
        // Inflection artifacts: one governor probe (O(1) dict) plus
        // paradigm case-code probes across the sampled words — faults in
        // the form-table/permutation/entries index pages every future
        // per-candidate lookup shares (same rationale as the morphology
        // spread below).
        if let paradigms = inflection.model?.paradigms {
            for word in icelandicCalibration.sampleWords {
                _ = paradigms.bundles(ofForm: word)
            }
            // Two-letter spread over the form table's binary-search paths,
            // same rationale as the morphology spread below.
            let alphabet = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")
            for first in alphabet {
                for second in alphabet {
                    _ = paradigms.bundles(ofForm: String([first, second]))
                }
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
