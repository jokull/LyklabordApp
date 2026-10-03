import XCTest
@testable import Learning

final class EventLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(day: Int32 = 20_000) -> EventLog {
        EventLog(
            url: directory.appendingPathComponent("events.log"),
            dayProvider: { day }
        )
    }

    // MARK: - Round trips

    func testRoundTripAllEventTypes() throws {
        let log = makeLog(day: 20_123)
        let events: [LearningEvent] = [
            .wordCommitted(word: "hús", previousWord: "gamalt", languageHint: .icelandic),
            .wordCommitted(word: "hello", previousWord: nil, languageHint: .english),
            .suggestionAccepted(typed: "hesturr", accepted: "hestur"),
            .correctionReverted(original: "profilmynd", applied: "prófílmynd"),
            .wordTapped(word: "Jökull"),
            .touchSample(keyChar: "a", dx: 0.1234, dy: -0.0567),
        ]
        try log.append(contentsOf: events)

        let result = try log.read()
        XCTAssertEqual(result.skippedLines, 0)
        XCTAssertEqual(result.events.map(\.event), events)
        XCTAssertTrue(result.events.allSatisfy { $0.day == 20_123 })
    }

    func testRoundTripNonASCIIIcelandic() throws {
        let log = makeLog()
        let words = ["ðöggva", "þórður", "æði", "möndull", "áéíóúý"]
        for word in words {
            try log.append(.wordCommitted(word: word, previousWord: "á", languageHint: .icelandic))
        }
        let result = try log.read()
        XCTAssertEqual(result.events.count, words.count)
        for (logged, word) in zip(result.events, words) {
            XCTAssertEqual(logged.event, .wordCommitted(word: word, previousWord: "á", languageHint: .icelandic))
        }
    }

    func testRoundTripBackslashInWord() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: #"a\b"#))
        let result = try log.read()
        XCTAssertEqual(result.events.map(\.event), [.wordTapped(word: #"a\b"#)])
    }

    func testRoundTripTouchSampleWithTabKeyChar() throws {
        // Tab as keyChar must be escaped so it can't break field framing.
        let log = makeLog()
        try log.append(.touchSample(keyChar: "\t", dx: 0.5, dy: 0.5))
        try log.append(.touchSample(keyChar: " ", dx: -0.25, dy: 0.75))
        try log.append(.touchSample(keyChar: "æ", dx: 0, dy: 0))
        let result = try log.read()
        XCTAssertEqual(result.skippedLines, 0)
        XCTAssertEqual(result.events.count, 3)
        guard case .touchSample(let keyChar, _, _) = result.events[0].event else {
            return XCTFail("expected touchSample")
        }
        XCTAssertEqual(keyChar, "\t")
    }

    func testTouchSampleValuesRoundTripToFourDecimals() throws {
        let log = makeLog()
        try log.append(.touchSample(keyChar: "k", dx: 0.123456789, dy: -0.987654321))
        let result = try log.read()
        guard case .touchSample(_, let dx, let dy) = result.events[0].event else {
            return XCTFail("expected touchSample")
        }
        XCTAssertEqual(dx, 0.1235, accuracy: 0.00005)
        XCTAssertEqual(dy, -0.9877, accuracy: 0.00005)
    }

    // MARK: - Validation

    func testRejectsEmojiOnlyWord() {
        let log = makeLog()
        XCTAssertThrowsError(try log.append(.wordCommitted(word: "🙂", previousWord: nil, languageHint: .unknown))) { error in
            guard case EventLogError.invalidContent = error else {
                return XCTFail("expected invalidContent, got \(error)")
            }
        }
    }

    func testRejectsWordContainingEmoji() {
        let log = makeLog()
        XCTAssertThrowsError(try log.append(.wordTapped(word: "há🙂")))
    }

    func testRejectsEmptyDigitsOnlyAndWhitespaceWords() {
        let log = makeLog()
        XCTAssertThrowsError(try log.append(.wordTapped(word: "")))
        XCTAssertThrowsError(try log.append(.wordTapped(word: "1234")))
        XCTAssertThrowsError(try log.append(.wordTapped(word: "two words")))
        XCTAssertThrowsError(try log.append(.wordTapped(word: "line\nbreak")))
        XCTAssertThrowsError(try log.append(.wordTapped(word: String(repeating: "a", count: 65))))
    }

    func testAcceptsApostropheHyphenAndAccentedWords() {
        XCTAssertTrue(EventLog.isLearnableWord("don't"))
        XCTAssertTrue(EventLog.isLearnableWord("vestur-þýskur"))
        XCTAssertTrue(EventLog.isLearnableWord("ðþæö"))
        XCTAssertTrue(EventLog.isLearnableWord("A4"))  // has a letter
        XCTAssertFalse(EventLog.isLearnableWord("..."))
        XCTAssertFalse(EventLog.isLearnableWord("🙂🙂"))
    }

    func testInvalidPreviousWordDowngradesToNil() throws {
        let log = makeLog()
        try log.append(.wordCommitted(word: "hús", previousWord: "🙂", languageHint: .icelandic))
        let result = try log.read()
        XCTAssertEqual(
            result.events.map(\.event),
            [.wordCommitted(word: "hús", previousWord: nil, languageHint: .icelandic)]
        )
    }

    func testInvalidEventWritesNothing() throws {
        let log = makeLog()
        XCTAssertThrowsError(try log.append(.wordTapped(word: "🙂")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))
    }

    // MARK: - Privacy: day-bucket coarseness

    func testLineContainsOnlyCoarseDayBucketNoFinerTimestamp() throws {
        let log = makeLog(day: 20_555)
        try log.append(.wordCommitted(word: "hús", previousWord: nil, languageHint: .icelandic))
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)  // header + one event
        XCTAssertTrue(lines[0].hasPrefix("#gen\t"))
        XCTAssertEqual(lines[1], "1\t20555\twc\thús\t\tis")
    }

    // MARK: - Torn final line

    func testTornFinalLineIsIgnoredAndExcludedFromMarker() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "fyrsta"))
        try log.append(.wordTapped(word: "annað"))
        let clean = try log.read()
        XCTAssertEqual(clean.events.count, 2)

        // Simulate a crash mid-append: raw bytes with no trailing newline.
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1\t20000\twc\tpart".utf8))
        try handle.close()

        let torn = try log.read()
        XCTAssertEqual(torn.events.count, 2)
        XCTAssertEqual(torn.skippedLines, 0)
        XCTAssertEqual(torn.endMarker, clean.endMarker, "torn bytes must not advance the consumed frontier")
    }

    func testAppendAfterTornTailSelfHealsWithIsolatedGarbageLine() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "fyrsta"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1\t20000\twc\tpart".utf8))
        try handle.close()

        try log.append(.wordTapped(word: "annað"))
        let result = try log.read()
        XCTAssertEqual(result.events.map(\.event), [.wordTapped(word: "fyrsta"), .wordTapped(word: "annað")])
        XCTAssertEqual(result.skippedLines, 1, "healed torn fragment becomes one skipped garbage line")
    }

    func testUnknownSchemaVersionAndUnknownEventCodeAreSkipped() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "fyrsta"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("2\t20000\tzz\tfuture\n1\t20000\tzz\tunknown\n".utf8))
        try handle.close()
        try log.append(.wordTapped(word: "annað"))

        let result = try log.read()
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.skippedLines, 2)
    }

    // MARK: - Incremental reads and markers

    func testReadAfterMarkerReturnsOnlyNewEvents() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "fyrsta"))
        let first = try log.read()
        XCTAssertEqual(first.events.count, 1)

        try log.append(.wordTapped(word: "annað"))
        let second = try log.read(after: first.endMarker)
        XCTAssertEqual(second.events.map(\.event), [.wordTapped(word: "annað")])

        let third = try log.read(after: second.endMarker)
        XCTAssertTrue(third.events.isEmpty)
        XCTAssertEqual(third.endMarker, second.endMarker)
    }

    func testMarkerFromDifferentGenerationResetsToHeader() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "fyrsta"))
        let staleMarker = EventLog.ConsumedMarker(generation: UUID(), offset: 999_999)
        let result = try log.read(after: staleMarker)
        XCTAssertEqual(result.events.count, 1, "generation mismatch must re-read from the header")
    }

    func testReadMissingFileReturnsEmpty() throws {
        let log = makeLog()
        let result = try log.read()
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.endMarker, .none)
    }

    // MARK: - Truncation with concurrent appends

    func testTruncatePreservesEventsAppendedAfterRead() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "consumed1"))
        try log.append(.wordTapped(word: "consumed2"))
        let read = try log.read()
        XCTAssertEqual(read.events.count, 2)

        // Concurrent writer lands two more events after the compactor read.
        try log.append(.wordTapped(word: "fresh1"))
        try log.append(.wordTapped(word: "fresh2"))

        let newMarker = try log.truncate(consumedUpTo: read.endMarker)
        XCTAssertNotEqual(newMarker.generation, read.endMarker.generation)

        let afterTruncate = try log.read()
        XCTAssertEqual(
            afterTruncate.events.map(\.event),
            [.wordTapped(word: "fresh1"), .wordTapped(word: "fresh2")],
            "consumed prefix dropped, concurrent appends preserved"
        )
        // The returned marker means "nothing of the new file consumed".
        let incremental = try log.read(after: newMarker)
        XCTAssertEqual(incremental.events.count, 2)
    }

    func testTruncateFullyConsumedFileLeavesOnlyHeader() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "orð"))
        let read = try log.read()
        _ = try log.truncate(consumedUpTo: read.endMarker)
        let after = try log.read()
        XCTAssertTrue(after.events.isEmpty)

        let contents = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#gen\t"))
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
    }

    func testTruncateWithStaleGenerationIsNoOp() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "orð"))
        let before = try Data(contentsOf: log.url)
        let stale = EventLog.ConsumedMarker(generation: UUID(), offset: 10)
        let returned = try log.truncate(consumedUpTo: stale)
        XCTAssertEqual(returned, stale)
        XCTAssertEqual(try Data(contentsOf: log.url), before, "stale-generation truncate must not touch the file")
    }

    func testTruncatePreservesTornTailBytes() throws {
        let log = makeLog()
        try log.append(.wordTapped(word: "consumed"))
        let read = try log.read()
        // Torn concurrent append lands after the read.
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1\t20000\twt\ttorn".utf8))
        try handle.close()

        _ = try log.truncate(consumedUpTo: read.endMarker)
        // The torn bytes survive the rotation; a subsequent append heals
        // them into a marked garbage line — never into an event, since the
        // reader cannot tell "torn" from a cut inside a longer word (see
        // `FoundBugTests.testTornVerbatimTapMustNotLearnATruncatedWord`).
        try log.append(.wordTapped(word: "fresh"))
        let result = try log.read()
        XCTAssertEqual(result.events.map(\.event), [.wordTapped(word: "fresh")])
        XCTAssertEqual(result.skippedLines, 1)
    }

    // MARK: - Coordination helper

    func testCoordinatedReadAndWrite() throws {
        let url = directory.appendingPathComponent("coordinated.log")
        let log = EventLog(url: url, dayProvider: { 20_000 })
        try CoordinatedFileAccess.coordinateWrite(at: url) { _ in
            try log.append(.wordTapped(word: "orð"))
        }
        let events = try CoordinatedFileAccess.coordinateRead(at: url) { _ in
            try log.read().events
        }
        XCTAssertEqual(events.map(\.event), [.wordTapped(word: "orð")])
    }

    func testCoordinatedAccessPropagatesAccessorErrors() {
        let url = directory.appendingPathComponent("error.log")
        XCTAssertThrowsError(
            try CoordinatedFileAccess.coordinateWrite(at: url) { _ -> Void in
                throw EventLogError.ioError("boom")
            }
        )
    }
}
