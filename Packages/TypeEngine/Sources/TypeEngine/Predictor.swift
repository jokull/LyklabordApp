import Foundation
import Lexicon

/// Next-word and mid-word prediction from bigram tables of both lexicons,
/// blended by the language posterior, with unigram fallback.
///
/// Candidate pooling: next-word candidates are the bigram FOLLOWERS of the
/// previous word (`Lexicon.continuations(of:limit:)`) from both lexicons,
/// so rare-but-strongly-bound followers surface. When no followers exist
/// (no context, unknown previous word, or a lexicon that doesn't implement
/// continuations — the protocol's default returns []), the pool degrades to
/// the top unigrams of each lexicon (`completions(of: "", ...)`), which is
/// the old behavior.
public struct Predictor {
    let model: BlendedLanguageModel
    let config: EngineConfig

    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        self.model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config
        )
    }

    init(model: BlendedLanguageModel, config: EngineConfig) {
        self.config = config
        self.model = model
    }

    /// Next-word suggestions after `previousWord` (nil at sentence start).
    public func nextWords(
        previousWord: String?,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }
        var pool = Set<String>()
        if let previousWord {
            for lexicon in [model.icelandic, model.english] {
                for entry in lexicon.continuations(of: previousWord, limit: config.continuationPoolLimit) {
                    pool.insert(entry.word)
                }
            }
            // Personal bigram followers join the SAME pool ("blend, don't
            // hard-prepend"): ranking is the shared blendedScore, where the
            // personal pair earns its `personalBigramBoost*` prior — enough
            // to outrank base continuations in proportion to how often the
            // user actually typed the pair, never unconditionally.
            for entry in model.personal.continuations(
                of: previousWord, limit: config.personalContinuationPoolLimit)
            {
                pool.insert(entry.word)
            }
        }
        if pool.isEmpty {
            // No bigram followers anywhere: top-unigram fallback.
            for lexicon in [model.icelandic, model.english] {
                for entry in lexicon.completions(of: "", limit: config.unigramPoolLimit) {
                    pool.insert(entry.word)
                }
            }
            for entry in model.personal.completions(of: "", limit: config.personalContinuationPoolLimit) {
                pool.insert(entry.word)
            }
        }
        return rank(pool: pool, previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
    }

    /// Mid-word: completions of the current prefix, re-ranked by bigram
    /// context with the previous word.
    public func completions(
        of prefix: String,
        previousWord: String?,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> [Suggestion] {
        guard limit > 0, !prefix.isEmpty else {
            return nextWords(previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
        }
        let lowered = prefix.lowercased()
        var pool = Set<String>()
        for lexicon in [model.icelandic, model.english] {
            for entry in lexicon.completions(of: lowered, limit: config.unigramPoolLimit) {
                pool.insert(entry.word)
            }
        }
        for entry in model.personal.completions(of: lowered, limit: config.personalCompletionPoolLimit) {
            pool.insert(entry.word)
        }
        return rank(pool: pool, previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
    }

    private func rank(
        pool: Set<String>,
        previousWord: String?,
        pIcelandic: Double,
        limit: Int
    ) -> [Suggestion] {
        // Tombstoned words are never predicted, base-lexicon presence
        // notwithstanding (PLAN.md learning semantics).
        let pool = pool.filter { !model.isPersonalTombstoned($0) }
        // Inflection-aware prediction (PLAN.md Stage B #3): after a governor
        // with a strong case signature, candidates matching the expected
        // case earn the same λ_morph backoff the corrector uses — and under
        // the same backoff rule: bigram-attested continuations already
        // carry the case signal (that's how the governors table was built),
        // so only bigram-SILENT pool members (personal words, unigram
        // fallback, cross-lexicon candidates) are re-ranked by it.
        let governorFit = model.inflection.governorFit(
            previousWord: previousWord,
            pIcelandic: pIcelandic,
            morphology: model.morphology,
            config: config
        )
        var scored: [(word: String, score: Double)] = pool.map { word in
            var s = model.blendedScore(of: word, previous: previousWord, pIcelandic: pIcelandic)
            if let fit = governorFit,
                model.icelandic.bigramFrequency(fit.previousWord, word) == nil
            {
                s += fit.fitNats(for: word)
            }
            return (word, s)
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }

        let confidencePool = scored.prefix(8)
        let maxScore = confidencePool.first?.score ?? 0
        let z = confidencePool.reduce(0.0) { $0 + exp($1.score - maxScore) }

        return scored.prefix(limit).map { entry in
            Suggestion(
                text: entry.word,
                isAutocorrect: false,  // predictions never auto-replace
                confidence: z > 0 ? exp(entry.score - maxScore) / z : 0
            )
        }
    }
}
