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

## Getting sessions off the device

Two paths, both landing in `./sessions/`:

### 1. OTA via the developer's own iCloud Drive (no cable)

On **stop** (and retroactively for any earlier unexported session), developer
mode copies each session's `-app.jsonl` + `-kb.jsonl` + a `-meta.json` manifest
into the app's iCloud ubiquity container (`iCloud.is.lyklabord`,
document-scope-public). It syncs to **the developer's own iCloud Drive** — no
servers — and lands on this Mac at:

```
~/Library/Mobile Documents/iCloud~is~lyklabord/Documents/sessions
```

Note the tilde-encoding: the container id `iCloud.is.lyklabord` becomes
`iCloud~is~lyklabord` (dots → tildes, **no** team prefix and **no** `.ios`
suffix). Override with `--ubiquity-dir` / `LYKLABORD_UBIQUITY_DIR` if your
account encodes it differently.

### 2. USB pull (`pull.sh`)

```sh
./pull.sh                 # auto-pick the first connected device
./pull.sh <device-udid>   # xcrun devicectl list devices
```

Copies `Documents/sessions/` from the app container (`is.lyklabord.ios`) into
`./sessions/`. Requires Xcode 15+ (`xcrun devicectl`), device paired &
unlocked, app installed. (Simulator: use
`xcrun simctl get_app_container booted is.lyklabord.ios data` and copy
`Documents/sessions` by hand — `devicectl` is device-only.)

## Ingest (collect + analyze + aggregate)

`ingest.py` is the one command to run — it pulls from every source into
`./sessions/`, analyzes new arrivals, and rebuilds the aggregate + corpus:

```sh
python3 ingest.py            # one pass (iCloud mirror → sessions/ → analyze → aggregate)
python3 ingest.py --watch    # poll every 15s while you type on the device
python3 ingest.py --ubiquity-dir DIR --pull-dir DIR --sessions-dir DIR
```

Dedupe is by **session id**: a file is copied only when absent or larger
(sessions are append-only, so larger == superset). Only changed sessions are
re-analyzed. A missing iCloud dir is skipped, never fatal.

## Aggregate

`aggregate.py` (run for you by `ingest.py`, or standalone) rolls **all**
sessions up **by engine build** (from each `-meta.json`'s `engineCommit`,
stamped at build time via `App/BuildInfo.swift`; sessions with no manifest
group under `unknown`). It writes, into the gitignored `sessions/` dir:

- `AGGREGATE.md` — per-build totals + rates (autocorrect false-positive rate,
  MISS_OFFERED/ABSENT, INFLECTION_MISS, SILENT_MISS, taps/session), a **weighted
  per-key tap-offset** table, a **PATTERNS** section (recurring `typo→intended`
  pairs and same-category counts = tuning candidates; singles = watch list), a
  **build-over-build trend** table (does a new build regress real-typing
  rates?), and **PENDING-REVIEW** (ambiguous cases awaiting confirmation).
- `aggregate.json` — the same, machine-readable.

```sh
python3 aggregate.py [sessions-dir]   # default: ./sessions
```

## Personal eval corpus

`aggregate.py` also maintains **`personal-eval.jsonl`** (this dir; **gitignored**
— it quotes real typed text): confirmed, unambiguous candidates in the
`data/eval/dev.jsonl` schema, deduped and **append-only**, each with provenance
(`session`, `engine_commit`, `class`, `source`). This is a **first-class tuning
gate** — a build change must not regress these cases.

Eligible (unambiguous intended word): `AUTOCORRECT_UNDONE`, `MISS_OFFERED`,
`MISS_ABSENT` (the user produced the intended word themselves), plus
`SILENT_MISS` **only** when the top guess is uncontested (single penalty-0 edit
that clearly beats the runner-up). Held back to `PENDING-REVIEW` in
`AGGREGATE.md`: `INFLECTION_MISS` (inflection backlog, not the corrector) and
contested `SILENT_MISS`. Nothing ambiguous enters the corpus without Jökull's
confirmation.

## Privacy / git hygiene

`sessions/` and `personal-eval.jsonl` are **gitignored**: every output that
quotes typed text (`AGGREGATE.md`, `aggregate.json`, `<id>-report.md`,
`<id>-candidates.jsonl`, `<id>-meta.json`, the corpus) stays local. Only this
README and the scripts are committed. The iCloud copy goes to the developer's
**own** iCloud Drive and is user-visible + deletable in Files (see
`docs/PRIVACY.md` → "Þróunarhamur").

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

### Known-class triage tagging (v3)

Every finding — a corrector `Event` or a `SILENT_MISS`/`UNRESOLVABLE` — gets a
`[class · status]` tag from the checked-in taxonomy in **`taxonomy.py`** (this
file IS committed; it contains no personal typed text, only class
definitions). Precedence (first match wins): `slangur-intentional` >
`stale-apply` > `valid-word-overlap` > `inflection` > `space-miss` >
`compound-oov` > `restoration-fold` > `deep-decode` > `context-ranking` >
`proper-noun-oov` > `NOVEL`. `NOVEL` findings (matched nothing) get their own
section at the **top** of the report; any finding tagged with a `fixed:*`
status (a shipped fix recurring) renders in a loud `⚠ REGRESSIONS` section,
also at the top. See `taxonomy.py`'s `CLASSES` for the full detect/status/notes
per class, and `test_analyze.py`'s `test_taxonomy_*` functions for worked
examples against this repo's own real cases (þvi→því, syndur→sýndur,
stökklrikanum→stökkleikanum, eotthbap→eitthvað, kozy, …).

`taxonomy.classify_finding` is pure (no type-repl, no kb.jsonl) — analyze.py's
`tag_findings` gathers the real context (BÍN/is.lex attestation via
`type-repl`, live bar contents, confirmed-intents overrides) and feeds it in.

### Lane posterior timeline (v3)

Each report gets a `## Lane posterior timeline` section: the session's final
committed text is replayed word-by-word through `type-repl`'s interactive
REPL (one word per line → one `state P(IS)=` report per commit, see
`Repl.swift`'s `report()`), giving a cheap per-word IS-lane posterior without
any TypeEngine changes. A single-step swing > 0.35 is flagged `⚠` (lane
whiplash — the Love-Island poisoning signature) and counted per session in
`aggregate.json`. Cost: dominated by process/engine startup, not per-word
work — a ~50-word session finishes in well under a second.

### Top gaps (v3, in AGGREGATE.md)

`AGGREGATE.md` leads with a **Top gaps** table: every tagged finding across
every session, bucketed by class, with a total count, a count restricted to
the latest 3 sessions, a rising/flat/falling trend (latest-3 rate vs. the
rate over every prior session), and a `typo → intended` example. `NOVEL` and
any recurring `fixed:*` class sort first; `slangur-intentional` and
`valid-word-overlap` (doctrine non-fires, never gaps) are excluded from the
ranking and reported as a separate visible count instead. This table is the
next-wave roadmap input.

### Greynir grammar-parse enrichment (v4, OPTIONAL)

**Setup** (one-time, local): install [reynir](https://pypi.org/project/reynir/)
into a dedicated venv so it never touches the ambient interpreter or the
`~/Forks/GreynirEngine` reference checkout:

```sh
cd tools/session-analyzer
uv venv .venv            # plain `python3 -m venv` can fail with uv-managed
                          # pythons — use uv if venv creation errors out
uv pip install --python .venv/bin/python reynir
```

reynir bundles/downloads its own BÍN data (via `islenska`) on first use —
that's expected, local-only tooling data. `.venv/` and the parse cache
`.greynir-cache.json` are gitignored (same rule as `sessions/`: the cache
quotes real typed sentences).

This is entirely **optional and additive** — every feature below degrades to
today's behaviour (a one-line `_greynir: unavailable_` note, never an
exception) if the venv or `reynir` import is missing. `analyze.py` stays
stdlib-importable: the actual `reynir`/`islenska` calls live in
`greynir_worker.py`, which only ever runs inside `.venv` via a subprocess
`greynir_enrich.py` shells out to — one batched invocation per session,
covering every sentence/word that session needs, with results cached on disk
per sentence-hash / lowercase word so re-ingests of an unchanged corpus
dispatch no subprocess at all.

Four report additions, all advisory (never change engine behavior):

- **Grammar review** (new report section): every sentence of the session's
  FINAL text is parsed; a failed or very-low-score parse is listed with the
  sentence and a `grammar` (genuine residual typo/structure the engine
  couldn't untangle) vs. `foreign-token` (a tokenizer-`UNKNOWN` chunk, or a
  token confirmed-intents.jsonl marks `intentional` — e.g. `kozy`) reason.
  Deliberately NOT keyed on "lacks Icelandic diacritics" — that would
  mislabel ordinary accent-drop typos (`þvi`, `Eg`) as foreign.
- **`grammar-vouched-overlap`** (new taxonomy class, status `watch`): an
  UPGRADE applied to `valid-word-overlap` findings — the sentence is parsed
  once with the typed word, once with the intended word substituted; if
  Greynir genuinely prefers the intended version (it parses cleanly and
  either the typed version doesn't parse at all, or its score clearly loses
  by a margin), the tag upgrades and the finding — unlike plain
  `valid-word-overlap` — ranks in the **Top gaps** table (candidate for
  future context-aware margin work, measured not yet acted on). Excludes
  `TAP_USED` and any typo that's a strict prefix of intended (a mid-word tap
  fragment "not parsing" as a complete word is an artifact, not grammar
  evidence).
- **Case government audit** (new report section): for `INFLECTION_MISS`
  findings, an independent BÍN case-form lookup on typed vs. intended; for
  the final text, every preposition Greynir's own parse resolves a governed
  case for, cross-checked against the following word's independent BÍN case
  set. One line per disagreement; `_none found_` is the expected steady
  state once a sentence already parses (case agreement is enforced by the
  grammar for a successful parse) — it earns its keep on partial/failed
  parses and un-BÍN-attested inflection fragments.
- **Candidate disambiguation** (PENDING-REVIEW, `AGGREGATE.md`): for
  `SILENT_MISS` findings, each of the top-3 candidates is substituted into
  the sentence and annotated `[parses]`/`[fails]` — sharpens the list for
  Jökull's own confirmation; never auto-promotes anything to the corpus.

## Test

```sh
python3 test_analyze.py   # exit 0 = pass
```

Runs the classifier on `fixtures/fixture-*.jsonl`, a hand-built session with
exactly one event of each class (living documentation of the wire format), plus
the v2 alignment/inflection/silent-miss behaviours, the v3 taxonomy
classifier (`test_taxonomy_*`, `test_stale_apply_detection`) against real
cases and small fabricated fixtures, and the v4 Greynir enrichment
(`test_greynir_*`, in `greynir_enrich.py`): pure-logic tests with fabricated
parse results (no venv needed), a monkeypatched graceful-degradation check,
a stubbed end-to-end vouch-upgrade check, and one real integration check
(`test_greynir_real_integration`) that actually shells out to reynir on a
known sentence — skipped cleanly, not failed, when `.venv` isn't set up.
