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
   | `falseAutocorrect` | **0** | micro-eval overall false-autocorrect count |
   | `validWordSafety` | pass | micro-eval: no expected word auto-replaces when typed verbatim |
   | `benchWorstLineMs` | **< 30 ms** | `type-repl bench` worst keystroke |
   | `scenarioPass` | **100%** | every scenario in every suite passes |

## Commands

```bash
# from repo root (all run against the REAL data/ artifacts unless noted)

# Replay a corpus split → per-category / per-language / overall table.
swift run -c release --package-path Packages/TypeEngine type-eval corpus dev
swift run -c release --package-path Packages/TypeEngine type-eval corpus heldout   # REPORT-ONLY

# Full scorecard: micro-eval + corpus dev + scenario suites + bench → one
# JSON, appended to scores/history.jsonl. Non-zero exit on a failed gate.
swift run -c release --package-path Packages/TypeEngine type-eval scorecard
swift run -c release --package-path Packages/TypeEngine type-eval scorecard --heldout  # adds a REPORT-ONLY heldout section

# A/B: baseline vs an EngineConfig override set, on corpus dev + micro-eval.
swift run -c release --package-path Packages/TypeEngine type-eval ab --config overrides.json

# Legacy micro-eval (DictLexicon fixture doubles, no corpus).
swift run -c release --package-path Packages/TypeEngine type-eval
```

The **micro-eval** uses small curated `DictLexicon` doubles (the
`eval-fixture.tsv` + hand-assembled wordlists) — a fast conservatism control.
The **corpus** eval uses the real `data/{is,en}` lexicons + BÍN morphology +
Stage-B inflection artifacts: 3,000 pairs replayed through one reused engine
(posterior reset + context primed per pair), ~12 s for a split.

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
  (commit, timestamp, corpus + micro counts, and the falseAutocorrect /
  validWordSafety / scenarioPass gates). The **latency gate is wall-clock
  volatile** (a cold first run can spike; measured 48 ms once, ~4 ms steady),
  so its measured value is logged to stderr and enforced on the **exit code**
  (with a one-shot retry to absorb cold-cache blips) — it is deliberately
  **not** written into the line. `benchWorstLineMs` appears in the JSON as its
  threshold spec only. The line's top-level `pass` therefore reflects the
  deterministic gates.

## history.jsonl format

One JSON object per line, keys sorted (deterministic bytes). Shape:

```json
{
  "version": "v0",
  "commit": "<HEAD hash>",
  "timestamp": "<HEAD commit time, ISO 8601>",
  "corpus": {
    "split": "dev",
    "overall":   { "n": 3000, "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... },
    "categories": { "<category>": { "n": ..., "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... }, ... },
    "byLang":     { "is": { ... }, "en": { ... } }
  },
  "heldout": { ...same shape..., "reportOnly": true },   // only with --scorecard --heldout
  "microEval": { "n": 166, "top1": ..., "top3": ..., "falseAutocorrect": 0, "validWordSafety": true },
  "hardGates": {
    "falseAutocorrect": { "required": 0, "actual": 0, "pass": true },
    "validWordSafety":  { "pass": true },
    "benchWorstLineMs": { "threshold": 30 },
    "scenarioPass":     { "required": "100%", "passed": 137, "total": 137, "pass": true }
  },
  "pass": true
}
```

Counts are integers (not rates) so re-derivation is exact. `v0` is the first
corpus-derived baseline (2026-07-16).
