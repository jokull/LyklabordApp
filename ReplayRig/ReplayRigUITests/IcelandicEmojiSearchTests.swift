import XCTest
import KeyboardKit
import Darwin

final class IcelandicEmojiSearchTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func index(tier: Int = 2) throws -> IcelandicEmojiSearchIndex {
        return try IcelandicEmojiSearchIndex(
            data: Data(
                contentsOf: root.appendingPathComponent("data/emoji/is-search.json"),
                options: .mappedIfSafe
            ),
            availability: EmojiAvailability(maximumTier: tier)
        )
    }

    private func catalog() throws -> EmojiCatalog {
        try EmojiCatalog(data: Data(
            contentsOf: root.appendingPathComponent("data/emoji/catalog.json"),
            options: .mappedIfSafe
        ))
    }

    func testArtifactMetadataAndRequiredQueries() throws {
        let index = try index()
        XCTAssertEqual(index.metadata.emojiCount, 1_914)
        XCTAssertEqual(index.metadata.availableEmojiCount, 1_914)
        XCTAssertEqual(index.metadata.tokenCount, 7_202)
        XCTAssertEqual(index.metadata.postingCount, 18_350)
        XCTAssertEqual(index.search("hjarta").first?.emoji, "❤️")
        XCTAssertEqual(index.search("heart").first?.emoji, "❤️")
        XCTAssertEqual(index.search("heart").first?.name, "rautt hjarta")
        XCTAssertEqual(index.search("kaffi").first?.emoji.replacingOccurrences(of: "\u{FE0F}", with: ""), "☕")
        XCTAssertEqual(index.search("coffee").first?.emoji.replacingOccurrences(of: "\u{FE0F}", with: ""), "☕")
        XCTAssertFalse(index.search("fáni").isEmpty)
        XCTAssertFalse(index.search("bros").isEmpty)
        XCTAssertFalse(index.search("þumal").isEmpty)
        XCTAssertFalse(index.search("fjölskylda").isEmpty)
        XCTAssertFalse(index.search("rauð").isEmpty)
        XCTAssertEqual(index.search("eldur").first?.emoji, "🔥")
        XCTAssertEqual(index.search("fire").first?.emoji, "🔥")
        XCTAssertTrue(index.search("bók").contains { $0.name.contains("bók") })
        XCTAssertFalse(index.search("book").isEmpty)
        XCTAssertFalse(index.search("family").isEmpty)
        XCTAssertTrue(index.search("hagfræði").isEmpty)
        XCTAssertFalse(index.search("ast").isEmpty)
        XCTAssertLessThanOrEqual(index.search("a").count, 24)
    }

    func testCatalogReleaseTiersMatchAppleRuntimeBoundaries() throws {
        XCTAssertEqual(
            EmojiAvailability(operatingSystemVersion: .init(
                majorVersion: 18, minorVersion: 0, patchVersion: 0
            )).maximumTier,
            0
        )
        XCTAssertEqual(
            EmojiAvailability(operatingSystemVersion: .init(
                majorVersion: 18, minorVersion: 4, patchVersion: 0
            )).maximumTier,
            1
        )
        XCTAssertEqual(
            EmojiAvailability(operatingSystemVersion: .init(
                majorVersion: 26, minorVersion: 3, patchVersion: 0
            )).maximumTier,
            1
        )
        XCTAssertEqual(
            EmojiAvailability(operatingSystemVersion: .init(
                majorVersion: 26, minorVersion: 4, patchVersion: 0
            )).maximumTier,
            2
        )

        let catalog = try catalog()
        XCTAssertEqual(catalog.metadata.sequenceCount, 3_944)
        XCTAssertEqual(catalog.metadata.familyCount, 1_914)
        let expectations: [(Int, Int, Int)] = [
            (0, 1_898, 3_773),
            (1, 1_906, 3_781),
            (2, 1_914, 3_944),
        ]
        for (tier, familyCount, sequenceCount) in expectations {
            let categories = catalog.pickerCategories(
                availability: EmojiAvailability(maximumTier: tier)
            )
            XCTAssertEqual(
                categories.reduce(0) { $0 + $1.emojis.count },
                familyCount
            )
            XCTAssertEqual(
                categories.reduce(0) { categoryTotal, category in
                    categoryTotal + category.emojis.reduce(0) {
                        $0 + $1.emojis.count
                    }
                },
                sequenceCount
            )
        }

        XCTAssertTrue(catalog.isAvailable("🍋‍🟩", availability: .init(maximumTier: 0)))
        XCTAssertFalse(catalog.isAvailable("🫆", availability: .init(maximumTier: 0)))
        XCTAssertTrue(catalog.isAvailable("🫆", availability: .init(maximumTier: 1)))
        XCTAssertFalse(catalog.isAvailable("🫍", availability: .init(maximumTier: 1)))
        XCTAssertTrue(catalog.isAvailable("🫍", availability: .init(maximumTier: 2)))
    }

    func testCurrentSimulatorRuntimeMapsToItsExpectedTier() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expectedTier: Int
        if version.majorVersion > 26
            || (version.majorVersion == 26 && version.minorVersion >= 4) {
            expectedTier = 2
        } else if version.majorVersion > 18
            || (version.majorVersion == 18 && version.minorVersion >= 4) {
            expectedTier = 1
        } else {
            expectedTier = 0
        }
        XCTAssertEqual(EmojiAvailability.current.maximumTier, expectedTier)
    }

    func testModernSearchResultsAreHiddenUntilTheirIOSTier() throws {
        let emoji15 = try index(tier: 0)
        XCTAssertEqual(emoji15.metadata.availableEmojiCount, 1_898)
        XCTAssertEqual(emoji15.search("límóna").first?.emoji, "🍋‍🟩")
        XCTAssertTrue(emoji15.search("fingrafar").isEmpty)

        let emoji16 = try index(tier: 1)
        XCTAssertEqual(emoji16.metadata.availableEmojiCount, 1_906)
        XCTAssertEqual(emoji16.search("fingrafar").first?.emoji, "🫆")
        XCTAssertEqual(emoji16.search("harp").first?.emoji, "🪉")
        XCTAssertTrue(emoji16.search("háhyrningur").isEmpty)

        let emoji17 = try index(tier: 2)
        XCTAssertEqual(emoji17.search("háhyrningur").first?.emoji, "🫍")
        XCTAssertEqual(emoji17.search("trombone").first?.emoji, "🪊")
    }

    func testOrdinarySuggestionsUseTheSameReleaseBoundary() throws {
        let url = root.appendingPathComponent("data/emoji/is-suggestions.json")
        let emoji15 = try XCTUnwrap(IcelandicEmojiSuggester(
            contentsOf: url,
            availability: .init(maximumTier: 0)
        ))
        XCTAssertEqual(emoji15.suggestion(for: "hjarta"), "❤️")
        XCTAssertNil(emoji15.suggestion(for: "fingrafar"))

        let emoji16 = try XCTUnwrap(IcelandicEmojiSuggester(
            contentsOf: url,
            availability: .init(maximumTier: 1)
        ))
        XCTAssertEqual(emoji16.suggestion(for: "fingrafar"), "🫆")
        XCTAssertNil(emoji16.suggestion(for: "háhyrningur"))

        let emoji17 = try XCTUnwrap(IcelandicEmojiSuggester(
            contentsOf: url,
            availability: .init(maximumTier: 2)
        ))
        XCTAssertEqual(emoji17.suggestion(for: "háhyrningur"), "🫍")
    }

    func testRankingAndDiacriticFallbackAreDeterministic() throws {
        let index = try index()
        let first = index.search("rautt hjarta")
        let second = index.search("rautt hjarta")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.emoji, "❤️")
        XCTAssertFalse(index.search("fani").isEmpty)
        XCTAssertTrue(index.search("zzzzóþekkt").isEmpty)
    }

    func testFirewallProxySpySeesOnlySelectedEmoji() {
        typealias Firewall = IcelandicEmojiSearchFirewall
        let owned: [(Keyboard.Gesture, KeyboardAction, Firewall.Command)] = [
            (.release, .character("h"), .append("h")),
            (.release, .space, .append(" ")),
            (.press, .backspace, .backspace),
            (.repeatPress, .backspace, .backspace),
            (.release, .primary(.done), .done),
            (.press, .keyboardType(.alphabetic), .exitAndPass),
        ]
        for (gesture, action, expected) in owned {
            XCTAssertEqual(
                Firewall.command(isActive: true, gesture: gesture, action: action),
                expected
            )
        }

        var proxySpy = ""
        let selected = KeyboardAction.emoji(KeyboardKit.Emoji("❤️"))
        if Firewall.command(isActive: true, gesture: .release, action: selected) == .pass {
            proxySpy.append("❤️")
        }
        XCTAssertEqual(proxySpy, "❤️")
        XCTAssertEqual(
            Firewall.command(isActive: false, gesture: .release, action: .character("h")),
            .pass
        )
    }

    func testSearchFitsOneFrameBudget() throws {
        let index = try index()
        let queries = [
            "hjarta", "heart", "kaffi", "coffee", "fáni", "flag", "bros",
            "smile", "þumal", "thumb", "fjölskylda", "family", "rauð", "red",
        ]
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 {
            for query in queries { _ = index.search(query) }
        }
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(seconds / Double(queries.count * 20), 1.0 / 60.0)
    }

    func testRetainedSearchHeapStaysUnderOneMegabyte() throws {
        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        let loaded = try index()
        var after = malloc_statistics_t()
        malloc_zone_statistics(nil, &after)
        XCTAssertEqual(loaded.metadata.emojiCount, 1_914)
        let delta = after.size_in_use > before.size_in_use
            ? after.size_in_use - before.size_in_use
            : 0
        XCTAssertLessThan(delta, 1_000_000, "retained search heap delta: \(delta) bytes")
    }

    func testCombinedCatalogAndSearchHeapStaysWithinReplacementBudget() throws {
        var before = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        let loadedCatalog = try catalog()
        let categories = loadedCatalog.pickerCategories(
            availability: EmojiAvailability(maximumTier: 2)
        )
        let loadedSearch = try index()
        var after = malloc_statistics_t()
        malloc_zone_statistics(nil, &after)
        XCTAssertEqual(categories.reduce(0) { $0 + $1.emojis.count }, 1_914)
        XCTAssertEqual(loadedSearch.metadata.availableEmojiCount, 1_914)
        let delta = after.size_in_use > before.size_in_use
            ? after.size_in_use - before.size_in_use
            : 0
        XCTAssertLessThan(
            delta,
            2_500_000,
            "combined picker/search retained heap delta: \(delta) bytes"
        )
    }

    @MainActor
    func testSessionOwnsCharactersSpacesBackspaceAndDone() throws {
        let index = try index()
        let session = IcelandicEmojiSearchSession(
            loader: { index },
            frecency: { ["❤️", "☕"] }
        )
        session.begin()
        XCTAssertEqual(
            session.results.map { $0.emoji.replacingOccurrences(of: "\u{FE0F}", with: "") },
            ["❤", "☕"]
        )
        session.append("rautt")
        session.append(" ")
        session.append("hjarta")
        XCTAssertEqual(session.query, "rautt hjarta")
        XCTAssertEqual(session.results.first?.emoji, "❤️")
        session.backspace()
        XCTAssertEqual(session.query, "rautt hjart")
        session.done()
        XCTAssertEqual(session.mode, .browse)
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.results.isEmpty)
    }

    @MainActor
    func testHostChangesClearButExpectedEmojiInsertionDoesNot() throws {
        let index = try index()
        let session = IcelandicEmojiSearchSession(loader: { index }, frecency: { [] })
        session.begin(hostWindow: "Halló ")
        session.expectEmojiHostInsertion(before: "Halló ", emoji: "❤️")
        XCTAssertFalse(session.hostContextDidChange(window: "Halló ❤️"))
        XCTAssertEqual(session.mode, .search)
        XCTAssertFalse(session.hostContextDidChange(window: "Halló ❤️"))

        session.expectEmojiHostInsertion(before: "langur gluggi", emoji: "☕️")
        XCTAssertFalse(session.hostContextDidChange(window: "gluggi☕️"))
        XCTAssertEqual(session.mode, .search)
        XCTAssertTrue(session.hostContextDidChange(window: "Host breytti"))
        XCTAssertEqual(session.mode, .browse)
    }

    @MainActor
    func testMissingIndexFailsClosedWithoutLosingQueryOwnership() {
        let session = IcelandicEmojiSearchSession(
            loader: { throw CocoaError(.fileNoSuchFile) },
            frecency: { [] }
        )
        session.begin(hostWindow: "óbreytt")
        session.append("hjarta")
        XCTAssertTrue(session.loadFailed)
        XCTAssertEqual(session.query, "hjarta")
        XCTAssertTrue(session.results.isEmpty)
        XCTAssertFalse(session.hostContextDidChange(window: "óbreytt"))
    }
}
