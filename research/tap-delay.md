# Tap delay — what the key press path costs, what was redrawing, what is still unmeasured

*Investigated 2026-10-06/07. Sources: device runs on an iPhone 14 Pro (see "Device measurements"), our own code (`KeyboardExt/`, vendored `Packages/KeyboardKit`), a timing probe added for this investigation (`KeyLatencyProbe`), a UI-test typing run (`ScreenshotUITests.testProbeTyping`) in the iPhone 16 Pro Max simulator (iOS 18.3, Xcode 16.2, Release build) on an M2 Mac mini, and one `sample` call-stack capture of the keyboard process during that run.*

Trigger: four users reported that the keyboard is slow in use (not at launch): "delay from press until the letter appears", "can't keep up when I type fast". The owner does not see it on an iPhone 14 Pro, but does see a lag between touching a key and its highlight when starting a long-press.

## Verdict up front

*Updated 2026-10-07 with device measurements (iPhone 14 Pro, Release build, typing in the app's own recording studio).*

- **The delay users feel is touch gating, not our code.** On the device a touch reaches the keyboard process about 22–27 ms after it happens, but SwiftUI's gesture on a key was only allowed to start at about 100 ms (median, every key), and at about 780 ms when a finger was held on an edge key such as A. The main thread was idle during the wait.
- **The cause is the system gesture gate on the keyboard window.** The window carries two `_UISystemGestureGateGestureRecognizer`s. Turning off `delaysTouchesBegan` changed nothing, and disabling the gate did not stick: iOS had re-armed it before every one of 82 touches.
- **Fix: read raw touches with our own UIKit recognizer.** A gesture recognizer is handed touches directly. `KeyTouchRouter` forwards them to the existing `GestureButton` logic, which no longer installs a SwiftUI gesture for keys. Measured: press 102 → 22 ms median, worst case 778–788 → 42 ms; release 41 → 23 ms.
- **Separately, the whole key grid was being rebuilt about five times per keystroke.** Fixed; on the device full rebuilds fell from about 40 per 40 presses to 2–3. This is real main-thread work saved, but it was not the delay users described.
- **The engine is not the bottleneck**, and reading the text field from the host costs about 0.02 ms on the device (in our own app; not measured in Messages or a web view).
- **Key-click sound and haptics were never measured**: both were off in every device run.

## Device measurements

Per 40 key presses. "Touch → key told" is the touch event's own timestamp to the gesture button's press or release callback.

| Build | Touch down → key told, p50 / max | Touch up → key told, p50 | Raw touch arrival (UIKit), p50 | Full keyboard rebuilds |
|---|---|---|---|---|
| SwiftUI gesture (7 batches) | 98–106 ms / up to 788 ms | 35–42 ms | 20–27 ms | ~40 |
| Same, gate "disabled" | 102–106 ms / 778 ms | 42 ms | 20–24 ms | 3–6 |
| Raw-touch router (4 batches) | 20–23 ms / 42 ms | 21–23 ms | 21–24 ms | 2–3 |

- With the router, 160 of 161 touches found a key; one landed outside every registered frame.
- **Unexplained:** after a release the main thread is now busy for about 10 ms (median), up from about 1.5 ms on the SwiftUI path. Not investigated.
- The 98 ms median on the SwiftUI path was nearly constant across batches (97.9–98.1 ms), which is what a fixed gate timeout would look like. That reading of the mechanism is inference; what is measured is the wait and that bypassing SwiftUI's gesture removes it.

## What happens on a key press

1. SwiftUI delivers the touch to `GestureButton` through a `DragGesture(minimumDistance: 0)`.
2. `tryHandlePress` sets `isPressed`, then runs the press action synchronously. The key cannot repaint as pressed until everything in this step returns and the run loop commits.
3. The press action is `LyklabordActionHandler.handle(.press, …)`:
   - reads `documentContextBeforeInput` (ledger snapshot), and again in the `defer` (`recordPendingSelfEdit`), even though a press never edits text;
   - triggers sound and haptic feedback synchronously;
   - updates the input callout, which publishes on `CalloutContext`.
4. Publishing on `CalloutContext` invalidated `KeyboardView`, because upstream declares it `@ObservedObject` there. Its body rebuilds every row and every key view. The key views hold closures, so SwiftUI cannot skip them by equality.

On release the same text-field reads happen around the insert, the insert triggers `textDidChange` and an autocomplete request, and the result lands as a batch of five `@Published` writes on `AutocompleteContext`, which invalidated `KeyboardView` again. On top of that, `SpaceCommitHintContainer` re-applied a `keyboardButtonStyle` closure in the environment on every autocomplete publish; a closure is not comparable, so every key re-rendered.

## Measurements (simulator, M2, Release, per 40 key presses)

Steady-state flush windows; the first window of each run includes cold start and is excluded. "Until main free" is the time from the gesture callback starting to the next main-queue block running, so it includes the SwiftUI update the press or release triggered.

| | Baseline | Observation fix + hint-container fix | Plus space-flag fix |
|---|---|---|---|
| `KeyboardView.body` evaluations | 198–207 | 30–32 | 6–8 |
| `KeyboardViewItem.body` evaluations | 2,576 | 1,250–1,328 | 314–392 |
| Press, until main free, p50 / p95 | 3.75 / 12.2 ms | 2.95 / 8.6 ms | 2.9 / 3.5 ms |
| Release, until main free, p50 / p95 | 3.4 / 21.2 ms | 2.55 / 16.0 ms | 2.55 / 3.0 ms |
| Press handler, p95 | 1.37 ms | 1.36 ms | 0.10 ms |
| Release handler, p95 | 11.1 ms | 8.5 ms | 0.30 ms |
| Press + release main time, per keystroke | ~12.1 ms | ~9.1 ms | ~5.4 ms |

Other readings from the same runs:

- Text-field reads cost 0.01 ms each in the simulator's test host. This says nothing about Messages, Messenger or a web view on a device.
- Touch-to-callback (touch event timestamp to the SwiftUI gesture callback): press p50 2.2 ms, release p50 11–14 ms. The touches are synthesized by XCUITest, so treat these as a plumbing check, not a result.

### Two measurement traps hit on the way

- **Wall time per run-loop pass is frame pacing, not work.** Passes clustered at ~8.5 ms (one 120 Hz frame). The probe now records thread CPU time as well.
- **Main-thread CPU in a UI test is mostly the test.** A `sample` capture showed ~72% of the keyboard's busy main-thread time was XCUITest's accessibility snapshot requests (`_accessibilityUserTestingSnapshot…`), made each time the test looks a key up. So `runloop.cpu` totals from a UI-test run overstate the keyboard's cost several times over. The "until main free" and body-count rows above are not affected the same way: one is timed from our own callbacks, the other is a count.

## What changed (working tree, uncommitted)

Touch path:

1. `Packages/KeyboardKit/.../Gestures/KeyTouchRouter.swift` (new) — a UIKit recognizer that never recognizes; it maps each touch to the gesture button whose window frame contains it and calls that button's handlers. Buttons register through the `keyTouchRouter` environment value.
2. `Packages/KeyboardKit/.../GestureButton/GestureButtonDragValue.swift` (new) and edits in `GestureButton.swift`, `GestureButtonState.swift`, `Keyboard+ButtonGestures.swift`, `CalloutContext.swift` — the button logic takes its own drag value type instead of `DragGesture.Value`, which has no public initializer. With a router in the environment (and outside a scroll view) a button installs no SwiftUI gesture.
3. `KeyboardExt/KeyboardViewController.swift` — owns the router, adds its recognizer to the controller's view, and injects it. `LyklabordKeyboardMetrics.usesRawTouchRouting` (true) is the switch back to the stock path. The suggestion bar and emoji keyboard still use SwiftUI gestures.

Redraws:

4. `Packages/KeyboardKit/.../_Keyboard/KeyboardView.swift` — `autocompleteContext` and `calloutContext` are plain `let`s, not `@ObservedObject`. The callout overlays observe the callout context themselves; a private `ToolbarObserver` re-evaluates only the suggestion bar. Consequence: `nextCharacterPrediction` (a KeyboardKit Pro feature our service never populates) is read without being observed.
5. `Packages/KeyboardKit/.../_Keyboard/Views/Keyboard+RootView.swift` — no longer declares the autocomplete context, which it never used but which made it hand SwiftUI a new `KeyboardView` on every suggestion update.
6. `KeyboardExt/DevSpaceContent.swift` — `SpaceCommitHintContainer` mirrors the armed state into `@State` via `onReceive` instead of observing the context, so the style closure is re-applied only when the state flips. An earlier attempt made the wrapper `Equatable` on the armed flag; that also swallowed layout updates (shift and 123 stopped working on device) and was replaced.
7. `Packages/KeyboardKit/.../_Keyboard/KeyboardContext.swift` — `setIsSpaceDragGestureActive` returns early when the value is unchanged.

Probe and harness, also uncommitted and **not meant to ship switched on**:

- `Packages/KeyboardKit/.../Gestures/KeyLatencyProbe.swift`, with measurement points in `GestureButton.swift`, `Keyboard+ButtonGestures.swift`, `KeyboardAction+StandardActionHandler.swift`, `KeyboardContext+Sync.swift`, `KeyboardContext.swift`, `KeyboardView.swift`, `KeyboardViewItem.swift`, `KeyTouchRouter.swift` and `KeyboardViewController.swift`.
- In `KeyboardViewController`: `KeyLatencyProbe.start()` and the file sink in `viewDidLoad`, and `TouchLagRecognizer` (raw touch arrival) added in `viewDidAppear`. All carry an "investigation only" comment. Timings and counts only; no keys or text.
- `ScreenshotUITests.testProbeTyping` is a temporary test.

## Two regressions the raw-touch path caused, both fixed

- **Top-row touches also tapped the suggestion bar.** The bar's tap area reaches down over the top of the top row. Each key's SwiftUI gesture used to claim those touches; with the gesture removed, one touch both typed a letter and tapped a suggestion (10 such taps in one recorded session, letters replaced by a space). Routed keys now keep a do-nothing SwiftUI gesture whose only job is to claim the touch.
- **Long-press menus flashed and closed after typing.** Not caused by the router but exposed while testing it: see the stuck-gesture timer under "Side findings". The timer is no longer armed for routed keys, and on the SwiftUI path it now acts only on the press that armed it.

## Not established

- **Other devices and hosts.** One phone (14 Pro), one host (our own app). Older phones and Messages, Messenger or a web view are unmeasured.
- **The raw-touch path beyond typing.** Long-press menus and drag selection, space cursor, held backspace, double-tap shift, sliding off a key, two fingers down at once, system-gesture cancellation and landscape have no automated coverage. The owner ran a typing script on device and called the result solid; that is the only check.
- **Multi-touch rollover.** Not tested on either path.
- **Sound and haptics cost.** Off in every run.
- **The ~10 ms after release** noted above.

## Side findings

- **A top-row key press can be dropped by KeyboardKit's stuck-gesture guard.** Top-row keys get a 3 s cancel timer (`isGestureAutoCancellable: row.offset == 0`). When it fires it compares the button's latest touch location with the one captured at the original press and, if equal, resets the button. A second press of the same key at the identical point, in flight exactly 3 s after an earlier tap, is therefore cancelled and its release dropped. The UI test taps dead centre at a steady cadence and hit this on every run ("fer" typed as "fr"; the probe shows one press without a release per run). A real finger almost never lands on the identical point, so this is a harness artefact first, but a perfectly still 3 s hold on a top-row key would also be cancelled.
- **The held-backspace word escalation existed but could never fire.** `LyklabordKeyboardBehavior` was created without the shared repeat timer, so `backspaceRange` always saw a timer that had never started. Fixed in the same working tree by passing `services.repeatGestureTimer`; words start after 2 s of repeating and are deleted on every third tick. Not part of the redraw work, and not yet tried on a device.

## Pulling the probe file

```
xcrun devicectl device copy from --device <udid> \
  --domain-type appGroupDataContainer --domain-identifier group.is.solberg.lyklabord \
  --source Documents/key-latency.jsonl --destination ./key-latency.jsonl
```

`devicectl` can only copy out of `Library`, `Documents` or `tmp` in the container. A summary is appended every 40 presses.
