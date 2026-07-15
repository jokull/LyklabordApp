//
//  KeyboardLayout+IcelandicRegressionTests.swift
//  KeyboardKit
//
//  Regression test for the better-keyboard fork: verifies that
//  `KeyboardLayout.DeviceBasedLayoutService`, configured with the
//  Icelandic input set exactly as `KeyboardExt/KeyboardViewController.swift`
//  wires it up via `services.layoutService`, produces a FULL keyboard
//  layout — not just the three letter rows. This is a static/unit
//  reproduction of the on-device bug where a hand-built
//  `IcelandicKeyboardLayoutProvider` (removed) only emitted
//  `KeyboardAction.standardLayoutItem` rows for the input set and skipped
//  the surrounding system keys (shift, backspace, 123/globe/space/return).
//

import KeyboardKit
import XCTest

class KeyboardLayout_IcelandicRegressionTests: XCTestCase {

    /// Mirrors `KeyboardLayout.InputSet.icelandic` in
    /// `KeyboardExt/KeyboardViewController.swift`: q..ð / a..æö / z..þ.
    var icelandicInputSet: KeyboardLayout.InputSet {
        .init(rows: [
            .init(chars: "qwertyuiopð"),
            .init(chars: "asdfghjklæö"),
            .init(chars: "zxcvbnmþ", deviceVariations: [.pad: "zxcvbnmþ,."])
        ])
    }

    func makeContext(device: DeviceType) -> KeyboardContext {
        let context = KeyboardContext()
        context.deviceTypeForKeyboard = device
        context.keyboardType = .alphabetic
        context.keyboardCase = .lowercased
        // On a real device with >1 keyboard installed (as in the bug
        // report: system Icelandic + English(UK) + Emoji + Better
        // Keyboard), iOS reports this as true and KeyboardKit renders
        // `.nextKeyboard` (the globe key) instead of `.keyboardType(.emojis)`.
        context.needsInputModeSwitchKey = true
        return context
    }

    /// Exactly how `KeyboardViewController.viewDidLoad()` assigns
    /// `services.layoutService` after the fix.
    func makeService() -> KeyboardLayout.DeviceBasedLayoutService {
        .init(
            alphabeticInputSet: icelandicInputSet,
            numericInputSet: .numeric,
            symbolicInputSet: .symbolic
        )
    }

    func testIphoneLayoutHasFourRowsNotThree() {
        let service = makeService()
        let context = makeContext(device: .phone)
        let layout = service.keyboardLayout(for: context)

        // The bug: the hand-built provider emitted exactly 3 rows (the
        // input set's own rows) with nothing else. The fix must add a
        // 4th, system bottom row.
        XCTAssertEqual(layout.itemRows.count, 4, "expected 3 letter rows + 1 system bottom row")
    }

    func testThirdRowHasShiftLeadingAndBackspaceTrailing() {
        let service = makeService()
        let context = makeContext(device: .phone)
        let layout = service.keyboardLayout(for: context)

        let row3 = layout.itemRows[2]
        let actions = row3.map(\.action)
        XCTAssertEqual(actions.first, .shift(.lowercased), "shift must be left of z")
        XCTAssertEqual(actions.last, .backspace, "backspace must be right of þ")

        // þ itself must still be present, to the right of z/x/c/v/b/n/m and
        // to the left of backspace (a leading/trailing margin spacer action
        // may sit between þ and backspace — that's an implementation detail
        // of iPhoneLayoutService, not something callers should assume away).
        guard let thornIndex = actions.firstIndex(of: .character("þ")),
              let shiftIndex = actions.firstIndex(of: .shift(.lowercased)),
              let backspaceIndex = actions.firstIndex(of: .backspace) else {
            return XCTFail("expected shift, þ and backspace all present in row 3")
        }
        XCTAssertLessThan(shiftIndex, thornIndex, "þ must be right of shift/z")
        XCTAssertLessThan(thornIndex, backspaceIndex, "þ must be left of backspace")

        // All of z x c v b n m þ must survive, in order, somewhere in the row.
        let expectedInputLetters = ["z", "x", "c", "v", "b", "n", "m", "þ"]
        let actualInputLetters = actions.compactMap { action -> String? in
            if case let .character(c) = action { return c }
            return nil
        }
        XCTAssertEqual(actualInputLetters, expectedInputLetters)
    }

    func testBottomRowHasNumericGlobeSpaceAndReturn() {
        let service = makeService()
        let context = makeContext(device: .phone)
        let layout = service.keyboardLayout(for: context)

        let bottomRow = layout.itemRows[3].map(\.action)
        XCTAssertEqual(bottomRow.first, .keyboardType(.numeric), "123 key must lead the bottom row")
        XCTAssertTrue(bottomRow.contains(.nextKeyboard), "globe key must switch keyboards when >1 is installed")
        XCTAssertTrue(bottomRow.contains(.space), "space bar must be present")
        XCTAssertEqual(bottomRow.last, .primary(.return), "return key must trail the bottom row")
    }

    func testAllElevenInputColumnsSurviveOnTopRow() {
        let service = makeService()
        let context = makeContext(device: .phone)
        let layout = service.keyboardLayout(for: context)

        // Row 1 (q..ð) has no leading/trailing margin actions added on
        // iPhone (shouldAddUpperMarginActions == false), so all 11 input
        // characters must appear, unmodified, in the top row.
        let topRowChars = layout.itemRows[0].compactMap { item -> String? in
            if case let .character(c) = item.action { return c }
            return nil
        }
        XCTAssertEqual(topRowChars, ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "ð"])
    }

    func testNumericKeyboardTypeStillProducesFourRows() {
        // Sanity-check the 123 page also goes through the same
        // row-assembly machinery (bottom row present for every keyboard
        // type), not just the alphabetic page.
        let service = makeService()
        let context = makeContext(device: .phone)
        context.keyboardType = .numeric
        let layout = service.keyboardLayout(for: context)

        XCTAssertEqual(layout.itemRows.count, 4)
        let bottomRow = layout.itemRows[3].map(\.action)
        // On the numeric page, the bottom-row switcher goes back to letters
        // ("ABC"); the "#+=" -> symbolic switcher lives on the lower INPUT
        // row (row index 2), not the bottom system row.
        XCTAssertEqual(bottomRow.first, .keyboardType(.alphabetic), "bottom row's switcher returns to ABC")
        XCTAssertEqual(bottomRow.last, .primary(.return))

        let lowerInputRow = layout.itemRows[2].map(\.action)
        XCTAssertEqual(lowerInputRow.first, .keyboardType(.symbolic), "lower input row's switcher goes to #+=")
    }

    func testIpadUsesIpadServiceAndStillProducesFullLayout() {
        // Confirms the device-based dispatch (iPhone vs iPad) documented
        // in PLAN.md ("iPad functional via KeyboardKit, unoptimized")
        // still resolves through the same fixed mechanism.
        let service = makeService()
        let context = makeContext(device: .pad)
        let layout = service.keyboardLayout(for: context)

        XCTAssertEqual(layout.itemRows.count, 4)

        // On iPad, the bottom row has space + dismiss-keyboard, but the
        // return/newline key lives on the MIDDLE row's trailing action
        // (see `iPadLayoutService.middleTrailingActions`), not the bottom
        // row — a real layout difference from iPhone, which this test
        // exists to make explicit rather than assume away.
        let bottomRow = layout.itemRows[3].map(\.action)
        XCTAssertTrue(bottomRow.contains(.space))
        XCTAssertTrue(bottomRow.contains(.dismissKeyboard))

        let middleRow = layout.itemRows[1].map(\.action)
        XCTAssertTrue(
            middleRow.contains(where: { if case .primary = $0 { return true }; return false }),
            "return/newline key must be present on the middle row for iPad"
        )
    }
}
