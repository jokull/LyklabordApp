import XCTest
@testable import Learning

/// Appender ⇄ compactor interleavings.
///
/// The real system is two processes (extension appends, app compacts) that
/// coordinate through `NSFileCoordinator`. In-process threads + the same
/// `CoordinatedFileAccess` wrappers exercise the identical serialization
/// contract; the crash grid then enumerates every point at which the
/// compactor can die, with appends landing before and after the crash.
final class ConcurrentLogTests: LearningTestCase {

    // MARK: - Live concurrency under file coordination

    /// Several appender threads and a compactor thread, every disk touch
    /// inside `CoordinatedFileAccess`. Exactly-once: the on-disk model after
    /// the final compaction has precisely one commit per appended event.
    func testCoordinatedAppendersAndCompactorApplyEveryEventExactlyOnce() throws {
        let appenders = 4
        let perAppender = ProcessInfo.processInfo.environment["LEARNING_CONCURRENCY_APPENDS"].flatMap(Int.init) ?? 40
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")

        let group = DispatchGroup()
        let errors = ErrorBox()
        for thread in 0..<appenders {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for i in 0..<perAppender {
                    do {
                        try CoordinatedFileAccess.coordinateWrite(at: log.url) { _ in
                            // Each (thread, i) pair is a unique word ⇒ count must be exactly 1.
                            try log.append(contentsOf: [
                                .wordCommitted(word: "t\(thread)w\(i)", previousWord: "t\(thread)w\(i - 1)", languageHint: .icelandic),
                                .touchSample(keyChar: "a", dx: 0.1, dy: 0.1),
                            ])
                        }
                    } catch {
                        errors.record(error)
                    }
                }
            }
        }

        // Compactor races the appenders until they are done.
        var compactions = 0
        while group.wait(timeout: .now()) == .timedOut {
            try CoordinatedFileAccess.coordinateWrite(at: log.url) { _ in
                try model.compactAndSave(applying: log, to: modelURL)
            }
            compactions += 1
        }
        XCTAssertNil(errors.first, "appender failed: \(String(describing: errors.first))")

        // A relaunched app finishes the job from the persisted marker.
        let relaunched = try PersonalModel(contentsOf: modelURL)
        try CoordinatedFileAccess.coordinateWrite(at: log.url) { _ in
            try relaunched.compactAndSave(applying: log, to: modelURL)
        }
        let final = try PersonalModel(contentsOf: modelURL)
        for thread in 0..<appenders {
            for i in 0..<perAppender {
                XCTAssertEqual(final.commitCount(of: "t\(thread)w\(i)"), 1, "t\(thread)w\(i)")
            }
        }
        // Touch samples decay past the per-key threshold, so compute the
        // expected effective count with the same rule (order-independent
        // because every sample is identical).
        var expectedTouch = TouchKeyStats()
        let config = PersonalModel.Configuration()
        for _ in 0..<(appenders * perAppender) {
            expectedTouch.update(dx: 0.1, dy: 0.1)
            if expectedTouch.count > config.touchSampleDecayThreshold {
                expectedTouch.decay(by: config.touchDecayFactor)
            }
        }
        XCTAssertEqual(final.touchStatistics(for: "a")?.count ?? -1, expectedTouch.count, accuracy: 1e-9)
        XCTAssertTrue(try log.read().events.isEmpty, "everything consumed and truncated")
        print("concurrent run: \(compactions) compactions raced \(appenders * perAppender) coordinated appends")
    }

    // MARK: - Crash grid

    private enum CrashPoint: CaseIterable {
        case afterRead          // compact() ran in memory, nothing saved
        case afterFirstSave     // marker durable, log not truncated
        case afterTruncate      // log rotated, model still holds the old marker
    }

    /// Every compactor crash point × append-before-crash × append-after-
    /// crash. The relaunched app must apply each event exactly once.
    func testCompactorCrashGridAppliesEveryEventExactlyOnce() throws {
        for point in CrashPoint.allCases {
            for appendBetween in [false, true] {
                for appendAfterCrash in [false, true] {
                    try FileManager.default.removeItem(at: directory)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try runCrashScenario(point: point, appendBetween: appendBetween, appendAfterCrash: appendAfterCrash)
                }
            }
        }
    }

    private func runCrashScenario(point: CrashPoint, appendBetween: Bool, appendAfterCrash: Bool) throws {
        let label = "point=\(point) between=\(appendBetween) after=\(appendAfterCrash)"
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        var expected: [String] = []

        // A prior, healthy compaction so the marker is non-trivial.
        try log.append(.wordTapped(word: "seed"))
        expected.append("seed")
        try model.compactAndSave(applying: log, to: modelURL)

        try log.append(.wordTapped(word: "pending"))
        expected.append("pending")

        // Manual compactAndSave with a crash injected at `point`. An append
        // "between" lands after the read but before the crash — the
        // extension's coordinated block slipping in.
        try model.compact(applying: log)
        if point == .afterRead {
            if appendBetween { try log.append(.wordTapped(word: "between")); expected.append("between") }
        } else {
            try model.save(to: modelURL)
            if appendBetween { try log.append(.wordTapped(word: "between")); expected.append("between") }
            if point == .afterTruncate {
                _ = try log.truncate(consumedUpTo: try XCTUnwrap(model.consumedLogMarker))
            }
        }
        // CRASH: `model` is dropped without the final save.

        if appendAfterCrash {
            try log.append(.wordTapped(word: "after"))
            expected.append("after")
        }

        let relaunched = try PersonalModel(contentsOf: modelURL)
        try relaunched.compactAndSave(applying: log, to: modelURL)
        let onDisk = try PersonalModel(contentsOf: modelURL)
        for word in expected {
            XCTAssertEqual(onDisk.commitCount(of: word), 1, "\(label): \(word)")
            XCTAssertTrue(onDisk.isLearned(word), "\(label): \(word)")
        }
        XCTAssertEqual(onDisk.learnedWords.count, expected.count, "\(label): \(onDisk.learnedWords)")
        XCTAssertTrue(try log.read().events.isEmpty, "\(label): log fully consumed")
        // Idempotent: one more compaction changes nothing.
        try onDisk.compactAndSave(applying: log, to: modelURL)
        for word in expected {
            XCTAssertEqual(onDisk.commitCount(of: word), 1, "\(label): \(word) re-applied")
        }
    }

    /// The same grid, but the extension appends a torn record right before
    /// the crash — recovery must keep every complete record, and the torn
    /// one must be consumed (never re-read forever).
    func testCompactorCrashWithTornConcurrentAppendRecovers() throws {
        for point in CrashPoint.allCases {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (model, log) = try makeModelAndLog()
            let modelURL = directory.appendingPathComponent("model.json")
            try log.append(.wordTapped(word: "seed"))
            try model.compact(applying: log)
            if point != .afterRead {
                try model.save(to: modelURL)
                // torn concurrent append (no trailing newline, wrong field count)
                let handle = try FileHandle(forWritingTo: log.url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("1\t20000\twc\tpar".utf8))
                try handle.close()
                if point == .afterTruncate {
                    _ = try log.truncate(consumedUpTo: try XCTUnwrap(model.consumedLogMarker))
                }
            }
            try log.append(.wordTapped(word: "after"))
            let relaunched = (try? PersonalModel(contentsOf: modelURL)) ?? PersonalModel()
            let summary = try relaunched.compactAndSave(applying: log, to: modelURL)
            XCTAssertEqual(relaunched.commitCount(of: "seed"), 1, "\(point)")
            XCTAssertEqual(relaunched.commitCount(of: "after"), 1, "\(point)")
            XCTAssertEqual(relaunched.learnedWords, ["after", "seed"], "\(point)")
            XCTAssertLessThanOrEqual(summary.linesSkipped, 1, "\(point)")
            XCTAssertTrue(try log.read().events.isEmpty, "\(point)")
        }
    }

    // MARK: - Reader racing a rotation

    /// A reader (e.g. a diagnostics screen) holding a marker from before a
    /// rotation must transparently restart at the new header and see only
    /// the unconsumed tail — never a half-rotated view.
    func testStaleReaderMarkerAfterRotationSeesOnlyUnconsumedTail() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        try log.append(.wordTapped(word: "old"))
        let staleReader = try log.read()
        try model.compactAndSave(applying: log, to: modelURL)
        try log.append(.wordTapped(word: "new"))
        let view = try log.read(after: staleReader.endMarker)
        XCTAssertEqual(view.events.map(\.event), [.wordTapped(word: "new")])
        XCTAssertNotEqual(view.endMarker.generation, staleReader.endMarker.generation)
    }
}

/// Thread-safe error sink for the concurrency test.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        errors.append(error)
    }

    var first: Error? {
        lock.lock(); defer { lock.unlock() }
        return errors.first
    }
}
