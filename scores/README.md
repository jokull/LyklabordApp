# Eval studio — scorecard & history

The anti-overfitting scoreboard for the TypeEngine autocorrect stack
(PLAN.md "Eval studio", testing-pyramid tier 1). One command per commit
produces a JSON scorecard with hard gates; the reproducible core of that
scorecard is appended, one line, to `history.jsonl` (this directory).

Everything here is driven by `type-eval` (macOS tooling in
`Packages/TypeEngine/Sources/type-eval`, with the reusable corpus/config
logic in `Sources/EvalKit`). Data lives in `data/eval/` (read-only:
`dev.jsonl` / `heldout.jsonl`, 3,000 pairs each — see that dir's README).

## The discipline (read this first)

1. **Dev is for tuning. Heldout is report-only.** All threshold sweeps,
   weight fitting, and error analysis run against `dev.jsonl`. `heldout.jsonl`
   is **never** tuned against — no "just checking heldout" mid-iteration.
   It produces the one honest number reported at the end of a work wave /
   pre-release. `dev` and `heldout` are built from **disjoint** sentences,
   so heldout vocabulary/context/typos were never visible during dev
   generation. If heldout is ever burned, regenerate both splits with a new
   seed (see `data/eval/README.md`) and note the burn there.

2. **A tunable/ranking change is accepted only if the heldout scorecard does
   not regress.** Bug reports become scenarios (behavioral contracts in
   `Packages/TypeEngine/Scenarios/*.scenarios`), not one-off tuning.

3. **Hard gates block a release.** The scorecard exits non-zero when any hard
   gate fails:

   | gate | requirement | source |
   |---|---|---|
   | `curatedSafety` | **0** false auto-applies + valid-word pass | fast curated micro invariant |
   | `corpusRegression` | no top-1/top-3 decrease; no false-autoapply increase | committed real-artifact baseline, exact suite/category/language cohorts |
   | `languageArtifacts` | pass | manifest generation, source age, bytes, SHA-256, required cohort |
   | `artifactRuntime` | fresh-process load **<500 ms**, peak footprint **<50 MiB** | host regression proxy; no retry |
   | `benchWorstLineMs` | **< 30 ms** | `type-repl bench` worst keystroke |
   | `scenarioPass` | **100%** | every scenario in every suite passes |
   | `lastMileReplay` | **100%** final-text cases; request p95 **<60 ms**, max **<120 ms**, fast drain **<100 ms**, action p95 **<5 ms** | async serial-session replay using production request/apply guards |

## Commands

```bash
# from repo root (all run against the REAL data/ artifacts unless noted)

# Replay a corpus split → per-category / per-language / overall table.
swift run -c release --package-path Packages/TypeEngine type-eval corpus dev
swift run -c release --package-path Packages/TypeEngine type-eval corpus safety
swift run -c release --package-path Packages/TypeEngine type-eval corpus heldout   # REPORT-ONLY

# Full scorecard: micro-eval + corpus dev + scenario suites + bench → one
# JSON, appended to scores/history.jsonl. Non-zero exit on a failed gate.
swift run -c release --package-path Packages/TypeEngine type-eval scorecard
swift run -c release --package-path Packages/TypeEngine type-eval scorecard --heldout  # adds a REPORT-ONLY heldout section

# Focused Wave 41 gate: fresh/deferred delimiter application, stale delivery,
# fast-input backlog, and backspace/literal revert; assertions use final text.
swift run -c release --package-path Packages/TypeEngine type-repl last-mile

# Only when deliberately accepting a new evaluation floor/cohort. This
# rewrites the committed baseline; an ordinary scorecard can never bless itself.
swift run -c release --package-path Packages/TypeEngine type-eval scorecard --update-corpus-baseline --no-history

# Regenerate the deterministic 600-row preserve corpus from the real artifacts.
swift run -c release --package-path Packages/TypeEngine type-eval generate-safety

# A/B: baseline vs an EngineConfig override set, on corpus dev + micro-eval.
swift run -c release --package-path Packages/TypeEngine type-eval ab --config overrides.json

# A/B one bounded candidate-source family (or use --disable-provider for one
# exact provider). Ranking/action settings are unchanged.
swift run -c release --package-path Packages/TypeEngine type-eval ab --disable-family context

# Legacy micro-eval (DictLexicon fixture doubles, no corpus).
swift run -c release --package-path Packages/TypeEngine type-eval

# Personal-eval hard gate (LOCAL ONLY — real confirmed typing, gitignored;
# a fresh checkout / CI has no personal-eval.jsonl and this is a clean no-op,
# exit 0). Compares against scores/personal-baseline.json (also gitignored)
# and asserts every tools/session-analyzer/confirmed-intents.jsonl
# `intentional: true` word (slangur, e.g. "kozy") does not force-autocorrect.
swift run -c release --package-path Packages/TypeEngine type-eval personal
# Accept the current run as the new floor (run once a wave is accepted):
swift run -c release --package-path Packages/TypeEngine type-eval personal --update-baseline
```

### Personal-eval gate (eval-studio v2 phase 2)

`type-eval personal` is the hard-gate twin of `corpus`/`scorecard`, but over
`tools/session-analyzer/personal-eval.jsonl` — real confirmed typo→intended
pairs from the developer's own device recordings (see that tool's README).
It is **not** part of the committed `scorecard` JSON (the input is gitignored
personal data, so the line would not be reproducible for anyone else), and it
is not run in CI — it is a **local pre-commit discipline**: run it before
accepting a wave, exactly like a manual heldout check.

- Each row is tracked by a stable key, `typo|intended` (lowercased), against
  `scores/personal-baseline.json` (gitignored — derived from personal text).
- **Regression** (nonzero exit, named explicitly): (a) a row that passed
  top-1 in the baseline and fails now, or (b) any row with a NEW
  false-autocorrect, including brand-new rows — false-autocorrect is the
  metric guarded most jealously, so even a first-time row is held to it.
- **Improvement** (listed, non-gating): a brand-new row, or a row that now
  passes top-1 when the baseline didn't.
- **Slangur check** (Feature 2, the false-positive class): every
  `confirmed-intents.jsonl` word marked `"intentional": true` is replayed at
  a neutral lane posterior (`resetLanguagePosterior()`, no priming context —
  the most permissive the engine ever runs) and must not auto-apply a
  different word. A failure here is its own regression, independent of the
  baseline.
- `--update-baseline` rewrites `scores/personal-baseline.json` with the
  current run — do this once a wave's personal-gate result is accepted, so
  the next wave compares against it.
- Missing `personal-eval.jsonl` (fresh checkout, CI, no local recordings
  yet): prints a note and exits 0 — the gate is only as available as the
  local personal data, by design.

The **micro-eval** uses small curated `DictLexicon` doubles (the
`eval-fixture.tsv` + hand-assembled wordlists) — a fast conservatism control
named `curatedSafety`, not a system-wide zero-error claim. The **corpus** eval
uses the real `data/{is,en}` lexicons + BÍN morphology + Stage-B inflection
artifacts. `dev` has 3,000 repair rows. `safety` has 600 deterministic
`expectation: preserve` rows: 400 clean identities and 200 valid-word hard
negatives, balanced by language. For preserve rows, false-autoapply is the
meaningful policy metric; top-1/top-3 are intentionally zero because the bar
need not repeat the verbatim slot.

The committed `corpus-baseline-v1.json` is a directional gate, not a target:
for `dev` and `safety`, it requires the exact suite/category/language cohort,
equal row counts, top-1/top-3 at least the baseline, and false-autoapplies no
higher than baseline. The initial safety baseline records 16 restoration-policy
fires among 200 valid-word hard negatives (15 IS, 1 EN). Those are visible
debt and may decrease; the baseline prevents them from silently increasing.

Every corpus outcome also carries one stage: `success`, `discoveryMiss`,
`rankingLoss`, `actionPolicyAbstention`, `actionPolicyError`, or
`sessionProxyFailure`. Stateless corpus replay cannot emit the last stage.
Wave 41's last-mile proxy rig makes that ownership executable: any failed
final-text case is a `sessionProxyFailure`; the current gate requires zero
across all four cases.

### A/B override files

An overrides file is a JSON object of `EngineConfig` knob → value. Swift has
no runtime reflection, so the A/B-tunable knobs are an **explicit** allowlist
(`EvalKit/ConfigOverrides.swift`); an unknown key is a hard error. The set
covers the corrector core & conservatism margins, the beam decoder, the
space-miss split, lane relaxation (accent restoration), the two-lane
switching model, and inflection intelligence — e.g.
`autocorrectMargin`, `autocorrectMinZ`, `beamMaxEdits`, `foldBaseCost`,
`restorationDominanceRatio`, `laneSwitchProbability`, `morphBackoffWeight`,
`minAutocorrectLength`, `foldProfileISEnabled`. Run any A/B command with a bad
key to print the full supported list. Example:

```json
{ "autocorrectMargin": 2.0, "beamMaxEdits": 2 }
```

Candidate discovery has a separate allocation-free ablation mask. The family
names are `beam`, `lexical-repair`, `restoration`, `context`, `completion`,
`morphology`, `compound`, and `split`; `CandidateProvider` raw values are the
stable exact-provider names printed by `:why`. Config and provider ablations
may be combined in one command.

## Reproducibility & determinism

- **Timestamp/commit come from git HEAD** (`%cI` commit time + hash), never
  `Date.now`, so re-running the scorecard on the same commit reproduces the
  same line.
- **Corpus & micro-eval run with the two wall-clock decode budgets
  (`beamTimeBudget`, `splitTimeBudget`) lifted**, so the deterministic
  expansion/position caps are the sole limiter. Without this a handful of
  hard pairs per 3,000 flip between runs on decode timing alone. Accuracy is
  what the corpus measures; latency-under-budget is measured separately by the
  bench (which keeps the shipping 6 ms budgets).
- **The committed history line records only the deterministic content**
  (commit, timestamp, dev/safety/compound corpus + stage counts, micro counts,
  artifact manifest audit, scenario gates, and last-mile final-text outcomes).
  The **latency and fresh-process footprint gates are host-volatile**, so their
  threshold specs are recorded while their measurements are enforced only on
  the exit code. This includes last-mile request/action/drain timing. The bench
  can spike on a cold first run (measured 48 ms once, ~4 ms steady),
  so its measured value is logged to stderr and enforced on the **exit code**
  (with a one-shot retry to absorb cold-cache blips) — it is deliberately
  **not** written into the line. `benchWorstLineMs` appears in the JSON as its
  threshold spec only. The line's top-level `pass` therefore reflects the
  deterministic gates.

## history.jsonl format

One JSON object per line, keys sorted (deterministic bytes). Shape:

```json
{
  "version": "v1",
  "commit": "<HEAD hash>",
  "timestamp": "<HEAD commit time, ISO 8601>",
  "corpus": {
    "split": "dev",
    "overall":   { "n": 3000, "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... },
    "categories": { "<category>": { "n": ..., "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... }, ... },
    "byLang":     { "is": { ... }, "en": { ... } }
  },
  "safety": { ...same corpus shape, expectation=preserve... },
  "compounds": { ...same corpus shape... },
  "heldout": { ...same shape..., "reportOnly": true },
  "microEval": { "n": 167, "top1": ..., "top3": ..., "curatedSafety": { "falseAutoApplies": 0, "validWordSafety": true } },
  "hardGates": {
    "curatedSafety": { "requiredFalseAutoApplies": 0, "actualFalseAutoApplies": 0, "validWordSafety": true, "pass": true },
    "corpusRegression": { "baseline": "scores/corpus-baseline-v1.json", "failures": [], "pass": true },
    "languageArtifacts": { "generations": { ... }, "sourceAgeDays": { ... }, "verifiedFiles": 14, "failures": [], "pass": true },
    "artifactRuntime": { "loadThresholdMs": 500, "peakFootprintThresholdBytes": 52428800 },
    "benchWorstLineMs": { "threshold": 30 },
    "scenarioPass":     { "required": "100%", "passed": 250, "total": 250, "pass": true },
    "lastMileReplay":   { "required": "100% final-text cases", "passed": 4, "total": 4, "sessionProxyFailures": 0, "behaviorPass": true, "requestP95ThresholdMs": 60, "requestMaxThresholdMs": 120, "backlogDrainThresholdMs": 100, "actionP95ThresholdMs": 5 }
  },
  "pass": true
}
```

Counts are integers (not rates) so re-derivation is exact. `v0` was the first
corpus-derived baseline (2026-07-16); `v1` is Wave 40's evaluation contract.
