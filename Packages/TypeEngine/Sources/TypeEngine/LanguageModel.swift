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

    /// Whether the form has an OPEN word-class analysis (noun/verb/
    /// adjective) — the compound-HEAD legality test (wave 22, the port of
    /// Miðeind's `_OPEN_CATS` restriction: function words are never
    /// compound heads). Default: plain `isKnown` (validation-only
    /// conformers over-accept rather than break).
    func hasOpenClassAnalysis(_ word: String) -> Bool
}

public extension MorphologyProviding {
    func nounAdjectiveCases(of word: String) -> [String] { [] }
    func lemmaCandidates(of word: String) -> [String] { [] }
    func hasOpenClassAnalysis(_ word: String) -> Bool { isKnown(word) }
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
    /// Lowered 1.25 → 1.15 (2026-07-16 auto-apply tuning wave): the
    /// 1.15–1.25 margin band on corpus dev was 20 correct / 4 false —
    /// materially under-fired; 1.10 and below degrade toward 70% precision.
    public var autocorrectMargin: Double = 1.15
    /// Typicality floor for a single-word auto-replacement: the winning
    /// candidate must be ATTESTED in a frequency table (personal words are
    /// exempt — personal attestation is stronger evidence) with a calibrated
    /// z-score at or above this. BÍN-only forms (z pinned at the BÍN floor,
    /// ≈ −2.9 on the real artifacts) are never auto-applied: BÍN's 3M
    /// surface forms sit one edit from everything, and replacing a typo
    /// with morphology-validated junk is the dogfood "faralega → garalega"
    /// landmine. Suggestions are unaffected — this gates the flag only.
    public var autocorrectMinZ: Double = -2.5
    /// Junk-tier winner discipline (session-3 replay "kozy" → "jozy",
    /// 2026-07-16): an ordinary auto-apply whose winner sits BELOW this
    /// calibrated z is a junk-tier replacement guess (jozy z −1.37 — an
    /// is.lex web-corpus name), so its required margin is SCALED by
    /// `autocorrectJunkWinnerMarginScale` instead of hard-floored: raising
    /// `autocorrectMinZ` itself to −1.5 cost 3.3pp fired for 0.4pp false on
    /// dev (~88% of the removed fires were correct — mid-tier vocabulary is
    /// where honest corrections land), while margin scaling only removes
    /// the narrow junk wins. Personal words are exempt (typicality ∞).
    public var autocorrectJunkWinnerZ: Double = -1.0
    /// Margin multiplier for junk-tier winners (see above). 1.0 disables.
    /// Swept on dev 2026-07-16: ×2 removed 12 fires (7 false), ×3 removed
    /// 27 (17 false), ×4 removed 5 more (0 false) — ×3 is the knee; the z
    /// threshold at −0.5 / −1.25 both removed mostly-correct fires.
    public var autocorrectJunkWinnerMarginScale: Double = 3.0
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
    /// Never auto-replace inputs shorter than this. Lowered 3 → 2 with the
    /// short-token discipline below (dogfood "eg"/"vð" diagnosis,
    /// 2026-07-16): two-letter unknown tokens carry little spatial
    /// evidence, but exactly the extreme-frequency Icelandic function words
    /// (ég, við, að, þú …) are what people actually mean by them — an
    /// unconditioned margin rule fired mostly junk on the dev corpus
    /// (3 of 4 new fires false), while the `autocorrectShortMinZ` floor
    /// keeps only headline-vocabulary winners.
    public var minAutocorrectLength: Int = 2
    /// Tokens of length at or below this are SHORT for the auto-apply
    /// typicality rule below.
    public var autocorrectShortLengthMax: Int = 2
    /// Typicality floor for auto-applying onto a SHORT unknown token: the
    /// winner must be attested at or above this calibrated z (personal
    /// words exempt, as everywhere). ég +2.42 / við +2.93 clear it; the
    /// mid-tier words a 2-letter token sits one edit from do not.
    public var autocorrectShortMinZ: Double = 1.5
    /// Archaic-twin restoration (wave 32, the eg/þu dogfood class): master
    /// toggle for the relaxed SHORT-token floor below (eval A/B switch).
    public var archaicTwinRestorationEnabled = true
    /// Relaxed short-token typicality floor for a RESTORATION-ONLY winner
    /// that is the typed skeleton's DOMINANT acute-fold twin (the wave-26
    /// `acuteFoldShadowTwin` probe, base-lexicon edition: is.lex dominance
    /// ratio over the skeleton's own attestation + above-noise twin + the
    /// twin beats the skeleton's ENGLISH reading). Such a skeleton maps
    /// deterministically to its twin — the acute vowel has no key of its
    /// own, so the two typed letters ARE the twin's evidence — and demanding
    /// the full `autocorrectShortMinZ` headline bar was the one gate that
    /// kept "þu" → "þú" (z +1.482, 0.02σ under the 1.5 floor) silent while
    /// "eg" → "ég" (+2.42) and "su" → "sú" (+1.72) fired. Band analysis on
    /// the real artifacts (2-char twins reachable from a skeleton that is
    /// attested NOWHERE — is.lex/en.lex-attested skeletons take the
    /// skeleton-collision triple gate instead and never see this floor):
    /// þú +1.48 is the only member in (1.17, 1.5); the next admit down is
    /// fé +1.17 (skeleton "fe" is en.lex-attested anyway) and já +1.12
    /// (skeleton "ja" is genuine is.lex vocabulary — dominance-ratio keeps
    /// it protected, the för/for-class shape). 1.3 sits between þú and fé
    /// with ~0.15σ of safety on both sides.
    public var archaicTwinShortMinZ: Double = 1.3
    /// Short double-substitution repairs (live-session "habb" → "hann",
    /// 2026-07-16): per-edit spatial-cost ceiling for the targeted 3-4 char
    /// two-substitution pass — ~adjacent keys only (adjacent ≈ 1.05 nats).
    // 1.2 covered row-mates (b→n) but excluded vertical-diagonal
    // neighbors (g→t ≈ 1.25 nats) — Jökull's real "hega"→"geta" miss.
    // 1.4 admits the row-above class; corpus A/B flat (±0.03pp).
    public var shortDoubleSubMaxEditCost: Double = 1.4
    /// Typicality floor for candidates admitted by that pass: only
    /// headline vocabulary may be reached through two edits on a short
    /// token ("hann" +2.7 clears it; junk neighbors of junk stay out).
    public var shortDoubleSubMinZ: Double = 2.0
    /// Context-vouched admission tier for the short double-sub pass: a
    /// candidate under the headline bar still enters when its exact bigram
    /// with the previous word is attested and its own typicality clears
    /// this (lower) floor. See Corrector's contextTypical.
    public var shortDoubleSubContextMinZ: Double = 1.0

    /// Vacuum auto-apply (live-session "stökklrikanum" wave, 2026-07-16):
    /// when the typed token is unknown everywhere AND the candidate pool
    /// holds NO attested-or-personal repair within `closeCandidateGate`,
    /// a BÍN-valid winner (normally barred from auto-apply by
    /// `autocorrectMinZ` — the junk floor) may fire at this STRICTER
    /// margin: with no attested competition, replacing an unknown token
    /// with the morphologically valid word one cheap edit away beats
    /// leaving the typo. Far repairs keep the hard attested-common rule
    /// (mash must never become BÍN junk — the "garalega" landmine is
    /// non-vacuum anyway: the honest attested repair is in the pool).
    public var vacuumAutoApplyMargin: Double = 2.0
    /// Master toggle for the vacuum auto-apply rule (eval A/B). DEFAULT
    /// OFF (2026-07-16 verdict): on the dev corpus the rule fired 48 new
    /// with 7 false — vacuum falses are margin-immune (no runner-up to
    /// margin against), the overall false-ac ceiling headroom vanished
    /// (4.87% of 5.0%), and it contradicts the sacred BÍN-junk contract
    /// (`testBinOnlyCandidateNeverAutoApplies`, the "garalega" landmine).
    /// Kept as an A/B knob for a future wave with better junk separation
    /// (e.g. compound-splitter validation instead of raw BÍN validity).
    public var vacuumAutoApplyEnabled = false

    // MARK: - Compound acceptance (wave 22 — PLAN.md "Compounds")

    /// Master toggle for productive compound VALIDITY (see Compounds.swift):
    /// an OOV word decomposable as legal-modifier(s)+legal-BÍN-head is
    /// autocorrect-PROTECTED (never auto-replaced by an error-class rewrite
    /// or a split; restoration-class auto-apply still runs through the
    /// skeleton triple gate, so lazy accent skeletons like "tungumal" that
    /// happen to decompose keep restoring). Deliberately NOT fed into the
    /// generation-pass gates: suggestions for a compound-shaped token are
    /// generated exactly as before, only the auto-apply decision changes.
    /// Inert without BOTH a morphology provider and an inflection model
    /// (paradigms.bin carries the definiteness bit the modifier rule
    /// needs).
    public var compoundValidityEnabled = true
    /// Minimum modifier (non-final part) length. Miðeind's prefix list
    /// bottoms out at 2; 4 is this engine's over-acceptance guard (the
    /// dev sweep: 3/3 protects 2.7% of typo rows, 4/4 → 1.2% with no loss
    /// on real-compound positives — short-part compounds live in BÍN
    /// anyway, so validity only needs the productive long tail).
    public var compoundMinModifierLength: Int = 4
    /// Minimum head (final part) length; same sweep as above.
    public var compoundMinHeadLength: Int = 4
    /// Words longer than this skip compound analysis (pathological-input
    /// latency guard; the split scan is O(length) lookups).
    public var compoundMaxWordLength: Int = 32
    /// Compound-head repair pass (Corrector step 5b): when an unknown
    /// token has a legal modifier PREFIX but no legal head, hold the
    /// modifier fixed and admit single-edit repairs of the head that are
    /// legal compound heads ("stökkl|rikanum" → stökk + leikanum). The
    /// candidates rank through the normal pipeline; being unattested they
    /// can never auto-apply (attested-winner rule).
    public var compoundRepairEnabled = true
    /// Minimum typed length for the compound-head repair pass. OOV
    /// compounds worth repairing are long (modifier ≥ 4 + head ≥ 4).
    public var compoundRepairMinLength: Int = 8
    /// The repair pass only runs when the cheap passes left no
    /// attested-or-personal candidate at or under this spatial cost (the
    /// `beamDeepGate` shape). 4.5 — one indel above the deep-beam gate —
    /// keeps compound hypotheses out of pools that already hold an
    /// honest single-insert repair ("eldsnyti" → attested "eldsneyti" at
    /// cost 4.0 must not grow a cheap-sub compound rival "elds+nytu").
    public var compoundRepairGate: Double = 4.5
    /// At most this many legal-modifier prefixes are tried, longest first.
    public var compoundRepairMaxModifiers: Int = 2
    /// Budget of head-legality lookups per correct() call (each is one
    /// mmap binary search over packed entries — no string decodes) — the
    /// latency cap for the repair pass. 1400 covers the full single-edit
    /// enumeration of two ~8-char head regions; the enumeration is
    /// cost-sorted, so a cut drops the least plausible repairs first.
    public var compoundRepairMaxLookups: Int = 1400
    /// Also pool lexicon completions of the head REGION under the fixed
    /// modifier ("stökklei|" → stökk + leikur…): compound continuations in
    /// the bar (scope 3 of wave 22, riding the same pass). Wave 22 shipped
    /// this DEFAULT OFF: at the raw 0.5/char completion price a
    /// speculative extension structurally outranked space-miss splits and
    /// honest repairs ("fimmtabókina" over "fimmta bókin"). Wave 23
    /// enabled it with completion-specific pricing: extensions cost
    /// `compoundCompletionBasePenalty` + 0.5/char (a hypothesized
    /// decomposition is dearer than an attested completion), rank WITHIN
    /// the pool by head attestation (`compoundCompletionHeadZWeight`) +
    /// the head's governor case fit, and a hard assembly rule keeps every
    /// space-miss split reading ranked above every compound extension —
    /// the split machinery keeps its slots unconditionally.
    public var compoundCompletionEnabled = true
    /// Base channel penalty of a compound-completion extension, on top of
    /// the 0.5/char completion rate (wave 23 — the completion-specific
    /// pricing wave 22 deferred for). Anchored at the split-substitution
    /// tier: hypothesizing an unattested decomposition is at least as
    /// speculative as reading a typed letter as a missed spacebar.
    public var compoundCompletionBasePenalty: Double = 3.0
    /// Weight on the head's calibrated is.lex z (floored at
    /// `compoundHeadMinZ` so bound suffix forms — attested nowhere by
    /// construction — are not punished for it) when ranking compound
    /// completions: the head carries the inflection and the frequency
    /// signal while the whole word sits at the shared compound floor.
    public var compoundCompletionHeadZWeight: Double = 0.25
    /// Frequency assigned to a compound-valid word absent from every
    /// table: STRICTLY below `binFloorFrequency`, so a BÍN-attested whole
    /// word always outranks a hypothesized decomposition at equal cost
    /// (dev-corpus verdict — a head-frequency lift and a shared BÍN floor
    /// both walked cheap-edit junk compounds over honest repairs).
    public var compoundFloorFrequency: UInt32 = 1
    /// Typicality floor for a GENERATED (repair/completion) compound head:
    /// bound suffix forms are exempt; every other hypothesized head must
    /// be is.lex-attested at or above this calibrated z. Set between the
    /// junk tier ("legan" −2.07, "legs" −2.04 — the web-corpus noise that
    /// flooded the "faralega" bar) and the honest rare heads ("spjallið"
    /// −1.50, "krikanum" −1.17). VALIDITY (protection) deliberately keeps
    /// the wider BÍN-only head rule: under-correcting a typed word is
    /// safe, suggesting junk is not.
    public var compoundHeadMinZ: Double = -1.6

    // MARK: - Context ranking (wave 27 — bigram evidence at ranking/margin
    // time). Four seams, all driven by the same currency: the CONTEXTUAL
    // LIFT of a candidate, z(w | prev) − z(w) in the lane language — how
    // many calibrated σ the attested bigram with the previous word moves
    // the candidate above its own unigram typicality. Positive lift ≈
    // positive pointwise mutual information: the context genuinely SELECTS
    // this word ("ég grét" +1.26σ), while a merely-frequent word after a
    // frequent context sits at ~0 or below ("en vil" −0.18σ — "en" does
    // not select "vil", vil is just common). Unattested bigrams have NO
    // lift (nil), never a penalty — unseen pairs are not evidence against.

    /// Fold-twin bigram context backoff (the "Eg gret" cold-start shape):
    /// when the previous word is attested in NEITHER frequency lexicon,
    /// bigram evidence is read through its dominant acute-fold twin
    /// (`acuteFoldShadowTwin`: eg → ég) instead of dying on the lazy
    /// skeleton — the twin machinery's own three gates (10× is.lex
    /// dominance, twin above the noise tier, twin beats the skeleton's
    /// English reading) keep this to exactly the skeletons that ARE lazy
    /// spellings of their twin. Doctrine: diacritics are an input method —
    /// that holds for the context word too.
    public var bigramContextFoldBackoffEnabled = true

    /// Bigram-dominance margin relief: when the auto-apply WINNER carries
    /// contextual lift at/above `bigramMarginReliefMinLift` in the
    /// posterior-dominant lane and the RUNNER-UP carries none (bigram
    /// unattested, or lift ≤ 0), the two are separated by direct corpus
    /// evidence of the pair the user just typed — the required margin is
    /// scaled by this factor (< 1). Dogfood "son minn ég gret": grét
    /// (lift +1.26, bigram "ég grét" 222) vs the morph-boosted completion
    /// "greta" (no bigram) sat at margin 0.469 against the 0.5 restoration
    /// margin. Junk-tier winners (`autocorrectJunkWinnerZ`) never get
    /// relief — the junk margin scaling stays intact.
    public var bigramMarginRelief: Double = 0.7
    /// Minimum winner contextual lift (calibrated σ) for the relief above.
    public var bigramMarginReliefMinLift: Double = 0.75

    /// Context-backed short-token discipline (dogfood "vli" → false "vil"
    /// fire, session 2026-07-17T10-12-46): a 3-letter token carries barely
    /// more spatial evidence than the 2-letter class below
    /// `autocorrectShortLengthMax`, so an ERROR-class rewrite of one must
    /// be backed by more than raw frequency — the winner needs typicality
    /// at/above `autocorrectContextShortMinZ` (eru +2.51, það +2.82, sama
    /// +1.88 all clear it; vil +1.48 does not) UNLESS its contextual lift
    /// clears `autocorrectContextLiftFloor` (the bigram vouches:
    /// "krakkarnir eru" +1.16σ fires regardless of the floor). Restoration-
    /// only winners are exempt — they carry their own gate stack (fra→frá
    /// unaffected). Applies to lengths in
    /// (autocorrectShortLengthMax, autocorrectContextLengthMax].
    public var autocorrectContextLengthMax: Int = 3
    /// The raised typicality floor for unvouched 3-letter error rewrites.
    public var autocorrectContextShortMinZ: Double = 1.5
    /// Contextual lift at/above this waives the raised floor (the context
    /// genuinely selects the winner).
    public var autocorrectContextLiftFloor: Double = 0.25

    /// Bigram-continuation proposals (generation): for an unknown token,
    /// the attested CONTINUATIONS of the (fold-backed) previous word are
    /// admitted as candidates when their exact channel cost is at/under
    /// `contextContinuationMaxCost` — context proposes, the typed keys
    /// verify. This is the only pass that can reach a word the edit passes
    /// structurally cannot ("en vli" → "væri": insert-r + l→æ is two edits
    /// on a 3-char token, outside every short-token budget, but væri is a
    /// top follower of "en"). Candidates are bigram-attested by
    /// construction and re-scored by the normal pipeline; the cost cap
    /// keeps far followers ("en það" from "vli") out of the pool.
    public var contextContinuationEnabled = true
    /// How many top bigram followers per lexicon are pooled. High-fan-out
    /// contexts need depth: "en" has hundreds of followers above f≈1000,
    /// and the wave's target ("en væri", f=858) sits between rank 300 and
    /// 450 — 500 covers the honest tail. The scan+sort cost of the fan-out
    /// is paid once per CONTEXT word (memoized in
    /// `ContinuationProposalCache`), not per keystroke, and the shape
    /// prefilter + typicality floor keep the DP work per keystroke to a
    /// handful of candidates.
    public var contextContinuationPoolLimit: Int = 500
    /// Channel-cost admission cap for a proposed continuation. 5.5 admits
    /// one omission (4.0) plus one adjacent-key/fold substitution, the
    /// double-error shape the pass exists for, and stays a full nat under
    /// `autocorrectMaxSpatialCost` + margin territory — these candidates
    /// essentially never auto-apply, they surface in the bar.
    public var contextContinuationMaxCost: Double = 5.5

    /// Proper-noun possessive guard (dev contraction_damage diagnosis,
    /// 2026-07-16): a capitalized MID-SENTENCE unknown token of shape
    /// Name+s whose stem is not English vocabulary is a possessive typed
    /// without the apostrophe that the derivation pass cannot read —
    /// error-class auto-apply is suppressed ("Corgans" must not become
    /// "Organs", "LSUs" not "Laus"); suggestions and restoration-only
    /// winners are unaffected, and sentence-initial capitals (empty
    /// context or after . ! ? …) keep every rule. Deliberately narrow: a
    /// blanket capitalized-token veto blocked 87% honest fixes on dev.
    public var properNounGuardEnabled = true

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
    /// Veto-asymmetry relaxation (2026-07-16, dogfood "vð" under careful
    /// taps): the whole-word aggregate veto applies to LENGTH-CHANGING
    /// rewrites whose indel costs the taps cannot reprice — so a careful
    /// typist's omission typo ("vð" for "við") was blocked purely by the
    /// ×4 margin while carrying no contradicting tap. When the winner is
    /// EXTREME vocabulary (calibrated z at or above
    /// `tapVetoCommonWinnerMinZ`; personal words qualify), the veto factor
    /// is clamped at `tapVetoCommonMaxFactor` instead: við (+2.9) fires at
    /// margin 3.1, while fixture-tier winners ("holes" +0.4) keep the full
    /// clamp — an all-dead-center unknown word still essentially never
    /// rewrites to anything but headline vocabulary.
    public var tapVetoCommonWinnerMinZ: Double = 2.0
    /// The relaxed clamp for extreme-common winners (see above).
    public var tapVetoCommonMaxFactor: Double = 2.5

    // --- Personal adaptive touch model (PLAN.md "Touch decoding", stage 2).
    // When a `PersonalTouchSnapshot` is injected (TypeEngine.setPersonalTouch)
    // AND taps flow, the PerTapCostProvider prices keys that cleared the
    // min-samples gate against a PERSONAL 2D Gaussian: the TSI prior shrunk
    // toward the user's own per-key distribution. Shrinkage (per key, with
    // n = effective sample count, k = touchPriorStrength, w = n/(n+k)):
    //
    //   mean_blend = w · mean_personal            (prior mean = key center)
    //   var_blend  = w · var_personal + (1−w) · tapSigma{X,Y}²
    //   cov_blend  = w · cov_personal             (prior covariance = 0)
    //
    // so a cold key IS the prior, and the personal distribution takes over
    // smoothly as evidence accumulates (steady state under the Learning
    // decay: n ≈ 250–500 → w ≈ 0.83–0.91). With no snapshot — or no key past
    // the gate — pricing is byte-identical to the stage-1 static provider.

    /// Effective per-key sample count a key must reach before its personal
    /// statistics participate at all (below: the pure TSI prior). Keeps
    /// early, noisy Welford estimates out of pricing.
    public var touchPersonalMinSamples: Double = 30
    /// k in the n/(n+k) shrinkage weight: the prior's strength in
    /// equivalent samples. 50 ≈ "the TSI prior is worth 50 of the user's
    /// taps" — at the 30-sample gate the blend is still 62% prior.
    public var touchPriorStrength: Double = 50
    /// Floor on each blended per-key σ, in key-pitch units. A user with a
    /// pathologically tight cloud (or a corrupt/near-zero variance) must
    /// not price every neighbor at absurd likelihood ratios: 0.08 caps the
    /// per-axis exponent of a full key pitch at ~78 nats BEFORE the
    /// min/maxSubstitution clamps (which still bound every priced cost) and,
    /// more importantly, keeps the confidence normalization well-behaved.
    public var touchSigmaFloor: Double = 0.08

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
    /// DID land where the space belongs, one key-row off. Raised 1.5 → 3.0
    /// on the v0 corpus dev split (space_miss diagnosis, 2026-07-16): at
    /// 1.5 the 3.5-nat gap to `splitInsertionPenalty` let a substitution
    /// split that consumes a REAL letter systematically beat the honest
    /// insertion split whenever the leftover right half was also valid
    /// ("insteadchose" → "instead hose" over "instead chose", "InMarch" →
    /// "I March"); 3.0 keeps the tap-evidence discount (2 nats) without
    /// letting letter-eating splits dominate. Swept 1.5/2.0/2.5/3.0/3.5:
    /// 3.0 maximizes space_miss top-1 + false-ac gains with zero movement
    /// in every other category and the micro-eval split block intact.
    public var splitSubstitutionPenalty: Double = 3.0
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
    /// Longest invalid half the edits1 repair fallback will walk (the
    /// diacritic/gemination passes are unbounded — they're tiny). Bounds
    /// the worst-case cost of ONE junk hypothesis so the split budget is
    /// spent across hypotheses, not inside the first one (see
    /// `Corrector.halfHypotheses`).
    public var splitHalfEdits1MaxLength: Int = 8
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
    /// this, in one common language, for the escape to be OFFERED. Rare
    /// words next to a dot are far more likely a real domain/file token.
    /// Lowered 1.0 → −0.25 (session-4 "læt.hann", 2026-07-16): Icelandic
    /// inflected verb forms sit at mid-tier unigram z ("læt" −0.06 — a
    /// perfectly ordinary 1sg), so the 1σ bar silently ate honest missed
    /// spaces; −0.25 still rejects the file-extension band (html −0.40,
    /// pdf −0.87, css −1.02) and everything unattested. The OFFER is
    /// bar-only either way — auto-apply keeps the strict 2σ bar below.
    /// One-letter halves must additionally clear
    /// `splitSingleCharHalfMinZ` (genuine one-letter words only).
    public var dottedEscapeMinHalfZ: Double = -0.25
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
    /// folds cost `foldEpsilon`). Lowered 0.85 → 0.75 (2026-07-16): a lane
    /// only a few committed words deep already deserves near-free folds;
    /// rampLo stays at the neutral 0.5 (the "no relaxation at/below the
    /// neutral prior" invariant is untouchable).
    public var laneWeightRampHi: Double = 0.75
    /// Per-profile toggles (eval A/B): the Icelandic acute-vowel profile and
    /// the English apostrophe/lone-i profile.
    public var foldProfileISEnabled = true
    public var foldProfileENEnabled = true
    /// Derived English possessives (EN profile; corpus-dev contraction_damage
    /// diagnosis, 2026-07-16): en.lex has essentially no possessive forms
    /// ("world's", "watson's" absent; "children's" present but undercounted
    /// 400x — the same Google-Ngram apostrophe-token undercount the
    /// contraction repair fixes for the curated contractions). Instead of
    /// enumerating possessives into the artifact, the model DERIVES them: an
    /// English word "X's" whose base X is attested in en.lex scores as
    /// English vocabulary with frequency
    ///   max(own attested frequency, possessiveFrequencyFraction · freq(X)).
    /// The fraction keeps every derived possessive strictly below its base
    /// word (log(0.1) ≈ −2.3 nats — a plural skeleton always dominates its
    /// possessive reading, "cats" ≫ "cat's") while lifting it far above the
    /// OOV floor so restoration can rank and (for unattested skeletons like
    /// "childrens"/"watsons") auto-apply. Swept 0.01/0.03/0.05/0.1/0.2 on
    /// corpus dev: gains plateau at 0.1 (en.lex's tight calibration σ means
    /// −4.6 nats of raw discount at 0.01 was ~4σ — enough for the stem
    /// "watson" to outrank its own ε-cost possessive repair); 0.2 starts
    /// ticking insertion false-ac up.
    public var possessiveFrequencyFraction: Double = 0.1
    /// Typicality floor on the BASE word for offering the possessive of a
    /// typed token that is itself a VALID word ("leagues" → offer
    /// "league's", bar-only): valid plurals only get the offer when the
    /// bare noun is genuinely attested vocabulary above the junk tier —
    /// rare-word plurals keep an undisturbed bar. Unattested skeletons
    /// ("childrens") need only an attested base.
    public var possessiveOfferMinBaseZ: Double = -1.5
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
    /// Relaxed dominance fallback for an OBLIQUE-ONLY skeleton (dogfood
    /// "simanum" diagnosis, 2026-07-16): a BÍN-valid, is.lex-unattested
    /// skeleton whose noun/adjective readings carry NO nominative — e.g.
    /// "simanum" (þgf-only form of BÍN's variant lemma "simi") — is not a
    /// citation-form word anyone types deliberately; it exists only as an
    /// accent-dropped spelling of its restored twin. Base-form skeletons
    /// ("vist", "for", "van", "mal" — all nf-readable) and non-noun
    /// skeletons keep the strict `restorationDominanceMinZ` bar. −0.5
    /// still demands the restored form be genuinely attested vocabulary
    /// above the noise tier ("símanum" +0.04 passes with headroom;
    /// junk-tier restorations stay offer-only). Swept 0.0/−0.5 on dev:
    /// −0.5 adds one correct fire, zero false.
    public var restorationDominanceObliqueMinZ: Double = -0.5
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
    /// saturated enough to overwhelm its English typicality. Lowered
    /// 0.5 → 0.25 (2026-07-16, first recorded live session): typed "Fair"
    /// meaning "Fáir" in a young IS lane (P(IS) 0.744) scored +0.47 —
    /// blocked by a hair while every other gate passed; 0.25 still demands
    /// the IS reading be ~1.3× likelier under the blend, dev corpus
    /// byte-identical, sletta scenarios ("deadline", EN "for" at neutral)
    /// unaffected.
    public var slettaGuardBlendThreshold: Double = 0.25

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

    // --- Case-aware long-word completions (wave 23 — the
    // Kirkjubæjarklaustur class, session 2026-07-16T15-32-25: after
    // "…okkur á" the bar offered ONLY the dative completion
    // "Kirkjubæjarklaustri" while the á-motion context wanted the
    // accusative "Kirkjubæjarklaustur"). Two seams, both RANKING-only
    // (completions are bar offers, never auto-applied — margin-free):
    //  * governed prefix-repair completions: an OOV token under an active
    //    governor may be a completion typed one-or-two junk characters
    //    past the intended stem ("Kirkjubæjars|" wanted extensions of
    //    "Kirkjubæjar"); the trimmed-prefix completions are admitted at a
    //    SPECULATIVE completion price (trailing typed chars as
    //    extra-character errors + completionCharCost per not-yet-typed
    //    char) instead of the structural full-DP price that made a
    //    7-chars-longer candidate unrankable.
    //  * case-sibling expansion: a pooled completion whose lemma
    //    attribution is UNAMBIGUOUS (surface-form doctrine: ambiguous
    //    lemma → attested surface only) contributes its paradigm siblings
    //    in the governor's supported cases — dominant plus the runner-up
    //    when the distribution is genuinely split (á governs both þgf
    //    location 0.52 and þf motion 0.26: guessing one starves the bar
    //    of the other), holding number/definiteness fixed.
    // Speculative admissions are EXCLUDED from every pass-gating probe
    // (bestSoFar / bestAttestedCost), so the split/deep-beam/diacritic
    // pass decisions stay byte-identical to the pre-wave engine.

    /// Master toggle (eval A/B). Inert without an inflection model.
    public var caseCompletionEnabled = true
    /// How many trailing typed characters may be treated as errors when
    /// completing a trimmed prefix (the "Kirkjubæjars" junk-s class). Each
    /// trimmed char prices at the extra-character (insertion) constant.
    public var caseCompletionMaxTrim: Int = 2
    /// Minimum typed length for the prefix-repair completion pass: short
    /// tokens have real repair passes and completion pools of their own —
    /// this machinery exists for the long-word tail where the DP price of
    /// a many-chars-longer candidate is structurally unpayable.
    public var caseCompletionMinLength: Int = 5
    /// A governor's runner-up case joins the supported-case set for
    /// sibling expansion when its probability is at/above this ("á": þf
    /// 0.257 qualifies — genuinely split government; "frá": þf 0.149 does
    /// not — dative government is essentially decided).
    public var caseSplitSecondMinProbability: Double = 0.2
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

    // --- Personal-learning self-poisoning guards (wave 26, real session
    // 2026-07-16T22-45-30). Two leaks made personal learning eat the very
    // behaviors it should personalize:
    //  1. lazy acute-less commits (þvi, eg, gret — acute vowels are
    //     long-press-only, so lazy typing IS the input method) get learned
    //     and then, as "valid personal vocabulary", veto the restoration
    //     autocorrect that produced/serves them — self-reinforcing death of
    //     restoration;
    //  2. iOS sentence-start autocapitalization gets learned into surfaces
    //     ("Fyrir", "Frábær") that then title-case every mid-sentence
    //     correction to those words.

    /// An IMPLICITLY learned personal word is an acute-fold SHADOW (loses
    /// the autocorrect veto, keeps ranking/prediction boosts) only when
    /// some pure acute-restoration twin is attested in is.lex at at least
    /// this ratio over the skeleton's own is.lex frequency (því ≫ þvi
    /// passes; bíll vs bill does not). Explicit adds / verbatim taps /
    /// tombstones are never shadows.
    public var personalFoldShadowDominanceRatio: Double = 10
    /// ... and the dominant twin must itself be attested at or above this
    /// calibrated z (real vocabulary above the noise tier: grét −0.37
    /// qualifies, junk twins do not) AND above the skeleton's ENGLISH
    /// calibrated z (an EN-attested skeleton like "for"/"bill" keeps full
    /// personal protection — its commits were plausibly English).
    public var personalFoldShadowMinTwinZ: Double = -0.5
    /// A learned personal surface differing from the pipeline candidate
    /// ONLY by a leading capital is treated as an autocap artifact (keep
    /// pipeline casing) when the lowercase form is attested in a base
    /// lexicon at or above this calibrated z. Common vocabulary (fyrir
    /// +2.80, frábær +0.71) folds back to lowercase; rare-or-OOV surfaces
    /// (Miðeind: miðeind −2.49) keep their learned capitalization —
    /// genuine proper nouns survive because their lowercase reading is
    /// never headline vocabulary. BÍN validity deliberately does NOT count
    /// as attestation here: lemma-is.bin lowercases its keys, so it cannot
    /// distinguish Miðeind-the-name from miðeind-the-particle.
    public var personalCapArtifactMinZ: Double = -1.0

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

/// Per-context memo of the bigram-continuation proposal pool (wave 27,
/// Corrector pass 2f). The follower scan of a high-fan-out context word
/// ("en", "á", "i") walks and sorts thousands of bigram rows; the context
/// word is FIXED for every keystroke of the pending word, so one entry per
/// (lexicon slot, context) makes the steady-state cost a dictionary hit.
/// Reference type shared like the other stores; engine-queue confined, the
/// lock is cheap insurance for the eval harnesses.
final class ContinuationProposalCache {
    private var lock = NSLock()
    private var key: String?
    private var pools: [[(word: String, frequency: UInt32)]] = [[], []]

    /// Followers of `previous` in the lexicon at `slot` (0 = IS, 1 = EN),
    /// computed through `fetch` on a cache miss.
    func continuations(
        of previous: String, slot: Int,
        fetch: () -> [(word: String, frequency: UInt32)]
    ) -> [(word: String, frequency: UInt32)] {
        lock.lock()
        defer { lock.unlock() }
        if key != previous {
            key = previous
            pools = [[], []]
        }
        if pools[slot].isEmpty {
            pools[slot] = fetch()
            // Distinguish "fetched, empty" from "not fetched" with a
            // sentinel-free trick: an empty fetch stores a single empty
            // marker via key reset avoidance — simplest correct form is to
            // refetch empties; empty fan-outs are O(1) lookups anyway.
        }
        return pools[slot]
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
    /// Personal adaptive-touch holder (PLAN.md "Touch decoding", stage 2),
    /// shared by reference exactly like `personal` — inert (nil snapshot)
    /// unless the embedder injects one via `TypeEngine.setPersonalTouch`.
    let touch: TouchModelStore
    /// Compound decomposition engine + memo caches (wave 22), shared by
    /// reference like the stores above. Inert unless both morphology and
    /// an inflection model (paradigms) are present.
    let compounds = CompoundAnalyzer()
    /// Bigram-continuation proposal memo (wave 27, Corrector pass 2f),
    /// shared by reference like the stores above.
    let continuationProposals = ContinuationProposalCache()

    init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding?,
        config: EngineConfig,
        personal: PersonalStore = PersonalStore(),
        inflection: InflectionStore = InflectionStore(),
        touch: TouchModelStore = TouchModelStore()
    ) {
        self.icelandic = icelandic
        self.english = english
        self.morphology = morphology
        self.config = config
        self.personal = personal
        self.inflection = inflection
        self.touch = touch
        self.icelandicCalibration = LexiconCalibration.measure(icelandic, addK: config.addK)
        self.englishCalibration = LexiconCalibration.measure(english, addK: config.addK)
    }

    func lexicon(for language: Language) -> Lexicon {
        language == .icelandic ? icelandic : english
    }

    func calibration(for language: Language) -> LexiconCalibration {
        language == .icelandic ? icelandicCalibration : englishCalibration
    }

    /// Is the word attested anywhere (either frequency table, BÍN-valid, or
    /// a derived English possessive)?
    func isKnownAnywhere(_ word: String) -> Bool {
        icelandic.frequency(of: word) != nil
            || english.frequency(of: word) != nil
            || morphology?.isKnown(word) == true
            || derivedPossessiveBase(of: word) != nil
    }

    /// Derived English possessive (EN profile — see
    /// `EngineConfig.possessiveFrequencyFraction`): the base X of a word
    /// shaped "X's" (straight or typographic apostrophe) when X is itself
    /// attested in en.lex; nil otherwise. Makes "watson's"/"world's" real
    /// English vocabulary — valid when typed, scoreable as a fraction of
    /// the base noun — without enumerating possessives into the artifact.
    /// Possessives of possessives ("x's's") never derive (the base must be
    /// apostrophe-free), and the base must be a word, not a fragment
    /// (all letters, ≥ 2 characters).
    func derivedPossessiveBase(of word: String) -> String? {
        guard word.count >= 4 else { return nil }
        var chars = Array(word)
        guard chars.removeLast() == "s" else { return nil }
        guard let apostrophe = chars.last, Corrector.apostrophes.contains(apostrophe) else {
            return nil
        }
        chars.removeLast()
        guard chars.count >= 2, chars.allSatisfy(\.isLetter) else { return nil }
        // An s-ending base never derives: the possessive of an s-plural is
        // "s'" (a different shape), and deriving "communications's" would
        // hand every accidental double-s typo a junk possessive reading
        // that outprices the honest de-doubling repair.
        guard chars.last != "s" else { return nil }
        let base = String(chars)
        guard english.frequency(of: base) != nil else { return nil }
        return base
    }

    /// Valid personal vocabulary: learned, user-added or session-learned —
    /// suggestible and boosted in ranking. NOTE: since wave 26 validity no
    /// longer implies autocorrect protection — see `isPersonalProtected`.
    func isPersonalValid(_ word: String) -> Bool {
        personal.isValidWord(word)
    }

    // MARK: - Lazy-fold shadows (wave 26, session 2026-07-16T22-45-30)

    /// The word with every acute vowel folded to its base (á→a … ý→y);
    /// nil when the word contains no acute vowel. The candidate-side probe
    /// of the shadow relationship (grét → gret).
    func acuteFoldSkeleton(of word: String) -> String? {
        let folded = String(word.map { SpatialModel.accentBase[$0] ?? $0 })
        return folded != word ? folded : nil
    }

    /// The DOMINANT pure acute-restoration twin of `word` (lowercase
    /// pipeline form), or nil when no twin dominates. A twin differs from
    /// the word ONLY by restoring acute vowels (a→á … y→ý — the lane
    /// relaxation fold set, nothing broader: surface forms stay ground
    /// truth for every other relationship). Dominance is the three-part
    /// gate documented on `personalFoldShadowDominanceRatio` /
    /// `personalFoldShadowMinTwinZ`.
    func acuteFoldShadowTwin(of word: String) -> String? {
        let chars = Array(word)
        let positions = chars.indices.filter { SpatialModel.acuteOfBase[chars[$0]] != nil }
        // No foldable vowel = no twin; > 5 foldable positions (2^5 variants)
        // = conservatively no shadow (long many-vowel words are never the
        // þvi/eg/gret shape, and the veto must default to staying).
        guard !positions.isEmpty, positions.count <= 5 else { return nil }
        var best: (twin: String, frequency: UInt32)?
        for mask in 1..<(1 << positions.count) {
            var variant = chars
            for (bit, position) in positions.enumerated() where mask & (1 << bit) != 0 {
                variant[position] = SpatialModel.acuteOfBase[chars[position]]!
            }
            let twin = String(variant)
            guard let frequency = icelandic.frequency(of: twin) else { continue }
            if best == nil || frequency > best!.frequency {
                best = (twin, frequency)
            }
        }
        guard let best else { return nil }
        // Gate 1: is.lex dominance over the skeleton's own attestation
        // (absent skeletons use a denominator of 1 — any honestly attested
        // twin past the ratio dominates nothing).
        let ownIS = Double(icelandic.frequency(of: word) ?? 0)
        guard
            Double(best.frequency)
                >= config.personalFoldShadowDominanceRatio * max(ownIS, 1)
        else { return nil }
        // Gate 2: the twin is real vocabulary above the noise tier.
        let twinZ = calibratedUnigramScore(of: best.twin, language: .icelandic)
        guard twinZ >= config.personalFoldShadowMinTwinZ else { return nil }
        // Gate 3: the twin beats the skeleton's ENGLISH reading — an
        // EN-attested skeleton ("for", "bill") was plausibly committed as
        // English and keeps full personal protection.
        guard twinZ > calibratedUnigramScore(of: word, language: .english) else { return nil }
        return best.twin
    }

    /// Personal validity FOR THE AUTOCORRECT VETO (the conservatism
    /// invariant's personal component). Wave-26 narrowing (session
    /// 2026-07-16T22-45-30 "learning self-poisoning"): an IMPLICITLY
    /// learned word that is a pure acute-fold shadow of a dominant base
    /// word (þvi/því, eg/ég, gret/grét) is exactly the lazy input the
    /// restoration autocorrect exists to serve — learning it must not kill
    /// that restoration. Such shadows stay valid (suggestible, boosted)
    /// but no longer veto. EXPLICIT signals — dictionary-editor adds,
    /// verbatim-tap learns (including a verbatim tap rejecting this very
    /// restoration), import seeds — keep full veto power: the user
    /// literally pointed at the word.
    func isPersonalProtected(_ word: String) -> Bool {
        guard personal.isValidWord(word) else { return false }
        if personal.isExplicitWord(word) { return true }
        return acuteFoldShadowTwin(of: word) == nil
    }

    /// Autocap-artifact test (wave 26, bug 1): whether `lower` (a
    /// lowercase pipeline word) is common base vocabulary — attested in
    /// either frequency lexicon at or above `personalCapArtifactMinZ` — so
    /// a learned leading-cap surface of it carries no casing information
    /// (iOS autocapitalizes sentence starts). See the config doc for why
    /// BÍN validity does not count.
    func isCapArtifactBase(_ lower: String) -> Bool {
        calibratedUnigramScore(of: lower, language: .icelandic)
            >= config.personalCapArtifactMinZ
            || calibratedUnigramScore(of: lower, language: .english)
                >= config.personalCapArtifactMinZ
    }

    /// Deleted in the dictionary editor: never suggest, never predict.
    func isPersonalTombstoned(_ word: String) -> Bool {
        personal.isTombstoned(word)
    }

    /// Validity for the TYPED word (autocorrect conservatism): base-known,
    /// personal-PROTECTED, or tombstoned. Tombstoned words count as valid
    /// here on purpose — deleting a word means "stop suggesting it", never
    /// "start correcting it when I type it" (PLAN.md learning semantics).
    /// The personal component is `isPersonalProtected`, not raw validity:
    /// implicitly learned acute-fold shadows (þvi, eg, gret) do not veto
    /// the restoration autocorrect (wave 26 — see `isPersonalProtected`).
    func isValidTypedWord(_ word: String) -> Bool {
        isKnownAnywhere(word) || isPersonalProtected(word) || personal.isTombstoned(word)
    }

    /// The word's compound decomposition (wave 22 — Compounds.swift), or
    /// nil when it has none / the machinery is unavailable. Only
    /// meaningful for words that are NOT known anywhere — callers
    /// short-circuit on `isValidTypedWord` first.
    func compoundSplit(of word: String) -> CompoundSplit? {
        guard config.compoundValidityEnabled,
            let morphology,
            let paradigms = inflection.model?.paradigms
        else { return nil }
        return compounds.split(
            of: word, morphology: morphology, paradigms: paradigms, config: config)
    }

    /// Validity for the AUTOCORRECT VETO (the conservatism invariant):
    /// `isValidTypedWord` widened by productive compound acceptance. A
    /// typed OOV compound ("stökkleikanum") must never be auto-replaced
    /// by an error-class rewrite or a split — but it deliberately does
    /// NOT count as valid for the generation-pass gates (deep beam,
    /// space-miss splits still generate OFFERS for it) nor as lane
    /// evidence (same junk-collision stance as BÍN validity).
    func isProtectedTypedWord(_ word: String) -> Bool {
        isValidTypedWord(word) || compoundSplit(of: word) != nil
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
        } else if let skeleton = acuteFoldSkeleton(of: word),
            personal.isValidWord(skeleton),
            !personal.isTombstoned(skeleton),
            !personal.isExplicitWord(skeleton),
            !personal.isTombstoned(word),
            acuteFoldShadowTwin(of: skeleton) == word
        {
            // Lazy-fold shadow redirection (wave 26, session
            // 2026-07-16T22-45-30): the implicit skeleton's commits WERE
            // lazy typings of this restored twin (acute vowels are
            // long-press-only), so the personal evidence rides on the twin
            // at full strength — the boost the skeleton's counts would
            // have earned. This is what lets a habitual "gret" typist's
            // grét outrank corpus rivals the way their own usage says it
            // should, instead of the learned skeleton killing the
            // restoration outright.
            let count = Double(personal.count(of: skeleton))
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
    /// forms that are morphologically valid but absent from the table, and
    /// the derived-possessive frequency for English "X's" forms (max of the
    /// word's own attestation — possessives en.lex does carry are
    /// undercounted 10-400x — and the fraction-of-base derivation; see
    /// `EngineConfig.possessiveFrequencyFraction`).
    func effectiveFrequency(of word: String, language: Language) -> UInt32? {
        let attested = lexicon(for: language).frequency(of: word)
        if language == .english,
            let base = derivedPossessiveBase(of: word),
            let baseFrequency = english.frequency(of: base)
        {
            let derived = UInt32(
                min(
                    max(1, (Double(baseFrequency) * config.possessiveFrequencyFraction).rounded()),
                    Double(UInt32.max)
                ))
            return max(attested ?? 0, derived)
        }
        if let f = attested { return f }
        if language == .icelandic, morphology?.isKnown(word) == true {
            return config.binFloorFrequency
        }
        // Compound-valid words score like BÍN-valid ones (wave 22): the
        // BÍN floor is what lets a generated compound candidate
        // ("stökkleikanum") outrank raw junk while still never outranking
        // attested vocabulary. Checked LAST (memoized in the analyzer);
        // attested and BÍN-known words never reach it.
        // Compound-valid words score at the compound floor — STRICTLY
        // below the BÍN floor (wave 22): a whole word BÍN attests
        // ("skrásetta") is one confirmed morphological unit and must
        // outrank a merely-hypothesized decomposition ("skrá+detta") at
        // equal spatial cost, exactly as Miðeind's analyzer only
        // compounds after the whole-word lookup fails. (A head-frequency
        // lift was tried here and reverted: it walked cheap-edit junk
        // compounds over honest rare repairs on the dev corpus.) Checked
        // LAST (memoized in the analyzer); attested and BÍN-known words
        // never reach it.
        if language == .icelandic, compoundSplit(of: word) != nil {
            return config.compoundFloorFrequency
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

    /// Effective BIGRAM context word (wave 27 — see
    /// `EngineConfig.bigramContextFoldBackoffEnabled`): the previous word
    /// itself when attested in either frequency lexicon; otherwise its
    /// dominant acute-fold twin when one exists (eg → ég — the lazy
    /// skeleton is a spelling of the twin, so the twin IS the context);
    /// otherwise the previous word unchanged (junk context stays junk —
    /// bigram lookups simply miss). Computed once per correct() call, not
    /// per candidate.
    func effectiveBigramContext(of previous: String?) -> String? {
        guard let previous else { return nil }
        if icelandic.frequency(of: previous) != nil || english.frequency(of: previous) != nil {
            return previous
        }
        return acuteFoldShadowTwin(of: previous) ?? previous
    }

    /// Contextual typicality LIFT of `word` after `previous` in language L:
    /// z_L(word | previous) − z_L(word), in calibrated σ — positive iff the
    /// attested bigram moves the word above its own unigram typicality
    /// (≈ positive PMI: the context selects the word). nil when the
    /// (previous, word) bigram is unattested in L — an unseen pair is NO
    /// evidence, never negative evidence.
    func contextualLift(of word: String, previous: String?, language: Language) -> Double? {
        guard let previous,
            lexicon(for: language).frequency(of: previous) != nil,
            lexicon(for: language).bigramFrequency(previous, word) != nil
        else { return nil }
        return calibratedScore(of: word, previous: previous, language: language)
            - calibratedUnigramScore(of: word, language: language)
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
