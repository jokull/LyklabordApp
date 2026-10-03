import XCTest
@testable import Learning

/// Crash / torn-write fault injection for `EventLog` and the model file.
///
/// The contract under test (EventLog.swift "Crash-safety guarantees"): a
/// crash can only produce a torn suffix at EOF, readers tolerate it,
/// appends heal it, and recovery never loses anything but the torn tail.
/// These tests take a real log, surgically produce every reachable bad
/// state (every byte-offset truncation, every single-byte corruption, torn
/// header, empty file) and check that contract holds — no throw, no crash,
/// earlier records intact, marker never past EOF.
final class EventLogFaultInjectionTests: LearningTestCase {

    private let sampleEvents: [LearningEvent] = [
        .wordCommitted(word: "Jökull", previousWord: nil, languageHint: .icelandic),
        .wordCommitted(word: "bráðnar", previousWord: "Jökull", languageHint: .icelandic),
        .suggestionAccepted(typed: "hesturr", accepted: "hestur"),
        .correctionReverted(original: "profilmynd", applied: "prófílmynd"),
        .wordTapped(word: "Þórsmörk"),
        .touchSample(keyChar: "ð", dx: 0.1234, dy: -0.4321),
        .wordCommitted(word: "the", previousWord: "and", languageHint: .english),
    ]

    /// A log whose records were written as one single-line append followed
    /// by one multi-line batch append (both write paths exercised).
    private func makeSampleLog() throws -> (EventLog, bytes: [UInt8], lineEnds: [Int]) {
        let (_, log) = try makeModelAndLog()
        try log.append(sampleEvents[0])
        try log.append(contentsOf: Array(sampleEvents[1...]))
        let bytes = try logBytes(log)
        // Offsets just past each '\n' (first one closes the header).
        let lineEnds = bytes.enumerated().compactMap { $0.element == 0x0A ? $0.offset + 1 : nil }
        XCTAssertEqual(lineEnds.count, sampleEvents.count + 1)
        return (log, bytes, lineEnds)
    }

    /// Events whose line is complete within the first `cut` bytes.
    private func expectedPrefix(cut: Int, lineEnds: [Int]) -> [LearningEvent] {
        guard cut >= lineEnds[0] else { return [] }  // header torn ⇒ nothing consumable
        let complete = lineEnds.dropFirst().filter { $0 <= cut }.count
        return Array(sampleEvents.prefix(complete))
    }

    // MARK: - Truncation at every byte offset

    func testTruncationAtEveryByteOffsetRecoversExactlyTheCompletePrefix() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        for cut in 0...bytes.count {
            try writeLogBytes(Array(bytes[..<cut]), to: log)
            let result: EventLog.ReadResult
            do {
                result = try log.read()
            } catch {
                return XCTFail("read threw at cut \(cut): \(error)")
            }
            let expected = expectedPrefix(cut: cut, lineEnds: lineEnds)
            XCTAssertEqual(result.events.map(\.event), expected, "cut=\(cut)")
            XCTAssertEqual(result.skippedLines, 0, "a clean torn tail is not a skipped line (cut=\(cut))")
            XCTAssertLessThanOrEqual(Int(result.endMarker.offset), cut, "marker past EOF at cut=\(cut)")
            if cut >= lineEnds[0] {
                // Marker sits exactly after the last complete line.
                let lastComplete = lineEnds.last { $0 <= cut } ?? lineEnds[0]
                XCTAssertEqual(Int(result.endMarker.offset), lastComplete, "cut=\(cut)")
            } else {
                XCTAssertEqual(result.endMarker, .none, "torn header must yield the none marker (cut=\(cut))")
            }
        }
    }

    /// Weak (currently true) invariant: the complete prefix survives, the
    /// fresh append is read, and the torn fragment becomes EITHER one
    /// skipped garbage line OR one healed event — never more. The strong
    /// contract the docs state ("the torn fragment becomes an isolated
    /// garbage line") is violated for records whose last field is free
    /// text; see `FoundBugTests.testTornVerbatimTapMustNotLearnATruncatedWord`.
    func testAppendAfterTruncationAtEveryOffsetHealsAndKeepsThePrefix() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        let fresh = LearningEvent.wordTapped(word: "nýtt")
        let headerEnd = lineEnds[0]
        var healedIntoDifferentEvent: [Int] = []
        for cut in 0...bytes.count {
            try writeLogBytes(Array(bytes[..<cut]), to: log)
            try log.append(fresh)
            let result = try log.read()
            let prefix = expectedPrefix(cut: cut, lineEnds: lineEnds)
            let got = result.events.map(\.event)
            XCTAssertEqual(Array(got.prefix(prefix.count)), prefix, "prefix damaged at cut=\(cut)")
            XCTAssertEqual(got.last, fresh, "fresh append lost at cut=\(cut)")
            let extra = got.count - prefix.count - 1
            XCTAssertTrue(extra == 0 || extra == 1, "torn fragment produced \(extra) events at cut=\(cut)")
            if extra == 1 {
                // The healed fragment must at least be the torn record's own
                // kind (same line, same code) — a different kind would mean
                // framing went wrong, not just a truncated field.
                let tornIndex = lineEnds.dropFirst().filter { $0 <= cut }.count
                let original = sampleEvents[tornIndex]
                if got[prefix.count] != original { healedIntoDifferentEvent.append(cut) }
                XCTAssertTrue(sameKind(got[prefix.count], original), "cut=\(cut) healed into a different record kind")
            }

            let tornInsideRecord = cut > headerEnd && !lineEnds.contains(cut)
            switch cut {
            case 0, _ where lineEnds.contains(cut):
                XCTAssertEqual(result.skippedLines, 0, "cut=\(cut)")
                XCTAssertEqual(extra, 0, "cut=\(cut)")
            case 1..<5:
                // Shorter than "#gen\t": a headerless file whose first line is garbage.
                XCTAssertEqual(result.skippedLines, 1, "cut=\(cut)")
            case 5..<headerEnd:
                // Garbled header line is absorbed AS the header (generation
                // .none) — except when only the newline was missing, in
                // which case healing restores the real UUID header.
                XCTAssertEqual(result.skippedLines, 0, "cut=\(cut)")
                if cut == headerEnd - 1 {
                    XCTAssertNotEqual(result.endMarker.generation, EventLog.ConsumedMarker.none.generation, "cut=\(cut)")
                } else {
                    XCTAssertEqual(result.endMarker.generation, EventLog.ConsumedMarker.none.generation, "cut=\(cut)")
                }
            default:
                XCTAssertTrue(tornInsideRecord)
                XCTAssertEqual(result.skippedLines + extra, 1, "torn record must be skipped xor healed (cut=\(cut))")
            }

            // The marker must be fully usable for an incremental read.
            try log.append(.wordTapped(word: "enn"))
            let incremental = try log.read(after: result.endMarker)
            XCTAssertEqual(incremental.events.map(\.event), [.wordTapped(word: "enn")], "cut=\(cut)")
        }
        // Diagnostic for the report: the cuts at which a torn record came
        // back as a *different* event (truncated last field).
        print("torn records healed into altered events at cuts: \(healedIntoDifferentEvent)")
    }

    private func sameKind(_ a: LearningEvent, _ b: LearningEvent) -> Bool {
        switch (a, b) {
        case (.wordCommitted, .wordCommitted), (.suggestionAccepted, .suggestionAccepted),
             (.correctionReverted, .correctionReverted), (.wordTapped, .wordTapped),
             (.touchSample, .touchSample):
            return true
        default:
            return false
        }
    }

    /// Full compaction pipeline over every torn state, including the
    /// `.none`-generation path a torn header produces: the model must end
    /// up with exactly-once counts for the surviving prefix + the heal
    /// append, and the log must be rotated to a real generation header.
    func testCompactAndSaveAtEveryTornOffsetThenResumesCleanly() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        for cut in 0...bytes.count {
            try writeLogBytes(Array(bytes[..<cut]), to: log)
            try log.append(.wordTapped(word: "heal"))
            let modelURL = directory.appendingPathComponent("model-\(cut).json")
            let model = PersonalModel()
            let summary = try model.compactAndSave(applying: log, to: modelURL)
            let prefixCount = expectedPrefix(cut: cut, lineEnds: lineEnds).count
            // +1 for "heal", +1 more when the torn fragment healed into an event.
            XCTAssertTrue(
                summary.eventsApplied == prefixCount + 1 || summary.eventsApplied == prefixCount + 2,
                "cut=\(cut): applied \(summary.eventsApplied), prefix \(prefixCount)"
            )
            XCTAssertTrue(summary.logTruncated)

            // Rotated: real UUID header, no stale bytes.
            let after = try log.read()
            XCTAssertTrue(after.events.isEmpty, "cut=\(cut)")
            XCTAssertNotEqual(after.endMarker.generation, EventLog.ConsumedMarker.none.generation, "cut=\(cut)")
            XCTAssertEqual(after.endMarker, model.consumedLogMarker, "cut=\(cut)")

            // Relaunch resumes without double counting.
            try log.append(.wordTapped(word: "after"))
            let reloaded = try PersonalModel(contentsOf: modelURL)
            let resumed = try reloaded.compactAndSave(applying: log, to: modelURL)
            XCTAssertEqual(resumed.eventsApplied, 1, "cut=\(cut)")
            XCTAssertEqual(reloaded.commitCount(of: "heal"), 1, "cut=\(cut)")
            XCTAssertEqual(reloaded.commitCount(of: "after"), 1, "cut=\(cut)")
            try FileManager.default.removeItem(at: log.url)
        }
    }

    // MARK: - Header-specific torn states

    func testHeaderTornAtEveryOffsetIsNotConsumableAndHealsIntoReadableFile() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        let headerEnd = lineEnds[0]
        for cut in 0..<headerEnd {
            try writeLogBytes(Array(bytes[..<cut]), to: log)
            let torn = try log.read()
            XCTAssertTrue(torn.events.isEmpty, "cut=\(cut)")
            XCTAssertEqual(torn.endMarker, .none, "cut=\(cut)")
            // truncate must be a no-op or harmless, never throw.
            XCTAssertNoThrow(try log.truncate(consumedUpTo: .none), "cut=\(cut)")

            try log.append(.wordTapped(word: "orð"))
            let healed = try log.read()
            XCTAssertEqual(healed.events.map(\.event), [.wordTapped(word: "orð")], "cut=\(cut)")
            try FileManager.default.removeItem(at: log.url)
        }
    }

    func testHeaderWithInvalidUUIDStillYieldsReadableRecords() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        var corrupted = bytes
        for i in 5..<(lineEnds[0] - 1) { corrupted[i] = UInt8(ascii: "x") }
        try writeLogBytes(corrupted, to: log)
        let result = try log.read()
        XCTAssertEqual(result.events.map(\.event), sampleEvents)
        XCTAssertEqual(result.endMarker.generation, EventLog.ConsumedMarker.none.generation)
        // And truncation with the returned marker rotates to a real header.
        let rotated = try log.truncate(consumedUpTo: result.endMarker)
        XCTAssertNotEqual(rotated.generation, EventLog.ConsumedMarker.none.generation)
        XCTAssertTrue(try log.read().events.isEmpty)
    }

    // MARK: - Zero-length file

    func testZeroLengthFileIsHarmlessOnEveryPath() throws {
        let (model, log) = try makeModelAndLog()
        try writeLogBytes([], to: log)
        let read = try log.read()
        XCTAssertTrue(read.events.isEmpty)
        XCTAssertEqual(read.endMarker, .none)

        let modelURL = directory.appendingPathComponent("model.json")
        XCTAssertNoThrow(try model.compactAndSave(applying: log, to: modelURL))

        // Appending after the compactor rotated the empty file works and
        // the header is a single, valid line.
        try log.append(.wordTapped(word: "orð"))
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("#gen\t"))
        XCTAssertEqual(try log.read().events.map(\.event), [.wordTapped(word: "orð")])

        // A zero-length file that the extension appends to directly (no
        // compactor in between) also gets a header.
        try writeLogBytes([], to: log)
        try log.append(.wordTapped(word: "orð"))
        XCTAssertTrue(try String(contentsOf: log.url, encoding: .utf8).hasPrefix("#gen\t"))
    }

    // MARK: - Single-byte corruption

    /// The format carries no checksum, so a corrupted byte inside a field
    /// can legitimately decode to a different (valid) value. The invariant
    /// is weaker but still hard: never throw, every unaffected record is
    /// recovered in order, the marker still reaches EOF (so the damage is
    /// consumed, not re-read forever), and the resulting model can still
    /// be saved (no un-encodable values sneak in).
    func testEveryUnflippedRecordSurvivesAnySingleByteCorruption() throws {
        let (log, bytes, lineEnds) = try makeSampleLog()
        let masks: [UInt8] = [0x01, 0x20, 0x80, 0xFF]
        for position in 0..<bytes.count {
            for mask in masks {
                var corrupted = bytes
                corrupted[position] ^= mask
                try writeLogBytes(corrupted, to: log)

                let result: EventLog.ReadResult
                do {
                    result = try log.read()
                } catch {
                    return XCTFail("read threw at byte \(position) mask \(mask): \(error)")
                }
                // Lines whose bytes include `position`, plus the line after
                // if a newline was destroyed (two lines fuse).
                var affected = Set<Int>()
                for (index, end) in lineEnds.enumerated() {
                    let start = index == 0 ? 0 : lineEnds[index - 1]
                    if position >= start && position < end { affected.insert(index) }
                }
                if bytes[position] == 0x0A, let hit = affected.first { affected.insert(hit + 1) }
                let unaffected = sampleEvents.enumerated()
                    .filter { !affected.contains($0.offset + 1) }  // line index = event index + 1
                    .map(\.element)
                XCTAssertTrue(
                    isSubsequence(unaffected, of: result.events.map(\.event)),
                    "lost an unaffected record at byte \(position) mask \(mask): got \(result.events.map(\.event))"
                )
                XCTAssertLessThanOrEqual(result.events.count, sampleEvents.count, "byte \(position) mask \(mask)")
                if position == bytes.count - 1 {
                    // Destroying the final newline leaves a torn tail: the
                    // marker correctly stops before it (the next append heals).
                    XCTAssertEqual(Int(result.endMarker.offset), lineEnds[lineEnds.count - 2], "byte \(position) mask \(mask)")
                } else {
                    XCTAssertEqual(Int(result.endMarker.offset), bytes.count, "damage must be consumed (byte \(position) mask \(mask))")
                }

                let model = PersonalModel()
                try model.compact(applying: log)
                XCTAssertNoThrow(
                    try model.save(to: directory.appendingPathComponent("m.json")),
                    "corruption at byte \(position) mask \(mask) produced an unsaveable model"
                )
            }
        }
    }

    private func isSubsequence(_ needle: [LearningEvent], of haystack: [LearningEvent]) -> Bool {
        var i = 0
        for item in haystack where i < needle.count && item == needle[i] { i += 1 }
        return i == needle.count
    }

    // MARK: - Model file

    /// `PersonalModel.save` is atomic, so a torn model file should be
    /// unreachable — but a truncated/garbled file must still produce a
    /// thrown error, never a crash, at every prefix length.
    func testTruncatedModelFileAlwaysThrowsNeverCrashes() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        try model.addUserWord("Þórsmörk")
        model.remove(word: "óvinur")
        let url = directory.appendingPathComponent("model.json")
        try model.save(to: url)
        let bytes = [UInt8](try Data(contentsOf: url))
        let cutURL = directory.appendingPathComponent("cut.json")
        for cut in 0..<bytes.count {
            try Data(bytes[..<cut]).write(to: cutURL)
            XCTAssertThrowsError(try PersonalModel(contentsOf: cutURL), "cut=\(cut) decoded a truncated model")
        }
        try Data(bytes).write(to: cutURL)
        XCTAssertNoThrow(try PersonalModel(contentsOf: cutURL))
    }
}
