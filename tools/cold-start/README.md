# Cold-first-usable measurement

Two instruments live here. The **device journal** (below) is the only
measurement of the real extension process on an iPhone; it starts its clock
at `viewDidLoad`. The **launch probe** (end of this file) is a headless macOS
replay of everything the extension does between `viewDidLoad` and the first
key, against the real `data/` artifacts, runnable on every change — it covers
what the journal cannot (per-phase cost, `phys_footprint`, the presentation
path, a second controller in a surviving process) and is blind to what only a
device shows (dyld/UIKit/SwiftUI start-up, NAND page-fault latency, the
jetsam limit itself).

Wave 39 measures a real keyboard-extension process from the entry to
`KeyboardViewController.viewDidLoad` through service creation, engine readiness,
and the first publishable, non-empty result. It also measures the request
backlog that formed behind bootstrap. No typed text, key values, suggestions,
or user identifiers are recorded.

The extension appends a bounded local journal at
`Documents/diagnostics/cold-start.jsonl` in the App Group. Each record marks
whether it came from the first service created in that extension process;
`report.py` excludes later presentations and Simulator samples by default so a
warm retry cannot hide the cold number. It deduplicates `runId` values because
each pull copies the cumulative journal, rejects incomplete records, and fails
a full gate if device model, OS, extension version, or extension build are
mixed.

```sh
tools/cold-start/run-cohort.sh <device-id> 20
tools/cold-start/pull.sh <device-id>
python3 tools/cold-start/report.py tools/cold-start/runs
python3 tools/cold-start/report.py --gate tools/cold-start/runs
swiftc KeyboardExt/ColdStartMetrics.swift tools/cold-start/tracker_tests.swift \
  -o /tmp/lyklabord-cold-start-tracker-tests && \
  /tmp/lyklabord-cold-start-tracker-tests
```

The hard gate requires 20 process-cold physical-device launches. Budgets live
in `budget.json`. `activationToEngineReadyMs` includes controller and App Group
setup before the service exists; `activationToServiceCreationMs` makes that
portion visible. `activationToStableResultMs` and `serviceToStableResultMs` are
observational UX numbers because they contain the user's delay before typing;
the gated `firstRequestToStableResultMs` starts when the first KeyboardKit
request arrives. A stable result is non-empty and not superseded at
publication.

The first accepted physical baseline is committed as
`baselines/wave-39-iphone14pro-ios26.5.2-build4.json`. It is an aggregate only;
the cumulative raw journals remain ignored under `runs/`. Compare like with
like: the reporter deliberately rejects a gated cohort that mixes device model,
OS, extension version, or extension build.

Wave 40's generation-bound calibration-sidecar cohort is committed separately
as `baselines/wave-40-calibration-iphone14pro-ios26.5.2-build4.json`. It uses
the same device/OS/marketing build as Wave 39 but a later dirty source build;
the filename records the implementation boundary that the marketing build
cannot distinguish. Its raw 20-run journal remains ignored like every cohort.

For a true process-cold run, dismiss the keyboard and ensure the extension
process has ended before presenting it again. Merely reopening the keyboard
inside a surviving extension process produces `isProcessCold: false` and is
excluded. Use a Release build on a physical device; the Simulator path is for
instrumentation smoke tests only.

`run-cohort.sh` automates that hygiene for the deterministic host bundled in
Release builds. It requires either an empty journal or a valid partial cold
cohort, so an interrupted run resumes without double-counting. It terminates
the containing app first, repeatedly terminates/rechecks the extension until
iOS proves it absent at the launch boundary, launches the host with its
cold-probe environment flag, and accepts each iteration only after the journal
contains exactly one new, unique, physical `isProcessCold` record. Keep the
phone unlocked and Lyklaborð selected while it runs. A locked phone or
missing/warm sample aborts the cohort instead of silently lowering the measured
latency.

Collect one cohort from one installed Release build without reinstalling it
mid-run. Clear or archive the device journal before starting a new build's
cohort; version/build consistency is enforced, but locally rebuilt binaries can
share the same marketing build number.

## Launch probe (headless, macOS)

`tools/cold-start/launch-probe/` is a SwiftPM executable that replays the
extension's launch sequence against the real `data/` artifacts and reports
per-phase wall time plus `phys_footprint` deltas (the metric the iOS jetsam
cap watches), as one JSON object per fresh process. It is a **macOS
regression alarm**, not an iOS forecast: no dyld/UIKit/SwiftUI cost, a
different CPU, usually a warm page cache, different footprint accounting.
Ratios and regressions transfer; absolute numbers do not.

```sh
tools/cold-start/launch-probe.sh            # build (release), 5 fresh processes, gate
tools/cold-start/launch-probe.sh 10         # more samples
python3 tools/cold-start/launch_probe_report.py --gate <runs.jsonl>
python3 tools/cold-start/launch_path_lint.py          # static launch-path guard
python3 -m unittest tools/cold-start/test_launch_path_lint.py \
                    tools/cold-start/test_launch_probe_report.py
```

What one run covers, in the extension's order:

| phase | mirrors | what it measures |
| --- | --- | --- |
| 1–6 | `LyklabordAutocompleteService.bootstrapIfNeeded` | `.lex` ×2 + calibration, `bin-morph.bin` + folded index, `TypeEngine` init, `engine.warmUp()`, curated vocabulary, `TypingSession` → **engineReadyMs** |
| 7 | `scheduleEmojiSuggesterLoad` | `is-suggestions.json` decode (post-publish since 2026-10-03) |
| 8 | first autocomplete passes | **firstKeystrokeMs**, worst of the first 11 windows |
| 9 | `reloadPersonalSnapshotIfChanged` | 1,500-word synthetic `personal-model.json` load + composite swap + touch snapshot |
| 10 | `scheduleInflectionLoad` + `setInflection` | paradigms mmap + governors gunzip/scan, **inflectionRetainedMB**, lemma-lift rebuild |
| 11 | `viewWillAppear` → toolbar | real `EmojiCatalog` decode, `EmojiFrequencyStore.top(8)` with 12 personal emoji → **presentationMainThreadMs**; `top(10)`, `pickerCategories` |
| 12 | `IcelandicEmojiSearchSession.refresh` | real search index decode, 24-entry frecency strip, three queries |
| 13 | second controller in a surviving process | engine re-bootstrap (**secondBootstrapMs**), uncached vs cached inflection reload footprint |

The KeyboardExt files phases 11–12 exercise (`EmojiCatalog`,
`EmojiFrequencyStore`, `IcelandicEmojiSuggester`, `IcelandicEmojiSearch`) are
compiled from symlinks into `Sources/launch-probe/`, so they are the shipping
code; `Sources/ISEmojiView` is a three-type shim for the iOS-only vendored
package they import. The service itself imports KeyboardKit and cannot be
compiled on macOS, so phases 1–7 and 10 are a mirror — keep them in step with
`bootstrapIfNeeded`, and rely on `launch_path_lint.py` for the structural
half: it extracts the bodies of `viewDidLoad`, `viewWillAppear`,
`viewWillSetupKeyboardView`, `forwardTextContextChange` and the service
`init`, strips comments/strings, and fails on blocking I/O, decodes,
`.sync` hops, App Group container resolution or artifact opens on those
threads; it also asserts that `bootstrapIfNeeded` publishes the session
(`coldStartTracker.engineReady()`) before it schedules the inflection or
emoji-suggester loads (or decodes either inline). Exemptions are listed in
the script with the reason; an exemption silences its pattern for the whole
named function, so review exempted functions by hand.

Budgets are in `launch-budget.json`, gated on the **max** over at least five
fresh processes, set at roughly 2× the values first observed on an
Apple-silicon Mac (2026-10-03: engine ready 13–19 ms, first keystroke
0.03–0.10 ms, presentation path 0.12–0.15 ms, inflection retained
4.3–4.6 MB, peak footprint 17.3–17.6 MB). Raise a budget deliberately, with a
WAVES.md note; never to make a run pass. A concurrent `xcodebuild` on the
same machine inflates the timings several-fold — run the probe on a quiet
machine.

Known blind spots (device-only): everything before `viewDidLoad`;
SwiftUI/KeyboardKit view construction; NAND page-fault latency when the
artifact pages are not in the unified buffer cache (the Mac page cache is
warm after one run, and the device cohort script relaunches the extension
back-to-back, so the committed device baseline is "process-cold,
page-cache-warm"; a true after-reboot cold number has never been captured);
the jetsam limit and the emoji picker's UIKit/font-cache footprint.
