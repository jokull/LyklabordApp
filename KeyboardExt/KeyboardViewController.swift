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
import TypeEngine

/// The `KeyboardApp` descriptor shared by the app and the extension. Kept
/// minimal for the M0 spike: no license key (we stay on the free/MIT tier
/// by design — see PLAN.md decision #4), single locale, App Group wired for
/// the future LearningStore / dictionary sync (M2/M3).
extension KeyboardApp {
    static var betterKeyboard: Self {
        .init(
            name: "Lyklaborð",
            appGroupId: "group.is.lyklabord",
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
        // `BetterKeyboardLayoutService` below is our subclass of
        // `DeviceBasedLayoutService` (see "Bottom-row affordances" section)
        // that adds the SwiftKey-style `.` key between space and return on
        // iPhone (PLAN.md "Bottom-row affordances"); iPad keeps KeyboardKit's
        // stock bottom row unchanged.
        //
        // Callouts (long-press accents) are wired separately via the
        // `.keyboardCalloutActions` view modifier in
        // `viewWillSetupKeyboardView()` below — that's the current, non-
        // deprecated mechanism regardless of layout service choice.
        services.layoutService = BetterKeyboardLayoutService(
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
        // bootstraps itself lazily on its own utility-QoS serial queue (mmap
        // of lemma-is.bin + en.lex + is.lex happens off the main thread —
        // the launch-flicker mitigation in PLAN.md; nothing heavy runs in
        // viewDidLoad). Until the engine is ready it returns empty
        // suggestions. Replaces the default `.disabled` service; the
        // standard KeyboardView toolbar (`toolbar: { $0.view }` below)
        // renders `AutocompleteContext.suggestions`, and the action handler
        // applies `.autocorrect` suggestions on space/delimiter.
        //
        // M2: the App Group id enables personal learning — the service
        // loads the app-compacted personal model (personal-model.json) as
        // the engine's personal vocabulary and appends learning events to
        // learning-events.log. Both fully optional: no App Group access
        // (Full Access denied) degrades to base-model-only, no logging.
        services.autocompleteService = BetterKeyboardAutocompleteService(
            appGroupId: KeyboardApp.betterKeyboard.appGroupId
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
        services.actionHandler = BetterKeyboardActionHandler(controller: self)
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
        (services.autocompleteService as? BetterKeyboardAutocompleteService)?
            .refreshPersonalSnapshotIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // M2: don't lose a verbatim tap/commit buffered right before the
        // keyboard is dismissed (events normally flush on the autocomplete
        // pass after each commit; this covers the last one).
        (services.autocompleteService as? BetterKeyboardAutocompleteService)?
            .flushPendingLearningEvents()
    }

    // MARK: - Text / selection change forwarding

    // Forward host text and selection changes to the autocomplete service so
    // TypingSession never misreads a cursor jump or host-app mutation
    // (autofill, undo, programmatic set) as a user word commit. Both
    // callbacks ALSO fire after our own insertions; the session's
    // window-aware note is idempotent for windows that are valid typing
    // evolutions of its own last-seen state, and the session additionally
    // detects non-append window changes internally — this forwarding is the
    // belt-and-braces layer for cases internal detection cannot see.

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        forwardTextContextChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        forwardTextContextChange()
    }

    private func forwardTextContextChange() {
        guard let service = services.autocompleteService as? BetterKeyboardAutocompleteService
        else { return }
        // Field-type gate (PLAN.md verbatim/URL layer 2): URL/email/web-
        // search fields must never auto-apply a correction.
        service.updateFieldKind(BetterKeyboardAutocompleteService.fieldKind(for: state.keyboardContext))
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
            // Bottom-row affordance #2 (PLAN.md): long-press on the new `.`
            // key (right of the spacebar — see `BetterKeyboardIPhoneLayoutService`
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
final class BetterKeyboardIPhoneLayoutService: KeyboardLayout.iPhoneLayoutService {

    override func bottomActions(
        for context: KeyboardContext
    ) -> KeyboardAction.Row {
        var actions = super.bottomActions(for: context)
        guard context.keyboardType == .alphabetic else { return actions }
        guard let returnIndex = actions.firstIndex(where: { $0.isPrimaryAction }) else { return actions }
        actions.insert(.character("."), at: returnIndex)
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
/// `BetterKeyboardIPhoneLayoutService` (adds the period key) while iPad
/// keeps KeyboardKit's stock `iPadLayoutService`, unmodified — per PLAN.md
/// decision #3 ("iPad functional via KeyboardKit, unoptimized").
///
/// `DeviceBasedLayoutService.iPhoneService`/`iPadService` are `lazy var`
/// (stored properties), which Swift cannot override, so this instead
/// overrides `keyboardLayoutService(for:)` — also `open` — and substitutes
/// our own iPhone service only for the `.phone` case, deferring to
/// `super` (which returns the stock `iPadService`) for everything else.
final class BetterKeyboardLayoutService: KeyboardLayout.DeviceBasedLayoutService {

    private lazy var betterIPhoneService: KeyboardLayoutService = BetterKeyboardIPhoneLayoutService(
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
/// 4. **Verbatim taps**: tapping the quoted `.unknown` escape-hatch slot
///    commits the literal token (KeyboardKit inserts tapped suggestions
///    as-is and never re-applies an autocorrect on that path — the
///    follow-up `handle(.release, on: .character(""))` is not an
///    autocorrect trigger); we additionally tell the session, so a
///    delimiter typed right after cannot re-correct the token either.
final class BetterKeyboardActionHandler: KeyboardAction.StandardActionHandler {

    private var betterAutocompleteService: BetterKeyboardAutocompleteService? {
        autocompleteService as? BetterKeyboardAutocompleteService
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
                BetterKeyboardAutocompleteService.pendingTokenInfoKey
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
            if character.isLetter || character.isNumber,
                let revert = betterAutocompleteService?.pendingContinuationRevert(for: character)
            {
                executeProxyEdit(revert)
            }
            // Punctuation attachment ("word . " → "word. "): the space
            // keystroke after an armed memo re-attaches the period; any
            // other keystroke discards the memo inside the session.
            if let attach = betterAutocompleteService?.pendingPunctuationAttachment(for: character) {
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

    override func handle(_ suggestion: Autocomplete.Suggestion) {
        // 4. Verbatim tap: `.unknown` suggestions are only ever produced by
        // our service's verbatim escape-hatch slot.
        if suggestion.isUnknown {
            betterAutocompleteService?.noteVerbatimChoice(suggestion.text)
        }
        super.handle(suggestion)
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
