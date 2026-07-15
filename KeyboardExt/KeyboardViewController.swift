//
//  KeyboardViewController.swift
//  BetterKeyboardExt
//
//  M0 spike: KeyboardKit shell wired up with a custom Icelandic QWERTY
//  layout. Autocorrect / prediction / learning land in later milestones
//  (see PLAN.md). This extension must never make a network call.
//
//  KeyboardKit note: v10+ ships as a closed-source XCFramework gated by a
//  LicenseKit dependency, which conflicts with this repo's locked decision
//  that the free tier stays MIT/auditable and the extension is
//  network-code-free. We pin to 9.9.1 (project.yml), the last tag with full
//  MIT Swift source and no license-key machinery.
//

import KeyboardKit
import SwiftUI

/// The `KeyboardApp` descriptor shared by the app and the extension. Kept
/// minimal for the M0 spike: no license key (we stay on the free/MIT tier
/// by design — see PLAN.md decision #4), single locale, App Group wired for
/// the future LearningStore / dictionary sync (M2/M3).
extension KeyboardApp {
    static var betterKeyboard: Self {
        .init(
            name: "Better Keyboard",
            appGroupId: "group.is.betterkeyboard",
            locales: [.icelandic]
        )
    }
}

final class KeyboardViewController: KeyboardInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure the settings store (App Group backed) and inject the
        // app descriptor into the keyboard state.
        KeyboardSettings.setupStore(for: .betterKeyboard)
        state.setup(for: .betterKeyboard)

        // Single Icelandic layout — no locale switching (PLAN.md decision #2:
        // mixed EN/IS typing is assumed on the one Icelandic layout).
        state.keyboardContext.locale = .icelandic
        state.keyboardContext.locales = [.icelandic]

        // Icelandic layout: swap in the Icelandic alphabetic input set on
        // top of KeyboardKit's own row-assembly machinery
        // (`KeyboardLayout.DeviceBasedLayoutService`, vendored in
        // Packages/KeyboardKit/Sources/KeyboardKit/_Deprecated/Layout
        // Services/). That service is what builds the *full* keyboard —
        // shift, backspace, 123/globe/space/return bottom row, iPhone vs
        // iPad variants, margins/widths — around whichever input set it's
        // given, picking `iPhoneLayoutService`/`iPadLayoutService`
        // internally based on device type. Hand-assembling just the input
        // rows (the previous `IcelandicKeyboardLayoutProvider`, now
        // removed) skipped all of that and rendered letters only. Doc
        // comments in that vendored code say "> Deprecated: ... will be
        // removed in 10.0", but per PLAN.md we vendor 9.9.1 permanently and
        // never track v10 (closed-source), so these are first-class APIs
        // in our fork, not actually-deprecated code — see the `_Deprecated`
        // README-equivalent note there. (None of these declarations carry
        // an `@available(*, deprecated...)` attribute, so this produces no
        // compiler warnings.)
        //
        // Callouts (long-press accents) are wired separately via the
        // `.keyboardCalloutActions` view modifier in
        // `viewWillSetupKeyboardView()` below — that's the current, non-
        // deprecated mechanism regardless of layout service choice.
        services.layoutService = KeyboardLayout.DeviceBasedLayoutService(
            alphabeticInputSet: .icelandic,
            numericInputSet: .numeric,
            symbolicInputSet: .symbolic
        )

        // M1: bilingual IS/EN autocomplete via TypeEngine. The service
        // bootstraps itself lazily on its own utility-QoS serial queue (mmap
        // of lemma-is.bin + en.lex + is.lex happens off the main thread —
        // the launch-flicker mitigation in PLAN.md; nothing heavy runs in
        // viewDidLoad). Until the engine is ready it returns empty
        // suggestions. Replaces the default `.disabled` service; the
        // standard KeyboardView toolbar (`toolbar: { $0.view }` below)
        // renders `AutocompleteContext.suggestions`, and the standard action
        // handler applies `.autocorrect` suggestions on space/delimiter.
        services.autocompleteService = BetterKeyboardAutocompleteService()
    }

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { controller in
            // No explicit `layout:` — the default `KeyboardView` init falls
            // back to `services.layoutService.keyboardLayout(for:)`, which
            // is the `DeviceBasedLayoutService` configured with `.icelandic`
            // above (viewDidLoad). That's what produces the full keyboard
            // (space/backspace/shift/123/globe/return), not just the letter
            // rows.
            KeyboardView(
                state: controller.state,
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { $0.view }
            )
            .keyboardCalloutActions { params in
                Callouts.Actions.icelandic.actions(for: params.action)
            }
        }
    }
}

// MARK: - Icelandic Layout

/// Icelandic QWERTY input layout.
///
/// Verified against the physical/hardware Icelandic layout (ÍST 125:2015,
/// cross-checked via kbdlayout.info/KBDIC) and iOS 6+ behavior (Æ, Þ, Ð, Ö
/// have been dedicated, always-visible keys since iOS 6 — not long-press
/// variants). The three-row software layout mirrors how iOS collapses other
/// Nordic/German hardware layouts onto the on-screen keyboard: characters
/// that live on the physical letter rows keep their row; ö (which sits on
/// the *number* row on physical Icelandic hardware, right of 0) is relocated
/// onto row 2 since the on-screen alphabetic keyboard has no number row.
///
///   Row 1: q w e r t y u i o p ð   (ð right of p — matches hardware)
///   Row 2: a s d f g h j k l æ ö   (æ right of l — matches hardware;
///                                   ö appended — relocated from the
///                                   hardware number row)
///   Row 3: z x c v b n m þ         (þ right of m — matches hardware,
///                                   which places þ at the end of the
///                                   bottom row)
///
/// Sources: kbdlayout.info/KBDIC (hardware key positions), Wikipedia
/// "Icelandic keyboard layout", and the iOS 6 Icelandic-keyboard coverage
/// on einstein.is / simon.is (confirms Æ/Þ/Ð/Ö are dedicated, always-visible
/// keys, not long-press-only).
extension KeyboardLayout.InputSet {
    static var icelandic: Self {
        .init(rows: [
            .init(chars: "qwertyuiopð"),
            .init(chars: "asdfghjklæö"),
            .init(chars: "zxcvbnmþ", deviceVariations: [.pad: "zxcvbnmþ,."])
        ])
    }
}

// MARK: - Icelandic Callouts (long-press accents)

/// Long-press callout actions for the Icelandic layout.
///
/// Provides the accented vowels á é í ó ú ý on long-press of their base
/// letter (per PLAN.md v1 scope), and keeps ð/þ discoverable on long-press
/// of d/t as a secondary path even though they're also dedicated keys.
///
/// KeyboardKit note: built on `Callouts.Actions` + `View.keyboardCalloutActions(_:)`,
/// the non-deprecated 9.9.1 value/modifier replacement for the deprecated
/// `Callouts.BaseCalloutService` subclassing pattern (see
/// research/keyboardkit-v10-delta.md §1). Starts from the standard English
/// callout set (base symbols/digits + Latin diacritics) so untouched keys
/// keep their existing long-press behavior, then overrides the eight
/// Icelandic-specific keys.
extension Callouts.Actions {
    static var icelandic: Self {
        var actions = Self.english
        let icelandicOverrides = Self(characters: [
            "a": "aá",
            "e": "eé",
            "i": "ií",
            "o": "oó",
            "u": "uú",
            "y": "yý",
            "d": "dð",
            "t": "tþ",
        ])
        actions.actionsDictionary.merge(icelandicOverrides.actionsDictionary) { _, new in new }
        return actions
    }
}
