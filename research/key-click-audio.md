# Key-click audio — what the platform intends, what other keyboards do, what we should do

*Researched 2026-10-05. Sources: developer.apple.com (current docs via the JSON doc API, plus the archived App Extension Programming Guide and Text Programming Guide), support.apple.com, vendor help centres (Microsoft, Grammarly, Google), source code of azooKey and Hamster, upstream `KeyboardKit/KeyboardKit` issues via `gh`, our vendored KeyboardKit at `Packages/KeyboardKit`. Two developer blog posts are used as anecdote and labelled as such. No device testing was done for this document; every "works / doesn't work on device" statement below is somebody else's report.*

Trigger: a user asked (in Icelandic) whether they can turn off the sound "and thereby the slowdown it causes". We ship a haptic toggle and no audio toggle.

## Verdict up front

- **There is no audio off-switch for our keyboard today other than the hardware ringer switch / volume.** `FeedbackSettings.isAudioFeedbackEnabled` defaults to `true` and nothing in `App/` or `KeyboardExt/` writes it. The user's first request is legitimate and cheap to satisfy.
- **The belief that system sound IDs 1104/1155/1156 follow iOS Settings → Sounds & Haptics → Keyboard Feedback → Sound is refuted**, by a vendor support page and an upstream KeyboardKit bug report. Only `playInputClick()` is documented by Apple as honouring that setting. So a user who has turned keyboard sound off system-wide still hears our clicks.
- **Full Access for audio is a doc-versus-practice split.** Apple's docs say a keyboard without open access has "no access to microphone and speaker" and list `playInputClick` under open-access capabilities. Developers report, and one shipping open-source keyboard's code assumes, that `AudioServicesPlaySystemSound` plays without Full Access. Not verified on device by us.
- **The "sound causes slowdown" claim is unverified.** I found no measurement, Apple statement, or upstream issue showing that a key-click system sound adds input latency in a keyboard extension. There is one documented limitation (one system sound at a time) that can make clicks drop or trail under fast typing, which a user could plausibly read as lag.
- **Ecosystem norm: an in-app toggle.** SwiftKey, Grammarly, azooKey and Hamster all have one. Defaults are split; the two open-source keyboards whose source I could read both default sound **off**.

---

## 0. What our code does today

Read from the vendored source, not re-derived from docs.

- IDs: `.input` = 1104, `.delete` = 1155, `.system` = 1156 (`Packages/KeyboardKit/Sources/KeyboardKit/Feedback/Feedback+Audio.swift:44-53`).
- Playback: a bare `AudioServicesPlaySystemSound(id)` with no dispatch, no completion handler (`Feedback/Feedback+AudioEngine.swift:41-46`). For the three standard IDs there is no registration step; `AudioServicesCreateSystemSoundID` is only used for `.customUrl` sounds, cached per URL in a static dictionary, and we don't use custom URLs.
- Trigger: `StandardActionHandler.handle(_:on:replaced:)` calls `tryTriggerFeedback` **before** performing the action (`Actions/Services/KeyboardAction+StandardActionHandler.swift:230`), synchronously on the caller's thread. In practice that is the main thread, since gestures arrive from SwiftUI and our own subclass uses `MainActor.assumeIsolated` in the same method (`KeyboardExt/KeyboardViewController.swift:1040-1048`).
- Which gestures: `.press` on input and system keys, `.press` and `.repeatPress` on backspace; nothing on `.release`; nothing on space long-press (`…StandardActionHandler.swift:573-585`). So one call per key-down, plus one per backspace repeat tick.
- Gate: `feedbackContext.settings.isAudioFeedbackEnabled` only (`…StandardActionHandler.swift:612-617`). No `hasFullAccess` check, no system-setting check.
- App side: the haptic toggle writes KeyboardKit's own key directly, `com.keyboardkit.settings.feedback.isHapticFeedbackEnabled` (`App/AppModel.swift:46-47`, `App/SettingsView.swift:65-66`). The audio key is the same shape with `isAudioFeedbackEnabled`.
- `KeyboardExt/Info.plist` has `RequestsOpenAccess = true`.

## 1. Platform-intended API

**Apple's documented path is `UIDevice.current.playInputClick()` plus `UIInputViewAudioFeedback`.**

- `playInputClick()`: "Use this method to play the standard system keyboard click in response to a user tapping in a custom input or keyboard accessory view. A click plays only if the user has enabled keyboard clicks in Settings > Sounds, and only if the input view is itself enabled and visible." Enabling requires adopting `UIInputViewAudioFeedback` on the input view class and returning `true` from `enableInputClicksWhenVisible`. ([playInputClick()](https://developer.apple.com/documentation/uikit/uidevice/playinputclick()))
- `enableInputClicksWhenVisible`: "Input clicks will be produced only if the user has also enabled keyboard clicks in Settings > Sounds." ([doc](https://developer.apple.com/documentation/uikit/uiinputviewaudiofeedback/enableinputclickswhenvisible))
- `UIInputViewAudioFeedback`: "Implementation of this protocol is optional but expected." ([doc](https://developer.apple.com/documentation/uikit/uiinputviewaudiofeedback))
- Text Programming Guide (archived): "The system automatically manages the audio session for custom input clicks, including audio ducking as needed." ([Custom Views for Data Input](https://developer.apple.com/library/archive/documentation/StringsTextFonts/Conceptual/TextAndWebiPhoneOS/InputViews/InputViews.html))

These docs were written for in-app `inputView` / `inputAccessoryView`. What Apple says specifically about keyboard *extensions*:

- The archived App Extension Programming Guide (Custom Keyboard) mentions key-click sound exactly once, in the list of capabilities gained by requesting open access: "Ability to play audio, including keyboard clicks using the `playInputClick` method". `UIInputViewAudioFeedback` is not mentioned anywhere in that chapter. ([Custom Keyboard](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html))
- The current replacement doc lists, for a keyboard without open access: "No access to microphone and speaker". It no longer names `playInputClick`. ([Configuring open access for a custom keyboard](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard))

So: `playInputClick()` is the intended API, Apple implies it works in an extension, and Apple ties it to Full Access. **Whether it actually produces sound in a SwiftUI-hosted keyboard extension like ours is not verified.** The protocol must be adopted by a `UIView`/`UIInputView` subclass in the input view hierarchy; an Apple forum thread asking how to satisfy that from SwiftUI has zero replies ([thread 712749](https://developer.apple.com/forums/thread/712749), Aug 2022). KeyboardKit never used this API.

One functional limit: `playInputClick()` is a single sound. A 2018 developer guide notes it "plays only the sound of character keys" and reaches for system sound IDs to get distinct delete and modifier sounds ([Shyngys Kassymov, iOS Custom Keyboard Guide](https://shyngys.com/ios-custom-keyboard-guide), anecdotal).

## 2. Which API respects the user's settings

| | `playInputClick()` | `AudioServicesPlaySystemSound(1104/1155/1156)` |
|---|---|---|
| (a) Settings → Sounds & Haptics → Keyboard Feedback → Sound | **Yes — Apple-documented** (quotes in §1) | **No — vendor- and issue-reported; Apple docs are silent** |
| (b) Ringer / silent switch | Not stated in Apple's docs. Presumed to behave like the system keyboard; not verified | **Muted by the switch — vendor-reported only** |
| Volume | Not stated | "Sounds play at the current system audio volume, with no programmatic volume control available" (Apple) |

(Apple's developer docs call the setting "Settings > Sounds"; the current user-facing path is Settings → Sounds & Haptics → Keyboard Feedback → Sound, per [Apple Support 102463](https://support.apple.com/en-us/102463). Same setting.)

Evidence for the right-hand column:

- **(a) refuted.** Microsoft's SwiftKey help page: "if keyboard click is turned off in Apple settings > Sounds & Haptics, this will not affect the settings selected in SwiftKey." ([Microsoft Support](https://support.microsoft.com/en-us/topic/how-do-i-change-the-sounds-or-vibrations-that-my-microsoft-swiftkey-keyboard-makes-3a36e887-3faa-417a-becb-c24cb02750a2)). That page does not say which API SwiftKey uses, so it is evidence about a third-party keyboard's observed behaviour, not about the IDs as such.
- **(a) refuted, same API as ours.** KeyboardKit issue [#378](https://github.com/KeyboardKit/KeyboardKit/issues/378) "Detect iOS system settings for audio and haptics" (Dec 2021): "KeyboardKit is not respecting the 'Keyboard Clicks' settings … tapping sound continues to play even when the 'Keyboard Clicks' is turned off by the user". Maintainer reply: "Reading and using these values would be a dream, but I haven't found a way to do so." Closed without a fix. This is the exact code path we vendor.
- **(b)** Same Microsoft page: "flicking the iPhone's Ringer switch to the red position will also mute Microsoft SwiftKey's key click." Vendor-reported, API unstated. Apple's `AudioServicesPlaySystemSound` reference does not mention the ringer switch at all ([doc](https://developer.apple.com/documentation/audiotoolbox/audioservicesplaysystemsound(_:))).
- Tech-press corroboration for (a), weak: "This works for Apple's stock keyboard, but not all third-party keyboards acknowledge the setting" ([Gadget Hacks](https://ios.gadgethacks.com/how-to/sick-your-iphone-keyboards-annoying-click-sounds-try-one-these-solutions-0331276/), undated).

Net: the brief's working assumption was wrong. With our current API, the system Keyboard Feedback sound toggle does nothing for Lyklaborð, and there is no public API to read that toggle.

## 3. Full Access

Two columns that do not agree. I am not collapsing them.

**What Apple documents**

- Without open access: "No access to microphone and speaker" ([current doc](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)).
- With open access: "Ability to play audio, including keyboard clicks using the `playInputClick` method" ([archived guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)).
- Read literally, all audio in a keyboard extension needs Full Access under either API.

**What developers report and ship**

- R0uter (author of a Chinese IME), 2017, updated 2025: using AudioToolbox system sounds does not need Full Access ([logcg.com](https://www.logcg.com/en/archives/2740.html); machine-translated English, anecdotal).
- Shyngys Kassymov, 2018: reports getting key-press sound without the user granting Full Access ([guide](https://shyngys.com/ios-custom-keyboard-guide); anecdotal, and the summary I could retrieve is ambiguous about whether `RequestsOpenAccess` merely had to be declared).
- azooKey (shipping App Store keyboard, MIT): haptics are gated on `hasFullAccess` and the setting is marked `requireFullAccess = true` with the comment that it cannot work without Full Access; the sound setting has no such flag and `playSystemSound` has no Full Access check ([KeyboardFeedback.swift](https://github.com/azooKey/azooKey/blob/main/AzooKeyCore/Sources/KeyboardViews/KeyboardFeedback.swift), `AzooKeyCore/Sources/AzooKeyUtils/KeyboardSetting/BoolKeyboardSetting.swift`). Code-level evidence that its authors treat system sounds as not needing Full Access. Still not a device test.
- `gesture-ime` issue [#135](https://github.com/kinoko34077/gesture-ime/issues/135) flags the opposite risk for `playInputClick()` specifically: under a no-Full-Access policy it cannot be presented as a working capability, per Apple's docs. That issue records no device test either.

**KeyboardKit's own position:** silent. `KeyboardKit.docc/Features/Feedback-Article.md` in our vendored copy does not mention Full Access for audio or haptics, and neither does the public feature page ([keyboardkit.com/features/feedback](https://keyboardkit.com/features/feedback)). No upstream issue found that settles it.

**For us this is mostly moot:** we declare `RequestsOpenAccess`, and the haptic toggle already depends on Full Access. The open question only matters for users who decline Full Access: they probably still get clicks from the system-sound path (reported, not Apple-documented, not verified by us) and would probably get none from `playInputClick()` (Apple-documented, not verified by us).

## 4. What third-party keyboards do

| Keyboard | Key sound default | In-app toggle | Follows iOS Keyboard Feedback → Sound | Source | Confidence |
|---|---|---|---|---|---|
| Microsoft SwiftKey | not found | Yes, "Key Click Sounds" | **No** (stated); ringer switch does mute it | [Microsoft Support](https://support.microsoft.com/en-us/topic/how-do-i-change-the-sounds-or-vibrations-that-my-microsoft-swiftkey-keyboard-makes-3a36e887-3faa-417a-becb-c24cb02750a2) | High (vendor page), default unknown |
| Grammarly Keyboard | not found | Yes, "Sound Feedback on Keypress" (plus "Haptic Feedback on Keypress") | not found | [Grammarly Support](https://support.grammarly.com/hc/en-us/articles/360041391992-Managing-your-keyboard-settings-in-Grammarly-for-iPhone) | High for the toggle; rest not stated |
| Gboard | not found | not found | not found | [Gboard Help, iPhone & iPad](https://support.google.com/gboard/answer/6102154?hl=en&co=GENIE.Platform%3DiOS) | Low. The page is titled "theme, sound, or vibration" but the iOS steps I could retrieve name no sound option. Secondary sources conflict: one says Gboard makes no sound on iPhone ([hardreset.info](https://www.hardreset.info/devices/apps/apps-gboard/enable-sound-keypress/)), another says it clicks and ignores the iOS toggle ([Gadget Hacks](https://ios.gadgethacks.com/how-to/sick-your-iphone-keyboards-annoying-click-sounds-try-one-these-solutions-0331276/)). Not resolved. |
| Fleksy | not found (consumer app) | not found | not found | `docs.fleksy.com` could not be reached (DNS failure). A search snippet of its SDK reference says sounds and haptics are disabled by default in `FeedbackConfiguration`; that is an SDK default from a page I could not open, not the consumer app's behaviour | Low |
| Typewise | not found | not found | not found | No vendor help page found on key sound | None |
| azooKey (OSS) | **Off** (`EnableKeySound.defaultValue = false`) | Yes ("キーの音") | No. Plays IDs 1104/1155/1156 via `AudioServicesPlaySystemSound` gated only on its own setting | [KeyboardFeedback.swift](https://github.com/azooKey/azooKey/blob/main/AzooKeyCore/Sources/KeyboardViews/KeyboardFeedback.swift), `BoolKeyboardSetting.swift` | High (source read) |
| Hamster / 仓输入法 (OSS, forked KeyboardKit; last push May 2025) | **Off** (`enableKeySounds ?? false`) | Yes ("开启按键声") | No. `AudioServicesPlaySystemSound(audio.id)` gated only on its own setting | [imfuxiao/Hamster](https://github.com/imfuxiao/Hamster), `StandardAudioFeedbackEngine.swift`, `KeyboardFeedbackViewModel.swift` | High (source read; shipped default could differ if `hamster.yaml` overrides it, which I did not open) |
| KeyboardKit 9.9.1 (what we vendor) | **On** | Setting exists (`isAudioFeedbackEnabled`); UI is up to the app | No (issue #378) | vendored source | High |

`research/oss-harvest.md` lists no other iOS OSS keyboard that cleared its trust bar, so I did not go further down that list.

Pattern: every keyboard whose behaviour I could establish has its own toggle and none is shown to follow the system setting. Defaults: KeyboardKit on, azooKey and Hamster off, the three commercial ones not documented.

## 5. Performance

**Nothing I found supports "the sound causes slowdown".** What exists:

- Apple: "Because sound might play for several seconds, this function is executed asynchronously" and "Sounds play immediately". Also: "Simultaneous playback is unavailable: You can play only one sound at a time". ([AudioServicesPlaySystemSound](https://developer.apple.com/documentation/audiotoolbox/audioservicesplaysystemsound(_:))). The call hands off to the system sound server and returns; Apple gives no cost figure for the call itself.
- Upstream KeyboardKit: [#594](https://github.com/KeyboardKit/KeyboardKit/issues/594) "Keyboard audio is slightly delayed" was about *when* the click fires and was closed by moving the trigger into the action handler (the press-time trigger we have). [#811](https://github.com/KeyboardKit/KeyboardKit/issues/811) "rare, random delayed behavior" was attributed to system busyness and a delimiter operation, not audio. No upstream issue blames audio for typing latency.
- Other keyboards move the call off the caller: Hamster wraps it in `DispatchQueue.global().async`; azooKey wraps it in `Task {}`. These are precautions, not measurements. azooKey's stated reason is not lag: the comment says calling it synchronously can occasionally produce a very loud sound.
- R0uter's post gives the trade-off in prose: play off the main thread "to avoid blocking the main thread", at the price that the tone may "not keep pace", and rapid presses drop tones because the previous one cannot be cancelled ([logcg.com](https://www.logcg.com/en/archives/2740.html)). Anecdotal, no numbers.
- One number surfaced in search, 0.3 ms blocked per call, is from a macOS clipboard app's pull request ([tiez-clipboard #179](https://github.com/jimuzhe/tiez-clipboard/pull/179)). Different platform, different process type, read only from a search summary. I would not cite it for iOS.

**Our call path (from §0):** one synchronous `AudioServicesPlaySystemSound` on the main thread per key-down, issued before the insertion work, no ID registration, no completion handler. If that call ever did block, it would sit directly in front of the keystroke. Nobody has measured whether it does.

**What a user could be perceiving, as hypotheses only:**

1. The one-sound-at-a-time limit: at speed, clicks drop or trail the keystroke, and a trailing click sounds like a slow keyboard even when text insertion is on time.
2. Real latency from elsewhere (autocorrect, prediction) that the click makes audible.
3. An actual main-thread cost in the sound call on their device. Possible, unsupported by anything I found.

Telling these apart needs a signpost around the call in `Feedback.AudioEngine.play` on a device, sound on versus off, at a fast typing rate.

---

## Recommendation for Lyklaborð

### Established

- We have no way for a user to turn key sound off in-app, and the system Keyboard Feedback toggle does not reach us (§2, upstream #378).
- The setting already exists in the App Group under `com.keyboardkit.settings.feedback.isAudioFeedbackEnabled`, and the handler already honours it. The haptic toggle in `App/SettingsView.swift` is the same pattern with the sibling key.
- An in-app sound toggle is what SwiftKey, Grammarly, azooKey and Hamster all ship.
- `playInputClick()` is the only API Apple documents as following the system setting; Apple documents it as an open-access capability; it gives one sound, not three.

### Inference

- **Add a "Hljóð" toggle next to the haptic toggle.** Smallest change, answers the user directly, matches the ecosystem. This part I would do regardless of the open questions.
- **Default: a product call, with a lean towards off.** For on: it is KeyboardKit's default and existing users have it now. For off: both open-source keyboards I could read default off, a keyboard that clicks when the user has silenced system keyboard clicks is behaving worse than Apple's, and we cannot read that system setting to do the right thing automatically. If the default flips, it flips for everyone who never touched the setting, since the key is currently unwritten; worth a line in release notes.
- **Do not switch to `playInputClick()` now.** It would be the only way to follow the system setting, but it is unverified in a SwiftUI-hosted extension, is tied to Full Access in Apple's docs, and loses the distinct delete and system-key sounds. Worth a one-hour device spike later (adopt `UIInputViewAudioFeedback` on the controller's `inputView`, test with Full Access on and off, system sound toggle on and off). If it works, "follow system" becomes a real option.
- **Do not promise the user a speed-up.** Tell them the toggle is coming and that the ringer switch is reported to silence third-party key clicks in the meantime (Microsoft says so for SwiftKey; I have not confirmed it for our keyboard). Whether muting makes typing faster is exactly what we have not measured.
- **If we want to answer the slowdown question properly:** measure before changing the threading. Moving the call to a background queue as Hamster does is cheap, but azooKey's comment and R0uter's post both describe audible side effects of changing how the call is issued, so it should follow a measurement, not replace one.

### Could not verify

- Whether `playInputClick()` plays at all in a keyboard extension, with or without Full Access, on current iOS.
- Whether `AudioServicesPlaySystemSound` with the click IDs plays without Full Access on current iOS (reported by developers and assumed by azooKey's code; contradicts a literal reading of Apple's doc).
- Whether the ringer switch mutes our clicks (Microsoft states it for SwiftKey; no Apple doc).
- Default sound state in SwiftKey, Grammarly and Gboard; whether Gboard on iOS has key sound at all; anything for Typewise; anything first-hand for Fleksy (`docs.fleksy.com` unreachable).
- Any latency cost of the sound call on iOS. No measurement found.
