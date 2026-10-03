import XCTest
@testable import Learning

/// Shared fixture: a temp directory, an injectable day bucket, and helpers
/// for building a model+log pair and learning words across distinct days.
class LearningTestCase: XCTestCase {

    var directory: URL!
    /// Mutable day bucket fed to `EventLog.dayProvider` — tests advance this
    /// to simulate distinct-day commits.
    var day: Int32 = 20_000

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearningTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        day = 20_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeModelAndLog(
        configuration: PersonalModel.Configuration = PersonalModel.Configuration(),
        logName: String = "events.log"
    ) throws -> (PersonalModel, EventLog) {
        let model = PersonalModel(configuration: configuration)
        let log = EventLog(
            url: directory.appendingPathComponent(logName),
            dayProvider: { [weak self] in self?.day ?? 0 }
        )
        return (model, log)
    }

    /// Raw bytes of the log file (fault-injection helpers).
    func logBytes(_ log: EventLog) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: log.url))
    }

    /// Overwrite the log file with exactly `bytes` (simulating a torn write,
    /// a bit flip, or an externally truncated file).
    func writeLogBytes(_ bytes: [UInt8], to log: EventLog) throws {
        try Data(bytes).write(to: log.url)
    }

    /// Commit `word` on the given distinct days (default two) and compact —
    /// enough to cross the default learned threshold.
    func learnWord(
        _ word: String,
        model: PersonalModel,
        log: EventLog,
        days: [Int32] = [20_000, 20_001]
    ) throws {
        for d in days {
            day = d
            try log.append(.wordCommitted(word: word, previousWord: nil, languageHint: .icelandic))
            try model.compact(applying: log)
        }
    }
}

// MARK: - Property-test plumbing

/// Deterministic seeded RNG (SplitMix64) — identical to the one in the Sync
/// test target so a printed seed reproduces a failure exactly.
struct SeededRNG: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<bound` (bound > 0).
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }
}

/// Env-var knobs shared by the property tests:
/// - `LEARNING_PROPERTY_SEED`     — reproduce one run (decimal or 0x-hex).
/// - `LEARNING_PROPERTY_ITERATIONS` — soak length (default keeps the suite
///   at a few seconds).
enum PropertyEnv {
    static func seed(default defaultSeed: UInt64) -> UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["LEARNING_PROPERTY_SEED"] else {
            return defaultSeed
        }
        if raw.hasPrefix("0x"), let v = UInt64(raw.dropFirst(2), radix: 16) { return v }
        return UInt64(raw) ?? defaultSeed
    }

    static func iterations(default defaultCount: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment["LEARNING_PROPERTY_ITERATIONS"],
              let n = Int(raw), n > 0 else { return defaultCount }
        return n
    }
}
