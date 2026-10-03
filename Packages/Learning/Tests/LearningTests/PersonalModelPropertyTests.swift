import XCTest
@testable import Learning

/// Seeded property test: random event/editor sequences run through the real
/// `EventLog` + `PersonalModel` pipeline (including save/reload and
/// crash-shaped compactions) and compared against a deliberately naive
/// reference model after every step.
///
/// Reproduce a failure: `LEARNING_PROPERTY_SEED=<printed seed> swift test
/// --filter PersonalModelPropertyTests`. Longer soak:
/// `LEARNING_PROPERTY_ITERATIONS=3000`. On failure the harness greedily
/// shrinks the operation list and prints the minimal sequence.
final class PersonalModelPropertyTests: LearningTestCase {

    // MARK: - Alphabet

    /// Small alphabet so collisions (same word, different case/normalization,
    /// tombstone-vs-commit) happen constantly. Includes an NFC/NFD pair and
    /// case variants: surface forms are byte-exact per the model doc, but
    /// Swift `String` equality is canonical, so NFC/NFD unify (the reference
    /// uses the same `Dictionary`, so this asserts consistency, not bytes).
    static let alphabet = [
        "Jökull", "jökull", "JÖKULL", "Jo\u{308}kull",
        "á", "Á", "hestur", "þú", "æði", "the", "his", "vestur-þýskur", "don't",
    ]
    static let days: [Int32] = [20_000, 20_001, 20_002, 20_003]

    enum Op: CustomStringConvertible {
        case commit(word: String, prev: String?, hint: LanguageHint, day: Int32)
        case accept(typed: String, accepted: String, day: Int32)
        case revert(original: String, applied: String, day: Int32)
        case tap(word: String, day: Int32)
        case remove(String)
        case addUser(String)
        case clearTombstone(String)
        case compact
        case compactAndSave
        case crashAfterFirstSave  // compact + save, no truncate, relaunch
        case crashAfterTruncate   // compact + save + truncate, no 2nd save, relaunch
        case reload               // save + load from disk

        var description: String {
            switch self {
            case .commit(let w, let p, let h, let d): return "commit(\(w), prev: \(p ?? "nil"), \(h.rawValue), day \(d))"
            case .accept(let t, let a, let d): return "accept(\(t) → \(a), day \(d))"
            case .revert(let o, let a, let d): return "revert(\(o) ← \(a), day \(d))"
            case .tap(let w, let d): return "tap(\(w), day \(d))"
            case .remove(let w): return "remove(\(w))"
            case .addUser(let w): return "addUser(\(w))"
            case .clearTombstone(let w): return "clearTombstone(\(w))"
            case .compact: return "compact"
            case .compactAndSave: return "compactAndSave"
            case .crashAfterFirstSave: return "crashAfterFirstSave"
            case .crashAfterTruncate: return "crashAfterTruncate"
            case .reload: return "reload"
            }
        }
    }

    static func randomOps(_ rng: inout SeededRNG, count: Int) -> [Op] {
        var ops: [Op] = []
        var day = days[0]
        for _ in 0..<count {
            // Day mostly moves forward, sometimes jumps back (clock change).
            if rng.chance(25) { day = rng.pick(days) }
            let roll = rng.below(100)
            switch roll {
            case 0..<35:
                ops.append(.commit(
                    word: rng.pick(alphabet),
                    prev: rng.chance(60) ? rng.pick(alphabet) : nil,
                    hint: rng.pick(LanguageHint.allCases),
                    day: day))
            case 35..<42: ops.append(.accept(typed: rng.pick(alphabet), accepted: rng.pick(alphabet), day: day))
            case 42..<47: ops.append(.revert(original: rng.pick(alphabet), applied: rng.pick(alphabet), day: day))
            case 47..<57: ops.append(.tap(word: rng.pick(alphabet), day: day))
            case 57..<65: ops.append(.remove(rng.pick(alphabet)))
            case 65..<70: ops.append(.addUser(rng.pick(alphabet)))
            case 70..<73: ops.append(.clearTombstone(rng.pick(alphabet)))
            case 73..<85: ops.append(.compact)
            case 85..<90: ops.append(.compactAndSave)
            case 90..<94: ops.append(.crashAfterFirstSave)
            case 94..<97: ops.append(.crashAfterTruncate)
            default: ops.append(.reload)
            }
        }
        ops.append(.compactAndSave)
        return ops
    }

    // MARK: - Reference model

    /// The simplest possible restatement of the documented semantics.
    struct Reference {
        struct Entry { var count = 0; var is_ = 0; var en = 0; var un = 0; var days = Set<Int32>(); var explicit = false }
        var words: [String: Entry] = [:]
        var bigrams: [String: Int] = [:]
        var tombstones = Set<String>()
        var userAdded = Set<String>()
        /// Re-add rule: every editor action that FLIPS tombstone state
        /// (delete, re-add, clear) bumps the word's epoch; nothing else does.
        var epochs: [String: Int] = [:]
        /// Events appended but not yet compacted.
        var pending: [(day: Int32, event: LearningEvent)] = []
        let threshold: Int

        mutating func commit(_ word: String, hint: LanguageHint, day: Int32, explicit: Bool) {
            guard !tombstones.contains(word) else { return }
            var e = words[word] ?? Entry()
            e.count += 1
            switch hint {
            case .icelandic: e.is_ += 1
            case .english: e.en += 1
            case .unknown: e.un += 1
            }
            if explicit { e.explicit = true }
            e.days.insert(day)  // cap is 8 ≥ |days| alphabet, so never reached
            words[word] = e
        }

        mutating func compact() {
            for (day, event) in pending {
                switch event {
                case .wordCommitted(let w, let p, let h):
                    commit(w, hint: h, day: day, explicit: false)
                    if let p, !tombstones.contains(p), !tombstones.contains(w) {
                        bigrams["\(p) \(w)", default: 0] += 1
                    }
                case .suggestionAccepted(_, let a): commit(a, hint: .unknown, day: day, explicit: false)
                case .correctionReverted(let o, _): commit(o, hint: .unknown, day: day, explicit: false)
                case .wordTapped(let w): commit(w, hint: .unknown, day: day, explicit: true)
                case .touchSample: break
                }
            }
            pending = []
        }

        mutating func remove(_ word: String) {
            words.removeValue(forKey: word)
            userAdded.remove(word)
            if tombstones.insert(word).inserted { epochs[word, default: 0] += 1 }
            bigrams = bigrams.filter { !$0.key.hasPrefix(word + " ") && !$0.key.hasSuffix(" " + word) }
        }

        mutating func addUser(_ word: String) {
            if tombstones.remove(word) != nil { epochs[word, default: 0] += 1 }
            userAdded.insert(word)
        }

        mutating func clearTombstone(_ word: String) {
            if tombstones.remove(word) != nil { epochs[word, default: 0] += 1 }
        }

        func isLearned(_ w: String) -> Bool {
            if tombstones.contains(w) { return false }
            if userAdded.contains(w) { return true }
            guard let e = words[w] else { return false }
            return e.explicit || e.days.count >= threshold
        }

        func frequency(_ w: String) -> UInt32? {
            guard isLearned(w) else { return nil }
            let c = UInt32(words[w]?.count ?? 0)
            return userAdded.contains(w) ? max(c, 1) : c
        }
    }

    // MARK: - Runner

    /// No decay / caps: those are covered by example tests, and keeping the
    /// reference naive is the point.
    private let config = PersonalModel.Configuration(
        learnedDayThreshold: 2, maxDistinctDaysTracked: 8, bigramCap: 1_000_000,
        maxWordEntries: 1_000_000, decayTotalCountCeiling: .max)

    /// Runs `ops` against both implementations; returns the first
    /// divergence description or nil.
    private func run(_ ops: [Op], tag: String) throws -> String? {
        let dir = directory.appendingPathComponent(tag)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelURL = dir.appendingPathComponent("model.json")
        let logURL = dir.appendingPathComponent("events.log")
        var currentDay: Int32 = Self.days[0]
        let log = EventLog(url: logURL, dayProvider: { currentDay })
        var model = PersonalModel(configuration: config)
        var ref = Reference(threshold: 2)

        func relaunch() throws {
            model = FileManager.default.fileExists(atPath: modelURL.path)
                ? try PersonalModel(contentsOf: modelURL, configuration: config)
                : PersonalModel(configuration: config)
        }

        for (index, op) in ops.enumerated() {
            switch op {
            case .commit(let w, let p, let h, let d):
                currentDay = d
                try log.append(.wordCommitted(word: w, previousWord: p, languageHint: h))
                ref.pending.append((d, .wordCommitted(word: w, previousWord: p, languageHint: h)))
            case .accept(let t, let a, let d):
                currentDay = d
                try log.append(.suggestionAccepted(typed: t, accepted: a))
                ref.pending.append((d, .suggestionAccepted(typed: t, accepted: a)))
            case .revert(let o, let a, let d):
                currentDay = d
                try log.append(.correctionReverted(original: o, applied: a))
                ref.pending.append((d, .correctionReverted(original: o, applied: a)))
            case .tap(let w, let d):
                currentDay = d
                try log.append(.wordTapped(word: w))
                ref.pending.append((d, .wordTapped(word: w)))
            case .remove(let w):
                model.remove(word: w); ref.remove(w)
                // Editor mutations are persisted by the app immediately.
                try model.save(to: modelURL)
            case .addUser(let w):
                try model.addUserWord(w); ref.addUser(w)
                try model.save(to: modelURL)
            case .clearTombstone(let w):
                model.removeTombstone(w); ref.clearTombstone(w)
                try model.save(to: modelURL)
            case .compact:
                try model.compact(applying: log); ref.compact()
            case .compactAndSave:
                try model.compactAndSave(applying: log, to: modelURL); ref.compact()
            case .crashAfterFirstSave:
                try model.compact(applying: log); ref.compact()
                try model.save(to: modelURL)
                try relaunch()
            case .crashAfterTruncate:
                try model.compact(applying: log); ref.compact()
                try model.save(to: modelURL)
                if let marker = model.consumedLogMarker { _ = try log.truncate(consumedUpTo: marker) }
                try relaunch()
            case .reload:
                // Un-compacted in-memory state would be lost by a reload, so
                // flush first (mirrors the app: compaction precedes exit).
                try model.compactAndSave(applying: log, to: modelURL); ref.compact()
                try relaunch()
            }
            if let divergence = compare(model, ref) {
                return "after op #\(index) \(op): \(divergence)"
            }
        }
        return nil
    }

    private func compare(_ model: PersonalModel, _ ref: Reference) -> String? {
        for w in Self.alphabet {
            if model.isLearned(w) != ref.isLearned(w) { return "isLearned(\(w)) model=\(model.isLearned(w)) ref=\(ref.isLearned(w))" }
            if model.isTombstoned(w) != ref.tombstones.contains(w) { return "isTombstoned(\(w))" }
            if model.isUserAdded(w) != ref.userAdded.contains(w) { return "isUserAdded(\(w))" }
            if Int(model.tombstoneEpoch(of: w)) != (ref.epochs[w] ?? 0) { return "tombstoneEpoch(\(w)) model=\(model.tombstoneEpoch(of: w)) ref=\(ref.epochs[w] ?? 0)" }
            if model.frequency(of: w) != ref.frequency(w) { return "frequency(\(w)) model=\(String(describing: model.frequency(of: w))) ref=\(String(describing: ref.frequency(w)))" }
            if Int(model.commitCount(of: w)) != (ref.words[w]?.count ?? 0) { return "commitCount(\(w)) model=\(model.commitCount(of: w)) ref=\(ref.words[w]?.count ?? 0)" }
            let explicitRef = ref.userAdded.contains(w) || (ref.words[w]?.explicit ?? false)
            if model.isExplicit(w) != explicitRef { return "isExplicit(\(w))" }
            if let e = ref.words[w] {
                guard let a = model.languageAttribution(of: w) else { return "attribution(\(w)) missing in model" }
                if Int(a.icelandic) != e.is_ || Int(a.english) != e.en || Int(a.unknown) != e.un { return "attribution(\(w))" }
            } else if model.languageAttribution(of: w) != nil {
                return "attribution(\(w)) present in model, absent in ref"
            }
            for v in Self.alphabet {
                let m = model.bigramFrequency(w, v).map(Int.init)
                let r = ref.bigrams["\(w) \(v)"]
                if m != r { return "bigram(\(w) \(v)) model=\(String(describing: m)) ref=\(String(describing: r))" }
            }
        }
        if model.learnedWords != Self.alphabet.filter({ ref.isLearned($0) && ref.words[$0] != nil }).sorted().uniqued() {
            // learnedWords lists words with stats entries only (user-added without commits are listed separately).
            return "learnedWords \(model.learnedWords)"
        }
        return nil
    }

    /// Greedy one-op-at-a-time shrink that preserves the failure.
    private func shrink(_ ops: [Op]) throws -> [Op] {
        var current = ops
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < current.count {
                var candidate = current
                candidate.remove(at: i)
                if try run(candidate, tag: "shrink-\(UUID().uuidString)") != nil {
                    current = candidate
                    changed = true
                } else {
                    i += 1
                }
            }
        }
        return current
    }

    // MARK: - Tests

    func testRandomSequencesMatchReferenceModel() throws {
        let seed = PropertyEnv.seed(default: 0x1CE1_A9D0)
        let iterations = PropertyEnv.iterations(default: 120)
        var rng = SeededRNG(seed: seed)
        for iteration in 0..<iterations {
            let caseSeed = rng.next()
            var caseRNG = SeededRNG(seed: caseSeed)
            let ops = Self.randomOps(&caseRNG, count: 12 + caseRNG.below(30))
            if let failure = try run(ops, tag: "case-\(iteration)") {
                let minimal = try shrink(ops)
                let minimalFailure = try run(minimal, tag: "minimal") ?? failure
                XCTFail("""
                    property failure (seed 0x\(String(seed, radix: 16)), iteration \(iteration), case seed 0x\(String(caseSeed, radix: 16)))
                    \(minimalFailure)
                    minimal ops (\(minimal.count)):
                    \(minimal.map { "  \($0)" }.joined(separator: "\n"))
                    """)
                return
            }
        }
    }

    /// Focused day-boundary property: a word committed on exactly N distinct
    /// days (in any order, including backwards) is learned iff N ≥ 2, and a
    /// tombstone placed at any point before the Nth commit blocks it.
    func testDistinctDayThresholdHoldsUnderAnyDayOrder() throws {
        let seed = PropertyEnv.seed(default: 0xDA75)
        var rng = SeededRNG(seed: seed)
        for iteration in 0..<PropertyEnv.iterations(default: 150) {
            let i = "seed 0x\(String(seed, radix: 16)) iteration \(iteration)"
            let (model, log) = try makeModelAndLog()
            let n = 1 + rng.below(5)
            var days: [Int32] = []
            for _ in 0..<n { days.append(Int32(20_000 + rng.below(3))) }  // collisions on purpose
            let tombstoneAt = rng.chance(30) ? rng.below(n) : nil
            for (k, d) in days.enumerated() {
                if tombstoneAt == k { model.remove(word: "orð") }
                day = d
                try log.append(.wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic))
                if rng.chance(50) { try model.compact(applying: log) }
            }
            try model.compact(applying: log)
            let distinct = Set(days).count
            if tombstoneAt != nil {
                XCTAssertFalse(model.isLearned("orð"), "iteration \(i): tombstone must block (days \(days), tomb at \(tombstoneAt!))")
                XCTAssertEqual(model.commitCount(of: "orð"), 0, "iteration \(i)")
            } else {
                XCTAssertEqual(model.isLearned("orð"), distinct >= 2, "iteration \(i): days \(days)")
                XCTAssertEqual(Int(model.commitCount(of: "orð")), n, "iteration \(i)")
            }
            try FileManager.default.removeItem(at: log.url)
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
