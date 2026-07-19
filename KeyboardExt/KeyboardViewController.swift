//
//  KeyboardViewController.swift
//  LyklabordKeyboard
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
import TypeEngine

/// The `KeyboardApp` descriptor shared by the app and the extension. Kept
/// minimal for the M0 spike: no license key (we stay on the free/MIT tier
/// by design — see PLAN.md decision #4), single locale, App Group wired for
/// the future LearningStore / dictionary sync (M2/M3).
extension KeyboardApp {
    static var lyklabord: Self {
        .init(
            name: "Lyklaborð",
            appGroupId: "group.is.solberg.lyklabord",
            locales: [.icelandic]
        )
    }
}

final class KeyboardViewController: KeyboardInputViewController {

    override func viewDidLoad() {
        // Wave 39 activation boundary. Capture before KeyboardKit/App Group
        // setup so the cold report includes controller work that happens
        // before the autocomplete service exists.
        let activationStartedAt = AutocompleteColdStartTracker.now
        super.viewDidLoad()

        // Configure the settings store (App Group backed) and inject the
        // app descriptor into the keyboard state.
        KeyboardSettings.setupStore(for: .lyklabord)
        state.setup(for: .lyklabord)

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
        // `LyklabordLayoutService` below is our subclass of
        // `DeviceBasedLayoutService` (see "Bottom-row affordances" section)
        // that adds the SwiftKey-style `.` key between space and return on
        // iPhone (PLAN.md "Bottom-row affordances"); iPad keeps KeyboardKit's
        // stock bottom row unchanged.
        //
        // Callouts (long-press accents) are wired separately via the
        // `.keyboardCalloutActions` view modifier in
        // `viewWillSetupKeyboardView()` below — that's the current, non-
        // deprecated mechanism regardless of layout service choice.
        services.layoutService = LyklabordLayoutService(
            alphabeticInputSet: .icelandic,
            numericInputSet: .numeric,
            symbolicInputSet: .symbolic
        )

        // Spacebar long-press → cursor movement (PLAN.md "Bottom-row
        // affordances" / "Spacebar behavior"). KeyboardKit 9.9.1 ships this
        // as `Keyboard.SpaceLongPressBehavior.moveInputCursor`, which is
        // already the compiled-in default for `KeyboardSettings
        // .spaceLongPressBehavior` (see `KeyboardSettings.swift`). We still
        // set it explicitly here — rather than relying on the vendored
        // default — because `@AppStorage` persists to the App Group's
        // shared `UserDefaults`: once a value has been written under this
        // key (e.g. by a future settings screen, or a prior build that
        // picked a different default), the compiled-in default no longer
        // applies. Setting it explicitly on every launch keeps this
        // affordance guaranteed regardless of persisted state.
        state.keyboardContext.settings.spaceLongPressBehavior = .moveInputCursor

        // M1: bilingual IS/EN autocomplete via TypeEngine. The service
        // bootstraps itself lazily on its own user-initiated serial queue (mmap
        // of bin-morph.bin + en.lex + is.lex happens off the main thread —
        // the launch-flicker mitigation in PLAN.md; no artifact/model work
        // runs in viewDidLoad). Autocomplete requests serialize behind bootstrap on
        // that queue without blocking the UI thread. Replaces the default
        // `.disabled` service; the
        // standard KeyboardView toolbar (`toolbar: { $0.view }` below)
        // renders `AutocompleteContext.suggestions`, and the action handler
        // applies `.autocorrect` suggestions on space/delimiter.
        //
        // M2: the App Group id enables personal learning — the service
        // loads the app-compacted personal model (personal-model.json) as
        // the engine's personal vocabulary and appends learning events to
        // learning-events.log. Both fully optional: no App Group access
        // (Full Access denied) degrades to base-model-only, no logging.
        services.autocompleteService = LyklabordAutocompleteService(
            appGroupId: KeyboardApp.lyklabord.appGroupId,
            activationStartedAt: activationStartedAt
        )

        // M2 learning: KeyboardKit auto-learns a tapped `.unknown`
        // suggestion (our quoted verbatim escape-hatch slot) by calling
        // `AutocompleteService.learnWord` — but only when this setting is
        // on (defaults to false in vendored 9.9.1). Set explicitly every
        // launch for the same @AppStorage-persistence reason as
        // spaceLongPressBehavior above. Side effect: the same flag enables
        // `tryAutocompleteIgnoreCurrentWord` (auto-ignore on backspace
        // after an autocorrect), which is harmless here — our service's
        // `ignoreWord` is a documented no-op.
        state.autocompleteContext.settings.isAutolearnEnabled = true

        // Verbatim escape hatch + URL handling (PLAN.md): our
        // `StandardActionHandler` subclass (below) excludes '.' from the
        // autocorrect-applying delimiters (the deferral that keeps
        // "profilmynd.tilvinstri.is" from being corrected at the first
        // dot), performs the deferred '.'-apply on the FOLLOWING delimiter,
        // executes revert-on-continuation proxy edits, and forwards
        // verbatim-suggestion taps to the session.
        services.actionHandler = LyklabordActionHandler(controller: self)
    }

    // MARK: - Appearance

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Push the field kind (URL/email/webSearch/secure autocorrect +
        // learning gate) before the first keystroke of a newly focused
        // field can be autocompleted.
        forwardTextContextChange()
        // M2: re-stat the personal model (the containing app compacts it on
        // its own schedule) — one mtime check per keyboard presentation,
        // reload only when the file actually changed.
        (services.autocompleteService as? LyklabordAutocompleteService)?
            .refreshPersonalSnapshotIfNeeded()
        // Spacebar behavior (PLAN.md "Spacebar behavior — three
        // user-selectable modes"): re-read the mode the containing app's
        // settings screen wrote into the App Group suite. Live per
        // presentation — the app is a different process, so a change made
        // there while the keyboard is off-screen is picked up here (without
        // Full Access the suite is unavailable and this stays at mode 1).
        (services.autocompleteService as? LyklabordAutocompleteService)?
            .refreshSpacebarMode()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // M2: don't lose a verbatim tap/commit buffered right before the
        // keyboard is dismissed (events normally flush on the autocomplete
        // pass after each commit; this covers the last one).
        (services.autocompleteService as? LyklabordAutocompleteService)?
            .flushPendingLearningEvents()
    }

    // MARK: - Text / selection change forwarding

    // Forward host text and selection changes to the autocomplete service so
    // TypingSession never misreads a cursor jump or host-app mutation
    // (autofill, undo, programmatic set) as a user word commit. Both
    // callbacks ALSO fire after our own insertions; the session recognizes
    // those EXACTLY via its proxy-edit ledger (every proxy mutation our
    // action handler performs is recorded as an expected before→after
    // window transform — see `LyklabordActionHandler`'s ledger
    // section), and the window-aware note peeks at the same ledger without
    // consuming it, so it is idempotent for our own edits and only resets
    // on genuinely inconsistent windows. This forwarding remains the
    // belt-and-braces layer for changes that never trigger an autocomplete
    // pass of their own.

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        forwardTextContextChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        forwardTextContextChange()
    }

    private func forwardTextContextChange() {
        guard let service = services.autocompleteService as? LyklabordAutocompleteService
        else { return }
        // Field-type gate (PLAN.md verbatim/URL layer 2): URL/email/web-
        // search fields must never auto-apply a correction.
        service.updateFieldKind(LyklabordAutocompleteService.fieldKind(for: state.keyboardContext))
        service.noteTextContextChange(textDocumentProxy.documentContextBeforeInput ?? "")
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
                buttonView: { params in
                    // Accessibility: override the vendored defaults where
                    // they're wrong for this keyboard (see
                    // `betterAccessibilityLabel(for:)` below). Everything
                    // else keeps KeyboardKit's stock label.
                    params.view.lyklabordAccessibility(
                        for: params.item.action,
                        context: controller.state.keyboardContext
                    )
                },
                collapsedView: { $0.view },
                // Real in-keyboard emoji picker. Returning a custom view type
                // (≠ `Emoji.KeyboardWrapper`, the empty Pro placeholder) is
                // what flips KeyboardKit's `hasEmojiKeyboard` to true, which
                // (a) keeps the `.keyboardType(.emojis)` key in the layout
                // instead of stripping it and (b) shows this view when the
                // emoji key is tapped. See `LyklabordEmojiKeyboard`.
                emojiKeyboard: { _ in
                    LyklabordEmojiKeyboard(
                        actionHandler: controller.services.actionHandler
                    )
                },
                // Autocomplete toolbar, but its empty state becomes a quick
                // strip of the user's most-used emoji (frecency) instead of a
                // blank bar. Standard toolbar returns as soon as there are
                // suggestions. See `LyklabordToolbar`.
                toolbar: { params in
                    LyklabordToolbar(
                        autocompleteContext: controller.state.autocompleteContext,
                        actionHandler: controller.services.actionHandler,
                        standard: params.view
                    )
                }
            )
            .keyboardCalloutActions { params in
                // Long-press the emoji key → a quick row of the user's top-10
                // emoji by frecency (seeded with popular defaults), rendered by
                // the same callout UI as the á/é/í diacritic menus. Selecting
                // one inserts it (and records the use). Every other key keeps
                // its Icelandic long-press actions.
                if params.action == .keyboardType(.emojis) {
                    return EmojiFrequencyStore.shared.top(10).map {
                        .emoji(KeyboardKit.Emoji($0))
                    }
                }
                return Callouts.Actions.icelandic.actions(for: params.action)
            }
            // Wave 37: long-press a suggestion that is the user's OWN learned
            // vocabulary to eject it (tap teaches, long-press forgets). Only
            // suggestions the service flags `isPersonalLearned` get the
            // affordance; the confirm is a reversible inline pill. Routes to
            // the autocomplete service's tombstone path (App Group file only,
            // no network). nil when the service is unavailable ⇒ tap-only.
            .autocompleteEjectAffordance(
                (controller.services.autocompleteService
                    as? LyklabordAutocompleteService)
                    .map { service in
                        Autocomplete.EjectAffordance(
                            action: { suggestion in
                                service.ejectPersonalWord(suggestion.text)
                            },
                            confirmTitle: { suggestion in
                                KeyboardStrings.ejectConfirm(suggestion.text)
                            },
                            cancelLabel: KeyboardStrings.ejectCancel
                        )
                    }
            )
        }
    }
}

// MARK: - Keyboard-extension copy (Icelandic)

/// User-facing copy that renders INSIDE the keyboard (the app's `Strings`
/// enum is a separate target). Icelandic-first, warm register — the same
/// COPY RULE as `App/Strings.swift`: system labels stay verbatim English,
/// everything else is Icelandic. Kept tiny; grows only as keyboard-side UI
/// needs strings.
enum KeyboardStrings {

    /// Long-press eject confirm pill (wave 37). Warm, plain Icelandic, with
    /// the word in Icelandic quotation marks; kept short so it fits a
    /// suggestion slot. Full intent: "remove <word> from your dictionary".
    static func ejectConfirm(_ word: String) -> String {
        "Fjarlægja \u{201E}\(word)\u{201C}?"
    }

    /// Accessibility label for the eject cancel (✕) control.
    static let ejectCancel = "Hætta við"
}

// MARK: - Accessibility (VoiceOver labels)

/// VoiceOver label overrides for keys whose vendored KeyboardKit defaults
/// are wrong for this keyboard (accessibility audit, launch wave).
///
/// What the audit found (see `KeyboardAction.accessibilityLabel` in
/// Packages/KeyboardKit/Sources/KeyboardKit/Actions/KeyboardAction+
/// Accessibility.swift — vendored, not edited; the fixes live HERE because
/// this wave owns KeyboardExt only):
///
/// - Correct already, no override: `.character` keys (ð/æ/ö/þ and the `.`
///   key speak the character itself — the speech engine handles Icelandic
///   letters), `.space` ("Bil" via KKL10n's is.lproj — matches the visible
///   key label), `.shift`/`.capsLock` ("Shift"/"Capslock" — icon keys with
///   universally known names), `.nextKeyboard` ("Next Keyboard" — a system
///   affordance named as iOS names it).
/// - Wrong, fixed here:
///   - `.primary` (return key): default speaks the raw type id ("return")
///     while the visible key says "Venda" — a spoken/visible mismatch that
///     confuses a VoiceOver user being helped by a sighted person. Fixed to
///     the same localized text the key displays.
///   - `.keyboardType` switchers: default is developer-speak ("Keyboard
///     Type - numeric"). Fixed to plain Icelandic ("Tölustafir" for "123",
///     "Bókstafir" for "ABC", "Tákn" for "#+=").
///   - `.backspace`: default "Backspace" — fixed to "Eyða", matching the
///     product's Icelandic register (same verb the app's UI uses).
private extension KeyboardAction {
    func betterAccessibilityLabel(for context: KeyboardContext) -> String? {
        switch self {
        case .backspace:
            return "Eyða"
        case .primary(let type):
            // The exact text the key displays ("Venda", "Áfram", "Leita" —
            // KKL10n's is.lproj); icon-only newline falls back to "Venda".
            return type.standardButtonText(for: context.locale) ?? "Venda"
        case .keyboardType(let type):
            switch type {
            case .numeric: return "Tölustafir"
            case .alphabetic: return "Bókstafir"
            case .symbolic: return "Tákn"
            case .emojis: return "Emoji"
            default: return nil
            }
        default:
            return nil
        }
    }
}

private extension View {
    /// Replaces the button's accessibility element with one carrying our
    /// corrected label; falls through untouched when the vendored default
    /// is already right.
    @ViewBuilder
    func lyklabordAccessibility(
        for action: KeyboardAction,
        context: KeyboardContext
    ) -> some View {
        if let label = action.betterAccessibilityLabel(for: context) {
            self
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(label)
        } else {
            self
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
            // Bottom-row affordance #2 (PLAN.md): long-press on the new `.`
            // key (right of the spacebar — see `LyklabordIPhoneLayoutService`
            // below) shows this cluster, period nearest/first since that's
            // the char under the finger. Overrides `Callouts.Actions.base`'s
            // stock "." -> ".…" mapping.
            ".": ".,!?@#:;-",
        ])
        actions.actionsDictionary.merge(icelandicOverrides.actionsDictionary) { _, new in new }
        return actions
    }
}

// MARK: - Bottom-row affordances (period key)

/// iPhone layout service that inserts a `.` key between the spacebar and
/// the return key, matching SwiftKey/Gboard muscle memory (PLAN.md
/// "Bottom-row affordances": `[123] [globe] [space] [.] [return]`).
///
/// Subclasses the vendored `KeyboardLayout.iPhoneLayoutService` rather than
/// editing it in place — `bottomActions(for:)` is `open`, so this is the
/// same non-deprecated override mechanism the rest of this file relies on
/// (see the layout-service comment in `viewDidLoad()` above). Only applies
/// to the plain alphabetic keyboard type: the email/url/webSearch bottom
/// rows (which already substitute `@`/`.com`/etc. for the space slot) and
/// the numeric/symbolic keypads (whose input sets already contain `.`/`,`)
/// are left untouched.
final class LyklabordIPhoneLayoutService: KeyboardLayout.iPhoneLayoutService {

    override func bottomActions(
        for context: KeyboardContext
    ) -> KeyboardAction.Row {
        var actions = super.bottomActions(for: context)
        guard context.keyboardType == .alphabetic else { return actions }
        // Exactly one emoji key, on the far left of the bottom row — the
        // bottom-left corner is where the thumb reaches for emoji. KeyboardKit's
        // stock layout ALSO adds a `.keyboardType(.emojis)` in the globe slot
        // whenever the input-switch (globe) key is absent, so remove any it
        // added before inserting ours; otherwise the row shows two emoji keys.
        actions.removeAll { $0 == .keyboardType(.emojis) }
        actions.insert(.keyboardType(.emojis), at: 0)
        // Period key immediately before the return key (dogfood pattern).
        if let returnIndex = actions.firstIndex(where: { $0.isPrimaryAction }) {
            actions.insert(.character("."), at: returnIndex)
        }
        return actions
    }

    /// Bottom-row width tuning (dogfood feedback 2026-07-15: the period key
    /// plus KeyboardKit's stock 25% return squeezed the spacebar to ~38% of
    /// the row, causing space-taps to land on '.'). Return narrows to 19%
    /// (landscape 16%) and the period key to 8% — slimmer than a letter key,
    /// it's a modifier-class target — handing the reclaimed ~11% to the
    /// spacebar (~45%, near Apple's proportions). Alphabetic only; other
    /// keyboard types keep stock widths.
    override func itemSizeWidth(
        for action: KeyboardAction,
        row: Int,
        index: Int,
        context: KeyboardContext
    ) -> KeyboardLayout.ItemWidth {
        if context.keyboardType == .alphabetic,
            row == inputSet(for: context).rows.count
        {
            switch action {
            case .character("."):
                return .percentage(0.08)
            case .keyboardType(.emojis):
                // Fixed modifier-class width for the emoji key so it doesn't
                // absorb `.available` space; the spacebar (`.available`) simply
                // yields this slice instead of the emoji key ballooning.
                return .percentage(0.11)
            case .primary:
                let portrait = context.interfaceOrientation.isPortrait
                return .percentage(portrait ? 0.19 : 0.16)
            default:
                break
            }
        }
        return super.itemSizeWidth(for: action, row: row, index: index, context: context)
    }
}

/// Device-based layout service that routes iPhone through
/// `LyklabordIPhoneLayoutService` (adds the period key) while iPad
/// keeps KeyboardKit's stock `iPadLayoutService`, unmodified — per PLAN.md
/// decision #3 ("iPad functional via KeyboardKit, unoptimized").
///
/// `DeviceBasedLayoutService.iPhoneService`/`iPadService` are `lazy var`
/// (stored properties), which Swift cannot override, so this instead
/// overrides `keyboardLayoutService(for:)` — also `open` — and substitutes
/// our own iPhone service only for the `.phone` case, deferring to
/// `super` (which returns the stock `iPadService`) for everything else.
final class LyklabordLayoutService: KeyboardLayout.DeviceBasedLayoutService {

    private lazy var lyklabordIPhoneService: KeyboardLayoutService = LyklabordIPhoneLayoutService(
        alphabeticInputSet: alphabeticInputSet,
        numericInputSet: numericInputSet,
        symbolicInputSet: symbolicInputSet
    )

    override func keyboardLayoutService(
        for context: KeyboardContext
    ) -> KeyboardLayoutService {
        switch context.deviceTypeForKeyboard {
        case .phone: lyklabordIPhoneService
        default: super.keyboardLayoutService(for: context)
        }
    }
}

// MARK: - Verbatim escape hatch + URL handling (action handler)

/// `StandardActionHandler` subclass implementing the keyboard-side half of
/// PLAN.md's "Verbatim escape hatch + URL handling" (the session-side half
/// lives in `TypeEngine.TypingSession`, shared with the `type-repl`
/// harness whose Typist mirrors exactly these behaviors):
///
/// 1. **'.'-deferral (primary mechanism on device)**: stock KeyboardKit
///    applies the pending `.autocorrect` suggestion on EVERY autocorrect
///    trigger, including '.'. That is precisely the reported
///    "profilmynd." → "prófílmynd." bug: at the '.' keystroke nobody can
///    know whether the dot ends a sentence or continues a URL/domain. Our
///    `shouldApplyAutocorrectSuggestion` excludes '.', so the dot inserts
///    literally and the session keeps the token pending ("teh.").
/// 2. **Deferred apply**: when the NEXT delimiter arrives (space/return/…),
///    the session's re-armed suggestion ("the.") must be applied even
///    though KeyboardKit now considers the cursor "at a new word" (its own
///    word boundary stops at the dot). We allow that apply exactly when
///    the armed suggestion carries a pending deferred-dot token that still
///    matches the live proxy text (staleness guard); its
///    `additionalDeleteCount` (set by the service bridge) makes
///    `replaceCurrentWordPreCursorPart` delete the whole pending token.
/// 3. **Revert-on-continuation (fallback)**: if a '.'-triggered
///    auto-replacement DID happen (any path we don't control) and the very
///    next keystroke is a letter/digit, the session orders a proxy edit
///    that restores the originally typed token before the new character is
///    inserted — URLs self-heal ("prófílmynd." → "profilmynd.t…").
/// 3b. **Coordinate plumbing (PLAN.md "Touch decoding", stage 1)**: every
///    released character forwards its touch point (within-key normalized
///    offsets from the vendored fork's `Keyboard.TouchEvidence` latch) to
///    the session via `noteKeyTap`; callout-selected (long-press)
///    characters forward `noteLongPressInsertion` instead — the
///    deliberateness signal, with no tap sample.
/// 4. **Verbatim taps**: tapping the quoted `.unknown` escape-hatch slot
///    commits the literal token (KeyboardKit inserts tapped suggestions
///    as-is and never re-applies an autocorrect on that path — the
///    follow-up `handle(.release, on: .character(""))` is not an
///    autocorrect trigger); we additionally tell the session, so a
///    delimiter typed right after cannot re-correct the token either.
/// 5. **Proxy-edit ledger**: every outermost `handle` call snapshots
///    `documentContextBeforeInput` around ALL the proxy edits it causes and
///    records the before→after pair into the session's expected-edit
///    ledger (azooKey pattern, research/oss-harvest.md §2), giving the
///    session exact self-vs-external attribution for every window
///    observation — see the "Proxy-edit ledger" section below.
///
/// It also implements PLAN.md "Spacebar behavior" **mode 2** ("always insert
/// a prediction"): on a `.space` release with no word in progress it injects
/// the top bar prediction before the space (see
/// `shouldInsertSpacePrediction()` / `spacePrediction()`). **Mode 3** ("always
/// insert a space") needs no code here — the service demotes `.autocorrect`
/// suggestions to `.regular`, so the space-commit path finds nothing to apply.
/// The active mode is read from the App Group suite via the service
/// (`LyklabordAutocompleteService.spacebarMode`).
final class LyklabordActionHandler: KeyboardAction.StandardActionHandler {

    private var lyklabordAutocompleteService: LyklabordAutocompleteService? {
        autocompleteService as? LyklabordAutocompleteService
    }

    // MARK: - Proxy-edit ledger (azooKey pattern, research/oss-harvest.md §2)

    // Every proxy mutation this handler causes — the keystroke insert and
    // everything KeyboardKit hangs off it (autocorrect apply, auto-inserted
    // space, double-space sentence ender), suggestion taps, our own
    // revert/attachment edits and the mode-2 prediction insert — is
    // recorded into the TypingSession's expected-edit ledger as ONE
    // before→after window transform per outermost `handle` call. The
    // session then attributes window observations EXACTLY: explained
    // changes are certainly ours, anything else is external (cursor jump,
    // host mutation, autofill) — no shape heuristics on device.
    //
    // Snapshot discipline: `documentContextBeforeInput` reflects our own
    // just-issued edits synchronously (the documented staleness class is
    // proxy-vs-host divergence on later reads, not self-read-back), so the
    // before/after pair is exact. The record is flushed from
    // `tryPerformAutocomplete` — after every edit of the handle sequence,
    // but BEFORE KeyboardKit's autocomplete call can enqueue the observing
    // pass onto the service's serial queue — with a depth-guarded fallback
    // at the outermost `handle` exit for paths that skip autocomplete.

    /// Window snapshot taken at the OUTERMOST `handle` entry; consumed by
    /// `recordPendingSelfEdit()`. `handle(_ suggestion:)` nests a
    /// `handle(.release, .character(""))` call, hence the depth guard.
    private var ledgerBeforeWindow: String?
    private var ledgerHandleDepth = 0

    private func recordPendingSelfEdit() {
        guard let before = ledgerBeforeWindow else { return }
        ledgerBeforeWindow = nil
        let after = keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        lyklabordAutocompleteService?.noteSelfEdit(before: before, after: after)
    }

    override func tryPerformAutocomplete(
        after gesture: Keyboard.Gesture,
        on action: KeyboardAction
    ) {
        // Flush the ledger record FIRST: its queue.async must precede the
        // autocomplete Task's, so the observation finds the expectation.
        recordPendingSelfEdit()
        super.tryPerformAutocomplete(after: gesture, on: action)
    }

    override func shouldApplyAutocorrectSuggestion(
        before gesture: Keyboard.Gesture,
        on action: KeyboardAction
    ) -> Bool {
        // 1. '.'-deferral: the period keystroke never applies autocorrect.
        if action == .character(".") { return false }
        if super.shouldApplyAutocorrectSuggestion(before: gesture, on: action) { return true }
        // 2. Deferred apply: super said no — the only case we overrule is
        // its `isCursorAtNewWord` veto when the armed suggestion is our
        // deferred-dot correction for the token that is still, verbatim,
        // at the cursor (the proxy-suffix check also rejects stale bars).
        guard gesture == .release, action.shouldApplyAutocorrectSuggestion else { return false }
        if action == .space, spaceDragGestureHandler.currentDragTextPositionOffset != 0 {
            return false
        }
        guard
            let suggestion = autocompleteContext.suggestions.first(where: { $0.isAutocorrect }),
            let pending = suggestion.additionalInfo[
                LyklabordAutocompleteService.pendingTokenInfoKey
            ],
            pending.hasSuffix("."),
            keyboardContext.textDocumentProxy.documentContextBeforeInput?.hasSuffix(pending) == true
        else { return false }
        return true
    }

    override func handle(
        _ gesture: Keyboard.Gesture,
        on action: KeyboardAction,
        replaced: Bool
    ) {
        // Proxy-edit ledger: snapshot the window before ANY of this call's
        // proxy edits (including the mode-2 insert below); flushed by the
        // tryPerformAutocomplete override, or at the exit fallback for
        // paths that never reach autocomplete. Outermost call only.
        if ledgerHandleDepth == 0 {
            ledgerBeforeWindow =
                keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        }
        ledgerHandleDepth += 1
        defer {
            ledgerHandleDepth -= 1
            if ledgerHandleDepth == 0 { recordPendingSelfEdit() }
        }

        // Spacebar mode 2 ("always insert a prediction", PLAN.md "Spacebar
        // behavior — three user-selectable modes"): on a `.space` release
        // with NO word in progress, insert the top bar prediction BEFORE the
        // space instead of a bare space ("sentence by spacebar"). Runs before
        // `super`, which then inserts the actual space, refreshes
        // autocomplete, and fires feedback as usual.
        //
        // This never double-fires with mode 1: mode 1 commits only when a
        // word IS in progress (mid-word autocorrect-on-space), whereas mode 2
        // fires only when NO word is in progress — the two conditions are
        // mutually exclusive. After the prediction is inserted the buffer no
        // longer ends in a space, so `super`'s double-space→". " path also
        // can't misfire (it requires two trailing spaces). Guards below keep
        // it out of URL/email/secure fields and off space-cursor drags.
        if gesture == .release, action == .space, shouldInsertSpacePrediction(),
            let prediction = spacePrediction()
        {
            keyboardContext.textDocumentProxy.insertText(prediction)
        }

        // DEV-MODE session recorder: forward a backspace so the analyzer can
        // reconstruct backspace-retype "miss" sequences. No-op unless the
        // containing app has armed a recording session (single flag check on
        // the engine queue); never records anything itself.
        if gesture == .release, action == .backspace {
            lyklabordAutocompleteService?.noteRecordedBackspace()
        }

        // Emoji frecency: every emoji insertion — from the full emoji keyboard,
        // the long-press quick-row, or the empty-state suggestion strip — bumps
        // its decayed score in the on-device store, so those surfaces reflect
        // what THIS user reaches for lately. App Group only, never synced.
        if gesture == .release, case .emoji(let emoji) = action {
            EmojiFrequencyStore.shared.record(emoji.char)
        }

        // 3. Revert-on-continuation: before a letter/digit is inserted, the
        // session may order the last '.'-triggered auto-replacement undone
        // (it holds the (original, corrected) memo for exactly one
        // keystroke). Executed as plain proxy edits, then the keystroke
        // proceeds normally.
        if gesture == .release,
            case .character(let char) = action,
            char.count == 1,
            let character = char.first
        {
            // Coordinate plumbing (PLAN.md "Touch decoding", stage 1):
            // forward the released character's touch point — or its
            // callout-selection deliberateness marker — to the session
            // BEFORE super inserts the text: the autocomplete pass that
            // consumes the tap is enqueued by that insertion, after this
            // note, on the same serial engine queue (ordering guaranteed).
            // The fork's TouchEvidence latches are consume-on-read and
            // matched on the action, so a stale point can never attach to
            // the wrong keystroke. All O(1), no per-tap allocation.
            if Keyboard.TouchEvidence.consumeCalloutSelection(matching: action) {
                // Long-press callout character: deliberateness signal, no
                // tap sample (the touch belongs to the base key).
                lyklabordAutocompleteService?.noteLongPressInsertion(character)
            } else if let touch = Keyboard.TouchEvidence.consumeReleaseTouch(matching: action) {
                lyklabordAutocompleteService?.noteKeyTap(
                    character, dx: touch.dxNorm, dy: touch.dyNorm)
            }
            if character.isLetter || character.isNumber,
                let revert = lyklabordAutocompleteService?.pendingContinuationRevert(for: character)
            {
                executeProxyEdit(revert)
            }
            // Punctuation attachment ("word . " → "word. "): the space
            // keystroke after an armed memo re-attaches the period; any
            // other keystroke discards the memo inside the session.
            if let attach = lyklabordAutocompleteService?.pendingPunctuationAttachment(for: character) {
                executeProxyEdit(attach)
            }
        }
        super.handle(gesture, on: action, replaced: replaced)
    }

    private func executeProxyEdit(_ edit: RevertInstruction) {
        let proxy = keyboardContext.textDocumentProxy
        for _ in 0..<edit.deleteCount { proxy.deleteBackward() }
        proxy.insertText(edit.text)
    }

    // MARK: - Spacebar mode 2 ("always insert a prediction")

    /// Whether a `.space` release should inject the current prediction
    /// (PLAN.md "Spacebar behavior" mode 2). All guards must pass:
    ///
    /// - The user selected mode 2 (read from the App Group suite via the
    ///   service; defaults to mode 1 without Full Access).
    /// - Not a space-cursor drag (long-press space to move the caret must
    ///   stay a caret move, never a word insert).
    /// - Standard field only — never URL/email/web-search/secure fields
    ///   (same field-kind gate the correction pipeline uses; injecting a
    ///   predicted word into a password or URL would be wrong and unsafe).
    /// - "No word in progress": the buffer is empty or ends in a space, i.e.
    ///   the space about to be typed would start a new word rather than
    ///   commit a mid-word correction. Requiring a trailing *space* (not just
    ///   any delimiter) keeps predictions from gluing onto a preceding
    ///   "word." / "word," and mirrors "cursor after a completed word + space
    ///   would insert".
    private func shouldInsertSpacePrediction() -> Bool {
        guard lyklabordAutocompleteService?.spacebarMode == .alwaysInsertPrediction else { return false }
        // Space-cursor drag in progress → this release is a caret move, not a
        // space insert (same probe the deferred-'.' override uses; the
        // `isSpaceCursorDrag` helper on `StandardActionHandler` is internal to
        // KeyboardKit, so we read the gesture handler directly).
        if spaceDragGestureHandler.currentDragTextPositionOffset != 0 { return false }
        guard LyklabordAutocompleteService.fieldKind(for: keyboardContext) == .standard else {
            return false
        }
        let before = keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        return before.isEmpty || before.hasSuffix(" ")
    }

    /// The prediction to inject on space: the primary (top-ranked) bar
    /// suggestion, skipping the quoted verbatim `.unknown` slot and any emoji
    /// suggestion. With no word in progress there is nothing to autocorrect,
    /// so this is simply the best next-word prediction the engine produced;
    /// `nil` (empty bar) falls back to a plain space.
    private func spacePrediction() -> String? {
        let suggestion = autocompleteContext.suggestions.first {
            !$0.isUnknown && $0.type != .emoji && !$0.text.isEmpty
        }
        return suggestion?.text
    }

    override func handle(_ suggestion: Autocomplete.Suggestion) {
        // Proxy-edit ledger: a suggestion tap edits the proxy
        // (`insertAutocompleteSuggestion`: replace token + auto-space) and
        // then nests a `handle(.release, .character(""))` — the depth guard
        // makes this ONE record covering the whole tap. Same flush points
        // as the gesture path (the nested handle's tryPerformAutocomplete,
        // else the exit fallback).
        if ledgerHandleDepth == 0 {
            ledgerBeforeWindow =
                keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        }
        ledgerHandleDepth += 1
        defer {
            ledgerHandleDepth -= 1
            if ledgerHandleDepth == 0 { recordPendingSelfEdit() }
        }

        // 4. Verbatim tap: `.unknown` suggestions are produced by our
        // service's verbatim escape-hatch slot AND the wave-36 reserved
        // literal-revert slot. A `.unknown` tap is first offered to the
        // revert path: if it WAS the armed literal-revert slot, the session
        // records the rejection (correctionReverted event, re-correction
        // suppressed) and the recorder logs a distinct "literal-revert" kind;
        // otherwise it is the ordinary verbatim escape hatch (learn + tap
        // log). super.handle performs the proxy edit either way, wrapped by
        // this call's ledger snapshot — so the revert is attributed as a
        // self-edit, never as an engine correction.
        if suggestion.isUnknown,
            lyklabordAutocompleteService?.noteLiteralRevertChoice(suggestion.text) == true
        {
            lyklabordAutocompleteService?.noteRecordedLiteralRevert(suggestion.text)
        } else {
            if suggestion.isUnknown {
                lyklabordAutocompleteService?.noteVerbatimChoice(suggestion.text)
            }
            // DEV-MODE recorder: log the tapped candidate as the applied
            // action of the next pass. No-op unless a session is armed.
            lyklabordAutocompleteService?.noteRecordedSuggestionTap(suggestion.text)
        }
        super.handle(suggestion)
    }

    /// Apply-time staleness guard (wave #28) + DEV-MODE recorder hook.
    /// `tryApplyAutocorrectSuggestion` is the single choke point where
    /// KeyboardKit auto-applies the pending `.autocorrect` on a delimiter —
    /// both the plain space-commit and our deferred-'.' apply flow through
    /// it (see the fork's `handle(_:on:replaced:)` sequence).
    ///
    /// The guard closes the real-device race from session
    /// 2026-07-17T08-30-35: suggestion delivery from the async engine queue
    /// to the main-actor `autocompleteContext` is not guaranteed current
    /// relative to keystrokes, so the suggestion sitting in the context can
    /// belong to a PREVIOUS word ("Þátturinn" applied over "Lovr", six
    /// passes stale). Every suggestion our service bridges carries the
    /// engine's pending token in `additionalInfo` (the WHOLE session token
    /// — dots and deferred trailing dot included — matching the
    /// `additionalDeleteCount` machinery, NOT KeyboardKit's dot-sheared
    /// current word); at apply time we require it to still equal the live
    /// proxy token the delimiter is about to commit (case-sensitively; the
    /// pure decision lives in `TypeEngine.AutocorrectApplyGuard`, unit-
    /// tested on macOS). Mismatch ⇒ skip the apply entirely — the delimiter
    /// inserts plainly and the user keeps what they typed. Bar taps are
    /// unaffected (`handle(_ suggestion:)` never comes through here).
    ///
    /// Ledger note: nothing is pre-armed for an apply — the proxy-edit
    /// ledger records the ACTUAL before→after window around the whole
    /// `handle` call (snapshot at entry, flush at `tryPerformAutocomplete`),
    /// so a skipped apply simply yields a smaller after-window (just the
    /// delimiter) and classifies as a plain typing evolution.
    ///
    /// Recorder: the applied/skipped text is noted BEFORE super mutates the
    /// document, so the following autocomplete pass attributes it. No-op
    /// unless a recording session is armed.
    override func tryApplyAutocorrectSuggestion(
        before gesture: Keyboard.Gesture,
        on action: KeyboardAction
    ) {
        guard
            shouldApplyAutocorrectSuggestion(before: gesture, on: action),
            let suggestion = autocompleteContext.suggestions.first(where: { $0.isAutocorrect })
        else { return }  // mirrors super's own early-outs (it would no-op too)
        let window = keyboardContext.textDocumentProxy.documentContextBeforeInput ?? ""
        guard
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: suggestion.additionalInfo[
                    LyklabordAutocompleteService.pendingTokenInfoKey
                ],
                textBeforeCursor: window
            )
        else {
            // Stale suggestion: skip the apply, insert the delimiter plainly.
            lyklabordAutocompleteService?.noteRecordedStaleAutocorrectSkip(suggestion.text)
            return
        }
        lyklabordAutocompleteService?.noteRecordedAutocorrectApplied(suggestion.text)
        super.tryApplyAutocorrectSuggestion(before: gesture, on: action)
    }
}

// MARK: - Double-space → ". " (built-in, no code needed)

// PLAN.md bottom-row affordance #3 ("Double-space → '. '") turned out to
// already be a fully wired KeyboardKit 9.9.1 feature, not something to
// implement:
//
//   - `Keyboard.StandardKeyboardBehavior.shouldEndCurrentSentence(after:on:)`
//     (`Packages/KeyboardKit/Sources/KeyboardKit/_Keyboard/Keyboard+StandardKeyboardBehavior.swift`)
//     returns true on `.release` of `.space` when the proxy's text before
//     the cursor ends in two spaces, the cursor is at a new word, the
//     previous sentence isn't already closed, and the second tap landed
//     within `endSentenceThreshold` (3s default) of the first.
//   - `KeyboardAction.StandardActionHandler.tryEndCurrentSentence(after:on:)`
//     calls that check unconditionally as part of every `handle(_:on:)`,
//     then does `textDocumentProxy.endSentence(withText: ". ")`, which
//     deletes the trailing spaces and inserts ". ".
//
// Both `services.keyboardBehavior` and `services.actionHandler` are left
// at their KeyboardKit defaults (`Keyboard.StandardKeyboardBehavior` /
// `KeyboardAction.StandardActionHandler`) in this file, so this fires as-is.
// Regression coverage: `Keyboard_StandardKeyboardBehaviorTests
// .testShouldEndSentenceOnlyForSpaceAfterPreviousSpace` (upstream, already
// in the vendored test suite) plus the new
// `KeyboardAction_SpaceSequencingTests` in
// `Packages/KeyboardKit/Tests/KeyboardKitTests/Actions/` (added for this
// change), which exercises the same behavior end-to-end through
// `StandardActionHandler.handle(_:on:)` and confirms it doesn't fire on a
// single space or disturb the mode-1 autocorrect-on-space commit (PLAN.md
// "Spacebar behavior").
