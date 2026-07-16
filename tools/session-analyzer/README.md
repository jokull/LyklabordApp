# session-analyzer

Offline analysis for DEV-MODE typing-session recordings (see
`docs/PRIVACY.md` → "Developer mode", `App/RecordingStore.swift`,
`KeyboardExt/SessionRecorder.swift`).

Recording is a developer-only affordance: it captures ground truth **only**
from the app's own "Upptökusvæði" pad — never any third-party app — and is off
by default. Each session produces two JSONL files in the App Group container's
`Documents/sessions/`:

- `<id>-app.jsonl` — the authoritative timeline: the full pad text snapshotted
  on every change, with timestamps.
- `<id>-kb.jsonl` — one record per keyboard `suggestions()` pass: window tail,
  the suggestion bar (texts + `ac`/`vb`/`rs` flags + confidence), the applied
  action (autocorrect / suggestion tap / none), touch samples since the last
  pass, backspaces, and the field kind.

## Pull from a device

```sh
./pull.sh                 # auto-pick the first connected device
./pull.sh <device-udid>   # xcrun devicectl list devices
```

Copies `Documents/sessions/` from the app container (`is.lyklabord.ios`) into
`./sessions/`. Requires Xcode 15+ (`xcrun devicectl`), device paired &
unlocked, app installed. (Simulator: use
`xcrun simctl get_app_container booted is.lyklabord.ios data` and copy
`Documents/sessions` by hand — `devicectl` is device-only.)

## Analyze

```sh
python3 analyze.py [sessions-dir]   # default: ./sessions
```

For each session it writes `<id>-report.md` (counts, event list with context,
per-key tap-offset stats) and `<id>-candidates.jsonl` (eval-ready cases, shaped
like `data/eval/dev.jsonl`).

### Event classes

| class | meaning |
|-------|---------|
| `AUTOCORRECT_UNDONE` | keyboard auto-applied a correction; user backspaced to restore what they typed (a false autocorrect) |
| `MISS_OFFERED` | user backspace-retyped to a word that **was** in the bar while typing — gating too conservative |
| `MISS_ABSENT` | user backspace-retyped to a word the bar never offered — a ranking / candidate miss |
| `TAP_USED` | user tapped a suggestion |
| `CLEAN` | word committed with no correction, retype, or tap |

## Test

```sh
python3 test_analyze.py   # exit 0 = pass
```

Runs the classifier on `fixtures/fixture-*.jsonl`, a hand-built session with
exactly one event of each class (living documentation of the wire format).
