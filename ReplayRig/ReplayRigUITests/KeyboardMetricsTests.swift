//
//  KeyboardMetricsTests.swift
//  ReplayRigUITests
//

import XCTest

final class KeyboardMetricsTests: XCTestCase {

    func testPortraitRowsMatchCompactAppleCadence() {
        XCTAssertEqual(
            LyklabordKeyboardMetrics.rowHeight(
                standard: 56,
                isPortrait: true
            ),
            54
        )
        XCTAssertEqual(
            LyklabordKeyboardMetrics.rowHeight(
                standard: 54,
                isPortrait: true
            ),
            54
        )
    }

    func testLandscapeRowsKeepTheirStandardHeight() {
        XCTAssertEqual(
            LyklabordKeyboardMetrics.rowHeight(
                standard: 40,
                isPortrait: false
            ),
            40
        )
    }

    func testAlphabeticContentHeightIsCompact() {
        let rowHeight = LyklabordKeyboardMetrics.rowHeight(
            standard: 56,
            isPortrait: true
        )
        let contentHeight = LyklabordKeyboardMetrics.toolbarHeight + 4 * rowHeight

        XCTAssertEqual(contentHeight, 260)
        XCTAssertEqual(LyklabordKeyboardMetrics.toolbarPadding, 2)
    }
}
