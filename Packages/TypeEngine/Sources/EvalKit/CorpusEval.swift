import Foundation
import TypeEngine

/// Aggregate counts for a slice of corpus pairs (a category, a language, or
/// the whole split). All integers — deterministic given commit + data +
/// engine, so a scorecard line is reproducible (no floating-point drift in
/// the committed history).
public struct CorpusTally: Sendable, Equatable {
    public var total = 0
    public var top1 = 0
    public var top3 = 0
    public var autocorrectFired = 0
    public var falseAutocorrect = 0

    public init() {}

    public mutating func add(_ other: CorpusTally) {
        total += other.total
        top1 += other.top1
        top3 += other.top3
        autocorrectFired += other.autocorrectFired
        falseAutocorrect += other.falseAutocorrect
    }

    public func percent(_ n: Int) -> Double {
        total == 0 ? 0 : 100.0 * Double(n) / Double(total)
    }
}

public struct CorpusResult: Sendable {
    public let split: String
    public let byCategory: [String: CorpusTally]
    public let byLang: [String: CorpusTally]
    public let overall: CorpusTally
    public let runtimeSeconds: Double
}

public enum CorpusEval {

    /// Replay each pair through `engine` and tally top-1 / top-3 /
    /// autocorrect-fired / false-autocorrect per category, per language, and
    /// overall. The engine is REUSED across all pairs (one artifact load);
    /// the lane posterior is reset per pair and re-primed by committing the
    /// pair's context words (the harness twin of "the user typed that context
    /// first"). Suggestion output mirrors the micro-eval exactly: no
    /// TypingSession verbatim slot is involved (the raw corrector/predictor
    /// bar), and leading capitalization is preserved by the engine.
    public static func run(
        engine: TypeEngine, pairs: [CorpusPair], split: String = "", limit: Int = 3
    ) -> CorpusResult {
        var byCategory: [String: CorpusTally] = [:]
        var byLang: [String: CorpusTally] = [:]
        var overall = CorpusTally()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for pair in pairs {
                engine.resetLanguagePosterior()
                for word in pair.context { engine.confirmWord(word) }

                let context = pair.context.joined(separator: " ")
                let suggestions = engine.suggestions(
                    context: context, currentWord: pair.typo, limit: limit)
                let texts = suggestions.map(\.text)
                let fired = suggestions.first?.isAutocorrect == true

                var tally = CorpusTally()
                tally.total = 1
                if texts.first == pair.intended { tally.top1 = 1 }
                if texts.contains(pair.intended) { tally.top3 = 1 }
                if fired {
                    tally.autocorrectFired = 1
                    if texts.first != pair.intended { tally.falseAutocorrect = 1 }
                }

                byCategory[pair.category, default: CorpusTally()].add(tally)
                byLang[pair.lang, default: CorpusTally()].add(tally)
                overall.add(tally)
            }
        }

        return CorpusResult(
            split: split,
            byCategory: byCategory,
            byLang: byLang,
            overall: overall,
            runtimeSeconds: elapsed.evalMilliseconds / 1000
        )
    }
}
