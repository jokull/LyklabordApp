import XCTest
import KeyboardKit
import Darwin

final class IcelandicEmojiSearchTests: XCTestCase {
    private func index() throws -> IcelandicEmojiSearchIndex {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try IcelandicEmojiSearchIndex(
            data: Data(
                contentsOf: root.appendingPathComponent("data/emoji/is-search.json"),
                options: .mappedIfSafe
            )
        )
    }

    func testArtifactMetadataAndRequiredQueries() throws {
        let index = try index()
        XCTAssertEqual(index.metadata.emojiCount, 1_586)
        XCTAssertEqual(index.metadata.tokenCount, 6_016)
        XCTAssertEqual(index.metadata.postingCount, 14_595)
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
        XCTAssertEqual(loaded.metadata.emojiCount, 1_586)
        let delta = after.size_in_use > before.size_in_use
            ? after.size_in_use - before.size_in_use
            : 0
        XCTAssertLessThan(delta, 1_000_000, "retained search heap delta: \(delta) bytes")
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
