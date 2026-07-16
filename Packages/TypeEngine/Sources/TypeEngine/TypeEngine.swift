import Foundation
import LemmaCore
import Lexicon

extension BinaryLemmatizer: MorphologyProviding {
    /// Inflection-backoff fallback (PLAN.md Stage B #1): cases of the
    /// word's noun/adjective analyses via `lemmatizeWithMorph` (v2 morph
    /// section; empty on v1 binaries, which simply disables the fallback).
    public func nounAdjectiveCases(of word: String) -> [String] {
        lemmatizeWithMorph(word).compactMap { analysis in
            guard analysis.pos == "no" || analysis.pos == "lo" else { return nil }
            return analysis.morph?.grammaticalCase
        }
    }

    /// Distinct lemma candidates (`lemmatize` semantics without the
    /// unknown-word echo): the personal lemma lift's unambiguity gate.
    public func lemmaCandidates(of word: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in lemmatizeWithPOS(word) where seen.insert(entry.lemma).inserted {
            result.append(entry.lemma)
        }
        return result
    }
}

/// Production paradigms conformance: the mmap reader over
/// `data/is/paradigms.bin` (LemmaCore) already exposes exactly the two
/// lookups the engine seam needs.
extension ParadigmsReader: ParadigmsProviding {}

/// Facade over the corrector and predictor with a running bilingual language
/// posterior. Pure synchronous API — no dispatch/async inside; the caller
/// owns threading. Not thread-safe (confirmWord mutates the posterior); use
/// from a single queue.
public final class TypeEngine {
    public let config: EngineConfig

    private let model: BlendedLanguageModel
    private let corrector: Corrector
    private let predictor: Predictor

    /// Lane posterior P(lane = Icelandic): the forward probability of the
    /// two-state IS/EN switching model over committed words, clamped to
    /// [posteriorFloor, posteriorCeiling] so it never saturates. Starts at
    /// the neutral 0.5 prior.
    public private(set) var probabilityIcelandic: Double

    /// Production initializer: BÍN morphology via LemmaCore.
    public convenience init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: BinaryLemmatizer?,
        config: EngineConfig = EngineConfig()
    ) {
        self.init(
            icelandic: icelandic,
            english: english,
            morphologyProvider: morphology,
            config: config
        )
    }

    /// Designated initializer; accepts any MorphologyProviding (tests use a
    /// dictionary-backed fake).
    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphologyProvider: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        let model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphologyProvider,
            config: config,
            personal: PersonalStore()
        )
        self.model = model
        self.corrector = Corrector(model: model, config: config)
        self.predictor = Predictor(model: model, config: config)
        self.probabilityIcelandic = 0.5
    }

    // MARK: - Personal vocabulary (M2 learning)

    /// Inject (or clear) the personal-learning snapshot. Cheap O(personal
    /// scale) index rebuild — no recalibration, no engine rebuild — so the
    /// embedder can swap freely whenever the model file changes on disk.
    /// Must be called on the queue that owns this engine (same confinement
    /// contract as every other engine call); the in-session learned overlay
    /// survives the swap (a fresh snapshot may or may not already contain
    /// those words — double counting is bounded and harmless for a boost).
    public func setPersonalVocabulary(_ vocabulary: PersonalVocabulary?) {
        model.personal.setSnapshot(vocabulary)
        rebuildLemmaLift()
    }

    /// Session-immediate learning: make `word` valid + suggestible RIGHT NOW
    /// (verbatim tap / explicit learn signals must not wait for the app's
    /// compaction). The overlay lives until `clearSessionVocabulary()`.
    public func learnSessionWord(_ word: String) {
        model.personal.learnSession(word)
        rebuildLemmaLift()
    }

    /// Drop the in-session learned overlay (session reset).
    public func clearSessionVocabulary() {
        model.personal.clearSession()
        rebuildLemmaLift()
    }

    // MARK: - Inflection intelligence (PLAN.md "Inflection intelligence")

    /// Inject (or clear) the Stage-B inflection artifacts (paradigms.bin
    /// reader + governors model). Absent by default: every inflection seam
    /// is inert and the engine is byte-identical to the pre-inflection one.
    /// Same queue-confinement contract as every other engine call.
    public func setInflection(_ inflection: InflectionModel?) {
        model.inflection.setModel(inflection)
        rebuildLemmaLift()
    }

    /// Rebuild the personal lemma lift (paradigm-sibling boost) from the
    /// current personal vocabulary. Runs on snapshot/model swaps and
    /// explicit learns — personal scale × paradigm size, never per
    /// keystroke.
    private func rebuildLemmaLift() {
        model.inflection.rebuildLift(
            words: model.personal.allValidKeys,
            morphology: model.morphology,
            liftNats: config.lemmaLiftBoost
        )
    }

    /// Case-government diagnostics for a word acting as a GOVERNOR (REPL
    /// `:gov`): (mass, P(case | word) sorted descending); nil when no
    /// inflection model is loaded or the word is not a governor.
    public func governorDiagnostics(for word: String)
        -> (mass: Double, entropyRatio: Double, cases: [(name: String, p: Double)])?
    {
        guard
            let governor = model.inflection.model?.governors.governor(of: word.lowercased())
        else { return nil }
        let cases = ParadigmBundle.caseNames.enumerated()
            .map { (name: $1, p: governor.caseProbabilities[$0]) }
            .filter { $0.p > 0 }
            .sorted { $0.p > $1.p }
        return (mass: governor.mass, entropyRatio: governor.caseEntropyRatio, cases: cases)
    }

    /// Diagnostics (REPL `:learned`, tests): canonical surfaces of the
    /// injected snapshot's words, sorted.
    public var personalSnapshotWords: [String] { model.personal.snapshotWords }

    /// Diagnostics: words learned in this session (overlay), sorted.
    public var sessionLearnedWords: [String] { model.personal.sessionWords }

    /// Whether `word` is currently valid personal vocabulary (snapshot or
    /// session overlay), case-insensitively.
    public func isPersonalWord(_ word: String) -> Bool {
        model.personal.isValidWord(word)
    }

    /// Suggestions for the suggestion bar.
    ///
    /// - Parameters:
    ///   - context: committed text before the current word (used only for the
    ///     trailing word, as bigram context)
    ///   - currentWord: the word being typed; empty string means "predict the
    ///     next word"
    ///   - limit: maximum suggestions returned
    ///   - deliberateCharacters: characters of the current word that were
    ///     entered via long-press/callout (the strongest deliberateness
    ///     signal — vetoes lane-relaxation folding for this word; see
    ///     `Corrector.correct` and `TypingSession.noteLongPressInsertion`)
    ///   - taps: per-position touch samples aligned with `currentWord`
    ///     (PLAN.md "Touch decoding", stage 1; see `Corrector.correct`).
    ///     Empty = static spatial pricing, unchanged.
    public func suggestions(
        context: String,
        currentWord: String,
        limit: Int = 3,
        deliberateCharacters: [Character] = [],
        taps: [TapSample?] = []
    ) -> [Suggestion] {
        let previous = Self.lastWord(in: context)
        let trimmed = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return restorePersonalSurfaces(
                predictor.nextWords(
                    previousWord: previous,
                    pIcelandic: probabilityIcelandic,
                    limit: limit
                )
            )
        }

        let result = corrector.correct(
            typed: trimmed,
            previousWord: previous,
            pIcelandic: probabilityIcelandic,
            limit: limit,
            deliberateCharacters: deliberateCharacters,
            taps: taps.count == trimmed.count ? taps : []
        )
        var suggestions = restorePersonalSurfaces(result.suggestions)

        // Preserve the user's leading capitalization.
        if let first = trimmed.first, first.isUppercase {
            suggestions = suggestions.map {
                Suggestion(
                    text: $0.text.prefix(1).uppercased() + $0.text.dropFirst(),
                    isAutocorrect: $0.isAutocorrect,
                    confidence: $0.confidence,
                    isRestoration: $0.isRestoration
                )
            }
        }
        // An "autocorrect" into the byte-identical typed text is a no-op
        // and must not be flagged (surfaces via the case-insensitive
        // pipeline: typed "I" → the lone-i capitalization suggestion "I").
        return suggestions.map {
            $0.isAutocorrect && $0.text == trimmed
                ? Suggestion(
                    text: $0.text, isAutocorrect: false, confidence: $0.confidence,
                    isRestoration: $0.isRestoration)
                : $0
        }
    }

    /// Dotted-token space-miss escape (PLAN.md "Space-miss correction" +
    /// verbatim/URL layers; dogfood "sem.er"): the "left right" reading of
    /// a word.word token whose SHAPE already passed TypingSession's URL
    /// checks. Returns nil unless both halves are common attested words in
    /// one common language; `isAutocorrect` follows the strict split rules
    /// (see `Corrector.dotSplitSuggestion`).
    public func dottedSpaceMiss(left: String, right: String, context: String) -> Suggestion? {
        let previous = Self.lastWord(in: context)
        guard
            let suggestion = corrector.dotSplitSuggestion(
                left: left.lowercased(),
                right: right.lowercased(),
                previousWord: previous,
                pIcelandic: probabilityIcelandic
            )
        else { return nil }
        // Preserve the user's leading capitalization ("Sem.er" → "Sem er").
        if let first = left.first, first.isUppercase {
            return Suggestion(
                text: suggestion.text.prefix(1).uppercased() + suggestion.text.dropFirst(),
                isAutocorrect: suggestion.isAutocorrect,
                confidence: suggestion.confidence
            )
        }
        return suggestion
    }

    /// Personal surface forms are byte-exact and case-preserving
    /// ("Miðeind") while the correction/prediction pipeline works in
    /// lowercase — restore the canonical personal casing on the way out.
    private func restorePersonalSurfaces(_ suggestions: [Suggestion]) -> [Suggestion] {
        suggestions.map { suggestion in
            guard let surface = model.personal.displaySurface(of: suggestion.text) else {
                return suggestion
            }
            return Suggestion(
                text: surface,
                isAutocorrect: suggestion.isAutocorrect,
                confidence: suggestion.confidence,
                isRestoration: suggestion.isRestoration
            )
        }
    }

    /// Update the language posterior after the user commits a word
    /// (typed through, tapped a suggestion, or accepted an autocorrect).
    ///
    /// One forward step of the two-lane (IS/EN) switching model — typing is
    /// either Icelandic-with-slettur or English, lanes are sticky but not
    /// strict (PLAN.md "Bilingual blending — lane model"):
    ///
    ///   predict: p' = (1-s)·p + s·(1-p)          s = laneSwitchProbability
    ///   update:  p  = p'·e_IS / (p'·e_IS + (1-p')·e_EN)
    ///
    /// where log(e_IS/e_EN) is the word's graded emission evidence from the
    /// calibrated per-lexicon z-scores (see BlendedLanguageModel.laneEvidence).
    /// The capped evidence + low switch prior make one sletta a bounded
    /// nudge (the lane holds) while 2–3 consecutive off-lane words flip it.
    /// Words with no attributable evidence (OOV, junk-tier like "dont" in
    /// is.lex web noise, ambiguous both-lexicon words) have ~uniform
    /// emissions: they only apply the predict step, i.e. a gentle decay of
    /// the lane toward neutral — never a drag toward either language.
    public func confirmWord(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }

        let s = config.laneSwitchProbability
        let predicted = (1 - s) * probabilityIcelandic + s * (1 - probabilityIcelandic)
        let evidence = model.laneEvidence(of: w)
        let odds = (predicted / (1 - predicted)) * exp(evidence)
        let updated = odds / (1 + odds)
        probabilityIcelandic = min(max(updated, config.posteriorFloor), config.posteriorCeiling)
    }

    /// Relax the lane posterior toward the neutral 0.5 prior across a
    /// sentence boundary (". ", "!", "?"): sheds laneBoundaryDecay of the
    /// distance to neutral — the lane weakens with discourse distance but
    /// does not reset. TypingSession calls this when a committed word's
    /// trailing delimiter is a sentence terminator.
    public func noteSentenceBoundary() {
        let decay = config.laneBoundaryDecay
        probabilityIcelandic = 0.5 + (probabilityIcelandic - 0.5) * (1 - decay)
    }

    /// Lane-model diagnostics for a word (REPL `:word` command): per-lexicon
    /// attestation + calibrated z-scores, BÍN morphology validity, and the
    /// resulting emission evidence log(e_IS/e_EN) in nats (0 = uniform,
    /// does not move the lane).
    public func laneDiagnostics(for word: String)
        -> (
            frequencyIS: UInt32?, frequencyEN: UInt32?, zIS: Double, zEN: Double,
            binKnown: Bool, evidence: Double
        )
    {
        let w = word.lowercased()
        return (
            frequencyIS: model.icelandic.frequency(of: w),
            frequencyEN: model.english.frequency(of: w),
            zIS: model.calibratedUnigramScore(of: w, language: .icelandic),
            zEN: model.calibratedUnigramScore(of: w, language: .english),
            binKnown: model.morphology?.isKnown(w) == true,
            evidence: model.laneEvidence(of: w)
        )
    }

    /// Touch representative pages of the mmap-ed artifacts (spread unigram,
    /// bigram and morphology lookups) so first keystrokes don't pay page
    /// faults. Call once after load, on the same queue that owns the engine.
    public func warmUp() {
        model.warmUp()
    }

    /// Reset the lane posterior to the neutral 50/50 prior — the full-decay
    /// case of the boundary relaxation (new text field, session reset).
    public func resetLanguagePosterior() {
        probabilityIcelandic = 0.5
    }

    // MARK: - Internals

    /// Trailing word of the committed context, lowercased and stripped of
    /// surrounding punctuation; nil if there is none.
    static func lastWord(in context: String) -> String? {
        guard
            let token = context
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .last
        else { return nil }
        let stripped = token.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.symbols)
        )
        guard !stripped.isEmpty else { return nil }
        return stripped.lowercased()
    }
}
