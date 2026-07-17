import XCTest

@testable import Learning

/// State round-trip + effective-entitlement logic for the Lyklaborð+
/// propagation seam (app writes → extension reads). The StoreKit purchase
/// flow itself is not testable off-device — verified manually against the
/// sandbox/StoreKit-configuration environment (see docs/SUBSCRIPTION.md).
final class PlusEntitlementTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "PlusEntitlementTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Round-trip

    func testFreshDefaultsReadAsNotEntitled() {
        let state = PlusEntitlement.read(from: defaults)
        XCTAssertFalse(state.isEntitled)
        XCTAssertNil(state.expiry)
        XCTAssertFalse(state.isEffectivelyEntitled())
    }

    func testEntitledWithExpiryRoundTrips() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        PlusEntitlement.write(.init(isEntitled: true, expiry: expiry), to: defaults)
        let state = PlusEntitlement.read(from: defaults)
        XCTAssertTrue(state.isEntitled)
        // Stored as timeIntervalSince1970 — exact for whole seconds.
        XCTAssertEqual(state.expiry, expiry)
    }

    func testEntitledWithoutExpiryRoundTrips() {
        PlusEntitlement.write(.init(isEntitled: true, expiry: nil), to: defaults)
        let state = PlusEntitlement.read(from: defaults)
        XCTAssertTrue(state.isEntitled)
        XCTAssertNil(state.expiry)
    }

    func testRevokedStateClearsPreviousExpiry() {
        PlusEntitlement.write(
            .init(isEntitled: true, expiry: Date(timeIntervalSince1970: 2_000_000_000)),
            to: defaults
        )
        PlusEntitlement.write(.init(isEntitled: false, expiry: nil), to: defaults)
        let state = PlusEntitlement.read(from: defaults)
        XCTAssertFalse(state.isEntitled)
        XCTAssertNil(state.expiry)
        XCTAssertFalse(state.isEffectivelyEntitled())
    }

    // MARK: - Effective entitlement (the extension's gate)

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEntitledNoExpiryIsEffective() {
        let state = PlusEntitlement.State(isEntitled: true, expiry: nil)
        XCTAssertTrue(state.isEffectivelyEntitled(now: now))
    }

    func testEntitledFutureExpiryIsEffective() {
        let state = PlusEntitlement.State(isEntitled: true, expiry: now.addingTimeInterval(3600))
        XCTAssertTrue(state.isEffectivelyEntitled(now: now))
    }

    func testExpiredWithinLenienceStaysEffective() {
        // 1 day past expiry — inside the 30-day lenience window that covers
        // billing grace and app-not-relaunched gaps.
        let state = PlusEntitlement.State(
            isEntitled: true, expiry: now.addingTimeInterval(-24 * 3600))
        XCTAssertTrue(state.isEffectivelyEntitled(now: now))
    }

    func testExpiredBeyondLenienceIsNotEffective() {
        let state = PlusEntitlement.State(
            isEntitled: true,
            expiry: now.addingTimeInterval(-(PlusEntitlement.expiryLenience + 1)))
        XCTAssertFalse(state.isEffectivelyEntitled(now: now))
    }

    func testLenienceBoundaryIsExclusive() {
        let expiry = now.addingTimeInterval(-PlusEntitlement.expiryLenience)
        let state = PlusEntitlement.State(isEntitled: true, expiry: expiry)
        // now == expiry + lenience exactly → no longer effective (strict <).
        XCTAssertFalse(state.isEffectivelyEntitled(now: now))
        // One second earlier → still effective.
        XCTAssertTrue(state.isEffectivelyEntitled(now: now.addingTimeInterval(-1)))
    }

    func testNotEntitledIgnoresFutureExpiry() {
        let state = PlusEntitlement.State(isEntitled: false, expiry: now.addingTimeInterval(3600))
        XCTAssertFalse(state.isEffectivelyEntitled(now: now))
    }
}
