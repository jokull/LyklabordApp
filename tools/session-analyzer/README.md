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
| `INFLECTION_MISS` | a MISS whose intended word shares a lemma-ish stem with a bar offer differing only in an inflectional ending (e.g. `Kirkjubæjarklaustri` offered, `Kirkjubæjarklaustur` wanted) — routes to the **inflection backlog**, not the corrector |
| `TAP_USED` | user tapped a suggestion |
| `CLEAN` | word committed with no correction, retype, or tap |

### Erase-then-retype alignment (v2)

Episodes are reconstructed word-level (difflib over the peak-vs-end word
lists) with plausibility-based pairing. When a user erases one word and
retypes a **longer** stretch, only the aligned word is paired (shared stem /
cheap edit); the extra words are insertions. E.g. erasing `foðu` and retyping
`af góðu` yields `foðu`→`góðu`, with `af` dropped (v1 mispaired `foðu`→`af`).

### Silent-miss pass (v2)

After episode analysis the analyzer scans the **final committed text** for
uncorrected typos and writes them to a `## Silent misses` section in the
report (human-in-the-loop signal, not eval candidates):

- `SILENT_MISS` — token not attested in either lexicon but with a
  high-frequency neighbour within 1–2 cheap keyboard/accent edits. Candidates
  are ranked by edit penalty (0 = one cheap edit, 1 = two, 2 = a non-adjacent
  substitution) then frequency.
- `UNRESOLVABLE` — no confident neighbour (keyboard mash / out-of-lexicon
  compound).

Attestation is authoritative via the engine: the analyzer shells to the
prebuilt `type-repl` binary and batches `:word <tok>` (curated `is.lex`/`en.lex`
membership, which excludes corpus noise like `fra`/`fa`). If the binary is
absent it falls back to plain membership in the frequency corpora
(`data/is/unigrams.json.gz`, `data/en/en-80k.txt`) — less precise. The
keyboard-adjacency model mirrors `SpatialModel.icelandicRows`. Build the
binary once with:

```sh
( cd ../../Packages/TypeEngine && swift build -c release --product type-repl )
```

## Test

```sh
python3 test_analyze.py   # exit 0 = pass
```

Runs the classifier on `fixtures/fixture-*.jsonl`, a hand-built session with
exactly one event of each class (living documentation of the wire format).
