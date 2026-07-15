import XCTest

@testable import TypeEngine

final class SpatialModelTests: XCTestCase {
    let model = SpatialModel()

    func testIdenticalCharIsFree() {
        XCTAssertEqual(model.substitutionCost(typed: "g", intended: "g"), 0)
        XCTAssertEqual(model.typingCost(typed: "hestur", intended: "hestur"), 0)
    }

    func testAdjacentKeyCheaperThanDistantKey() {
        // g and h are neighbors on the home row; p is far away top-right.
        let gh = model.substitutionCost(typed: "g", intended: "h")
        let gp = model.substitutionCost(typed: "g", intended: "p")
        XCTAssertLessThan(gh, gp)
        // Adjacent same-row keys should cost about 1/(2σ²) ≈ 1.02 nats.
        XCTAssertEqual(gh, 1.0 / (2 * 0.7 * 0.7), accuracy: 0.01)
        // Distant keys are capped.
        XCTAssertEqual(gp, model.costs.maxSubstitution)
    }

    func testSubstitutionIsSymmetricForLayoutKeys() {
        XCTAssertEqual(
            model.substitutionCost(typed: "d", intended: "f"),
            model.substitutionCost(typed: "f", intended: "d")
        )
    }

    func testAccentVariantsAreCheap() {
        // á sits on the a key (long-press): floor cost, far below a real
        // adjacent-key substitution.
        let aAccent = model.substitutionCost(typed: "a", intended: "á")
        XCTAssertEqual(aAccent, model.costs.minSubstitution)
        XCTAssertLessThan(aAccent, model.substitutionCost(typed: "a", intended: "s"))
    }

    func testIcelandicOrthographicConfusionsAreModerate() {
        // d↔ð are spatially far but a classic slip; must beat the cap.
        let dEth = model.substitutionCost(typed: "d", intended: "ð")
        XCTAssertEqual(dEth, model.costs.orthographicConfusion)
        XCTAssertLessThan(dEth, model.substitutionCost(typed: "d", intended: "p"))
    }

    func testIcelandicKeysHavePositions() {
        for ch in "ðþæö" {
            XCTAssertLessThan(
                model.substitutionCost(typed: ch, intended: ch), 0.001,
                "\(ch) should be on the layout"
            )
        }
        // þ's neighbor on the bottom row is m.
        XCTAssertLessThan(
            model.substitutionCost(typed: "þ", intended: "m"),
            model.substitutionCost(typed: "þ", intended: "q")
        )
    }

    func testTranspositionCheaperThanTwoSubstitutions() {
        // "teh" -> "the" is one transposition.
        let cost = model.typingCost(typed: "teh", intended: "the")
        XCTAssertEqual(cost, model.costs.transposition, accuracy: 0.001)
        // Cheaper than treating it as two independent substitutions (e↔h far).
        let twoSubs =
            model.substitutionCost(typed: "e", intended: "h")
            + model.substitutionCost(typed: "h", intended: "e")
        XCTAssertLessThan(cost, twoSubs)
    }

    func testSpaceAdjacentLettersDerivedFromGeometry() {
        // The bottom-row letters whose key centers fall inside the
        // spacebar's horizontal span: c v b n m. z, x and þ sit over the
        // 123/globe/./return keys and must NOT count as space-adjacent.
        XCTAssertEqual(model.spaceAdjacentLetters, Set("cvbnm"))
    }

    func testInsertionAndDeletionCosts() {
        // typed an extra char
        XCTAssertEqual(
            model.typingCost(typed: "takkk", intended: "takk"),
            model.costs.insertion, accuracy: 0.001
        )
        // omitted a char
        XCTAssertEqual(
            model.typingCost(typed: "hestr", intended: "hestur"),
            model.costs.deletion, accuracy: 0.001
        )
    }
}
