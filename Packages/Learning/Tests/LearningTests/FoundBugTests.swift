import XCTest
@testable import Learning

/// Minimal deterministic repros of real bugs found by the fault-injection /
/// property harness. Each is wrapped in a strict `XCTExpectFailure` so the
/// suite stays green today and flips red (strict ⇒ "expected failure did
/// not occur") the moment the bug is fixed — at which point the wrapper
/// should be deleted and the test kept as a plain regression.
final class FoundBugTests: LearningTestCase {

    // MARK: - Bug 1: a non-finite touch sample permanently freezes compaction

    /// `EventLog.encodeLine` formats `dx`/`dy` with `%.4f`, which renders
    /// `.nan` / `.infinity` as the strings `nan` / `inf`; `decodeLine`
    /// parses them back with `Double(_:)`, which accepts both. Nothing
    /// validates finiteness (words ARE validated — touch samples are not),
    /// so `TouchKeyStats.update` poisons the per-key mean/M2 with NaN, and
    /// `PersonalModel.save` (default `JSONEncoder`, `.throw` for
    /// non-conforming floats) then throws.
    ///
    /// Consequence chain: `compactAndSave` fails at step 2, so the marker is
    /// never persisted and the log is never truncated → every later launch
    /// re-reads the same poisoned line and fails again. Learning is frozen
    /// for good, the log grows without bound, and `exportedJSONData` throws
    /// too ("export my data" is broken).
    func testNonFiniteTouchSampleMustNotBreakSaveAndCompaction() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        // The extension computes dx/dy from key geometry; a zero-width key
        // (or any 0/0) yields NaN. The package accepts it unchallenged.
        try log.append(.touchSample(keyChar: "a", dx: .nan, dy: 0))
        try log.append(.touchSample(keyChar: "b", dx: 0, dy: .infinity))

        try XCTExpectFailure("EventLog accepts non-finite touch samples; PersonalModel.save then throws forever", strict: true) {
            XCTAssertNoThrow(try model.compactAndSave(applying: log, to: modelURL))
            XCTAssertNoThrow(try model.exportedJSONData())
        }
    }

    /// Same root cause, viewed from the crash-recovery angle: the poisoned
    /// line is never consumed, so a relaunch repeats the failure and the
    /// perfectly good word committed next to it is never persisted either.
    func testNonFiniteTouchSampleStarvesNeighbouringWordsOfPersistence() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")
        try log.append(.touchSample(keyChar: "a", dx: .nan, dy: .nan))
        try log.append(.wordTapped(word: "Jökull"))

        _ = try? model.compactAndSave(applying: log, to: modelURL)  // "launch 1" fails
        let relaunched = (try? PersonalModel(contentsOf: modelURL)) ?? PersonalModel()
        _ = try? relaunched.compactAndSave(applying: log, to: modelURL)  // "launch 2" fails the same way

        XCTExpectFailure("Explicitly tapped word never reaches disk while a NaN touch sample sits in the log", strict: true) {
            let onDisk = try? PersonalModel(contentsOf: modelURL)
            XCTAssertEqual(onDisk?.isLearned("Jökull"), true)
        }
    }

    // MARK: - Bug 2: a torn record whose LAST field is a word heals into a shorter word

    /// EventLog.swift promises: "Appends self-heal a torn tail … so the
    /// torn fragment becomes an isolated garbage line (skipped by readers)".
    /// That holds only when the cut leaves the wrong number of fields. For
    /// `wt` (and `sa`), the final field is free text, so a cut anywhere
    /// inside that word still yields a well-formed line — and `decodeLine`
    /// does not re-run `isLearnableWord`. The healed fragment is applied as
    /// an EXPLICIT verbatim tap, so a truncated prefix ("Þórs", or a word
    /// ending in U+FFFD when the cut lands mid-UTF-8) is learned instantly,
    /// skipping the 2-day threshold, and shows up in the dictionary editor.
    ///
    /// Fix options: a trailing field terminator/record checksum, or have
    /// the appender's heal mark the fragment (e.g. prepend `#torn\t`), or
    /// at least re-validate words on read.
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
        try model.compact(applying: log)

        XCTExpectFailure("Torn `wt` record heals into a shorter word that is learned as an explicit tap", strict: true) {
            XCTAssertFalse(model.isLearned("Þórs"), "truncated fragment must not be vocabulary")
            XCTAssertFalse(model.isExplicit("Þórs"))
            XCTAssertEqual(model.learnedWords, [])
        }
    }

    /// Cut inside a multi-byte character: the healed word carries U+FFFD.
    /// `isLearnableWord` would reject it on append, but nothing rejects it
    /// on read, and it is then persisted, exported and synced.
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
        XCTExpectFailure("Torn mid-UTF-8 `wt` record heals into a word containing U+FFFD and is learned", strict: true) {
            XCTAssertFalse(learned.contains { $0.unicodeScalars.contains("\u{FFFD}") }, "got \(learned)")
            XCTAssertEqual(learned, ["orð"])
        }
    }

    // MARK: - Bug 3 (low severity): the `.none` generation is shared by every headerless incarnation

    /// `ConsumedMarker.generation` exists so an offset is only ever honoured
    /// against the file incarnation it was taken from. `parseHeader` hands
    /// out the SAME sentinel generation (`.none`) for every file that lacks a
    /// parseable header — a torn first write shorter than the header, or a
    /// garbled UUID. Two such incarnations are indistinguishable, so a
    /// stored `(.none, offset)` marker is honoured against a DIFFERENT
    /// headerless file and silently skips its first `offset` bytes.
    ///
    /// Preconditions are rare (two torn first writes with a log deletion in
    /// between, and the model marker not reset), so impact is low — but
    /// the fix is trivial: never resume at a non-zero offset for `.none`.
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

        XCTExpectFailure("Marker (.none, offset) from one headerless log is honoured against a different headerless log — events skipped", strict: true) {
            XCTAssertEqual(applied, fresh.count, "every event of the new incarnation must be applied")
        }
    }

    // MARK: - Bug 4: CRLF SwiftKey export imports zero words

    /// `SwiftKeyImport.parseVocabulary` splits on `\n` and trims with
    /// `.whitespaces`, which excludes `\r`. Every line of a CRLF file keeps
    /// its trailing `\r`, `EventLog.isLearnableWord` rejects it as a newline
    /// character, and the whole import "succeeds" with 0 words — the user
    /// sees "0 imported, N skipped" with no explanation.
    func testCRLFVocabularyFileImportsItsWords() {
        let crlf = "# Your SwiftKey vocabulary\r\n#\r\nJökull\r\nmatvöruverslunum\r\nhestur\r\n"
        let (words, skipped) = SwiftKeyImport.parseVocabulary(crlf)
        XCTExpectFailure("parseVocabulary does not strip \\r — CRLF exports import nothing", strict: true) {
            XCTAssertEqual(words, ["Jökull", "matvöruverslunum", "hestur"])
            XCTAssertEqual(skipped, 0)
        }
    }
}
