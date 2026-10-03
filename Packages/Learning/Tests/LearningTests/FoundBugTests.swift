import XCTest
@testable import Learning

/// Regressions for real bugs found by the fault-injection / property
/// harness. Each started life as a strict `XCTExpectFailure` repro; the
/// wrapper was removed when the bug was fixed and the assertions kept.
final class FoundBugTests: LearningTestCase {

    // MARK: - Bug 1: a non-finite touch sample must not freeze compaction

    /// `encodeLine` used to format `.nan`/`.infinity` as `nan`/`inf`, which
    /// `Double(_:)` happily parsed back; `TouchKeyStats.update` then
    /// poisoned the per-key mean/M2 and `PersonalModel.save` (default
    /// `JSONEncoder`, `.throw` for non-conforming floats) threw forever —
    /// the marker was never persisted, the log never truncated, learning
    /// frozen and "export my data" broken. Now: rejected on append, skipped
    /// on read, ignored by `TouchKeyStats.update`.
    func testNonFiniteTouchSampleMustNotBreakSaveAndCompaction() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        XCTAssertThrowsError(try log.append(.touchSample(keyChar: "a", dx: .nan, dy: 0))) { error in
            XCTAssertEqual(error as? EventLogError, .invalidContent("touch offset is not finite / in range"))
        }
        XCTAssertThrowsError(try log.append(.touchSample(keyChar: "b", dx: 0, dy: .infinity)))
        XCTAssertThrowsError(try log.append(.touchSample(keyChar: "c", dx: 1e300, dy: 0)), "absurd magnitude")

        XCTAssertNoThrow(try model.compactAndSave(applying: log, to: modelURL))
        XCTAssertNoThrow(try model.exportedJSONData())
        XCTAssertEqual(model.commitCount(of: "hestur"), 1)
    }

    /// A log already poisoned on a user's device (written by a build without
    /// the encode-time check): the line is skipped, the frontier advances,
    /// and the perfectly good word next to it is persisted.
    func testPoisonedLogRecoversOnNextCompaction() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        try log.append(.wordTapped(word: "fyrsta"))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("1\t20000\tts\ta\tnan\tnan\n1\t20000\tts\tb\t0.1000\tinf\n".utf8))
        try handle.close()
        try log.append(.wordTapped(word: "Jökull"))

        let summary = try model.compactAndSave(applying: log, to: modelURL)
        XCTAssertEqual(summary.linesSkipped, 2)
        XCTAssertEqual(summary.eventsApplied, 2)
        XCTAssertTrue(summary.logTruncated)
        XCTAssertNil(model.touchStatistics(for: "a"))
        XCTAssertNil(model.touchStatistics(for: "b"))

        let onDisk = try PersonalModel(contentsOf: modelURL)
        XCTAssertEqual(onDisk.isLearned("Jökull"), true)
        XCTAssertTrue(try log.read().events.isEmpty, "poisoned lines consumed, not re-read forever")
    }

    /// Belt and braces: the aggregate itself refuses a bad sample, so no
    /// other producer (tests, future callers) can poison it either.
    func testTouchKeyStatsIgnoresNonFiniteAndAbsurdSamples() {
        var stats = TouchKeyStats()
        stats.update(dx: 0.1, dy: -0.2)
        let before = stats
        stats.update(dx: .nan, dy: 0)
        stats.update(dx: 0, dy: -.infinity)
        stats.update(dx: 1e200, dy: 1e200)  // finite, but Welford would overflow M2 to inf
        XCTAssertEqual(stats, before)
        XCTAssertTrue(stats.meanDX.isFinite && stats.m2DX.isFinite && stats.cDXDY.isFinite)
    }

    // MARK: - Bug 2: a torn record must never heal into a different, valid record

    /// `wt`/`sa`/`cr` end in a free-text field, so a cut anywhere inside that
    /// word used to leave a well-formed line after the bare-`\n` heal, and
    /// the truncated prefix ("Þórs") was learned as an EXPLICIT tap. The
    /// heal now marks the fragment (`EventLog.tornMark`) and readers skip
    /// marked lines regardless of field count.
    func testTornVerbatimTapMustNotLearnATruncatedWord() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordTapped(word: "Þórsmörk"))
        let bytes = try logBytes(log)
        // Drop the trailing "mörk\n" so "…\twt\tÞórs" survives as the torn tail.
        let suffix = Array("mörk\n".utf8)
        XCTAssertEqual(Array(bytes.suffix(suffix.count)), suffix)
        try writeLogBytes(Array(bytes.dropLast(suffix.count)), to: log)

        // Next launch of the extension heals the tail and appends normally.
        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        let summary = try model.compact(applying: log)

        XCTAssertFalse(model.isLearned("Þórs"), "truncated fragment must not be vocabulary")
        XCTAssertFalse(model.isExplicit("Þórs"))
        XCTAssertEqual(model.commitCount(of: "Þórs"), 0)
        XCTAssertEqual(model.learnedWords, [])
        XCTAssertEqual(summary.linesSkipped, 1)
        XCTAssertEqual(summary.eventsApplied, 1)
    }

    /// Cut inside a multi-byte character: the healed word would carry U+FFFD.
    func testTornRecordInsideMultibyteCharMustNotProduceReplacementCharacterWord() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordTapped(word: "Þórsmörk"))
        let bytes = try logBytes(log)
        // "…Þórsmörk\n" ends in: C3 B6 ('ö') 72 ('r') 6B ('k') 0A. Drop the
        // last 4 bytes so the cut lands between the two bytes of "ö".
        XCTAssertEqual(Array(bytes.suffix(5)), [0xC3, 0xB6, 0x72, 0x6B, 0x0A])
        try writeLogBytes(Array(bytes.dropLast(4)), to: log)
        try log.append(.wordTapped(word: "orð"))
        try model.compact(applying: log)
        let learned = model.learnedWords
        XCTAssertFalse(learned.contains { $0.unicodeScalars.contains("\u{FFFD}") }, "got \(learned)")
        XCTAssertEqual(learned, ["orð"])
    }

    /// The mark must defeat every record kind at every field count — both
    /// for this reader (suffix check) and, by construction, for a reader
    /// that only counts fields: the 4-field `sa`/`cr` fragments are the
    /// case a single-tab mark would have turned into a valid 5-field
    /// record that learns the mark itself.
    func testTornMarkIsRejectedForEveryRecordKind() throws {
        let fragments = [
            "1\t20000\tsa\thesturr",       // sa cut after `typed`
            "1\t20000\tsa",
            "1\t20000\tcr\tprofilmynd",    // cr likewise
            "1\t20000\twc\torð\tprev",     // wc cut inside/after prev
            "1\t20000\twc\torð",
            "1\t20000\twt\tÞórs",
            "1\t20000\twt",
            "1\t20000\tts\ta\t0.1200",
            "1\t20000\tts\ta",
            "1\t20000",
            "1",
        ]
        for fragment in fragments {
            let (model, log) = try makeModelAndLog(logName: "frag-\(UUID().uuidString).log")
            try log.append(.wordTapped(word: "fyrsta"))
            let handle = try FileHandle(forWritingTo: log.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(fragment.utf8))
            try handle.close()
            try log.append(.wordTapped(word: "annað"))
            let result = try log.read()
            XCTAssertEqual(result.events.map(\.event), [.wordTapped(word: "fyrsta"), .wordTapped(word: "annað")], fragment)
            XCTAssertEqual(result.skippedLines, 1, fragment)
            try model.compact(applying: log)
            XCTAssertEqual(model.learnedWords, ["annað", "fyrsta"], fragment)
            // A reader shipped before the mark (downgraded install) knows
            // nothing about it and only checks field counts and emptiness:
            // it must reject the healed line too.
            XCTAssertNil(Self.preMarkDecoder(fragment + EventLog.tornMark), "old decoder would parse \(fragment.debugDescription) + mark")
        }
    }

    /// The `decodeLine` of builds before the torn mark and read-side
    /// re-validation, verbatim: field count + non-empty words only.
    private static func preMarkDecoder(_ line: String) -> String? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, fields[0] == "1", Int32(fields[1]) != nil else { return nil }
        switch fields[2] {
        case "wc":
            guard fields.count == 6, LanguageHint(rawValue: fields[5]) != nil, !fields[3].isEmpty else { return nil }
            return "wc"
        case "sa", "cr":
            guard fields.count == 5, !fields[3].isEmpty, !fields[4].isEmpty else { return nil }
            return fields[2]
        case "wt":
            guard fields.count == 4, !fields[3].isEmpty else { return nil }
            return "wt"
        case "ts":
            guard fields.count == 6, Double(fields[4]) != nil, Double(fields[5]) != nil, fields[3].count == 1 else { return nil }
            return "ts"
        default:
            return nil
        }
    }

    /// Readers re-validate words with the writer's rule, so a line that
    /// bypassed `append` (hand-edited, bit-flipped, written by a build with
    /// a looser rule) cannot smuggle in whitespace, emoji or U+FFFD words.
    func testDecodeRevalidatesWordsWithTheWriterRule() {
        XCTAssertNil(EventLog.decodeLine("1\t20000\twt\tÞórsm\u{FFFD}"))
        XCTAssertNil(EventLog.decodeLine("1\t20000\twt\t🙂"))
        XCTAssertNil(EventLog.decodeLine("1\t20000\twt\ttwo\\twords"))  // escaped tab inside the word
        XCTAssertNil(EventLog.decodeLine("1\t20000\tsa\tok\t\u{FFFD}"))
        XCTAssertNil(EventLog.decodeLine("1\t20000\tcr\t123\tok"))
        // Invalid predecessor downgrades to nil exactly as the writer does.
        XCTAssertEqual(
            EventLog.decodeLine("1\t20000\twc\torð\t🙂\tis")?.event,
            .wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic)
        )
        // Well-formed lines are untouched.
        XCTAssertEqual(
            EventLog.decodeLine("1\t20000\twc\tbráðnar\tJökull\tis")?.event,
            .wordCommitted(word: "bráðnar", previousWord: "Jökull", languageHint: .icelandic)
        )
        XCTAssertFalse(EventLog.isLearnableWord("Þórsm\u{FFFD}"))
    }

    /// A header that only lost its newline keeps its real generation after
    /// the marked heal (the UUID field ends at the first tab).
    func testHealedHeaderKeepsItsGeneration() throws {
        let (_, log) = try makeModelAndLog()
        try log.append(.wordTapped(word: "orð"))
        let bytes = try logBytes(log)
        let headerEnd = try XCTUnwrap(bytes.firstIndex(of: 0x0A)) + 1
        let generation = try log.read().endMarker.generation
        try writeLogBytes(Array(bytes[..<(headerEnd - 1)]), to: log)
        try log.append(.wordTapped(word: "nýtt"))
        let result = try log.read()
        XCTAssertEqual(result.endMarker.generation, generation)
        XCTAssertEqual(result.events.map(\.event), [.wordTapped(word: "nýtt")])
        XCTAssertEqual(result.skippedLines, 0)
    }

    // MARK: - Bug 3: the `.none` generation is shared by every headerless incarnation

    /// `parseHeader` hands out the SAME sentinel generation (`.none`) for
    /// every file that lacks a parseable header, so a stored `(.none,
    /// offset)` marker used to be honoured against a DIFFERENT headerless
    /// file and silently skipped its first `offset` bytes. A headerless file
    /// is now always read from byte 0.
    func testNoneGenerationOffsetIsNotHonouredAgainstADifferentHeaderlessFile() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")

        // Incarnation 1: headerless (first write torn before "#gen\t" completed),
        // then healed by ordinary appends; compactor reads it but crashes
        // before truncating (marker (.none, N) is durable).
        try writeLogBytes(Array("#g".utf8), to: log)
        for _ in 0..<6 { try log.append(.wordTapped(word: "gamalt")) }
        try model.compact(applying: log)
        try model.save(to: modelURL)
        let marker = try XCTUnwrap(model.consumedLogMarker)
        XCTAssertEqual(marker.generation, EventLog.ConsumedMarker.none.generation)

        // Incarnation 2: log deleted (e.g. a "reset" or a reinstall that
        // keeps the model file), extension's first write torn again below
        // the header length, then more appends than before.
        try FileManager.default.removeItem(at: log.url)
        try writeLogBytes(Array("#ge".utf8), to: log)
        let fresh = (0..<10).map { LearningEvent.wordTapped(word: "nýtt\($0)".replacingOccurrences(of: "0", with: "a")) }
        for event in fresh { try log.append(event) }

        let relaunched = try PersonalModel(contentsOf: modelURL)
        try relaunched.compactAndSave(applying: log, to: modelURL)
        let applied = relaunched.learnedWords.filter { $0.hasPrefix("nýtt") }.count
        XCTAssertEqual(applied, fresh.count, "every event of the new incarnation must be applied")
    }

    // MARK: - Bug 4: CRLF SwiftKey export imports zero words

    /// Swift treats `"\r\n"` as ONE `Character`, so `split(separator: "\n")`
    /// never split a CRLF file at all and the whole import "succeeded" with
    /// 0 words. Every line ending (LF, CRLF, lone CR, mixed) now works.
    func testCRLFVocabularyFileImportsItsWords() {
        let crlf = "# Your SwiftKey vocabulary\r\n#\r\nJökull\r\nmatvöruverslunum\r\nhestur\r\n"
        let (words, skipped) = SwiftKeyImport.parseVocabulary(crlf)
        XCTAssertEqual(words, ["Jökull", "matvöruverslunum", "hestur"])
        XCTAssertEqual(skipped, 0)
    }

    func testLoneCRAndMixedLineEndingsImportEveryWord() {
        let (cr, crSkipped) = SwiftKeyImport.parseVocabulary("Jökull\rhestur\r")
        XCTAssertEqual(cr, ["Jökull", "hestur"])
        XCTAssertEqual(crSkipped, 0)
        let (mixed, mixedSkipped) = SwiftKeyImport.parseVocabulary("# hdr\r\nJökull\nhestur\r\nþú\rorð")
        XCTAssertEqual(mixed, ["Jökull", "hestur", "þú", "orð"])
        XCTAssertEqual(mixedSkipped, 0)
    }

    // MARK: - Bug 5 (local half): explicit tombstone flips are counted

    /// The sync merge needs a monotonic per-word signal to let an explicit
    /// re-add beat a synced deletion (see `PersonalModelMerge`). Locally the
    /// epoch bumps on every state-changing editor action and on nothing
    /// else — repeats and implicit learning leave it alone.
    func testTombstoneEpochBumpsOnlyWhenTombstoneStateFlips() throws {
        let (model, log) = try makeModelAndLog()
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 0)
        try model.addUserWord("orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 0, "adding a never-deleted word is not a flip")
        model.remove(word: "orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 1)
        model.remove(word: "orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 1, "repeat delete is a no-op")
        try log.append(.wordTapped(word: "orð"))
        try model.compact(applying: log)
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 1, "implicit relearn attempt is not a flip")
        XCTAssertFalse(model.isLearned("orð"))
        try model.addUserWord("orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 2)
        try model.addUserWord("orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 2)
        model.remove(word: "orð")
        model.removeTombstone("orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 4)
        model.removeTombstone("orð")
        XCTAssertEqual(model.tombstoneEpoch(of: "orð"), 4)
    }

    func testTombstoneEpochsPersistAndAreAbsentFromUntouchedFiles() throws {
        let modelURL = directory.appendingPathComponent("model.json")
        let model = PersonalModel()
        try model.addUserWord("orð")
        try model.save(to: modelURL)
        XCTAssertFalse(try String(contentsOf: modelURL, encoding: .utf8).contains("tombstoneEpochs"),
                       "no flips ⇒ byte-identical to the pre-epoch format")
        model.remove(word: "orð")
        try model.addUserWord("orð")
        try model.save(to: modelURL)
        let reloaded = try PersonalModel(contentsOf: modelURL)
        XCTAssertEqual(reloaded.tombstoneEpoch(of: "orð"), 2)
        XCTAssertTrue(reloaded.isLearned("orð"))
    }
}
