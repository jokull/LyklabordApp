# TypeEngine laboratory

This is the default workbench for improving Lyklaborð's core typing experience.
It runs without the app, keyboard UI, simulator, or a connected iPhone while
using the production language artifacts and the production session/engine
path.

## What the lab faithfully models

```text
typed characters / taps / host mutations
                    │
                    ▼
             ProxySimulator
   UITextDocumentProxy-shaped window behavior
                    │
                    ▼
             TypingSession
 commits, continuity, revert, learning, bar assembly
                    │
                    ▼
              TypeEngine
 discovery → exact scoring → ranking → action policy
                    │
                    ▼
      suggestions + simulated proxy edits
```

`type-repl` and the extension share `TypingSession`, `TypeEngine`, artifact
formats, engine configuration, and the mutation-reporting contract. The lab
therefore answers engine questions such as:

- Was the intended word discovered?
- Which evidence won or lost the ranking?
- Why was a winner offered but not auto-applied?
- Did a delimiter, stale result, cursor change, or revert mutate the document
  correctly?
- Did quality or synchronous keystroke latency move across a change?

The ordinary REPL/scenario loop intentionally does not model KeyboardKit
rendering, iOS extension process launch, real touch event delivery, or
arbitrary host-app behavior. The `last-mile` command adds the async embedder
boundary that can be proven headlessly: a separately published bar, the same
production request sequencer and apply-time token guard, a real serial session
queue, and final proxy text. Rendering, process launch, and host-specific iOS
quirks remain downstream device gates.

## Fast diagnosis loop

From this directory:

```bash
swift run -c release type-repl
```

Type the failing phrase exactly as a user would. Use `:why` to separate
discovery, ranking, and action-policy failures; use `:context`, `:posterior`,
`:word`, `:bigram`, `:gov`, and `:timing` to inspect the responsible evidence.
For each top candidate, `:why` prints stable `via=` provider provenance; exact
channel, weighted language, morphology, compound, and precedence
contributions; and contextual/personal evidence already contained in the
language term.
The REPL also accepts tap hypotheses, long-press intent, cursor movement, host
mutations, and truncated proxy windows.

For a deterministic reproduction, put the interaction in a scenario file:

```bash
swift run -c release type-repl run Scenarios/core.scenarios
swift run -c release type-repl run Scenarios/dogfood.scenarios
```

`core.scenarios` is the behavioral gate. `dogfood.scenarios` tracks observed
real-session cases and may document gaps before they are promoted to accepted
behavior.

## Incremental change loop

Use the narrowest evidence that can disprove the proposed change, then widen
the gate before accepting it.

1. Add a focused package test for a local invariant or a scenario for a full
   typing interaction.
2. Reproduce the case in `type-repl` and inspect `:why`; diagnose discovery,
   ranking, action policy, or session behavior before changing code.
3. Make one bounded change and rerun the focused test/scenario.
4. Compare aggregate movement on the dev corpus and personal evidence.
5. Run the full scorecard and latency gate. Use heldout only at the wave
   boundary and never tune against it.

Useful commands:

```bash
swift test
swift run -c release type-eval corpus dev
swift run -c release type-eval ab --config /path/to/overrides.json
swift run -c release type-eval ab --disable-family restoration
swift run -c release type-eval ab --disable-provider context-continuation
swift run -c release type-eval personal
swift run -c release type-repl bench
swift run -c release type-repl last-mile
swift run -c release type-eval scorecard
swift run -c release type-eval scorecard --heldout
```

`type-eval scorecard` is the one-command acceptance gate. It runs the curated
micro evaluation, real-artifact dev corpus, every scenario suite, the timed
last-mile replay, and the latency bench, appending a deterministic result to
`scores/history.jsonl`.
`--heldout` adds report-only heldout results and belongs at an accepted wave
boundary, not in the tuning loop.

## Choosing the right evidence

| Question | First instrument | Acceptance evidence |
|---|---|---|
| Candidate never appears | `type-repl :why` | Scenario + discovery slice |
| Wrong candidate ranks first | `:why`, `:word`, `:bigram`, `:gov` | Dev corpus/A-B + personal gate |
| Correct winner should or should not apply | `:why` policy branch | Valid-word safety + scenario + false-autoapply slices |
| Commit/session behavior is wrong | `ProxySimulator` scenario | Core scenario suite |
| Delimiter, stale delivery, fast queue, or revert is wrong at the embedder boundary | `type-repl last-mile` | Four final-text cases + request/action latency gate |
| One algorithmic invariant is wrong | Focused package test | Full package tests + scorecard |
| Per-key work is too slow | `type-repl bench` and `:timing` | Release bench p95/p99/max gate |
| First bar after extension activation is slow | Cold-start journal on physical iPhone | Physical process-cold cohort; never inferred from the headless bench |
| Correct in last-mile replay but wrong in an app | Device trace / ReplayRig | iOS embedder or UI test, not ranking retuning |

## Evidence hygiene

- Real typing reports become scenario reproductions; they are not tuning
  datasets by themselves.
- The dev corpus is a tuning surface. Heldout is report-only.
- Personal evaluation data stays local and must not regress.
- A scenario protects a known interaction but does not establish aggregate
  quality.
- A faster benchmark cannot excuse a behavioral regression, and an aggregate
  gain cannot excuse a new false autocorrect.
- Every new candidate source needs provenance, a bounded cost, an ablation,
  and unchanged action safety.

This separation is intentional: most engine work should iterate quickly and
deterministically in the lab. Simulator, ReplayRig, and physical iPhone checks
are reserved for facts the headless model cannot establish.
