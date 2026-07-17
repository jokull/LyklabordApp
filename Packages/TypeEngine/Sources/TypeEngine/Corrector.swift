import Foundation
import Lexicon

/// One ranked suggestion.
public struct Suggestion: Equatable, Sendable {
    public let text: String
    /// True only on the top candidate, and only when the conservatism rules
    /// allow auto-replacement (typed word unknown everywhere + confidence
    /// margin met). A valid typed word NEVER yields isAutocorrect = true —
    /// with ONE sanctioned, lane-gated exception: single-letter accent
    /// restoration (a→á, i→í), where the bare letter may be valid in the
    /// OTHER language ("a" in English) but is not a word in the confident
    /// Icelandic lane (see `Corrector.singleLetterCorrection`).
    public let isAutocorrect: Bool
    /// Softmax posterior over the scored candidate pool, in (0, 1].
    public let confidence: Double
    /// True for the verbatim escape-hatch slot: the literal token the user
    /// typed, offered so it can be committed as-is (rendered quoted by the
    /// keyboard toolbar via KeyboardKit's `.unknown` suggestion type).
    /// Emitted by `TypingSession`, never by the corrector/predictor.
    public let isVerbatim: Bool
    /// RESTORATION-class candidate (PLAN.md "Lane relaxation profiles"):
    /// every edit between the typed token and this text is restoration —
    /// acute-vowel folds (a→á …), directional orthographic confusions
    /// (d→ð, t→þ, o→ö), apostrophe insertions (dont→don't), or the lone
    /// i→I capitalization. Distinct from error-class corrections for
    /// margins, eval bucketing and UI affordances; `TypingSession` drops
    /// restoration suggestions entirely in URL/email/webSearch/secure
    /// fields.
    public let isRestoration: Bool

    public init(
        text: String,
        isAutocorrect: Bool,
        confidence: Double,
        isVerbatim: Bool = false,
        isRestoration: Bool = false
    ) {
        self.text = text
        self.isAutocorrect = isAutocorrect
        self.confidence = confidence
        self.isVerbatim = isVerbatim
        self.isRestoration = isRestoration
    }
}

/// Result of correcting a single typed word.
public struct CorrectionResult {
    public let suggestions: [Suggestion]
    /// True when the typed word exists in either lexicon, is BÍN-valid, or
    /// is an accepted productive compound (wave 22). When true, suggestions
    /// are alternatives only (never autocorrect).
    public let typedWordIsValid: Bool
}

/// Noisy-channel corrector: spatial likelihood × blended language prior.
public struct Corrector {
    /// Candidate-generation alphabet: base latin + Icelandic letters +
    /// long-press accents + apostrophes (word-internal characters for
    /// contractions: "don't", "I'm"; both the straight and typographic
    /// forms iOS produces).
    static let alphabet: [Character] = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö'’")

    /// Word-internal apostrophe characters (straight + typographic).
    static let apostrophes: Set<Character> = ["'", "’"]

    let spatial: SpatialModel
    let model: BlendedLanguageModel
    let config: EngineConfig
    let beam: BeamDecoder
    /// Per-position substitution costs for the beam decoder. Static
    /// keyboard geometry today; the coordinate-plumbing wave swaps in a
    /// per-tap provider without touching the decoder (see
    /// `PositionCostProvider`).
    let positionCosts: PositionCostProvider

    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.init(
            model: BlendedLanguageModel(
                icelandic: icelandic,
                english: english,
                morphology: morphology,
                config: config
            ),
            config: config
        )
    }

    init(model: BlendedLanguageModel, config: EngineConfig) {
        self.config = config
        let spatial = SpatialModel(costs: config.spatialCosts)
        self.spatial = spatial
        self.model = model
        self.beam = BeamDecoder(config: config, spatial: spatial)
        self.positionCosts = StaticSpatialCostProvider(spatial: spatial)
    }

    /// Ranked correction candidates for `typed` (assumed a single word).
    ///
    /// - Parameters:
    ///   - typed: the word as typed (will be lowercased internally)
    ///   - previousWord: last committed word, for bigram context (lowercased)
    ///   - pIcelandic: current language posterior P(IS)
    ///   - limit: max suggestions returned
    ///   - deliberateCharacters: characters of the pending word entered via
    ///     an explicit long-press/callout act (fed by the embedder through
    ///     `TypingSession.noteLongPressInsertion`). Any such character is
    ///     the strongest deliberateness signal (PLAN.md triple gate, part
    ///     3a): lane relaxation is vetoed for the whole word, restoration
    ///     never auto-applies past the valid-word rule, and no candidate
    ///     that drops one of these characters may auto-apply (a
    ///     long-pressed accent is never folded away).
    ///   - taps: per-position touch samples aligned with `typed` (PLAN.md
    ///     "Touch decoding", stage 1; fed through `TypingSession.noteTap`).
    ///     When any position carries a tap, substitutions are priced from
    ///     the ACTUAL tap point (`PerTapCostProvider`) in both the beam
    ///     search and the exact DP re-score, the space-substitution split
    ///     penalty scales with the consumed tap's distance to the spacebar
    ///     edge, and the word's aggregate tap confidence RAISES (never
    ///     lowers) the autocorrect margins — the bidirectional evidence
    ///     principle's veto half. Empty/mismatched taps run the static
    ///     provider, byte-identically to the pre-coordinate engine. The
    ///     targeted generation passes (`edits1Costed` costs, split-half
    ///     repairs) stay static-priced: they only PROPOSE candidates, and
    ///     every admitted candidate is re-scored by the per-tap DP.
    /// - Parameter capitalizedMidSentence: the typed token starts with an
    ///   uppercase letter in the middle of a sentence (the embedder/facade
    ///   computes this from the raw context) — the proper-noun signal that
    ///   suppresses ERROR-class auto-apply when `properNounGuardEnabled`
    ///   (restoration-only winners and bar suggestions are unaffected).
    public func correct(
        typed rawTyped: String,
        previousWord: String? = nil,
        pIcelandic: Double = 0.5,
        limit: Int = 3,
        deliberateCharacters: [Character] = [],
        taps: [TapSample?] = [],
        capitalizedMidSentence: Bool = false,
        trace: CorrectionTrace? = nil
    ) -> CorrectionResult {
        let typed = rawTyped.lowercased()
        let typedChars = Array(typed)
        if let trace {
            trace.typed = typed
            trace.previousWord = previousWord
            trace.pIcelandic = pIcelandic
        }
        guard !typedChars.isEmpty, limit > 0 else {
            return CorrectionResult(suggestions: [], typedWordIsValid: false)
        }
        let deliberate = deliberateCharacters.map { Character($0.lowercased()) }
        // Lane-relaxation pricing for this call (PLAN.md "Lane relaxation
        // profiles"); a long-pressed character anywhere in the word vetoes
        // the relaxation outright.
        let pricing = FoldPricing(
            config: config, pIcelandic: pIcelandic, vetoRelaxation: !deliberate.isEmpty)

        // Coordinate evidence (PLAN.md "Touch decoding"): swap in the
        // per-tap provider when aligned samples exist; otherwise the static
        // provider (identical to the pre-coordinate engine).
        let perTap: PerTapCostProvider? =
            taps.count == typedChars.count && taps.contains(where: { $0 != nil })
            ? PerTapCostProvider(
                taps: taps, spatial: spatial, config: config,
                personalTouch: model.touch.snapshot)
            : nil

        // Hyphenated compound rule (PLAN.md "Compounds" + harness quirk
        // list): a token containing hyphens whose parts are each valid is
        // itself valid — never corrected, never walked through the edits2
        // landmine ("vel-þekkt" must not be rewritten to "velþekkt").
        if isValidHyphenatedCompound(typed) {
            return CorrectionResult(suggestions: [], typedWordIsValid: true)
        }

        // Personal-learning semantics fold in here (PLAN.md "Learning"):
        // learned/user-added words are valid (never auto-corrected away) —
        // and so are TOMBSTONED words, because deletion means "stop
        // suggesting", never "punish typing" (isValidTypedWord docs).
        let typedIsValid = model.isValidTypedWord(typed)
        // Compound acceptance (wave 22): an OOV token decomposable as
        // modifier(s)+BÍN-head is autocorrect-PROTECTED like a valid word,
        // but stays "invalid" for the generation-pass gates — every
        // suggestion pass below runs for it exactly as before, only the
        // auto-apply branches see the widened validity. Lazily computed:
        // valid words never pay for decomposition.
        let typedCompoundSplit = typedIsValid ? nil : model.compoundSplit(of: typed)
        let typedIsProtected = typedIsValid || typedCompoundSplit != nil
        trace?.typedIsValid = typedIsValid
        if let split = typedCompoundSplit {
            trace?.note(
                "typed decomposes as compound "
                    + (split.modifiers + [split.head]).joined(separator: "+")
                    + " -> autocorrect-protected (offers only)")
        }

        // Single-letter input: the general pipeline is both too expensive
        // (1-char completion ranges) and too noisy for one letter — the only
        // useful correction is accent restoration (dogfood "giskar a allt":
        // a→á, i→í are extreme-frequency Icelandic words typed accentless
        // because accents live behind long-press). Dedicated targeted path.
        if typedChars.count == 1 {
            trace?.rule = "single-letter"
            return singleLetterCorrection(
                letter: typedChars[0],
                previousWord: previousWord,
                pIcelandic: pIcelandic,
                typedIsValid: typedIsValid,
                trace: trace
            )
        }

        // Inflection backoff context (PLAN.md "Inflection intelligence"
        // Stage B #1): non-nil when the previous word is a known Icelandic
        // case governor (mass + lane gates in InflectionStore.governorFit).
        // Candidates that are strict-prefix COMPLETIONS of the typed word
        // additionally earn λ_morph·log(P(case|governor)/uniform) at
        // scoring — but ONLY when the exact (governor, candidate) bigram is
        // NOT attested in is.lex: attested bigram evidence already carries
        // the case signal at corpus strength through the contextual score
        // and must keep dominating; the morph term is the backoff for
        // unseen noun-governor pairs. Computed up front because the
        // completions pass below also widens its pool under a governor.
        let governorFit = model.inflection.governorFit(
            previousWord: previousWord,
            pIcelandic: pIcelandic,
            morphology: model.morphology,
            config: config
        )

        // ---- Candidate generation ----------------------------------------
        // word -> lane-priced channel cost (total + restoration/error split)
        var candidates: [String: ChannelCost] = [:]

        func admit(_ word: String) {
            guard word != typed, candidates[word] == nil else { return }
            // Tombstoned words are never offered, base-lexicon presence
            // notwithstanding (every generation pass funnels through here).
            guard !model.isPersonalTombstoned(word) else { return }
            candidates[word] = channelCost(
                typedChars: typedChars, candidate: word, pricing: pricing, perTap: perTap)
        }

        // 1. PRIMARY: beam-search spatial decode over both frequency
        // lexicons (replaced the edits1+edits2 generate-and-test walks —
        // see BeamDecoder). The beam only visits prefixes the lexicons
        // contain, so multi-position adjacent-key noise ("koetip" →
        // "kortið") is reachable inside the latency budget. Beam cost is a
        // search currency only; admit() re-scores every candidate with the
        // exact spatial DP, so ranking is identical to the old pipeline's
        // for words both would find.
        //
        // Two phases, mirroring the old edits1 → gated-edits2 shape: the
        // single-edit decode always runs (cheap — a few hundred
        // expansions); the DEEP multi-edit decode (step 5) runs only when
        // the cheap passes and completions leave no good close candidate,
        // so words-in-progress (which always have a cheap completion)
        // never pay for it on every keystroke.
        var beamCoveredLexicons = true
        // The beam prices substitutions per position through the provider
        // seam — the per-tap provider when coordinate evidence exists.
        let beamCosts: PositionCostProvider = perTap ?? self.positionCosts
        func runBeam(maxEdits: Int) {
            for (index, lexicon) in [model.icelandic, model.english].enumerated() {
                guard let searchable = lexicon as? PrefixSearchableLexicon else {
                    beamCoveredLexicons = false
                    continue
                }
                for (word, _) in beam.decode(
                    typed: typedChars,
                    lexicon: searchable,
                    lexiconIndex: index,
                    costs: beamCosts,
                    pricing: pricing,
                    maxEdits: maxEdits
                ) {
                    admit(word)
                }
            }
        }
        runBeam(maxEdits: config.beamShortMaxEdits)

        // 1b. edits1 residue: single-edit candidates the beam cannot see —
        // personal vocabulary and BÍN-only forms (rare valid inflections
        // absent from the frequency tables) live outside the sorted pools.
        // When a lexicon doesn't support prefix search (exotic conformers
        // only; every in-repo lexicon does), this also restores the full
        // legacy edits1 existence check.
        for word in Self.edits1Costed(of: typedChars, spatial: spatial).keys {
            guard candidates[word] == nil else { continue }
            if model.isPersonalValid(word)
                || model.morphology?.isKnown(word) == true
                || (!beamCoveredLexicons && isCandidateWord(word, checkMorphology: false))
            {
                admit(word)
            }
        }

        // 2. Diacritic/orthographic restoration: all combinations of the
        // cheap Icelandic confusions (a→á, o→ó/ö, d→ð, t→þ, …) up to 3
        // positions, existence-checked. Targeted and tiny compared to
        // edits2, and exactly the accent-restoration case that matters on
        // this layout ("islenska"→"íslenska", "godan"→"góðan"): each
        // substitution costs only the spatial floor / orthographic-confusion
        // constant, so restored forms rank (and auto-apply) easily.
        for word in Self.diacriticVariants(of: typedChars)
        where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2b. Gemination repairs: drop one of a doubled letter and/or double
        // another ("tommorow"→"tomorrow", "occured"→"occurred"; Icelandic
        // kk/ll/nn/tt geminates). These are the classic distance-2 typos a
        // budgeted edits2 walk can no longer be relied on to reach; the
        // variant set is tiny (≈ n² worst case) and existence-checked.
        for word in Self.geminationVariants(of: typedChars)
        where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2c. Gemination + accent compositions ("nogg" → dedouble → "nog" →
        // o→ó → "nóg"; "huss" → "hús"): the classic Icelandic double-error
        // shape neither targeted pass reaches alone. Tiny: dedoubled bases
        // (≤ #doubled pairs) × their diacritic variants, existence-checked.
        for base in Self.dedoubledVariants(of: typedChars) {
            for word in Self.diacriticVariants(of: base, maxChanges: 2)
            where isCandidateWord(word, checkMorphology: true) {
                admit(word)
            }
        }

        // 2e. Short double-substitution repairs (live-session "habb" →
        // "hann", 2026-07-16; the same structural cap behind the known
        // ik → ok weakness): a 3-4 char unknown token was limited to ONE
        // beam edit (the deep multi-edit decode gates on length ≥
        // beamLongMinLength, and its no-close-attested gate is anyway held
        // shut by wrong-but-close 1-sub rivals like "gabb"), so double
        // adjacent-key noise could never reach the target no matter how
        // frequent. Enumerate the tiny cheap-neighbor space (both subs ≤
        // `shortDoubleSubMaxEditCost`, ≈ adjacent keys only) and admit only
        // HIGH-TYPICALITY attested words (`shortDoubleSubMinZ`): "hann"
        // (+2.7) qualifies, junk neighbors of junk do not. Margins and the
        // ordinary conservatism rules judge auto-apply as usual; attested
        // typed words never enter (typedIsValid gate).
        if !typedIsValid,
            typedChars.count >= 3,
            typedChars.count < config.beamLongMinLength,
            typedChars.allSatisfy(\.isLetter)
        {
            let n = typedChars.count
            // Cheap neighbor sets per position (adjacent-key tier).
            var cheap: [[Character]] = []
            cheap.reserveCapacity(n)
            for ch in typedChars {
                cheap.append(
                    Self.alphabet.filter {
                        $0 != ch
                            && spatial.substitutionCost(typed: ch, intended: $0)
                                <= config.shortDoubleSubMaxEditCost
                    })
            }
            var variant = typedChars
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    for ci in cheap[i] {
                        variant[i] = ci
                        for cj in cheap[j] {
                            variant[j] = cj
                            let word = String(variant)
                            guard candidates[word] == nil else { continue }
                            let typical =
                                model.isPersonalValid(word)
                                || (model.icelandic.frequency(of: word) != nil
                                    && model.calibratedUnigramScore(of: word, language: .icelandic)
                                        >= config.shortDoubleSubMinZ)
                                || (model.english.frequency(of: word) != nil
                                    && model.calibratedUnigramScore(of: word, language: .english)
                                        >= config.shortDoubleSubMinZ)
                            // Context-vouched tier (Jökull's real
                            // "hega"→"geta" miss: geta z +1.75 sits under
                            // the headline bar, but "að geta" is one of
                            // the strongest bigrams in the language).
                            // Borderline-typicality candidates are
                            // admitted when the EXACT bigram with the
                            // previous word is attested — junk neighbors
                            // essentially never are, so this stays
                            // precise where blanket z-lowering measurably
                            // regressed the corpus.
                            let contextTypical =
                                !typical
                                && previousWord.map { prev in
                                    (model.icelandic.bigramFrequency(prev, word) != nil
                                        && model.calibratedUnigramScore(of: word, language: .icelandic)
                                            >= config.shortDoubleSubContextMinZ)
                                        || (model.english.bigramFrequency(prev, word) != nil
                                            && model.calibratedUnigramScore(of: word, language: .english)
                                                >= config.shortDoubleSubContextMinZ)
                                } ?? false
                            if typical || contextTypical { admit(word) }
                        }
                        variant[j] = typedChars[j]
                    }
                    variant[i] = typedChars[i]
                }
            }
        }

        // 2d. Possessive apostrophe restoration (EN profile; the
        // contraction_damage diagnosis): a token ending in s whose stem is
        // attested English vocabulary may be the possessive stem+'s typed
        // without the apostrophe — "childrens" → "children's", "watsons" →
        // "watson's". The candidate is scored through the derived-possessive
        // seam (`BlendedLanguageModel.derivedPossessiveBase`), so it ranks
        // as a fraction of the stem's own frequency. Two conservatism
        // shapes, per the sacred valid-word rule:
        //  * UNATTESTED skeleton ("childrens" is no word anywhere): full
        //    restoration semantics — may auto-apply through the ordinary
        //    unknown-token margins (apostrophe insertion is restoration
        //    class, so the relaxed margin applies inside an EN lane).
        //  * VALID typed word ("leagues", "cats"): OFFER-ONLY, and only
        //    when the stem is genuinely common (possessiveOfferMinBaseZ) —
        //    auto-apply past the valid-word rule is structurally impossible
        //    for a derived possessive (the skeleton-collision triple gate
        //    demands en.lex attestation of the candidate, which a DERIVED
        //    possessive by definition lacks), so "cats" can never become
        //    "cat's" uninvited.
        // Lane-gated like the accent-offer mirror: no possessive offers in
        // a confidently Icelandic lane.
        if config.foldProfileENEnabled,
            1 - pIcelandic >= config.accentOfferMinPosterior,
            typedChars.count >= 4,
            typedChars.last == "s",
            !typedChars.contains(where: { Self.apostrophes.contains($0) }),
            typedChars.allSatisfy(\.isLetter)
        {
            let candidate = String(typedChars.dropLast()) + "'s"
            // derivedPossessiveBase is the single authority on the shape
            // (attested apostrophe-free stem, ≥ 2 letters, not s-ending).
            if let stem = model.derivedPossessiveBase(of: candidate),
                !typedIsValid
                    || model.calibratedUnigramScore(of: stem, language: .english)
                        >= config.possessiveOfferMinBaseZ
            {
                admit(candidate)
            }
        }

        // 3. Prefix completions of the typed word (completion-as-suggestion).
        // Under a governor context the pool WIDENS
        // (morphCompletionPoolLimit): the governed oblique form is often
        // simply absent from the frequency-ranked top-8 — the backoff can
        // only reorder what is pooled.
        let completionLimit =
            governorFit != nil
            ? max(config.completionPoolLimit, config.morphCompletionPoolLimit)
            : config.completionPoolLimit
        for lexicon in [model.icelandic, model.english] {
            for completion in lexicon.completions(of: typed, limit: completionLimit) {
                admit(completion.word)
            }
        }

        // 3b. Personal-vocabulary completions: learned/user-added words are
        // always suggestible, including OOV ones the base pools can never
        // produce ("veitingahusid" typed as "veitingahusi" must complete).
        for completion in model.personal.completions(
            of: typed, limit: config.personalCompletionPoolLimit)
        {
            admit(completion.word)
        }

        // 4. Completions of slightly shorter prefixes — but only when no
        // good close candidate exists yet: covers suffix-area typos that
        // neither the beam's bounded edits nor typed-prefix completions
        // reach cheaply ("basicly"→"basically", "publically"→"publicly").
        // Spatial cost still judges the candidates, so junk from the wider
        // buckets ranks on merit.
        if typedChars.count >= 5,
            (candidates.values.map(\.total).min() ?? .infinity) > config.closeCandidateGate
        {
            let shortestPrefix = max(3, typedChars.count - 4)
            for length in stride(from: typedChars.count - 1, through: shortestPrefix, by: -1) {
                let prefix = String(typedChars.prefix(length))
                for lexicon in [model.icelandic, model.english] {
                    for completion in lexicon.completions(of: prefix, limit: config.completionPoolLimit) {
                        admit(completion.word)
                    }
                }
                for completion in model.personal.completions(
                    of: prefix, limit: config.personalCompletionPoolLimit)
                {
                    admit(completion.word)
                }
            }
        }

        // 4b. Diacritic-restored prefix completions (dogfood "faralega" →
        // "fáránlega"): missing accents in the PREFIX combined with an
        // ordinary omission/typo in the tail are unreachable by every pass
        // above (3 edits from the typed word). Completing diacritic
        // variants of typed prefixes ("fárá" → fáránlega…) covers exactly
        // that shape. Icelandic-only (accents are the IS phenomenon), and
        // gated like every fallback pass — but on the best ATTESTED-or-personal
        // candidate, so BÍN-floored junk ("garalega") cannot suppress the
        // honest repair it is junk relative to.
        if !typedIsValid, typedChars.count >= 5,
            bestAttestedCost(in: candidates) > config.diacriticCompletionGate
        {
            // Shortest prefix first: it has the fewest variants and the
            // widest completion range, and the tail typo is more likely to
            // sit several characters back ("fara|lega" needs the length-4
            // prefix) — longest-first would burn the budget on
            // near-full-length variants that pass 2 mostly covered.
            var budget = config.diacriticCompletionMaxLookups
            let shortestPrefix = max(3, typedChars.count - 4)
            outer: for length in stride(from: shortestPrefix, through: typedChars.count, by: 1) {
                let prefix = Array(typedChars.prefix(length))
                for variant in Self.diacriticVariants(of: prefix, maxChanges: 2) {
                    guard budget > 0 else { break outer }
                    budget -= 1
                    for completion in model.icelandic.completions(
                        of: variant, limit: config.completionPoolLimit)
                    {
                        admit(completion.word)
                    }
                }
            }
        }

        // 5. DEEP beam decode (multi-edit; replaced the generate-and-test
        // edits2 walk): only for unknown tokens of length >=
        // beamLongMinLength with no good close ATTESTED hit from the cheap
        // passes — the same gate shape the old edits2 used, so a
        // word-in-progress (which always has a cheap completion) never
        // pays for the wide search on every keystroke. This is where
        // multi-position adjacent-key noise gets decoded ("koetip" →
        // "kortið", two 1-nat substitutions; triple-noise up to
        // beamMaxEdits). See `beamDeepGate` for why the gate sits below
        // the indel constant and ignores BÍN-only candidates.
        if !typedIsValid,
            typedChars.count >= config.beamLongMinLength,
            config.beamMaxEdits > config.beamShortMaxEdits,
            bestAttestedCost(in: candidates) > config.beamDeepGate
        {
            runBeam(maxEdits: config.beamMaxEdits)
        }

        // Captured BEFORE the compound pass on purpose: compound candidates
        // are cheap unattested readings ("frá"+completion) that must not
        // hold the space-miss split gate shut — split suggestions compete
        // with them on merit instead.
        let bestSoFar = candidates.values.map(\.total).min() ?? .infinity

        // 5b. Compound-head repairs + compound completions (wave 22, the
        // dogfood "stökklrikanum" → "stökkleikanum" class — PLAN.md
        // "Compounds"): an unknown all-letter token with a legal compound-
        // modifier PREFIX may be a productive compound with the typo in the
        // head. Hold the modifier fixed and admit (a) single-edit repairs
        // of the head region and (b) lexicon completions of it, each
        // validated as a legal compound head (BÍN open-class or bound
        // suffix form). Candidates rank through the normal pipeline —
        // spatial DP prices the full word, the language score sits at the
        // BÍN floor (see effectiveFrequency) — and, being unattested, they
        // can never auto-apply (attested-winner rule). Gated like the deep
        // passes: never fires while a close attested repair exists.
        if config.compoundRepairEnabled, !typedIsValid,
            typedChars.count >= config.compoundRepairMinLength,
            typedChars.count <= config.compoundMaxWordLength,
            typedChars.allSatisfy(\.isLetter),
            let morphology = model.morphology,
            let paradigms = model.inflection.model?.paradigms,
            bestAttestedCost(in: candidates) > config.compoundRepairGate
        {
            let minModifier = config.compoundMinModifierLength
            let minHead = config.compoundMinHeadLength
            let n = typedChars.count
            var lookupBudget = config.compoundRepairMaxLookups
            var modifiersTried = 0
            // GENERATED heads are held to a stricter bar than validity:
            // bound suffix forms, or BÍN open-class AND is.lex-attested at
            // decent typicality (compoundHeadMinZ). BÍN-only and junk-tier
            // heads ("lefa", "legan", "legs") sit one edit from everything —
            // hypothesizing them floods the bar and displaces honest
            // repairs (the core "faralega offers fáránlega" regression).
            // Protection (validity) keeps the wider BÍN-only head rule:
            // under-correcting a typed word is safe, suggesting junk is not.
            func generatedHeadOK(_ headWord: String) -> Bool {
                guard
                    model.compounds.isHead(
                        headWord, morphology: morphology, minLength: minHead)
                else { return false }
                if CompoundAnalyzer.boundHeadForms.contains(headWord) { return true }
                return model.icelandic.frequency(of: headWord) != nil
                    && model.calibratedUnigramScore(of: headWord, language: .icelandic)
                        >= config.compoundHeadMinZ
            }
            // Longest legal modifier prefix first: the typo is more often
            // deep in the head than at the seam, and a longer fixed
            // modifier means a shorter, cheaper head repair.
            var splitPoint = n - 2
            while splitPoint >= minModifier, modifiersTried < config.compoundRepairMaxModifiers {
                defer { splitPoint -= 1 }
                let modifier = String(typedChars[..<splitPoint])
                guard
                    model.compounds.isModifier(
                        modifier, paradigms: paradigms, minLength: minModifier)
                else { continue }
                modifiersTried += 1
                let headRegion = Array(typedChars[splitPoint...])
                // (a) Single-edit head repairs. Runs even when the typed
                // word has a compound reading of its own: a typo can
                // decompose by accident ("kaffispjalið" = kaffis+pjalið),
                // and the honest repair ("kaffi"+"spjallið") must still be
                // OFFERED — protection only vetoes auto-apply.
                if headRegion.count >= minHead {
                    // Direct edits1 enumeration (no dict, no sort — the
                    // generation order is deterministic and roughly
                    // plausibility-ranked by edit class: deletions,
                    // transpositions, substitutions, insertions).
                    var headVariants: [[Character]] = []
                    headVariants.reserveCapacity(
                        headRegion.count * 2 * (Self.alphabet.count + 1))
                    for i in 0..<headRegion.count {
                        var copy = headRegion
                        copy.remove(at: i)
                        headVariants.append(copy)
                    }
                    for i in 0..<(headRegion.count - 1)
                    where headRegion[i] != headRegion[i + 1] {
                        var copy = headRegion
                        copy.swapAt(i, i + 1)
                        headVariants.append(copy)
                    }
                    for i in 0..<headRegion.count {
                        // Restoration-pair substitutions (o→ö, a→á, d→ð)
                        // are deliberately excluded: they price at the
                        // lane-relaxed fold cost, and a fold-cheap junk
                        // compound ("prentletu" → prent+létu) walks over
                        // honest error-class repairs. Compound repair is
                        // an ERROR-class hypothesis by design; accent
                        // restoration stays with the restoration passes.
                        for ch in Self.alphabet
                        where ch != headRegion[i] && ch.isLetter
                            && !Self.isRestorationPair(headRegion[i], ch)
                        {
                            var copy = headRegion
                            copy[i] = ch
                            headVariants.append(copy)
                        }
                    }
                    for i in 0...headRegion.count {
                        for ch in Self.alphabet where ch.isLetter {
                            var copy = headRegion
                            copy.insert(ch, at: i)
                            headVariants.append(copy)
                        }
                    }
                    for variant in headVariants {
                        guard lookupBudget > 0 else { break }
                        guard variant.count >= minHead else { continue }
                        let headWord = String(variant)
                        let candidateWord = modifier + headWord
                        guard candidates[candidateWord] == nil, candidateWord != typed
                        else { continue }
                        // Strict-prefix EXTENSIONS of the typed word take
                        // the completion shortcut in channelCost (0.5/char)
                        // — a speculative compound extension at that price
                        // structurally dominates honest space-miss splits
                        // ("fimmtabókin" must keep offering "fimmta
                        // bókin", not "fimmtabókina"). Extensions are the
                        // completion pass's business (see
                        // compoundCompletionEnabled), not the repair's.
                        guard
                            !(candidateWord.count > typed.count
                                && candidateWord.hasPrefix(typed))
                        else { continue }
                        lookupBudget -= 1
                        if generatedHeadOK(headWord) {
                            admit(candidateWord)
                        }
                    }
                }
                // (b) Compound continuations ("stökklei|" → stökk+leikur):
                // is.lex completions of the head region, head-validated.
                // Icelandic-only — compounding is the IS phenomenon.
                if config.compoundCompletionEnabled, headRegion.count >= 2 {
                    for completion in model.icelandic.completions(
                        of: String(headRegion), limit: config.completionPoolLimit)
                    {
                        guard lookupBudget > 0 else { break }
                        lookupBudget -= 1
                        if generatedHeadOK(completion.word) {
                            admit(modifier + completion.word)
                        }
                    }
                }
            }
        }

        // ---- Scoring ------------------------------------------------------
        // score = -channelCost + λ·S_lang(candidate | context, posterior),
        // where S_lang blends per-lexicon CALIBRATED scores by the posterior
        // (see BlendedLanguageModel.blendedScore). The channel cost is the
        // lane-priced total, so restoration-class edits cost ~ε inside a
        // saturated lane while error-class edits keep their full prices.
        //
        var scored: [(word: String, cost: ChannelCost, score: Double)] = candidates.map {
            word, cost in
            let s = model.blendedScore(of: word, previous: previousWord, pIcelandic: pIcelandic)
            var score = -cost.total + config.languageWeight * s
            // The morph term applies to strict-prefix COMPLETIONS of the
            // typed word only (the Stage-B #1 shape: "typed frá hest| →
            // candidate forms get + λ_morph·log P(features | governor)").
            // Error-class repairs stay pure noisy-channel: boosting them by
            // case fit lifts right-case junk ("á rit|" pulling "rut" above
            // honest completions) without any grammatical justification —
            // the typed keys, not the governor, are the evidence there.
            if let fit = governorFit,
                word.hasPrefix(typed),
                model.icelandic.bigramFrequency(fit.previousWord, word) == nil
            {
                score += fit.fitNats(for: word)
            }
            return (word, cost, score)
        }

        // 6. Space-miss splits (PLAN.md "Space-miss correction"): an unknown
        // all-letter token with no good single-word candidate may be two
        // words around a missed/mis-hit spacebar tap. Gated on the beam +
        // cheap passes' best spatial cost being above the gate, so ordinary
        // typos and prefixes-in-progress (which always have a cheap
        // completion) never pay for it — and a genuine multi-substitution
        // repair the beam found (koetip → kortið at ~2 nats) suppresses the
        // split pass outright. Split candidates join the same
        // scored pool: the channel cost (penalty + half repairs) plays the
        // spatial-cost role in ranking, conservatism and confidence.
        if !typedIsValid,
            typedChars.count >= config.splitMinLength,
            typedChars.allSatisfy(\.isLetter),
            bestSoFar > config.splitGate
        {
            let rawChars = Array(rawTyped)
            scored.append(
                contentsOf: splitCandidates(
                    typedChars: typedChars,
                    previousWord: previousWord,
                    pIcelandic: pIcelandic,
                    taps: taps.count == typedChars.count ? taps : [],
                    rawChars: rawChars.count == typedChars.count ? rawChars : []
                ).map {
                    // Splits are error-class rewrites by definition (a
                    // missed keystroke, never restoration).
                    (
                        word: $0.word,
                        cost: ChannelCost(total: $0.spatialCost, errorOps: 1, restorationOps: 0),
                        score: $0.score
                    )
                }
            )
        }

        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }

        if let trace {
            // Language contribution backed out of the final score (covers
            // split candidates' pair scores and the morph term uniformly):
            // score = -cost + languageWeight·S  =>  S = (score+cost)/weight.
            trace.candidates = scored.prefix(8).map { entry in
                CorrectionTrace.Candidate(
                    word: entry.word,
                    costTotal: entry.cost.total,
                    errorOps: entry.cost.errorOps,
                    restorationOps: entry.cost.restorationOps,
                    languageScore: config.languageWeight != 0
                        ? (entry.score + entry.cost.total) / config.languageWeight
                        : 0,
                    score: entry.score
                )
            }
        }

        // ---- Conservatism / autocorrect decision --------------------------
        // Every auto-apply margin below is multiplied by `tapMarginFactor`
        // (≥ 1): the aggregate-confidence VETO of the bidirectional
        // evidence principle (see `tapVetoFactor`). An all-dead-center word
        // demands ~4× today's evidence; a tapless or sloppy word keeps
        // today's margins exactly.
        var autocorrect = false
        if let best = scored.first {
            // Preconditions of every auto-apply rule; computed individually
            // (all pure) so the trace can report which one blocked. The
            // `preconditionsOK` conjunction reproduces the original guard.
            let lengthOK = typedChars.count >= config.minAutocorrectLength
            let costOK = best.cost.total <= config.autocorrectMaxSpatialCost
            let apostrophesOK = Self.preservesApostrophes(of: typed, in: best.word)
            let deliberateOK = Self.preservesDeliberateCharacters(
                deliberate, of: typedChars, in: best.word)
            let preconditionsOK = lengthOK && costOK && apostrophesOK && deliberateOK
            let margin = scored.count > 1 ? best.score - scored[1].score : .infinity
            let tapMarginFactor = tapVetoFactor(
                typedChars: typedChars,
                candidate: best.word,
                perTap: perTap,
                isRestorationOnly: best.cost.isRestorationOnly,
                winnerTypicality: model.isPersonalValid(best.word)
                    ? .infinity
                    : (attestedTypicality(of: best.word) ?? -.infinity)
            )
            if let trace {
                trace.margin = margin
                trace.tapVetoFactor = tapMarginFactor
                trace.rule =
                    !typedIsProtected && best.word.contains(" ")
                    ? "split"
                    : !typedIsProtected
                        ? "ordinary-unknown"
                        : best.cost.isRestorationOnly && !best.word.contains(" ")
                            && deliberate.isEmpty
                            ? "skeleton-restoration" : "valid-word (no auto-apply path)"
                if !lengthOK {
                    trace.gate(
                        "minAutocorrectLength",
                        "typed length \(typedChars.count) < \(config.minAutocorrectLength)",
                        pass: false)
                }
                if !costOK {
                    trace.gate(
                        "autocorrectMaxSpatialCost",
                        "best cost \(String(format: "%.3f", best.cost.total))"
                            + " > \(config.autocorrectMaxSpatialCost)",
                        pass: false)
                }
                if !apostrophesOK { trace.gate("preservesApostrophes", "candidate drops a typed apostrophe", pass: false) }
                if !deliberateOK { trace.gate("preservesDeliberateCharacters", "candidate drops a long-pressed character", pass: false) }
            }
            if preconditionsOK, !typedIsProtected, best.word.contains(" ") {
                // Split auto-apply (dogfood "fara lega" tightening): a split
                // is a bigger intervention than a repair, so it must clear a
                // RAISED margin AND the merged token must have no plausible
                // attested/personal single-word repair within the generous
                // cost bound — if a one-word fix exists, the split stays
                // bar-only. BÍN-only forms never veto (junk one edit from
                // everything must not block "helloworld" → "hello world").
                let bestSingleCost = scored
                    .filter { !$0.word.contains(" ") && isAttestedOrPersonal($0.word) }
                    .map(\.cost.total)
                    .min() ?? .infinity
                let marginOK = margin >= config.splitAutocorrectMargin * tapMarginFactor
                let noSingleRepair = bestSingleCost > config.splitAutoApplySingleWordCutoff
                if let trace {
                    trace.requiredMargin = config.splitAutocorrectMargin
                    trace.gate(
                        "splitMargin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(config.splitAutocorrectMargin) x \(String(format: "%.2f", tapMarginFactor))",
                        pass: marginOK)
                    trace.gate(
                        "noSingleWordRepair",
                        "best attested single-word cost \(String(format: "%.3f", bestSingleCost))"
                            + " > cutoff \(config.splitAutoApplySingleWordCutoff)",
                        pass: noSingleRepair)
                }
                autocorrect = marginOK && noSingleRepair
            } else if preconditionsOK, !typedIsProtected {
                // Single-word auto-apply additionally requires the winner to
                // be typical vocabulary (attested at z ≥ autocorrectMinZ;
                // personal words are exempt): BÍN-floored junk like
                // "garalega" may be suggested but never auto-applied. FAR
                // repairs (unit edit distance ≥ autocorrectFarRepairEdits —
                // now reachable at all thanks to the multi-edit beam) raise
                // the bar to COMMON vocabulary: keyboard mash sits within 3
                // substitutions of some rare word ("awgke" → "aegis"), and
                // replacing mash with rarities is worse than leaving it.
                let typicality =
                    model.isPersonalValid(best.word)
                    ? Double.infinity
                    : (attestedTypicality(of: best.word) ?? -.infinity)
                let rewrite = Self.rewriteDistance(typedChars, Array(best.word))
                let farRepair = rewrite >= config.autocorrectFarRepairEdits
                // Short-token discipline (dogfood "eg"/"vð", 2026-07-16):
                // a 2-letter token carries almost no spatial evidence, so
                // auto-apply demands a headline-vocabulary winner (ég, við
                // — the words people actually mean) via the raised floor.
                let short = typedChars.count <= config.autocorrectShortLengthMax
                var minZ =
                    farRepair
                    ? max(config.autocorrectMinZ, config.autocorrectFarRepairMinZ)
                    : config.autocorrectMinZ
                if short { minZ = max(minZ, config.autocorrectShortMinZ) }
                // A short token never auto-EXPANDS into a strict-prefix
                // completion ("fo" must not commit "for" uninvited — two
                // keystrokes are evidence of a two-letter word, not of any
                // particular continuation); repairs ("vð" → "við", "eg" →
                // "ég") are unaffected.
                let shortCompletion =
                    short && best.word.count > typedChars.count
                    && best.word.hasPrefix(typed)
                // RESTORATION-only winners (every edit an acute fold /
                // directional confusion / apostrophe insertion) get the
                // relaxed margin once the lane ramp is open: restoration
                // serves an input method and does not compete for the
                // error-budget margin. At/below the neutral prior the
                // ordinary margin applies — nothing changes there.
                let profileWeight = restorationProfileWeight(
                    typed: typed, candidate: best.word, pricing: pricing)
                let restorationRelaxed = best.cost.isRestorationOnly && profileWeight > 0
                var requiredMargin =
                    restorationRelaxed
                    ? config.restorationAutoApplyMargin
                    : config.autocorrectMargin
                // Junk-tier winner discipline (session-3 replay "kozy" →
                // "jozy"): an ERROR-class winner below
                // `autocorrectJunkWinnerZ` is a junk-tier vocabulary guess —
                // the margin it must clear is scaled up rather than the
                // fire being hard-floored (see the EngineConfig doc:
                // raising `autocorrectMinZ` removed ~88%-correct fires on
                // dev; scaling removes only the narrow junk wins).
                // Restoration-relaxed winners are exempt: they carry their
                // own gate stack, and derived possessives ("childrens" →
                // "children's") are deliberately priced at a FRACTION of
                // their stem's typicality — junk-scaling them would kill
                // the possessive restoration the fraction exists to serve.
                // Personal winners (typicality ∞) and everything at/above
                // the threshold are untouched.
                let junkWinner =
                    !restorationRelaxed && typicality < config.autocorrectJunkWinnerZ
                if junkWinner {
                    requiredMargin *= config.autocorrectJunkWinnerMarginScale
                }
                var marginOK = margin >= requiredMargin * tapMarginFactor
                var typicalityOK = typicality >= minZ
                // Vacuum auto-apply (dogfood "stökklrikanum" wave): a
                // BÍN-valid winner below the typicality floor may still
                // fire when the pool holds NO attested-or-personal repair
                // within the close-candidate bound — with no attested
                // competition, the morphologically valid word one cheap
                // edit away beats leaving the typo. Stricter margin; far
                // repairs keep the hard attested-common rule (mash never
                // becomes BÍN junk).
                var vacuum = false
                if config.vacuumAutoApplyEnabled,
                    !typicalityOK, !farRepair, !short,
                    model.morphology?.isKnown(best.word) == true,
                    bestAttestedCost(in: candidates) > config.closeCandidateGate
                {
                    vacuum = true
                    typicalityOK = true
                    marginOK =
                        margin >= max(requiredMargin, config.vacuumAutoApplyMargin)
                            * tapMarginFactor
                }
                // Proper-noun possessive guard: a capitalized mid-sentence
                // s-ending token whose stem is NOT English vocabulary is
                // overwhelmingly Name+s (a possessive typed without the
                // apostrophe — "Corgans", "LSUs", "Rugovas") that the
                // possessive-derivation pass could not read (stem absent
                // from en.lex), so any error-class winner is a guess at a
                // DIFFERENT word ("Organs", "Arcs") — bar-only. Attested
                // stems keep every rule (the derived possessive competes
                // honestly), restoration-only winners are the lazy-input
                // case and still fire ("Olafur" → "Ólafur"). Deliberately
                // NOT a blanket capitalized-token veto: on the dev corpus
                // most mid-sentence-capital corrections are honest fixes
                // of attested names (87% of what a blanket guard blocked).
                let properNounOK: Bool
                if config.properNounGuardEnabled, capitalizedMidSentence,
                    !best.cost.isRestorationOnly,
                    typedChars.count >= 4,
                    typedChars.last == "s",
                    typedChars.allSatisfy(\.isLetter)
                {
                    let stem = String(typedChars.dropLast())
                    // Guarded shape: the stem is a KNOWN token (is.lex —
                    // names surface in the Icelandic web corpus) that
                    // en.lex lacks, so the possessive derivation could not
                    // read Name+'s. A junk stem (typo inside the stem,
                    // attested nowhere) is an ordinary typo and repairs
                    // freely; an en.lex-attested stem competes honestly
                    // via the derived possessive.
                    properNounOK =
                        model.english.frequency(of: stem) != nil
                        || model.icelandic.frequency(of: stem) == nil
                } else {
                    properNounOK = true
                }
                if let trace {
                    if config.properNounGuardEnabled, capitalizedMidSentence, !properNounOK {
                        trace.gate(
                            "proper-noun-possessive-guard",
                            "capitalized mid-sentence Name+s with unattested stem;"
                                + " error-class auto-apply suppressed",
                            pass: false)
                    }
                }
                if let trace {
                    trace.requiredMargin =
                        vacuum ? max(requiredMargin, config.vacuumAutoApplyMargin) : requiredMargin
                    trace.note(
                        restorationRelaxed
                            ? "restoration-only winner, lane ramp open (weight "
                                + "\(String(format: "%.2f", profileWeight))) -> relaxed margin"
                            : best.cost.isRestorationOnly
                                ? "restoration-only winner but lane ramp CLOSED -> ordinary margin"
                                : "error-class winner (rewriteDistance \(rewrite)"
                                    + "\(farRepair ? ", FAR repair" : ""))")
                    if vacuum {
                        trace.note(
                            "VACUUM: BÍN-valid winner below the typicality floor, no attested"
                                + " repair within closeCandidateGate -> stricter margin, floor waived")
                    }
                    if junkWinner {
                        trace.note(
                            "junk-tier winner (z \(String(format: "%+.3f", typicality))"
                                + " < \(String(format: "%+.2f", config.autocorrectJunkWinnerZ)))"
                                + " -> margin x\(String(format: "%.1f", config.autocorrectJunkWinnerMarginScale))")
                    }
                    trace.gate(
                        "margin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(String(format: "%.3f", vacuum ? max(requiredMargin, config.vacuumAutoApplyMargin) : requiredMargin))"
                            + " x \(String(format: "%.2f", tapMarginFactor))"
                            + (vacuum ? " (vacuum margin)" : ""),
                        pass: marginOK)
                    trace.gate(
                        "typicality",
                        "winner z \(typicality == .infinity ? "personal" : String(format: "%+.3f", typicality))"
                            + " >= minZ \(String(format: "%+.3f", minZ))"
                            + (farRepair ? " (far-repair floor)" : "")
                            + (short ? " (short-token floor)" : ""),
                        pass: typicalityOK)
                }
                if let trace, shortCompletion {
                    trace.gate(
                        "short-completion",
                        "short token; winner \"\(best.word)\" is a strict-prefix"
                            + " completion — never auto-expanded",
                        pass: false)
                }
                autocorrect = marginOK && typicalityOK && properNounOK && !shortCompletion
            } else if preconditionsOK, best.cost.isRestorationOnly, !best.word.contains(" "),
                deliberate.isEmpty
            {
                // Skeleton collision (PLAN.md "The hard part"): the typed
                // token is itself a valid word ("for", "vist", "dont") or
                // an accepted compound ("tungumal" = tungu+mal — the lazy
                // accent skeleton of "tungumál" decomposes; wave 22), so
                // the sacred valid-word rule applies — restoration may
                // auto-apply PAST it only through the triple gate
                // (dominance × context × no deliberateness signal), plus
                // the sletta guard and the relaxed margin.
                let marginOK =
                    margin >= config.restorationAutoApplyMargin * tapMarginFactor
                if let trace {
                    trace.requiredMargin = config.restorationAutoApplyMargin
                    trace.gate(
                        "margin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(config.restorationAutoApplyMargin)"
                            + " x \(String(format: "%.2f", tapMarginFactor))",
                        pass: marginOK)
                }
                // Pure function: safe to evaluate even when the margin
                // failed, so the trace always carries the full triple-gate
                // picture.
                let tripleOK = passesRestorationTripleGate(
                    typed: typed,
                    candidate: best.word,
                    previousWord: previousWord,
                    pIcelandic: pIcelandic,
                    trace: trace
                )
                autocorrect = marginOK && tripleOK
            }
        }

        trace?.autocorrect = autocorrect

        // ---- Confidence: softmax over the top of the candidate pool -------
        let confidencePool = scored.prefix(8)
        let maxScore = confidencePool.first?.score ?? 0
        let z = confidencePool.reduce(0.0) { $0 + exp($1.score - maxScore) }

        var suggestions = scored.prefix(limit).enumerated().map { index, entry in
            Suggestion(
                text: entry.word,
                isAutocorrect: index == 0 && autocorrect,
                confidence: z > 0 ? exp(entry.score - maxScore) / z : 0,
                isRestoration: entry.cost.isRestorationOnly
            )
        }

        // Wrong-form offer (PLAN.md Stage B #2, offer-only — HARD): the
        // typed word is VALID but a paradigm sibling of the same lemma fits
        // the governor dramatically better ("frá hestur" → "hesti"). The
        // sibling is surfaced in the bar and NEVER auto-applied — one valid
        // form of a lemma is never auto-replaced by another (grammar
        // assistance, not autocorrect). Suppressed outright when the typed
        // (governor, word) bigram is itself corpus-attested: attested usage
        // must never trigger a "correction" offer (grammar-offer precision).
        if typedIsValid, let fit = governorFit,
            model.icelandic.bigramFrequency(fit.previousWord, typed) == nil,
            let offer = wrongFormOffer(typed: typed, fit: fit)
        {
            suggestions.removeAll { $0.text == offer }
            // Never displace an auto-apply winner (the skeleton-collision
            // restoration path can legitimately hold slot 0 here), and never
            // displace a top candidate the corpus attests WITH this governor
            // ("til bak|" → bigram-attested "baka" stays on top, the
            // genitive offer rides second): exact bigram evidence dominates
            // the grammar generalization here exactly as it does in scoring.
            let topHasBigramEvidence =
                suggestions.first.map {
                    model.icelandic.bigramFrequency(fit.previousWord, $0.text) != nil
                } ?? false
            let slot = (suggestions.first?.isAutocorrect == true || topHasBigramEvidence) ? 1 : 0
            suggestions.insert(
                Suggestion(
                    text: offer,
                    isAutocorrect: false,
                    confidence: fit.governor.caseProbabilities[fit.dominantCaseCode]
                ),
                at: min(slot, suggestions.count)
            )
            suggestions = Array(suggestions.prefix(limit))
        }

        return CorrectionResult(suggestions: suggestions, typedWordIsValid: typedIsProtected)
    }

    /// The single best wrong-form sibling to offer for a VALID typed word
    /// under a governor: `GovernorFit.wrongFormSiblings` (same lemma, same
    /// agreement axes, case swapped to the governor's dominant case, past
    /// the advantage threshold), tombstones excluded, ranked by is.lex
    /// frequency (BÍN alternate spellings for one slot: the attested one
    /// wins; wholly unattested siblings still qualify — the paradigm is the
    /// authority on existence, frequency only breaks ties).
    private func wrongFormOffer(typed: String, fit: GovernorFit) -> String? {
        let siblings = fit.wrongFormSiblings(
            ofValidTyped: typed,
            minAdvantage: config.morphWrongFormMinAdvantage
        ).filter { !model.isPersonalTombstoned($0) }
        return siblings.max { lhs, rhs in
            let l = model.icelandic.frequency(of: lhs) ?? 0
            let r = model.icelandic.frequency(of: rhs) ?? 0
            return l < r || (l == r && lhs > rhs)
        }
    }

    // MARK: - Coordinate margin veto (PLAN.md "Touch decoding")

    /// Autocorrect-margin factor from the word's tap confidence — the VETO
    /// half of the bidirectional evidence principle. Always ≥ 1: coordinate
    /// evidence only ever makes auto-apply HARDER than the static engine,
    /// or equal (v1 safety choice, documented on `EngineConfig
    /// .tapVetoBaseline`); the ENABLING half acts through the cheaper
    /// per-tap substitution costs instead.
    ///
    /// Aggregation is candidate-aware — the veto must come from taps that
    /// CONTRADICT the rewrite, not from taps the candidate agrees with:
    ///
    ///  * same-length candidates aggregate confidence over the tapped
    ///    positions the candidate REWRITES (a dead-center tap there says
    ///    "I hit exactly this key" — believe the user; matching positions
    ///    are consistent with both readings and stay out),
    ///  * restoration pairs (accent twins, orthographic confusions) never
    ///    veto: a dead-center base-letter tap is the LAZY-INPUT signal, and
    ///    confusions are cognitive — the tap carries no information,
    ///  * a substitution-split's consumed letter (candidate has ' ' there)
    ///    stays out: its evidence is already priced through the tap-scaled
    ///    split penalty, and the key-normalized confidence cannot see the
    ///    spacebar as an alternative target,
    ///  * RESTORATION-ONLY candidates (every edit an acute fold /
    ///    directional confusion / apostrophe insertion — the caller passes
    ///    `isRestorationOnly` from the winner's channel-cost decomposition)
    ///    never veto REGARDLESS of length change (veto-asymmetry fix,
    ///    2026-07-16): a dead-center tap on the base vowel is the
    ///    LAZY-INPUT signal FOR restoration — the fold pricing already
    ///    prices per-tap evidence through `foldEvidencePenalty`, and the
    ///    whole-word aggregate was double-punishing careful typists on
    ///    apostrophe insertions ("dont"→"don't", the one length-changing
    ///    restoration shape),
    ///  * remaining length-changing rewrites (indels, insertion splits)
    ///    fall back to the whole-word aggregate: deliberately hitting every
    ///    key dead-center is evidence against ANY error-class rewrite of
    ///    the token — this is what makes an all-dead-center unknown word
    ///    essentially never auto-replace. One relaxation (veto asymmetry,
    ///    2026-07-16): the taps cannot reprice indels, so this branch was
    ///    blocking careful typists' omission typos ("vð" → "við") on the
    ///    margin alone with no contradicting tap — an EXTREME-vocabulary
    ///    winner (`winnerTypicality` ≥ `tapVetoCommonWinnerMinZ`; personal
    ///    words qualify) therefore gets the softer
    ///    `tapVetoCommonMaxFactor` clamp.
    func tapVetoFactor(
        typedChars: [Character],
        candidate: String,
        perTap: PerTapCostProvider?,
        isRestorationOnly: Bool = false,
        winnerTypicality: Double = -.infinity
    ) -> Double {
        guard let perTap else { return 1 }
        if isRestorationOnly { return 1 }
        let candidateChars = Array(candidate)
        let mean: Double?
        var maxFactor = config.tapVetoMaxFactor
        if candidateChars.count == typedChars.count {
            var sum = 0.0
            var count = 0
            for index in 0..<typedChars.count where typedChars[index] != candidateChars[index] {
                let intended = candidateChars[index]
                if intended == " " { continue }
                if Self.isRestorationPair(typedChars[index], intended) { continue }
                guard perTap.hasTap(at: index) else { continue }
                sum += perTap.confidence(position: index)
                count += 1
            }
            mean = count > 0 ? sum / Double(count) : nil
        } else {
            mean = perTap.meanTapConfidence
            if winnerTypicality >= config.tapVetoCommonWinnerMinZ {
                maxFactor = min(maxFactor, config.tapVetoCommonMaxFactor)
            }
        }
        guard let mean else { return 1 }
        return min(
            1 + config.tapVetoStrength * max(0, mean - config.tapVetoBaseline),
            maxFactor
        )
    }

    // MARK: - Lane relaxation (restoration auto-apply machinery)

    /// Which profile's lane ramp governs a restoration-only candidate:
    /// apostrophe ADDITIONS are the English profile, everything else (acute
    /// folds, directional confusions) the Icelandic one.
    private func restorationProfileWeight(
        typed: String, candidate: String, pricing: FoldPricing
    ) -> Double {
        let typedApostrophes = typed.filter { Self.apostrophes.contains($0) }.count
        let candidateApostrophes = candidate.filter { Self.apostrophes.contains($0) }.count
        return candidateApostrophes > typedApostrophes ? pricing.weightEN : pricing.weightIS
    }

    /// A candidate may never auto-apply if it drops a character the user
    /// entered via long-press/callout (deliberateness hierarchy, strongest
    /// signal): multiset containment on the long-pressed characters — a
    /// long-pressed accent is never folded away, a long-pressed letter
    /// never rewritten away. Bar suggestions are unaffected.
    static func preservesDeliberateCharacters(
        _ deliberate: [Character], of typed: [Character], in candidate: String
    ) -> Bool {
        guard !deliberate.isEmpty else { return true }
        let candidateChars = Array(candidate)
        for char in Set(deliberate) {
            let required = min(
                deliberate.filter { $0 == char }.count,
                typed.filter { $0 == char }.count
            )
            guard candidateChars.filter({ $0 == char }).count >= required else { return false }
        }
        return true
    }

    /// Skeleton-collision triple gate (PLAN.md "Lane relaxation profiles",
    /// "The hard part"): the typed skeleton is itself a valid word, and the
    /// restoration-only candidate may auto-apply past the sacred valid-word
    /// rule only when ALL gates pass. Fail any → offer-only (both readings
    /// stay visible in the bar).
    private func passesRestorationTripleGate(
        typed: String,
        candidate: String,
        previousWord: String?,
        pIcelandic: Double,
        trace: CorrectionTrace? = nil
    ) -> Bool {
        // All gates are evaluated (pure lookups) and ANDed so a trace
        // carries the full picture; without a trace the result is identical
        // to the original early-return chain.
        var pass = true
        func gate(_ name: String, _ detail: @autoclosure () -> String, _ ok: Bool) {
            trace?.gate(name, detail(), pass: ok)
            if !ok { pass = false }
        }

        // Deliberateness, part (c): the user previously learned or
        // verbatim-tapped the skeleton (personal dict outranks restoration),
        // or tombstoned it (deletion means "stop suggesting", never "start
        // correcting what I type"). Tombstoned candidates never got here —
        // admit() excludes them. PROTECTED personal validity, not raw
        // (wave 26, session 2026-07-16T22-45-30): an implicitly learned
        // acute-fold shadow of a dominant twin is lazy input, not a
        // deliberateness signal — the remaining gates (lane, dominance,
        // context, sletta) still judge the restoration on merit.
        let personalSkeleton =
            model.isPersonalProtected(typed) || model.isPersonalTombstoned(typed)
        gate(
            "no-personal-skeleton",
            "skeleton \"\(typed)\" is\(personalSkeleton ? "" : " not") personal/tombstoned",
            !personalSkeleton)

        // Profile from the restoration direction: apostrophe additions are
        // the English profile, acute folds the Icelandic one.
        let addsApostrophes =
            candidate.filter { Self.apostrophes.contains($0) }.count
            > typed.filter { Self.apostrophes.contains($0) }.count
        let lane: Language = addsApostrophes ? .english : .icelandic
        let other: Language = addsApostrophes ? .icelandic : .english
        let pLane = addsApostrophes ? 1 - pIcelandic : pIcelandic

        // Lane gate: the general rule inherits the shipped single-letter
        // path's auto-apply posterior (that path is the special case of
        // this rule) — never past the valid-word rule from a neutral or
        // off-lane posterior.
        gate(
            "lane-posterior",
            "P(lane) \(String(format: "%.3f", pLane))"
                + " >= accentAutoApplyMinPosterior \(config.accentAutoApplyMinPosterior)",
            pLane >= config.accentAutoApplyMinPosterior)

        // Gate 1 — frequency dominance in the lane lexicon (the is.lex
        // accent-dominance ratio machinery): the restored form must be
        // ≥ restorationDominanceRatio× the skeleton. fór (369k) over an
        // is.lex-absent "for" passes trivially; víst (+0.78, below
        // restorationDominanceMinZ) over BÍN-valid "vist" does not.
        let candidateFrequency = model.lexicon(for: lane).frequency(of: candidate)
        if let candidateFrequency {
            if let skeletonFrequency = model.lexicon(for: lane).frequency(of: typed) {
                gate(
                    "dominance-ratio",
                    "f(\(candidate)) \(candidateFrequency)"
                        + " >= \(config.restorationDominanceRatio) x f(\(typed)) \(skeletonFrequency)",
                    Double(candidateFrequency)
                        >= config.restorationDominanceRatio * Double(skeletonFrequency))
            } else if lane == .icelandic, model.morphology?.isKnown(typed) == true {
                // BÍN-valid skeleton of unknown frequency: the ratio
                // machinery has no denominator, so only headline-frequency
                // restored forms may claim dominance over a
                // real-but-unmeasured word. EXCEPT oblique-only skeletons
                // (noun/adjective readings with no nominative — "simanum",
                // þgf-only): those are never a citation-form word typed
                // deliberately, only the accent-dropped spelling of their
                // restored twin, so a lexicon-average restored form
                // (`restorationDominanceObliqueMinZ`) already dominates.
                // Base-form skeletons ("vist", "for" — nf-readable) and
                // non-noun skeletons keep the strict bar.
                let z = model.calibratedUnigramScore(of: candidate, language: lane)
                let skeletonCases = model.morphology?.nounAdjectiveCases(of: typed) ?? []
                let obliqueOnly = !skeletonCases.isEmpty && !skeletonCases.contains("nf")
                let minZ =
                    obliqueOnly
                    ? config.restorationDominanceObliqueMinZ
                    : config.restorationDominanceMinZ
                gate(
                    "dominance-minZ",
                    "BÍN-valid skeleton, no lane frequency"
                        + " (cases: \(skeletonCases.isEmpty ? "-" : skeletonCases.joined(separator: " "))"
                        + "\(obliqueOnly ? ", oblique-only" : "")): z(\(candidate))"
                        + " \(String(format: "%+.3f", z))"
                        + " >= \(obliqueOnly ? "restorationDominanceObliqueMinZ" : "restorationDominanceMinZ")"
                        + " \(minZ)",
                    z >= minZ)
            } else {
                trace?.note(
                    "dominance: skeleton valid only outside the lane — no own-lane collision")
            }
        } else {
            gate("dominance-ratio", "candidate \"\(candidate)\" unattested in lane lexicon", false)
        }
        // (Skeleton valid only in the OTHER language — e.g. "bud" via
        // en.lex: no own-lane collision; gate 3 prices the cross-language
        // reading.)

        // Gate 2 — context support: bigram/context evidence must favor the
        // restored reading in the lane language ("ég for heim" → fór
        // overwhelmingly; a bigram-supported skeleton like "í vist" fails).
        let candidateContext = model.calibratedScore(
            of: candidate, previous: previousWord, language: lane)
        let skeletonContext = model.calibratedScore(
            of: typed, previous: previousWord, language: lane)
        gate(
            "context-advantage",
            "ctx(\(candidate)) \(String(format: "%+.3f", candidateContext))"
                + " - ctx(\(typed)) \(String(format: "%+.3f", skeletonContext))"
                + " = \(String(format: "%+.3f", candidateContext - skeletonContext))"
                + " >= restorationContextMinAdvantage \(config.restorationContextMinAdvantage)",
            candidateContext - skeletonContext >= config.restorationContextMinAdvantage)

        // Sletta guard: the restored lane reading must dominate the OTHER
        // language's reading of the skeleton under the current blend — the
        // lane model absorbs slettur, restoration must not undo that
        // ("for" as English inside a merely-leaning IS lane keeps its
        // English reading; only a saturated lane overwhelms it).
        if model.lexicon(for: other).frequency(of: typed) != nil {
            let otherScore = model.calibratedScore(
                of: typed, previous: previousWord, language: other)
            let clamped = min(max(pLane, 1e-6), 1 - 1e-6)
            let advantage =
                log(clamped / (1 - clamped))
                + config.calibrationTemperature * (candidateContext - otherScore)
            gate(
                "sletta-guard",
                "log-odds \(String(format: "%+.3f", log(clamped / (1 - clamped))))"
                    + " + tau·(ctx(\(candidate)) - other(\(typed))"
                    + " \(String(format: "%+.3f", otherScore)))"
                    + " = \(String(format: "%+.3f", advantage))"
                    + " >= slettaGuardBlendThreshold \(config.slettaGuardBlendThreshold)",
                advantage >= config.slettaGuardBlendThreshold)
        }
        return pass
    }

    // MARK: - Space-miss splits

    /// Split hypotheses for an unknown token (see `correct` step 6). Two
    /// generation classes, explored best-evidence-first under a wall-clock
    /// budget:
    ///
    /// 1. **Space-substitution** (cheap penalty): an interior letter that
    ///    sits directly above the spacebar (`SpatialModel
    ///    .spaceAdjacentLetters`, derived from key geometry) is consumed AS
    ///    the space — "smelirna" → "smelir"+"a".
    /// 2. **Space-insertion** (full omitted-keystroke penalty): a space is
    ///    inserted between two characters — "helloworld" → "hello"+"world".
    ///
    /// Each half must be exact-valid or cheaply repairable by the targeted
    /// passes (`halfHypotheses`); a candidate's score combines both halves'
    /// calibrated language scores — blended JOINTLY per lane, the second
    /// half conditioned on the first so bigram coherence is priced in (see
    /// `BlendedLanguageModel.blendedPairScore`) — plus the split penalty
    /// and any half repair costs:
    ///
    ///   score = -(penalty + cost_left + cost_right)
    ///           + λ·S_pair(left, right | prev, posterior)
    ///
    /// Returned tuples mirror the single-word pool's (word, spatialCost,
    /// score) shape; the channel cost stands in for the spatial cost in the
    /// autocorrect conservatism check.
    /// `taps` (when aligned with `typedChars`) drives the space-adjacent
    /// evidence rule (PLAN.md "Touch decoding", stage 1): the
    /// space-substitution penalty scales with the consumed tap's distance
    /// to the spacebar edge — a tap hugging the bottom of the letter key
    /// prices the split below the static constant, a dead-center/top-edge
    /// tap prices it up (see `EngineConfig.tapSpaceSplitSlope`).
    /// `rawChars` (when aligned with `typedChars`) is the ORIGINAL-case
    /// typed token: a merged pair keeps the user's interior capitalization
    /// ("RitaHayworth" → "Rita Hayworth", never "Rita hayworth") — the
    /// second half's first letter takes the case of the typed character it
    /// starts from. Ranking/validity are case-insensitive throughout
    /// (lexicon lookups normalize), so only the rendered text changes.
    func splitCandidates(
        typedChars: [Character],
        previousWord: String?,
        pIcelandic: Double,
        taps: [TapSample?] = [],
        rawChars: [Character] = []
    ) -> [(word: String, spatialCost: Double, score: Double)] {
        let n = typedChars.count
        guard n >= config.splitMinLength else { return [] }

        /// Tap-scaled space-substitution penalty for consuming position `j`
        /// as the space; the static constant without an aligned tap.
        ///
        /// Stage 2 (personal touch model): the tap's dy is read RELATIVE to
        /// the user's habitual (shrunk) dy on that key when its personal
        /// stats cleared the gate — a user who always taps low is not
        /// leaning toward the spacebar when they tap low, and a habitual
        /// high-tapper's low tap is unusually strong space evidence, so
        /// their split hypotheses cheapen exactly by slope·|habitual dy|.
        /// Same clamps as stage 1; no snapshot (or a cold key) is the
        /// stage-1 arithmetic byte-identically.
        func substitutionSplitPenalty(at j: Int) -> Double {
            guard j < taps.count, let tap = taps[j], tap.char == typedChars[j] else {
                return config.splitSubstitutionPenalty
            }
            let scaled: Double
            if let habitual = model.touch.snapshot?
                .blendedMeanOffset(for: tap.char, config: config)
            {
                scaled =
                    config.splitSubstitutionPenalty
                    + config.tapSpaceSplitSlope
                        * (config.tapSpaceSplitNeutralDy - (tap.dyNorm - habitual.y))
            } else {
                scaled =
                    config.splitSubstitutionPenalty
                    + config.tapSpaceSplitSlope * (config.tapSpaceSplitNeutralDy - tap.dyNorm)
            }
            return min(
                max(scaled, config.tapSpaceSplitMinPenalty), config.splitInsertionPenalty)
        }

        // (left, right, penalty, repairCap) hypotheses. Substitution splits
        // first (strongest evidence, smallest class), then insertion
        // splits; each class walked center-out — a missed space is
        // likeliest near the middle of the fused token — so the budget
        // sheds edges. Insertion splits get the tighter half-repair cap
        // (no tap evidence — see splitInsertionHalfRepairMaxCost).
        var hypotheses:
            [(
                left: [Character], right: [Character], penalty: Double, repairCap: Double,
                rightStart: Int
            )] = []
        let centerOut: (Int, Int) -> Bool = { lhs, rhs in
            let l = abs(2 * lhs - n)
            let r = abs(2 * rhs - n)
            return l < r || (l == r && lhs < rhs)
        }

        // A substitution split may never consume a character the user
        // SHIFTED for ("skelfingVestursins" must not eat the V): an
        // uppercase interior letter is deliberate input, not a missed
        // spacebar — the insertion-split hypotheses still read it as the
        // second word's (capitalized) first letter.
        let substitutionPositions = (1..<(n - 1))
            .filter {
                spatial.spaceAdjacentLetters.contains(typedChars[$0])
                    && !($0 < rawChars.count && rawChars[$0].isUppercase)
            }
            .sorted(by: centerOut)
            .prefix(config.splitMaxPositions)
        for j in substitutionPositions {
            hypotheses.append(
                (
                    Array(typedChars[0..<j]),
                    Array(typedChars[(j + 1)...]),
                    substitutionSplitPenalty(at: j),
                    config.splitHalfRepairMaxCost,
                    j + 1
                )
            )
        }

        let insertionPositions = (1...(n - 1))
            .sorted(by: centerOut)
            .prefix(min(n - 2, config.splitMaxPositions))
        for i in insertionPositions {
            hypotheses.append(
                (
                    Array(typedChars[0..<i]),
                    Array(typedChars[i...]),
                    config.splitInsertionPenalty,
                    config.splitInsertionHalfRepairMaxCost,
                    i
                )
            )
        }

        // Saturated-lane discipline (dogfood koetip: "joe tip" junk at
        // P(IS)=0.9): when the lane posterior is saturated, both halves
        // must clear the calibrated-z bar IN THE LANE LANGUAGE (personal
        // words exempt) — a junk split may not cherry-pick the other
        // language for one half. Below saturation, blendedPairScore's joint
        // pricing is the only cross-language discipline (unchanged).
        let saturatedLane: Language? =
            pIcelandic >= config.splitSaturatedLanePosterior
            ? .icelandic
            : (pIcelandic <= 1 - config.splitSaturatedLanePosterior ? .english : nil)
        var laneCache: [String: Bool] = [:]
        func clearsLaneBar(_ word: String) -> Bool {
            guard let lane = saturatedLane else { return true }
            if let cached = laneCache[word] { return cached }
            let admitted =
                model.isPersonalValid(word)
                || (model.lexicon(for: lane).frequency(of: word) != nil
                    && model.calibratedUnigramScore(of: word, language: lane)
                        >= config.splitSaturatedHalfMinZ)
            laneCache[word] = admitted
            return admitted
        }

        var best: [String: (spatialCost: Double, score: Double)] = [:]
        var halfCache: [String: [(word: String, cost: Double)]] = [:]
        func resolvedHalves(for half: [Character]) -> [(word: String, cost: Double)] {
            let key = String(half)
            if let cached = halfCache[key] { return cached }
            let fresh = halfHypotheses(half).filter { clearsLaneBar($0.word) }
            halfCache[key] = fresh
            return fresh
        }

        let deadline = ContinuousClock.now + .seconds(config.splitTimeBudget)
        for hypothesis in hypotheses {
            if ContinuousClock.now >= deadline { break }
            let lefts = resolvedHalves(for: hypothesis.left)
            guard !lefts.isEmpty else { continue }
            let rights = resolvedHalves(for: hypothesis.right)
            guard !rights.isEmpty else { continue }
            // Interior-capitalization carryover: the second half starts at
            // typed index `rightStart` — an uppercase typed character there
            // keeps its case in the rendered split ("RitaHayworth" →
            // "Rita Hayworth"). Leading capitalization of the FIRST half is
            // the engine wrapper's job, exactly as for one-word candidates.
            let capitalizeRight =
                hypothesis.rightStart < rawChars.count
                && rawChars[hypothesis.rightStart].isUppercase
            for (leftWord, leftCost) in lefts where leftCost <= hypothesis.repairCap {
                for (rightWord, rightCost) in rights where rightCost <= hypothesis.repairCap {
                    let channel = hypothesis.penalty + leftCost + rightCost
                    let renderedRight =
                        capitalizeRight
                        ? rightWord.prefix(1).uppercased() + rightWord.dropFirst()
                        : rightWord
                    let text = leftWord + " " + renderedRight
                    if let existing = best[text], existing.spatialCost <= channel { continue }
                    let language = model.blendedPairScore(
                        first: leftWord,
                        second: rightWord,
                        previous: previousWord,
                        pIcelandic: pIcelandic
                    )
                    best[text] = (channel, -channel + config.languageWeight * language)
                }
            }
        }
        // Deterministic order out of the dictionary (score, then
        // lexicographic): the caller's final ranking has its own tie-break,
        // but the pool must never leak per-process hash order downstream.
        return best
            .map { (word: $0.key, spatialCost: $0.value.spatialCost, score: $0.value.score) }
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }
    }

    /// Resolutions of one split half: the half itself when valid (cost 0)
    /// plus cheaply-repaired valid forms from the targeted passes —
    /// diacritic restoration, gemination, and (only when those find
    /// nothing) single edits with tight spatial cost. Never edits2. Capped
    /// at `splitHalfHypothesisLimit`, cheapest first.
    func halfHypotheses(_ chars: [Character]) -> [(word: String, cost: Double)] {
        var best: [String: Double] = [:]
        func admit(_ word: String, _ cost: Double) {
            guard cost <= config.splitHalfRepairMaxCost else { return }
            guard word.count > 1 || isGenuineSingleCharWord(word) else { return }
            guard !model.isPersonalTombstoned(word) else { return }
            if let existing = best[word], existing <= cost { return }
            best[word] = cost
        }

        let text = String(chars)
        if model.isKnownAnywhere(text) || model.isPersonalValid(text) { admit(text, 0) }
        for variant in Self.diacriticVariants(of: chars)
        where isCandidateWord(variant, checkMorphology: true) {
            admit(variant, spatialCost(typedChars: chars, candidate: variant))
        }
        for variant in Self.geminationVariants(of: chars)
        where isCandidateWord(variant, checkMorphology: true) {
            admit(variant, spatialCost(typedChars: chars, candidate: variant))
        }
        // edits1 is the expensive pass (hundreds of existence checks): only
        // walked when the cheap passes produced nothing, never for 1–2 char
        // halves (every 1–2 letter word is one edit from another), and
        // never for LONG halves (splitHalfEdits1MaxLength): a long invalid
        // half's edits1 walk costs a milliseconds-tier slab of lexicon+BÍN
        // probes that can eat the whole split budget on ONE junk
        // hypothesis ("southcaroli"+"a") before the honest split of the
        // same token ("south"+"carolina") is ever explored — and every
        // genuine repaired-half shape is short ("smelir" 6, "arolina" 7,
        // "angalore" 8).
        if best.isEmpty, chars.count >= 3, chars.count <= config.splitHalfEdits1MaxLength {
            for (word, cost) in Self.edits1Costed(of: chars, spatial: spatial)
            where cost <= config.splitHalfRepairMaxCost
                && isCandidateWord(word, checkMorphology: true)
            {
                admit(word, cost)
            }
        }
        return best
            .sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(config.splitHalfHypothesisLimit)
            .map { (word: $0.key, cost: $0.value) }
    }

    /// A single-character split half must be a GENUINE one-letter word —
    /// always an extreme-frequency function word in its language (IS á/í,
    /// EN a/i) — not corpus tokenization noise: "s" and "e" are attested in
    /// both lexicons but only at mid-tier typicality. Judged by calibrated
    /// z-score against `splitSingleCharHalfMinZ`.
    private func isGenuineSingleCharWord(_ word: String) -> Bool {
        let minZ = config.splitSingleCharHalfMinZ
        if model.icelandic.frequency(of: word) != nil,
            model.calibratedUnigramScore(of: word, language: .icelandic) >= minZ
        {
            return true
        }
        if model.english.frequency(of: word) != nil,
            model.calibratedUnigramScore(of: word, language: .english) >= minZ
        {
            return true
        }
        return false
    }

    // MARK: - Single-letter accent restoration

    /// The accent vowel pairs: bare letter → the long-press accented twin
    /// that is (potentially) a genuine one-letter Icelandic word. Only
    /// vowels — d→ð / t→þ never form one-letter words.
    static let singleLetterAccentPairs: [Character: Character] = [
        "a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý",
    ]

    /// Could a single-letter token get the accent-restoration suggestion at
    /// all? Cheap shape check for embedder gating (TypingSession's ≥2-char
    /// gate stays shut for every other single letter).
    public static func hasSingleLetterAccentEscape(_ token: String) -> Bool {
        guard token.count == 1, let letter = token.lowercased().first else { return false }
        return singleLetterAccentPairs[letter] != nil
    }

    /// Targeted single-letter path — the shipped SPECIAL CASE of the lane
    /// relaxation rule (PLAN.md "Lane relaxation profiles"), one per
    /// profile:
    ///
    ///  * IS (dogfood "giskar a allt" → "giskar á"): offer the accented
    ///    twin when it is a genuinely frequent Icelandic word, lane-gated.
    ///    Auto-apply — the sanctioned exception to both
    ///    `minAutocorrectLength` and the valid-typed-word rule — only when
    ///    the lane is confidently Icelandic AND the bare letter is not
    ///    itself Icelandic vocabulary (is.lex-genuine, personal, or
    ///    tombstoned; BÍN deliberately excluded, as everywhere
    ///    junk-collides).
    ///  * EN mirror: lone i → I capitalization ("i think" → "I think"),
    ///    same gates on P(EN). Both twins may be OFFERED around the neutral
    ///    prior; the auto-apply posteriors are mutually exclusive.
    ///
    /// A long-pressed letter (deliberateness veto) never reaches this path
    /// with relaxation on — but a lone long-pressed letter is the accent
    /// itself ("á"), which has no fold pair anyway.
    private func singleLetterCorrection(
        letter: Character,
        previousWord: String?,
        pIcelandic: Double,
        typedIsValid: Bool,
        trace: CorrectionTrace? = nil
    ) -> CorrectionResult {
        var suggestions: [Suggestion] = []
        trace?.typedIsValid = typedIsValid

        // --- IS profile: bare vowel → long-press accent twin.
        if config.foldProfileISEnabled,
            let accented = Self.singleLetterAccentPairs[letter],
            pIcelandic >= config.accentOfferMinPosterior
        {
            let variant = String(accented)
            // The accented twin must be genuinely frequent Icelandic ("á"
            // +3.3, "í" +3.4 clear the bar; "é"/"ý" are corpus noise and
            // never show), and never tombstoned.
            if !model.isPersonalTombstoned(variant),
                model.icelandic.frequency(of: variant) != nil,
                model.calibratedUnigramScore(of: variant, language: .icelandic)
                    >= config.accentRestoreMinZ
            {
                let bare = String(letter)
                let bareIsIcelandicWord =
                    model.isPersonalValid(bare)
                    || model.isPersonalTombstoned(bare)
                    || (model.icelandic.frequency(of: bare) != nil
                        && model.calibratedUnigramScore(of: bare, language: .icelandic)
                            >= config.splitSingleCharHalfMinZ)
                let autocorrect =
                    pIcelandic >= config.accentAutoApplyMinPosterior && !bareIsIcelandicWord
                if let trace {
                    trace.gate(
                        "accentAutoApplyMinPosterior",
                        "P(IS) \(String(format: "%.3f", pIcelandic))"
                            + " >= \(config.accentAutoApplyMinPosterior)",
                        pass: pIcelandic >= config.accentAutoApplyMinPosterior)
                    trace.gate(
                        "bare-letter-not-IS-word",
                        "\"\(letter)\" is\(bareIsIcelandicWord ? "" : " not") genuine IS vocabulary",
                        pass: !bareIsIcelandicWord)
                    trace.autocorrect = autocorrect
                }

                // Confidence: two-way softmax between the accented reading
                // and the typed letter's own blended score.
                let sVariant = model.blendedScore(
                    of: variant, previous: previousWord, pIcelandic: pIcelandic)
                let sBare = model.blendedScore(
                    of: bare, previous: previousWord, pIcelandic: pIcelandic)
                let m = max(sVariant, sBare)
                let confidence = exp(sVariant - m) / (exp(sVariant - m) + exp(sBare - m))
                suggestions.append(
                    Suggestion(
                        text: variant,
                        isAutocorrect: autocorrect,
                        confidence: confidence,
                        isRestoration: true
                    )
                )
            }
        }

        // --- EN profile mirror: lone i → I, gated on P(EN) exactly like
        // the accent path is gated on P(IS). "i" must be the genuine
        // extreme-frequency English pronoun in en.lex, never personal/
        // tombstoned vocabulary of its own.
        let pEnglish = 1 - pIcelandic
        if config.foldProfileENEnabled,
            letter == "i",
            pEnglish >= config.accentOfferMinPosterior,
            !model.isPersonalTombstoned("i"),
            model.english.frequency(of: "i") != nil,
            model.calibratedUnigramScore(of: "i", language: .english)
                >= config.accentRestoreMinZ
        {
            let autocorrect =
                pEnglish >= config.accentAutoApplyMinPosterior
                && !model.isPersonalValid("i")
            // Capitalization restoration has no competing reading — the
            // squashed lane posterior stands in as display confidence.
            suggestions.append(
                Suggestion(
                    text: "I",
                    isAutocorrect: autocorrect,
                    confidence: min(max(pEnglish, 0), 1),
                    isRestoration: true
                )
            )
        }

        // At most one auto-apply (the gates are posterior-exclusive, but
        // keep the invariant structural), autocorrect leads the bar.
        if suggestions.count > 1 {
            suggestions.sort {
                ($0.isAutocorrect ? 1 : 0, $0.confidence) > ($1.isAutocorrect ? 1 : 0, $1.confidence)
            }
            if suggestions[0].isAutocorrect {
                suggestions = suggestions.enumerated().map { index, s in
                    index == 0
                        ? s
                        : Suggestion(
                            text: s.text, isAutocorrect: false, confidence: s.confidence,
                            isRestoration: s.isRestoration)
                }
            }
        }
        return CorrectionResult(suggestions: suggestions, typedWordIsValid: typedIsValid)
    }

    // MARK: - Dotted-token space-miss escape

    /// Score/validate the "word word" reading of a dotted token whose SHAPE
    /// already passed TypingSession's checks (exactly one internal dot,
    /// all-letter halves, no known TLD, no www — see
    /// `TypingSession.spaceEscapeHalves`). Returns nil unless both halves
    /// are common attested words in one common language
    /// (`dottedEscapeMinHalfZ`). Auto-apply follows the strict split rules:
    /// the stricter half-typicality bar AND no attested/personal
    /// single-word repair of the merged letters within the generous bound.
    func dotSplitSuggestion(
        left: String,
        right: String,
        previousWord: String?,
        pIcelandic: Double
    ) -> Suggestion? {
        guard !model.isPersonalTombstoned(left), !model.isPersonalTombstoned(right) else {
            return nil
        }
        guard let commonness = pairCommonness(left: left, right: right),
            commonness >= config.dottedEscapeMinHalfZ
        else { return nil }

        let score =
            -config.dottedEscapePenalty
            + config.languageWeight
                * model.blendedPairScore(
                    first: left, second: right, previous: previousWord, pIcelandic: pIcelandic)
        let autocorrect =
            commonness >= config.dottedEscapeAutoApplyMinHalfZ
            && bestSingleWordRepairCost(of: left + right) > config.splitAutoApplySingleWordCutoff
        // Squashed score as a display confidence (there is no candidate
        // pool to softmax against — the alternative reading is the literal
        // verbatim token, which the bar always carries anyway).
        let confidence = 1 / (1 + exp(-score))
        return Suggestion(
            text: left + " " + right,
            isAutocorrect: autocorrect,
            confidence: min(max(confidence, 0), 1)
        )
    }

    /// max over language L of min(z_L(left), z_L(right)) — the pair's
    /// commonness in its best COMMON language; nil when no single language
    /// attests both halves (cross-language pairs never get the escape).
    /// One-letter halves must be genuine one-letter words in that language
    /// (`splitSingleCharHalfMinZ`).
    private func pairCommonness(left: String, right: String) -> Double? {
        func z(_ word: String, _ language: Language) -> Double? {
            guard model.lexicon(for: language).frequency(of: word) != nil else { return nil }
            let score = model.calibratedUnigramScore(of: word, language: language)
            if word.count == 1, score < config.splitSingleCharHalfMinZ { return nil }
            return score
        }
        var best: Double?
        for language in [Language.icelandic, .english] {
            if let l = z(left, language), let r = z(right, language) {
                best = max(best ?? -.infinity, min(l, r))
            }
        }
        return best
    }

    /// Cheapest ATTESTED-or-personal single-word repair of `typed` by the
    /// targeted passes (valid-as-is, edits1, diacritics, gemination — never
    /// edits2/completions): the item-2 "no plausible one-word fix" probe
    /// for split auto-apply. BÍN-only forms deliberately don't count.
    func bestSingleWordRepairCost(of typed: String) -> Double {
        if model.isValidTypedWord(typed) { return 0 }
        let chars = Array(typed)
        var best = Double.infinity
        func consider(_ word: String, _ cost: Double) {
            guard cost < best, isAttestedOrPersonal(word) else { return }
            best = cost
        }
        for (word, cost) in Self.edits1Costed(of: chars, spatial: spatial) {
            consider(word, cost)
        }
        for word in Self.diacriticVariants(of: chars) {
            consider(word, spatialCost(typedChars: chars, candidate: word))
        }
        for word in Self.geminationVariants(of: chars) {
            consider(word, spatialCost(typedChars: chars, candidate: word))
        }
        return best
    }

    // MARK: - Attestation helpers

    /// Attested in a frequency table, a derived English possessive of an
    /// attested stem (see `BlendedLanguageModel.derivedPossessiveBase`), or
    /// valid personal vocabulary (tombstoned words excluded). BÍN validity
    /// deliberately does not count — its 3M forms collide with junk (same
    /// stance as laneEvidence).
    private func isAttestedOrPersonal(_ word: String) -> Bool {
        guard !model.isPersonalTombstoned(word) else { return false }
        return model.isPersonalValid(word)
            || model.icelandic.frequency(of: word) != nil
            || model.english.frequency(of: word) != nil
            || model.derivedPossessiveBase(of: word) != nil
    }

    /// Best within-language calibrated typicality of an ATTESTED word; nil
    /// when the word is in neither frequency table (BÍN-only / unknown).
    /// Derived English possessives count as attested — their calibrated
    /// score already reflects the fraction-of-stem derived frequency, so
    /// the auto-apply typicality floor prices them honestly (a possessive
    /// of a rare stem stays below `autocorrectMinZ` and never auto-applies).
    private func attestedTypicality(of word: String) -> Double? {
        var best: Double?
        if model.icelandic.frequency(of: word) != nil {
            best = model.calibratedUnigramScore(of: word, language: .icelandic)
        }
        if model.english.frequency(of: word) != nil
            || model.derivedPossessiveBase(of: word) != nil
        {
            best = max(
                best ?? -.infinity,
                model.calibratedUnigramScore(of: word, language: .english)
            )
        }
        return best
    }

    /// Cheapest attested-or-personal candidate cost in a generation pool
    /// (the gate currency for passes that BÍN-floored junk must not
    /// suppress — see step 4b).
    private func bestAttestedCost(in candidates: [String: ChannelCost]) -> Double {
        var best = Double.infinity
        for (word, cost) in candidates where cost.total < best && isAttestedOrPersonal(word) {
            best = cost.total
        }
        return best
    }

    // MARK: - Internals

    /// Apostrophe conservatism (harness quirk: "don't"→"dont", "I'm"→"Ibm"):
    /// an auto-replacement may never drop apostrophes the user typed. The
    /// candidate must contain at least as many apostrophes as the typed
    /// word (bar suggestions are unaffected — only auto-apply is blocked).
    /// Holds regardless of whether the lexicon knows the contraction.
    static func preservesApostrophes(of typed: String, in candidate: String) -> Bool {
        let typedCount = typed.filter { apostrophes.contains($0) }.count
        guard typedCount > 0 else { return true }
        return candidate.filter { apostrophes.contains($0) }.count >= typedCount
    }

    /// A token containing hyphens whose parts are each valid (lexicon or
    /// BÍN) is treated as a valid compound. A trailing hyphen (word in
    /// progress: "vel-") only needs the completed parts to be valid.
    private func isValidHyphenatedCompound(_ word: String) -> Bool {
        guard word.contains("-") else { return false }
        let parts = word.split(separator: "-")
        guard !parts.isEmpty else { return false }
        // Typed-word protection semantics (personal words count, and so do
        // tombstoned ones — see isValidTypedWord).
        return parts.allSatisfy { model.isValidTypedWord(String($0)) }
    }

    private func isCandidateWord(_ word: String, checkMorphology: Bool) -> Bool {
        guard !model.isPersonalTombstoned(word) else { return false }
        if model.isPersonalValid(word) { return true }
        if model.icelandic.frequency(of: word) != nil { return true }
        if model.english.frequency(of: word) != nil { return true }
        if checkMorphology, model.morphology?.isKnown(word) == true { return true }
        return false
    }

    /// Diacritic/orthographic restoration pairs count as FREE in the
    /// rewrite-size measure: typing the base letter for an accent-twin
    /// (a→á lives behind long-press) or a classic orthographic slip (d→ð,
    /// t→þ, o→ö) is not a rewrite of intent — the tapped key IS (or shares)
    /// the intended key.
    static func isRestorationPair(_ x: Character, _ y: Character) -> Bool {
        SpatialModel.accentBase[x] == y
            || SpatialModel.accentBase[y] == x
            || SpatialModel.confusionPairs.contains(String(x) + String(y))
    }

    /// Restricted Damerau-Levenshtein REWRITE distance: unit costs, except
    /// restoration substitutions (see `isRestorationPair`) and apostrophe
    /// insertions (the EN fold class: dont → don't restores, it does not
    /// rewrite) are free. The intervention-size measure for the far-repair
    /// auto-apply rule — the spatial DP can't play this role (one omitted
    /// letter costs 4.0 nats while three adjacent-key substitutions cost
    /// ~3, yet the latter is the bigger, mash-shaped rewrite), and raw unit
    /// distance would count accent restorations ("godann" → "góðan") as if
    /// they were rewrites.
    static func rewriteDistance(_ a: [Character], _ b: [Character]) -> Int {
        let n = a.count
        let m = b.count
        if n == 0 { return b.filter { !apostrophes.contains($0) }.count }
        if m == 0 { return n }
        let width = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * width)
        for i in 0...n { dp[i * width] = i }
        for j in 1...m { dp[j] = dp[j - 1] + (apostrophes.contains(b[j - 1]) ? 0 : 1) }
        for i in 1...n {
            for j in 1...m {
                let subCost: Int
                if a[i - 1] == b[j - 1] || isRestorationPair(a[i - 1], b[j - 1]) {
                    subCost = 0
                } else {
                    subCost = 1
                }
                let insertCost = apostrophes.contains(b[j - 1]) ? 0 : 1
                let sub = dp[(i - 1) * width + (j - 1)] + subCost
                var best = min(
                    sub, dp[(i - 1) * width + j] + 1, dp[i * width + (j - 1)] + insertCost)
                if i >= 2, j >= 2, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1], a[i - 1] != a[i - 2] {
                    best = min(best, dp[(i - 2) * width + (j - 2)] + 1)
                }
                dp[i * width + j] = best
            }
        }
        return dp[n * width + m]
    }

    /// Spatial cost of a candidate; strict-prefix completions are charged
    /// per not-yet-typed character instead of per "insertion error".
    func spatialCost(typedChars: [Character], candidate: String) -> Double {
        let candidateChars = Array(candidate)
        var cost = spatial.typingCost(typed: typedChars, intended: candidateChars)
        if candidateChars.count > typedChars.count, candidateChars.starts(with: typedChars) {
            let extra = Double(candidateChars.count - typedChars.count)
            cost = min(cost, extra * config.completionCharCost)
        }
        return cost
    }

    /// Lane-priced channel cost of a candidate with the restoration/error
    /// decomposition (see `ChannelCost`); same strict-prefix completion
    /// shortcut as `spatialCost` — completion characters are error-class
    /// (a completion is never "restoration-only"). With a per-tap provider
    /// the DP prices substitutions from the actual tap points (the
    /// coordinate-decoding re-score); nil = static, byte-identical to the
    /// pre-coordinate engine.
    func channelCost(
        typedChars: [Character],
        candidate: String,
        pricing: FoldPricing,
        perTap: PerTapCostProvider? = nil
    ) -> ChannelCost {
        let candidateChars = Array(candidate)
        var cost =
            if let perTap {
                spatial.channelCost(
                    typed: typedChars,
                    intended: candidateChars,
                    pricing: pricing,
                    positionCosts: perTap,
                    foldEvidenceCap: config.tapFoldConfidenceMaxPenalty
                )
            } else {
                spatial.channelCost(
                    typed: typedChars, intended: candidateChars, pricing: pricing)
            }
        if candidateChars.count > typedChars.count, candidateChars.starts(with: typedChars) {
            let extra = candidateChars.count - typedChars.count
            let completion = Double(extra) * config.completionCharCost
            if completion < cost.total {
                cost = ChannelCost(total: completion, errorOps: extra, restorationOps: 0)
            }
        }
        return cost
    }

    /// Diacritic/orthographic restoration map: plain character → characters
    /// commonly intended instead on the Icelandic layout (accents live
    /// behind long-press, so users often type the base letter; d/ð and t/þ
    /// are the classic orthographic slips).
    static let restorationVariants: [Character: [Character]] = [
        "a": ["á"], "e": ["é"], "i": ["í"], "o": ["ó", "ö"], "u": ["ú"],
        "y": ["ý"], "d": ["ð"], "t": ["þ"], "v": ["ð"],
    ]

    /// All words reachable from `chars` by replacing up to `maxChanges`
    /// characters with their restoration variants (see above). Bounded and
    /// tiny: a 10-letter all-vowel word yields < 200 variants.
    static func diacriticVariants(of chars: [Character], maxChanges: Int = 3) -> [String] {
        var results: [String] = []
        var current = chars

        func recurse(from index: Int, changesLeft: Int) {
            guard changesLeft > 0 else { return }
            for i in index..<current.count {
                guard let variants = Self.restorationVariants[current[i]] else { continue }
                let original = current[i]
                for variant in variants {
                    current[i] = variant
                    results.append(String(current))
                    recurse(from: i + 1, changesLeft: changesLeft - 1)
                }
                current[i] = original
            }
        }
        recurse(from: 0, changesLeft: maxChanges)
        return results
    }

    /// Bases reachable by removing one letter of a doubled pair ("nogg" →
    /// "nog"). Shared by the gemination pass and the gemination+accent
    /// composition pass (2c).
    static func dedoubledVariants(of chars: [Character]) -> [[Character]] {
        let n = chars.count
        guard n >= 2 else { return [] }
        var dedoubled: [[Character]] = []
        for i in 0..<(n - 1) where chars[i] == chars[i + 1] {
            var copy = chars
            copy.remove(at: i)
            dedoubled.append(copy)
        }
        return dedoubled
    }

    /// Gemination-error variants: remove one letter of a doubled pair,
    /// double an existing letter, or both (in that order — covering
    /// "tommorow"→"tomorrow" in one targeted pass).
    static func geminationVariants(of chars: [Character]) -> [String] {
        let n = chars.count
        guard n >= 2 else { return [] }
        let dedoubled = Self.dedoubledVariants(of: chars)
        var results: [String] = dedoubled.map { String($0) }
        func doubling(_ base: [Character], into results: inout [String]) {
            for i in 0..<base.count where i == 0 || base[i] != base[i - 1] {
                var copy = base
                copy.insert(base[i], at: i)
                results.append(String(copy))
            }
        }
        doubling(chars, into: &results)
        for base in dedoubled {
            doubling(base, into: &results)
        }
        return results
    }

    /// All strings at Damerau-Levenshtein distance 1 from `chars`, each with
    /// the spatial cost of the single edit that produced it (minimum across
    /// generation paths), O(1) cost per string. Used where candidates must
    /// be tested against NON-enumerable vocabularies the beam cannot walk:
    /// personal words and BÍN morphology (step 1b), split-half repairs,
    /// and the single-word-repair probe.
    static func edits1Costed(
        of chars: [Character], spatial: SpatialModel
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(chars.count * 2 * (alphabet.count + 1))

        func admit(_ word: [Character], _ cost: Double) {
            let key = String(word)
            if let existing = out[key], existing <= cost { return }
            out[key] = cost
        }

        let n = chars.count
        let costs = spatial.costs
        // deletions (the user typed an extra, unintended character)
        for i in 0..<n {
            var copy = chars
            copy.remove(at: i)
            admit(copy, costs.insertion)
        }
        // transpositions
        if n >= 2 {
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var copy = chars
                copy.swapAt(i, i + 1)
                admit(copy, costs.transposition)
            }
        }
        // substitutions
        for i in 0..<n {
            for ch in alphabet where ch != chars[i] {
                var copy = chars
                copy[i] = ch
                admit(copy, spatial.substitutionCost(typed: chars[i], intended: ch))
            }
        }
        // insertions (the user omitted a character they intended)
        for i in 0...n {
            for ch in alphabet {
                var copy = chars
                copy.insert(ch, at: i)
                admit(copy, costs.deletion)
            }
        }
        return out
    }

}
