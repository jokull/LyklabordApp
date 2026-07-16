import XCTest
@testable import Learning

final class PersonalModelTests: LearningTestCase {

    // MARK: - Learning thresholds

    func testRepeatedSameDayCommitsDoNotLearn() throws {
        let (model, log) = try makeModelAndLog()
        for _ in 0..<5 {
            try log.append(.wordCommitted(word: "smellir", previousWord: nil, languageHint: .icelandic))
        }
        try model.compact(applying: log)
        XCTAssertFalse(model.isLearned("smellir"), "5 commits on ONE day must not learn a word")
        XCTAssertEqual(model.commitCount(of: "smellir"), 5)
        XCTAssertNil(model.frequency(of: "smellir"), "pending words must not leak into ranking")
    }

    func testTwoDistinctDayCommitsLearn() throws {
        let (model, log) = try makeModelAndLog()
        day = 100
        try log.append(.wordCommitted(word: "smellir", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertFalse(model.isLearned("smellir"))

        day = 101
        try log.append(.wordCommitted(word: "smellir", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertTrue(model.isLearned("smellir"), "commits on 2 distinct days meet the default threshold")
        XCTAssertEqual(model.frequency(of: "smellir"), 2)
    }

    func testVerbatimTapLearnsImmediately() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordTapped(word: "Jökull"))
        try model.compact(applying: log)
        XCTAssertTrue(model.isLearned("Jökull"), "explicit verbatim tap skips the day threshold")
        XCTAssertEqual(model.frequency(of: "Jökull"), 1)
    }

    func testUserAddLearnsImmediatelyAndIsAlwaysValid() throws {
        let model = PersonalModel()
        try model.addUserWord("Þórsmörk")
        XCTAssertTrue(model.isLearned("Þórsmörk"))
        XCTAssertTrue(model.isUserAdded("Þórsmörk"))
        XCTAssertEqual(model.frequency(of: "Þórsmörk"), 1, "user-added words get a frequency floor of 1")
    }

    func testAddUserWordRejectsInvalidWord() {
        let model = PersonalModel()
        XCTAssertThrowsError(try model.addUserWord("🙂"))
        XCTAssertThrowsError(try model.addUserWord("two words"))
    }

    // MARK: - Explicitness (wave 26: the autocorrect-veto distinction)

    func testOrganicallyLearnedWordIsNotExplicit() throws {
        // Threshold-learned words are IMPLICIT: the engine may deny them
        // the autocorrect veto when they are lazy acute-fold skeletons
        // (session 2026-07-16T22-45-30 "learning self-poisoning").
        let (model, log) = try makeModelAndLog()
        day = 100
        try log.append(.wordCommitted(word: "þvi", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        day = 101
        try log.append(.wordCommitted(word: "þvi", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertTrue(model.isLearned("þvi"))
        XCTAssertFalse(model.isExplicit("þvi"), "organic learning is implicit")
    }

    func testVerbatimTapMakesWordExplicit() throws {
        // The verbatim escape hatch is a deliberate act — including when it
        // rejects a restoration autocorrect: full veto power sticks.
        let (model, log) = try makeModelAndLog()
        try log.append(.wordTapped(word: "þvi"))
        try model.compact(applying: log)
        XCTAssertTrue(model.isExplicit("þvi"))
    }

    func testUserAddedWordIsExplicit() throws {
        let model = PersonalModel()
        try model.addUserWord("þvi")
        XCTAssertTrue(model.isExplicit("þvi"))
    }

    func testCorrectionRevertIsNotExplicit() throws {
        // A single revert can still be a one-off (see the apply(_:) doc);
        // it counts as an implicit commit, not a deliberate learn.
        let (model, log) = try makeModelAndLog()
        try log.append(.correctionReverted(original: "þvi", applied: "því"))
        try model.compact(applying: log)
        XCTAssertFalse(model.isExplicit("þvi"))
    }

    func testSuggestionAcceptedCountsAsCommitOfAcceptedWordOnly() throws {
        let (model, log) = try makeModelAndLog()
        day = 100
        try log.append(.suggestionAccepted(typed: "hesturr", accepted: "hestur"))
        try model.compact(applying: log)
        day = 101
        try log.append(.suggestionAccepted(typed: "hesturr", accepted: "hestur"))
        try model.compact(applying: log)
        XCTAssertTrue(model.isLearned("hestur"))
        XCTAssertEqual(model.commitCount(of: "hesturr"), 0, "the typo must never be learned")
    }

    func testCorrectionRevertedCountsOriginalButIsNotExplicit() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.correctionReverted(original: "profilmynd", applied: "prófílmynd"))
        try model.compact(applying: log)
        XCTAssertEqual(model.commitCount(of: "profilmynd"), 1)
        XCTAssertFalse(model.isLearned("profilmynd"), "one revert stays below the threshold (conservative)")
    }

    func testCustomThresholdRespected() throws {
        let config = PersonalModel.Configuration(learnedDayThreshold: 3)
        let (model, log) = try makeModelAndLog(configuration: config)
        for d: Int32 in [100, 101] {
            day = d
            try log.append(.wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic))
            try model.compact(applying: log)
        }
        XCTAssertFalse(model.isLearned("orð"))
        day = 102
        try log.append(.wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertTrue(model.isLearned("orð"))
    }

    // MARK: - Language attribution

    func testLanguageAttributionCounts() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "banana", previousWord: nil, languageHint: .icelandic))
        try log.append(.wordCommitted(word: "banana", previousWord: nil, languageHint: .english))
        try log.append(.wordCommitted(word: "banana", previousWord: nil, languageHint: .english))
        try log.append(.wordCommitted(word: "banana", previousWord: nil, languageHint: .unknown))
        try model.compact(applying: log)
        let attribution = try XCTUnwrap(model.languageAttribution(of: "banana"))
        XCTAssertEqual(attribution.icelandic, 1)
        XCTAssertEqual(attribution.english, 2)
        XCTAssertEqual(attribution.unknown, 1)
        XCTAssertEqual(model.commitCount(of: "banana"), 4)
    }

    // MARK: - Tombstones

    func testRemoveTombstonesAndForgetsWord() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("óvinur", model: model, log: log)
        XCTAssertTrue(model.isLearned("óvinur"))

        model.remove(word: "óvinur")
        XCTAssertTrue(model.isTombstoned("óvinur"))
        XCTAssertFalse(model.isLearned("óvinur"))
        XCTAssertNil(model.frequency(of: "óvinur"))
        XCTAssertEqual(model.commitCount(of: "óvinur"), 0)
    }

    func testTombstonedWordDoesNotRelearnFromCommitsAcrossCompactions() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("óvinur", model: model, log: log)
        model.remove(word: "óvinur")

        for d: Int32 in [200, 201, 202] {
            day = d
            try log.append(.wordCommitted(word: "óvinur", previousWord: nil, languageHint: .icelandic))
            try model.compact(applying: log)
        }
        XCTAssertFalse(model.isLearned("óvinur"), "committed tombstoned word must NOT relearn")
        XCTAssertEqual(model.commitCount(of: "óvinur"), 0)
        XCTAssertTrue(model.isTombstoned("óvinur"), "tombstone survives compactions")
    }

    func testVerbatimTapDoesNotOverrideTombstone() throws {
        let (model, log) = try makeModelAndLog()
        model.remove(word: "bannorð")
        try log.append(.wordTapped(word: "bannorð"))
        try model.compact(applying: log)
        XCTAssertFalse(model.isLearned("bannorð"), "only the dictionary editor may reverse a deletion")
    }

    func testAddUserWordClearsTombstone() throws {
        let model = PersonalModel()
        model.remove(word: "orð")
        try model.addUserWord("orð")
        XCTAssertFalse(model.isTombstoned("orð"))
        XCTAssertTrue(model.isLearned("orð"))
    }

    func testRemoveTombstoneAllowsOrganicRelearning() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("orð", model: model, log: log)
        model.remove(word: "orð")
        model.removeTombstone("orð")
        XCTAssertFalse(model.isLearned("orð"), "clearing a tombstone does not restore counts")
        try learnWord("orð", model: model, log: log, days: [300, 301])
        XCTAssertTrue(model.isLearned("orð"))
    }

    func testRemoveDropsBigramsContainingWord() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "leyndarmál", previousWord: "stórt", languageHint: .icelandic))
        try log.append(.wordCommitted(word: "eftir", previousWord: "leyndarmál", languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertNotNil(model.bigramFrequency("stórt", "leyndarmál"))
        XCTAssertNotNil(model.bigramFrequency("leyndarmál", "eftir"))

        model.remove(word: "leyndarmál")
        XCTAssertNil(model.bigramFrequency("stórt", "leyndarmál"))
        XCTAssertNil(model.bigramFrequency("leyndarmál", "eftir"))
    }

    // MARK: - Bigrams and continuations

    func testBigramCountsAndContinuationsOrdering() throws {
        let (model, log) = try makeModelAndLog()
        for _ in 0..<3 {
            try log.append(.wordCommitted(word: "morgun", previousWord: "góðan", languageHint: .icelandic))
        }
        for _ in 0..<2 {
            try log.append(.wordCommitted(word: "daginn", previousWord: "góðan", languageHint: .icelandic))
        }
        try log.append(.wordCommitted(word: "aftan", previousWord: "góðan", languageHint: .icelandic))
        try log.append(.wordCommitted(word: "apa", previousWord: "góðan", languageHint: .icelandic))
        try model.compact(applying: log)

        XCTAssertEqual(model.bigramFrequency("góðan", "morgun"), 3)
        let continuations = model.continuations(of: "góðan", limit: 10)
        XCTAssertEqual(
            continuations.map(\.word),
            ["morgun", "daginn", "aftan", "apa"],
            "descending count, lexicographic tie-break"
        )
        XCTAssertEqual(model.continuations(of: "góðan", limit: 2).map(\.word), ["morgun", "daginn"])
        XCTAssertTrue(model.continuations(of: "óþekkt", limit: 5).isEmpty)
    }

    func testNoBigramRecordedWhenEitherSideTombstoned() throws {
        let (model, log) = try makeModelAndLog()
        model.remove(word: "bannað")
        try log.append(.wordCommitted(word: "orð", previousWord: "bannað", languageHint: .icelandic))
        try log.append(.wordCommitted(word: "bannað", previousWord: "orð", languageHint: .icelandic))
        try model.compact(applying: log)
        XCTAssertNil(model.bigramFrequency("bannað", "orð"))
        XCTAssertNil(model.bigramFrequency("orð", "bannað"))
    }

    // MARK: - Listings

    func testListingsAreSortedDeterministically() throws {
        let (model, log) = try makeModelAndLog()
        for word in ["ör", "api", "banki", "æska", "dalur"] {
            try learnWord(word, model: model, log: log)
        }
        try model.addUserWord("zzz")
        try model.addUserWord("aaa")

        XCTAssertEqual(model.learnedWords, model.learnedWords.sorted())
        XCTAssertEqual(model.learnedWords, ["api", "banki", "dalur", "æska", "ör"])
        XCTAssertEqual(model.userAddedWords, ["aaa", "zzz"])
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        try log.append(.wordCommitted(word: "hleypur", previousWord: "hestur", languageHint: .icelandic))
        try log.append(.touchSample(keyChar: "a", dx: 0.1, dy: -0.2))
        try log.append(.touchSample(keyChar: "a", dx: 0.3, dy: -0.1))
        try model.compact(applying: log)
        try model.addUserWord("Þórsmörk")
        model.remove(word: "óvinur")

        let url = directory.appendingPathComponent("model.json")
        try model.save(to: url)
        let reloaded = try PersonalModel(contentsOf: url)

        XCTAssertTrue(reloaded.isLearned("hestur"))
        XCTAssertEqual(reloaded.frequency(of: "hestur"), model.frequency(of: "hestur"))
        XCTAssertEqual(reloaded.bigramFrequency("hestur", "hleypur"), 1)
        XCTAssertTrue(reloaded.isUserAdded("Þórsmörk"))
        XCTAssertTrue(reloaded.isTombstoned("óvinur"))
        XCTAssertEqual(reloaded.consumedLogMarker, model.consumedLogMarker)

        let original = try XCTUnwrap(model.touchStatistics(for: "a"))
        let restored = try XCTUnwrap(reloaded.touchStatistics(for: "a"))
        XCTAssertEqual(restored, original)
    }

    func testSavedFileCarriesSchemaVersionField() throws {
        let model = PersonalModel()
        let url = directory.appendingPathComponent("model.json")
        try model.save(to: url)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
    }

    func testLoadRejectsUnsupportedSchemaVersion() throws {
        let model = PersonalModel()
        let url = directory.appendingPathComponent("model.json")
        try model.save(to: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        XCTAssertThrowsError(try PersonalModel(contentsOf: url)) { error in
            XCTAssertEqual(error as? PersonalModelError, .unsupportedSchemaVersion(99))
        }
    }

    func testSaveIsDeterministic() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        let urlA = directory.appendingPathComponent("a.json")
        let urlB = directory.appendingPathComponent("b.json")
        try model.save(to: urlA)
        try model.save(to: urlB)
        XCTAssertEqual(try Data(contentsOf: urlA), try Data(contentsOf: urlB))
    }

    // MARK: - Touch accessors

    func testKeyOffsetAccessor() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.touchSample(keyChar: "n", dx: 0.2, dy: 0.4))
        try log.append(.touchSample(keyChar: "n", dx: 0.4, dy: 0.2))
        try model.compact(applying: log)

        let offset = try XCTUnwrap(model.keyOffset(for: "n"))
        XCTAssertEqual(offset.dx, 0.3, accuracy: 1e-9)
        XCTAssertEqual(offset.dy, 0.3, accuracy: 1e-9)
        XCTAssertEqual(offset.weight, 2, accuracy: 1e-9)
        XCTAssertNil(model.keyOffset(for: "q"))
        XCTAssertEqual(model.touchKeys, ["n"])
    }

    func testResetTouchModelClearsAllKeys() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.touchSample(keyChar: "n", dx: 0.2, dy: 0.4))
        try model.compact(applying: log)
        model.resetTouchModel()
        XCTAssertTrue(model.touchKeys.isEmpty)
        XCTAssertNil(model.keyOffset(for: "n"))
    }
}
