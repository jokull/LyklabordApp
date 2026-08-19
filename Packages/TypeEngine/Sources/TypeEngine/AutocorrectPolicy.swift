import Foundation

/// Everything the action/safety layer may inspect after ranking is complete.
///
/// Keeping this boundary explicit prevents policy tuning from reaching back
/// into candidate generation or score assembly. Values use copy-on-write
/// storage, so constructing the input does not duplicate candidate buffers.
struct AutocorrectPolicyInput {
    let typed: String
    let typedChars: [Character]
    let deliberate: [Character]
    let previousWord: String?
    let contextPrev: String?
    let pIcelandic: Double
    let capitalizedMidSentence: Bool
    let typedIsValid: Bool
    let typedIsProtected: Bool
    let typedCompoundSplit: CompoundSplit?
    let perTap: PerTapCostProvider?
    let pricing: FoldPricing
    let candidates: CandidateAdmissionPool
    let speculativeCompletions: Set<String>
    let mashRecoveryAdmissions: Set<String>
    let foldedMorphologyAdmissions: Set<String>
    let scored: [RankedCandidate]
}

extension Corrector {
    /// Decide whether the already-ranked winner may be applied automatically.
    ///
    /// This method intentionally owns only the action decision and its trace
    /// gates. It must not mutate candidate scores, ordering, or admission.
    func decideAutocorrect(
        input: AutocorrectPolicyInput,
        trace: CorrectionTrace?
    ) -> Bool {
        let action = config.domains.action
        let typed = input.typed
        let typedChars = input.typedChars
        let deliberate = input.deliberate
        let previousWord = input.previousWord
        let contextPrev = input.contextPrev
        let pIcelandic = input.pIcelandic
        let capitalizedMidSentence = input.capitalizedMidSentence
        let typedIsValid = input.typedIsValid
        let typedIsProtected = input.typedIsProtected
        let typedCompoundSplit = input.typedCompoundSplit
        let perTap = input.perTap
        let pricing = input.pricing
        let candidates = input.candidates
        let speculativeCompletions = input.speculativeCompletions
        let mashRecoveryAdmissions = input.mashRecoveryAdmissions
        let foldedMorphologyAdmissions = input.foldedMorphologyAdmissions
        let scored = input.scored

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
            let lengthOK = typedChars.count >= action.minAutocorrectLength
            let costOK = best.cost.total <= action.autocorrectMaxSpatialCost
            let apostrophesOK = Self.preservesApostrophes(of: typed, in: best.word)
            let quotationsOK = Self.preservesQuotationMarks(of: typed, in: best.word)
            let deliberateOK = Self.preservesDeliberateCharacters(
                deliberate, of: typedChars, in: best.word)
            let preconditionsOK =
                lengthOK && costOK && apostrophesOK && quotationsOK && deliberateOK
            // Linking-letter yield (wave 31, the framhaldskóla class): the
            // typed word is protected ONLY by an accidental compound
            // reading (framhald+skóla), while the winner is an is.lex-
            // ATTESTED whole word exactly one genitive linking letter
            // (bandstafur) away at the decomposition boundary
            // (framhaldsskóla). A hypothesized decomposition must not
            // shield the corpus's most common real compound error from the
            // ordinary margin/typicality gates — attested whole-word
            // evidence outranks the hypothesis, mirroring Miðeind's
            // whole-word-lookup-first order. Splits and restoration-only
            // winners are untouched; lexicon-valid typed words never reach
            // this (typedIsValid short-circuits the compound analysis).
            let linkingYield =
                action.compoundLinkingRepairYieldEnabled
                && !typedIsValid
                && !best.word.contains(" ")
                && typedCompoundSplit.map {
                    model.icelandic.frequency(of: best.word) != nil
                        && Self.isLinkingLetterRepair(
                            typedChars: typedChars, candidate: best.word, split: $0)
                } ?? false
            let effectiveProtected = typedIsProtected && !linkingYield
            if linkingYield {
                trace?.note(
                    "compound protection YIELDS: winner \"\(best.word)\" is an attested"
                        + " linking-letter repair at the decomposition boundary")
            }
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
                    !effectiveProtected && best.word.contains(" ")
                    ? "split"
                    : !effectiveProtected
                        ? "ordinary-unknown"
                        : best.cost.isRestorationOnly && !best.word.contains(" ")
                            && deliberate.isEmpty
                            ? "skeleton-restoration" : "valid-word (no auto-apply path)"
                if !lengthOK {
                    trace.gate(
                        "minAutocorrectLength",
                        "typed length \(typedChars.count) < \(action.minAutocorrectLength)",
                        pass: false)
                }
                if !costOK {
                    trace.gate(
                        "autocorrectMaxSpatialCost",
                        "best cost \(String(format: "%.3f", best.cost.total))"
                            + " > \(action.autocorrectMaxSpatialCost)",
                        pass: false)
                }
                if !apostrophesOK { trace.gate("preservesApostrophes", "candidate drops a typed apostrophe", pass: false) }
                if !quotationsOK { trace.gate("preservesQuotationMarks", "candidate drops a typed quotation mark", pass: false) }
                if !deliberateOK { trace.gate("preservesDeliberateCharacters", "candidate drops a long-pressed character", pass: false) }
            }
            if preconditionsOK, !effectiveProtected, best.word.contains(" ") {
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
                let marginOK = margin >= action.splitAutocorrectMargin * tapMarginFactor
                let noSingleRepair = bestSingleCost > action.splitAutoApplySingleWordCutoff
                if let trace {
                    trace.requiredMargin = action.splitAutocorrectMargin
                    trace.gate(
                        "splitMargin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(action.splitAutocorrectMargin) x \(String(format: "%.2f", tapMarginFactor))",
                        pass: marginOK)
                    trace.gate(
                        "noSingleWordRepair",
                        "best attested single-word cost \(String(format: "%.3f", bestSingleCost))"
                            + " > cutoff \(action.splitAutoApplySingleWordCutoff)",
                        pass: noSingleRepair)
                }
                autocorrect = marginOK && noSingleRepair
            } else if preconditionsOK, !effectiveProtected {
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
                let farRepair = rewrite >= action.autocorrectFarRepairEdits
                let foldedMorphologyEvidence =
                    foldedMorphologyAdmissions.contains(best.word)
                    && best.cost.restorationOps >= 1
                    && best.cost.errorOps <= 1
                    && rewrite <= 1
                let foldedMorphologyArming =
                    action.foldedMorphologyAutocorrectEnabled
                    && foldedMorphologyEvidence
                    && pIcelandic >= action.foldedMorphologyAutocorrectMinPosterior
                let deepShortFoldWinner = isDeepShortAcuteFold(
                    typed: typed,
                    candidate: best.word,
                    pIcelandic: pIcelandic,
                    deliberate: deliberate)
                // Short-token discipline (dogfood "eg"/"vð", 2026-07-16):
                // a 2-letter token carries almost no spatial evidence, so
                // auto-apply demands a headline-vocabulary winner (ég, við
                // — the words people actually mean) via the raised floor.
                let short = typedChars.count <= action.autocorrectShortLengthMax
                // Archaic-twin restoration (wave 32, dogfood "þu"/"eg"):
                // a restoration-only winner that is the typed skeleton's
                // DOMINANT acute-fold twin (wave-26 shadow probe — ratio,
                // noise-tier and English-reading gates all inside) earns
                // the relaxed short floor below: the acute vowel has no
                // key, so the typed skeleton IS the twin's lazy spelling
                // and the headline bar over-demands ("þú" +1.482 sat
                // 0.02σ under it). Only for tokens attested NOWHERE —
                // valid skeletons (nu, sa, ja, for) never reach this
                // branch at all (skeleton-collision triple gate).
                let archaicTwinWinner =
                    action.archaicTwinRestorationEnabled && short
                    && best.cost.isRestorationOnly
                    && model.acuteFoldShadowTwin(of: typed) == best.word
                var minZ =
                    farRepair
                    ? max(action.autocorrectMinZ, action.autocorrectFarRepairMinZ)
                    : action.autocorrectMinZ
                if short {
                    minZ = max(
                        minZ,
                        deepShortFoldWinner
                            ? action.deepShortFoldMinZ
                            : archaicTwinWinner
                                ? action.archaicTwinShortMinZ : action.autocorrectShortMinZ)
                }
                // Contextual lift of winner and runner-up in the posterior-
                // dominant lane (wave 27) — the bigram-evidence currency
                // for the margin relief and the context-short floor below.
                let marginLane: Language = pIcelandic >= 0.5 ? .icelandic : .english
                let winnerLift = model.contextualLift(
                    of: best.word, previous: contextPrev, language: marginLane)
                let runnerUpLift =
                    scored.count > 1
                    ? model.contextualLift(
                        of: scored[1].word, previous: contextPrev, language: marginLane)
                    : nil
                // Context-backed 3-letter discipline (dogfood "vli" → false
                // "vil" fire): an error-class rewrite of a 3-letter token
                // needs a headline-typicality winner unless the bigram with
                // the previous word genuinely vouches for it (lift at/above
                // the floor). Only when a previous word EXISTS — the rule
                // is "the context was consulted and declined to vouch";
                // with no context (sentence-initial) the pre-wave rules
                // stand unchanged. Restoration-only winners keep their own
                // gate stack.
                let contextShort =
                    !short && typedChars.count <= action.autocorrectContextLengthMax
                    && !best.cost.isRestorationOnly
                    && contextPrev != nil
                let contextShortUnvouched =
                    contextShort
                    && (winnerLift ?? -.infinity) < action.autocorrectContextLiftFloor
                if contextShortUnvouched {
                    minZ = max(minZ, action.autocorrectContextShortMinZ)
                }
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
                    ? action.restorationAutoApplyMargin
                    : action.autocorrectMargin
                if deepShortFoldWinner {
                    requiredMargin = min(
                        requiredMargin, action.deepShortFoldAutoApplyMargin)
                }
                if foldedMorphologyArming {
                    requiredMargin = min(
                        requiredMargin, action.foldedMorphologyAutocorrectMargin)
                }
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
                    !restorationRelaxed && !foldedMorphologyArming
                    && typicality < action.autocorrectJunkWinnerZ
                if junkWinner {
                    requiredMargin *= action.autocorrectJunkWinnerMarginScale
                }
                // Bigram-dominance margin relief (wave 27, dogfood "son
                // minn ég gret"): when the winner carries strong contextual
                // lift and the runner-up carries none (bigram unattested or
                // non-positive lift), direct corpus evidence of the typed
                // pair separates the top two — the margin bar drops by
                // `bigramMarginRelief`. Junk-tier winners never get relief
                // (the junk margin scaling stays intact).
                let bigramRelief =
                    !junkWinner
                    && (winnerLift ?? -.infinity) >= action.bigramMarginReliefMinLift
                    && (runnerUpLift ?? -.infinity) <= 0
                if bigramRelief {
                    requiredMargin *= action.bigramMarginRelief
                }
                var marginOK = margin >= requiredMargin * tapMarginFactor
                var typicalityOK = typicality >= minZ || foldedMorphologyArming
                // Vacuum auto-apply (dogfood "stökklrikanum" wave): a
                // BÍN-valid winner below the typicality floor may still
                // fire when the pool holds NO attested-or-personal repair
                // within the close-candidate bound — with no attested
                // competition, the morphologically valid word one cheap
                // edit away beats leaving the typo. Stricter margin; far
                // repairs keep the hard attested-common rule (mash never
                // becomes BÍN junk).
                var vacuum = false
                if action.vacuumAutoApplyEnabled,
                    !typicalityOK, !farRepair, !short,
                    model.morphology?.isKnown(best.word) == true,
                    bestAttestedCost(in: candidates.costs, excluding: speculativeCompletions)
                        > action.closeCandidateGate
                {
                    vacuum = true
                    typicalityOK = true
                    marginOK =
                        margin >= max(requiredMargin, action.vacuumAutoApplyMargin)
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
                if action.properNounGuardEnabled, capitalizedMidSentence,
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
                    if foldedMorphologyEvidence {
                        let enabled = action.foldedMorphologyAutocorrectEnabled
                        let laneOK =
                            pIcelandic >= action.foldedMorphologyAutocorrectMinPosterior
                        trace.gate(
                            "folded-morphology-arming",
                            "structured BÍN hit; enabled=\(enabled), P(IS) "
                                + String(format: "%.3f", pIcelandic)
                                + " >= "
                                + String(
                                    format: "%.3f",
                                    action.foldedMorphologyAutocorrectMinPosterior),
                            pass: enabled && laneOK)
                    }
                    if action.properNounGuardEnabled, capitalizedMidSentence, !properNounOK {
                        trace.gate(
                            "proper-noun-possessive-guard",
                            "capitalized mid-sentence Name+s with unattested stem;"
                                + " error-class auto-apply suppressed",
                            pass: false)
                    }
                }
                if let trace {
                    trace.requiredMargin =
                        vacuum ? max(requiredMargin, action.vacuumAutoApplyMargin) : requiredMargin
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
                                + " < \(String(format: "%+.2f", action.autocorrectJunkWinnerZ)))"
                                + " -> margin x\(String(format: "%.1f", action.autocorrectJunkWinnerMarginScale))")
                    }
                    if bigramRelief {
                        trace.note(
                            "bigram-dominance relief: winner lift "
                                + "\(String(format: "%+.2f", winnerLift ?? 0))"
                                + " vs runner-up "
                                + (runnerUpLift.map { String(format: "%+.2f", $0) } ?? "none")
                                + " -> margin x\(String(format: "%.2f", action.bigramMarginRelief))")
                    }
                    if contextShortUnvouched {
                        trace.note(
                            "context-short token (len \(typedChars.count)) without bigram vouch"
                                + " (winner lift "
                                + (winnerLift.map { String(format: "%+.2f", $0) } ?? "none")
                                + ") -> minZ raised to "
                                + String(format: "%+.2f", action.autocorrectContextShortMinZ))
                    }
                    trace.gate(
                        "margin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(String(format: "%.3f", vacuum ? max(requiredMargin, action.vacuumAutoApplyMargin) : requiredMargin))"
                            + " x \(String(format: "%.2f", tapMarginFactor))"
                            + (vacuum ? " (vacuum margin)" : ""),
                        pass: marginOK)
                    trace.gate(
                        "typicality",
                        "winner z \(typicality == .infinity ? "personal" : String(format: "%+.3f", typicality))"
                            + " >= minZ \(String(format: "%+.3f", minZ))"
                            + (foldedMorphologyArming
                                ? " (waived: structured folded-BÍN evidence)" : "")
                            + (farRepair ? " (far-repair floor)" : "")
                            + (short
                                ? deepShortFoldWinner
                                    ? " (deep-IS short-fold floor)"
                                    : archaicTwinWinner
                                        ? " (archaic-twin floor)" : " (short-token floor)"
                                : ""),
                        pass: typicalityOK)
                }
                if let trace, shortCompletion {
                    trace.gate(
                        "short-completion",
                        "short token; winner \"\(best.word)\" is a strict-prefix"
                            + " completion — never auto-expanded",
                        pass: false)
                }
                // Mash-recovery fire suppression (wave 30): a winner only
                // the WIDENED multi-edit cone admitted, whose exact DP cost
                // sits above the ordinary `beamMultiEditCostCap`, was
                // structurally unpoolable pre-wave — widening the search
                // fills an otherwise-empty bar with OFFERS, it must not
                // widen the calibrated set of auto-applies (the dev A/B
                // showed exactly this leak: 4 wrong fires in the 5.0–6.0
                // band, ráðherra-from-raðvherfa class). Winners the
                // ordinary cone could also have reached (DP cost at or
                // under the cap, e.g. eitthvað at 3.06) keep every fire
                // rule unchanged.
                let mashOfferOnly =
                    mashRecoveryAdmissions.contains(best.word)
                    && best.cost.total > action.beamMultiEditCostCap
                if let trace, mashOfferOnly {
                    trace.gate(
                        "mash-recovery-offer-only",
                        "winner admitted only by the widened mash-recovery cone"
                            + " at cost \(String(format: "%.3f", best.cost.total))"
                            + " > beamMultiEditCostCap \(action.beamMultiEditCostCap)"
                            + " — offer, never auto-apply",
                        pass: false)
                }
                autocorrect =
                    marginOK && typicalityOK && properNounOK && !shortCompletion
                    && !mashOfferOnly
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
                let deepShortFoldWinner = isDeepShortAcuteFold(
                    typed: typed,
                    candidate: best.word,
                    pIcelandic: pIcelandic,
                    deliberate: deliberate)
                let requiredMargin =
                    deepShortFoldWinner
                    ? min(
                        action.restorationAutoApplyMargin,
                        action.deepShortFoldAutoApplyMargin)
                    : action.restorationAutoApplyMargin
                let marginOK = margin >= requiredMargin * tapMarginFactor
                if let trace {
                    trace.requiredMargin = requiredMargin
                    trace.gate(
                        "margin",
                        "margin \(String(format: "%.3f", margin))"
                            + " >= \(requiredMargin)"
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

        return autocorrect
    }
}
