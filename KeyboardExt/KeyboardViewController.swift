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
import LemmaCore
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

        // Custom layout (input keys) and callouts (long-press accents).
        services.layoutService = IcelandicKeyboardLayoutService()
        services.calloutService = IcelandicCalloutService()

        // M0 smoke: mmap the full BÍN binary from the extension bundle and
        // prove the LemmaCore chain works inside the keyboard process.
        // TODO(M1): replace with LemmaCoreAutocompleteService wired into
        //   services.autocompleteService (mmap-backed BÍN-aware
        //   corrector/predictor) instead of the default `.disabled` one.
        if let url = Bundle(for: Self.self).url(forResource: "lemma-is", withExtension: "bin") {
            do {
                let lemmatizer = try BinaryLemmatizer(contentsOf: url)
                let probe = lemmatizer.lemmatize("hestinum")
                NSLog("[better-keyboard] LemmaCore loaded: %d word forms, hestinum -> %@",
                      lemmatizer.wordFormCount, probe.joined(separator: ","))
            } catch {
                NSLog("[better-keyboard] LemmaCore load FAILED: %@", String(describing: error))
            }
        } else {
            NSLog("[better-keyboard] lemma-is.bin missing from extension bundle")
        }
    }

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { controller in
            KeyboardView(
                state: controller.state,
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { $0.view }
            )
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

/// Generates the full keyboard layout (letters + numeric + symbolic pages)
/// using the Icelandic input set for the alphabetic page. Numeric/symbolic
/// pages reuse KeyboardKit's standard sets for now.
final class IcelandicKeyboardLayoutService: KeyboardLayout.BaseLayoutService {
    init() {
        super.init(
            alphabeticInputSet: .icelandic,
            numericInputSet: .numeric,
            symbolicInputSet: .symbolic
        )
    }
}

// MARK: - Icelandic Callouts (long-press accents)

/// Long-press callout actions for the Icelandic layout.
///
/// Provides the accented vowels á é í ó ú ý on long-press of their base
/// letter (per PLAN.md v1 scope), and keeps ð/þ discoverable on long-press
/// of d/t as a secondary path even though they're also dedicated keys.
final class IcelandicCalloutService: Callouts.BaseCalloutService {
    override func calloutActionString(for char: String) -> String {
        switch char {
        case "a": return "aá"
        case "e": return "eé"
        case "i": return "ií"
        case "o": return "oó"
        case "u": return "uú"
        case "y": return "yý"
        case "d": return "dð"
        case "t": return "tþ"
        default: return super.calloutActionString(for: char)
        }
    }
}
