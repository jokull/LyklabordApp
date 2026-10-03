import Learning
import XCTest

@testable import TypeEngine

/// What `KeyboardExt` actually reports through
/// `noteSelfEdit(before:after:keystroke:replacement:)`, beyond the shapes
/// `ApplySeamFoundBugTests` covers: a multi-word (space-miss split)
/// replacement, and a tapped suggestion when no word is pending. Each runs
/// under both window shapes a host can show at a sentence boundary.
final class ExtensionWiringSeamTests: XCTestCase {

    private static let shapes: [(String, ProxySimulator.TruncationPolicy)] = [
        ("visible", .none),
        ("sentence cut", ProxySimulator.TruncationPolicy()),
        ("lagging cut", {
            var policy = ProxySimulator.TruncationPolicy()
            policy.holdsBoundaryUntilTextFollows = true
            return policy
        }()),
    ]

    private func accepted(_ events: [LearningEvent]) -> [LearningEvent] {
        events.filter {
            if case .suggestionAccepted = $0 { return true }
            return false
        }
    }

    func testTappedSplitReportsAMultiWordReplacementAndCommitsBothWords() {
        for (name, shape) in Self.shapes {
            let d = SeamDriver(Fixtures.engine(), proxy: ProxySimulator(truncation: shape))
            d.type("gottnveður")
            XCTAssertTrue(d.tap("gott veður"), "\(name): split is on the bar")
            XCTAssertEqual(d.document, "gott veður ", name)
            XCTAssertEqual(d.session.committedWordCount, 2, name)
            XCTAssertEqual(d.session.lastCommittedWord, "veður", name)
        }
    }

    func testSplitThenSentenceEndCommitsEachWordOnce() {
        for (name, shape) in Self.shapes {
            let d = SeamDriver(Fixtures.engine(), proxy: ProxySimulator(truncation: shape))
            d.type("gottnveður")
            XCTAssertTrue(d.tap("gott veður"), name)
            d.typeDotAfterTap()
            d.type("ok ")
            XCTAssertEqual(d.document, "gott veður. ok ", name)
            XCTAssertEqual(d.session.committedWordCount, 3, name)
            XCTAssertEqual(d.session.lastCommittedWord, "ok", name)
        }
    }

    func testTapWithNoPendingWordIsNotAnAcceptedCorrection() {
        var tapped = 0
        defer { XCTAssertGreaterThan(tapped, 0, "the fixture must offer a prediction to tap") }
        for (name, shape) in Self.shapes {
            let d = SeamDriver(Fixtures.engine(), proxy: ProxySimulator(truncation: shape))
            d.type("gott ")
            _ = d.drainEvents()
            let commitsBefore = d.session.committedWordCount
            // Whatever the bar offers with no word in progress is a
            // prediction: the tap replaces nothing.
            guard let prediction = d.bar.first(where: { !$0.isVerbatim }) else {
                continue  // fixture offers no prediction here; nothing to tap
            }
            XCTAssertTrue(d.tap(prediction.text), name)
            tapped += 1
            XCTAssertEqual(d.document, "gott \(prediction.text) ", name)
            XCTAssertTrue(
                accepted(d.drainEvents()).isEmpty,
                "\(name): a prediction tap corrected nothing")
            XCTAssertLessThanOrEqual(
                d.session.committedWordCount - commitsBefore,
                prediction.text.split(separator: " ").count,
                "\(name): the tapped text is committed at most once")
        }
    }
}
