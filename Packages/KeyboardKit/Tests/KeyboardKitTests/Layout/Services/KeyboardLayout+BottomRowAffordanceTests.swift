//
//  KeyboardLayout+BottomRowAffordanceTests.swift
//  KeyboardKit
//
//  Regression test for the better-keyboard fork's bottom-row affordances
//  (PLAN.md "Bottom-row affordances"): a `.` key between the spacebar and
//  return on iPhone, with a long-press callout cluster.
//
//  This mirrors `KeyboardLayout_IcelandicRegressionTests`: it duplicates
//  the production types from `KeyboardExt/KeyboardViewController.swift`
//  (`BetterKeyboardIPhoneLayoutService`, `BetterKeyboardLayoutService`, and
//  the "." override in `Callouts.Actions.icelandic`) locally, since that
//  file lives in the `BetterKeyboardExt` app-extension target, which this
//  test target (a Swift package) cannot import. Keep both copies in sync
//  when either changes.
//

import KeyboardKit
import XCTest

// MARK: - Mirrors of KeyboardExt/KeyboardViewController.swift

/// Mirrors `BetterKeyboardIPhoneLayoutService`.
class TestIPhoneLayoutService: KeyboardLayout.iPhoneLayoutService {

    override func bottomActions(
        for context: KeyboardContext
    ) -> KeyboardAction.Row {
        var actions = super.bottomActions(for: context)
        guard context.keyboardType == .alphabetic else { return actions }
        guard let returnIndex = actions.firstIndex(where: { $0.isPrimaryAction }) else { return actions }
        actions.insert(.character("."), at: returnIndex)
        return actions
    }
}

/// Mirrors `BetterKeyboardLayoutService`.
class TestDeviceLayoutService: KeyboardLayout.DeviceBasedLayoutService {

    private lazy var betterIPhoneService: KeyboardLayoutService = TestIPhoneLayoutService(
        alphabeticInputSet: alphabeticInputSet,
        numericInputSet: numericInputSet,
        symbolicInputSet: symbolicInputSet
    )

    override func keyboardLayoutService(
        for context: KeyboardContext
    ) -> KeyboardLayoutService {
        switch context.deviceTypeForKeyboard {
        case .phone: betterIPhoneService
        default: super.keyboardLayoutService(for: context)
        }
    }
}

/// Mirrors the "." entry added to `Callouts.Actions.icelandic`.
private extension Callouts.Actions {
    static var testIcelandicWithPeriodCluster: Self {
        var actions = Self.english
        let overrides = Self(characters: [
            ".": ".,!?@#:;-",
        ])
        actions.actionsDictionary.merge(overrides.actionsDictionary) { _, new in new }
        return actions
    }
}

class KeyboardLayout_BottomRowAffordanceTests: XCTestCase {

    /// Mirrors `KeyboardLayout.InputSet.icelandic` in
    /// `KeyboardExt/KeyboardViewController.swift`.
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
        context.needsInputModeSwitchKey = true
        return context
    }

    func makeService() -> TestDeviceLayoutService {
        .init(
            alphabeticInputSet: icelandicInputSet,
            numericInputSet: .numeric,
            symbolicInputSet: .symbolic
        )
    }


    // MARK: - Bottom row structure

    func testIphoneBottomRowIs123GlobeSpacePeriodReturn() {
        let service = makeService()
        let context = makeContext(device: .phone)
        let layout = service.keyboardLayout(for: context)

        let bottomRow = layout.itemRows[3].map(\.action)
        XCTAssertEqual(
            bottomRow,
            [.keyboardType(.numeric), .nextKeyboard, .space, .character("."), .primary(.return)],
            "expected [123][globe][space][.][return] on iPhone with needsInputModeSwitchKey=true"
        )
    }

    func testIphonePeriodKeyOnlyAddedForAlphabeticKeyboardType() {
        let service = makeService()
        let context = makeContext(device: .phone)

        context.keyboardType = .numeric
        var bottomRow = service.keyboardLayout(for: context).itemRows[3].map(\.action)
        XCTAssertFalse(bottomRow.contains(.character(".")), "numeric bottom row already has '.' on its own input rows")

        context.keyboardType = .email
        bottomRow = service.keyboardLayout(for: context).itemRows[3].map(\.action)
        XCTAssertFalse(bottomRow.contains(.character(".")), "email bottom row keeps its own @/…com layout, untouched")
    }

    func testIpadBottomRowIsUnaffected() {
        // PLAN.md decision #3: iPad stays on KeyboardKit's stock layout.
        let service = makeService()
        let context = makeContext(device: .pad)
        let layout = service.keyboardLayout(for: context)

        let bottomRow = layout.itemRows[3].map(\.action)
        XCTAssertFalse(bottomRow.contains(.character(".")), "the iPad bottom row must not gain the iPhone-only period key")
        XCTAssertTrue(bottomRow.contains(.space))
    }


    // MARK: - Callout cluster

    func testPeriodKeyCalloutActionsContainTheSwiftKeyCluster() {
        let actions = Callouts.Actions.testIcelandicWithPeriodCluster
        let callout = actions.actions(for: .character("."))

        let expectedChars: [String] = [".", ",", "!", "?", "@", "#", ":", ";", "-"]
        XCTAssertEqual(
            callout,
            expectedChars.map(KeyboardAction.character),
            "period must be first/nearest, matching the design in PLAN.md"
        )
    }
}
