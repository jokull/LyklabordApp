import LemmaCore
import TypeEngine

/// Dictionary-backed morphology fake (stands in for BÍN's BinaryLemmatizer).
final class FakeMorphology: MorphologyProviding {
    private let words: Set<String>
    /// word -> grammatical cases (the lemmatizeWithMorph fallback seam).
    var cases: [String: [String]] = [:]
    /// word -> lemma candidates (the personal-lemma-lift unambiguity seam).
    var lemmas: [String: [String]] = [:]

    init(_ words: Set<String>) { self.words = words }
    func isKnown(_ word: String) -> Bool { words.contains(word) }
    func nounAdjectiveCases(of word: String) -> [String] { cases[word] ?? [] }
    func lemmaCandidates(of word: String) -> [String] { lemmas[word] ?? [] }
}

/// Dictionary-backed paradigms fake (stands in for LemmaCore's
/// ParadigmsReader over paradigms.bin).
final class FakeParadigms: ParadigmsProviding {
    var groupsByLemma: [String: [ParadigmGroup]] = [:]
    var analysesByForm: [String: [ParadigmAnalysis]] = [:]

    func groups(ofLemma lemma: String) -> [ParadigmGroup] {
        groupsByLemma[lemma.lowercased()] ?? []
    }
    func analyses(ofForm form: String) -> [ParadigmAnalysis] {
        analysesByForm[form.lowercased()] ?? []
    }

    /// Register a noun paradigm: lemma + (form, caseCode, plural, definite)
    /// rows; fills both directions.
    func addNoun(lemma: String, genderCode: UInt8 = 0, forms: [(String, Int, Bool, Bool)]) {
        let paradigmForms = forms.map {
            ParadigmForm(
                form: $0.0,
                bundle: .noun(caseCode: $0.1, plural: $0.2, definite: $0.3)
            )
        }
        groupsByLemma[lemma, default: []].append(
            ParadigmGroup(lemma: lemma, pos: .noun, genderCode: genderCode, forms: paradigmForms)
        )
        for form in paradigmForms {
            analysesByForm[form.form, default: []].append(
                ParadigmAnalysis(
                    lemma: lemma, pos: .noun, genderCode: genderCode, bundle: form.bundle)
            )
        }
    }
}

/// In-memory personal vocabulary (stands in for the production
/// `PersonalSnapshot(model:)` adapter over `Learning.PersonalModel`).
struct FakePersonal: PersonalVocabulary {
    var words: [String: UInt32] = [:]
    var bigrams: [String: UInt32] = [:]  // "first second"
    var tombstones: Set<String> = []

    func allWords() -> [(word: String, count: UInt32)] {
        words
            .filter { !tombstones.contains($0.key) }
            .map { (word: $0.key, count: $0.value) }
    }

    func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = first + " "
        return bigrams
            .compactMap { key, count -> (word: String, count: UInt32)? in
                guard key.hasPrefix(prefix) else { return nil }
                let follower = String(key.dropFirst(prefix.count))
                guard !tombstones.contains(follower) else { return nil }
                return (word: follower, count: count)
            }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.word < $1.word) }
            .prefix(limit)
            .map { $0 }
    }

    func bigramCount(_ first: String, _ second: String) -> UInt32? {
        bigrams["\(first) \(second)"]
    }

    func isTombstoned(_ word: String) -> Bool {
        tombstones.contains(word)
    }
}

enum Fixtures {
    /// Small Icelandic lexicon.
    static let icelandic = DictLexicon(
        unigrams: [
            "og": 2000,
            "að": 1800,
            "er": 1500,
            "ekki": 900,
            "borða": 300,
            "hestur": 500,
            "hestar": 100,
            "hesti": 60,
            "hús": 400,
            "íslenska": 250,
            "góðan": 200,
            "dag": 100,
            "daginn": 90,
            "takk": 350,
            "gott": 150,
            "veður": 200,
            "vetur": 300,
            "greeþ": 100,  // synthetic: bilingual-ambiguity twin of "green"
        ],
        bigrams: [
            "góðan dag": 50,
            "gott veður": 30,
        ]
    )

    /// Small English lexicon (same total as icelandic is not required; the
    /// bilingual test uses the dedicated twins below).
    static let english = DictLexicon(
        unigrams: [
            "the": 2000,
            "and": 1500,
            "with": 900,
            "which": 600,
            "ten": 50,
            "he": 700,
            "hello": 200,
            "green": 100,  // synthetic twin of "greeþ"
        ],
        bigrams: [
            "with the": 120
        ]
    )

    static func engine(
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) -> TypeEngine {
        TypeEngine(
            icelandic: icelandic,
            english: english,
            morphologyProvider: morphology,
            config: config
        )
    }
}
