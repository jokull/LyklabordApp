import Learning
import XCTest

@testable import TypeEngine

/// Apply-seam contracts that HOLD today (2026-10 seam audit): the published
/// bar lagging behind the session, host mutation between request and apply,
/// and a fast-typing backlog — all consulted through the same
/// `AutocorrectApplyGuard` the extension's `tryApplyAutocorrectSuggestion`
/// override uses. Bugs found at the same seam live in
/// `ApplySeamFoundBugTests`.
final class ApplySeamTests: XCTestCase {

    private func driver() -> SeamDriver {
        SeamDriver(Fixtures.engine(), proxy: ProxySimulator(truncation: .none))
    }

    func testStaleBarFromAnEarlierWindowNeverAppliesToGrownToken() {
        let d = driver()
        d.type("hestr")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur")
        // Delivery stalls: the session keeps observing, the toolbar keeps the
        // "hestr" bar.
        d.holdDeliveries = true
        d.type("x")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur", "toolbar still shows the stale bar")
        d.type(" ")
        XCTAssertEqual(d.document, "hestrx ", "guard: stamp \"hestr\" ≠ live \"hestrx\" → plain space")
        XCTAssertEqual(d.session.lastCommittedWord, "hestrx")
    }

    func testStaleBarFromThePreviousWordNeverResurrectsItsCorrection() {
        // The device trace that motivated the guard (2026-07-17): a previous
        // word's correction sitting in the context when the next word's
        // delimiter lands.
        let d = driver()
        d.type("hestr")
        d.holdDeliveries = true
        d.type(" ")  // applies hestur (bar current at that moment)
        XCTAssertEqual(d.document, "hestur ")
        d.type("ok ")
        XCTAssertEqual(d.document, "hestur ok ")
        XCTAssertEqual(d.session.committedWordCount, 2)
        XCTAssertEqual(d.session.lastCommittedWord, "ok")
    }

    func testHostMutationBetweenRequestAndApplyIsCaughtByTheGuard() {
        let d = driver()
        d.type("hestr")
        d.holdDeliveries = true
        // Host rewrites the pending token (e.g. host-side capitalisation)
        // before any new result is delivered.
        d.proxy.hostReplaceText("Hestr")
        d.type(" ")
        XCTAssertEqual(d.document, "Hestr ", "case-sensitive stamp mismatch → no apply")
    }

    func testHostMutationBeforeTheTokenStillLetsTheApplyLand() {
        let d = driver()
        d.type("ok hestr")
        d.holdDeliveries = true
        d.proxy.hostReplaceText("OK hestr")  // context changed, token intact
        d.type(" ")
        XCTAssertEqual(d.document, "OK hestur ")
    }

    func testBacklogDeliveryAfterTheDelimiterIsHarmless() {
        let d = driver()
        d.holdDeliveries = true
        d.type("hestr ")  // no bar ever published: the word commits as typed
        XCTAssertEqual(d.document, "hestr ")
        d.deliverLatest()  // the last result (for "hestr ") arrives late
        XCTAssertNil(d.armedAutocorrect, "a word-boundary result carries no autocorrect")
        XCTAssertEqual(d.publishedPendingToken, "")
        d.type(" ")
        XCTAssertEqual(d.document, "hestr  ")
    }

    func testDeferredDotApplyStillWorksThroughTheGuard() {
        let d = driver()
        d.type("hestr.")
        XCTAssertEqual(d.armedAutocorrect?.text, "hestur.")
        XCTAssertEqual(d.publishedPendingToken, "hestr.")
        d.type(" ")
        XCTAssertEqual(d.document, "hestur. ")
        XCTAssertEqual(d.session.lastCommittedWord, "hestur")
    }

    func testSequencerSupersessionMatchesTheGuardContract() {
        // The same decision the service makes at publish time: an older
        // request for DIFFERENT text is superseded; identical text is not.
        let sequencer = AutocompleteRequestSequencer()
        let a = sequencer.accept(text: "hest")
        let b = sequencer.accept(text: "hestr")
        XCTAssertTrue(sequencer.isSuperseded(a))
        XCTAssertFalse(sequencer.isSuperseded(b))
        let c = sequencer.accept(text: "hestr")
        XCTAssertFalse(sequencer.isSuperseded(b), "a refresh of the same text does not supersede")
        XCTAssertFalse(sequencer.isSuperseded(c))
    }
}
