# TypeEngine architecture

This is the working mental model for Lyklaborð's core typing experience. It
describes the engine as it exists today: where state lives, how one keystroke
becomes a suggestion bar, how candidates are found and ranked, why a top-ranked
candidate may still not auto-apply, and how to debug or change the system
without tuning the wrong layer.

The engine's source contains extensive local rationale and measurements. This
document is the map across those details. Product history and future ideas live
in the repository-level `PLAN.md` and `docs/WAVES.md`; neither is the authority
for the current engine structure.

## Engine laboratory

Core typing work does not require the app, keyboard UI, simulator, or an
iPhone. The package contains a production-shaped headless laboratory:

- `type-repl` loads the shipping language artifacts and drives the same
  `TypingSession` and `TypeEngine` path as the extension through
  `ProxySimulator`;
- scenario files reproduce complete keystroke, document-window, delimiter,
  stale-read, cursor, touch, and revert sequences;
- `type-repl last-mile` drives a separately published bar over the production
  request sequencer and a real serial session queue, asserting delimiter,
  stale-delivery, fast-input, and backspace/revert outcomes against final
  proxy text;
- `type-eval` measures curated safety, corpus quality, personal evidence, and
  configuration A/B movement;
- package tests pin narrow invariants, and `type-repl bench` measures the
  synchronous per-keystroke hot path.

The UI and real-device layers are deliberately downstream. They test the
embedder contract, extension activation, real touch delivery, and host-app
behavior; they are not where engine ranking or policy is tuned. See
[`LAB.md`](LAB.md) for the repeatable development loops and evidence ladder.

## The shortest useful model

Lyklaborð is a stateful, bilingual noisy-channel decoder behind a conservative
policy layer:

```text
touches + document window + field signals
                    │
                    ▼
             TypingSession
     proxy continuity, commits, tap alignment,
      verbatim/revert state, learning events
                    │
                    ▼
               TypeEngine
      running IS/EN lane posterior + facade
             ┌──────┴──────┐
             ▼             ▼
         Corrector      Predictor
             │             │
 candidate discovery       │
             ▼             │
 exact channel cost         │
 + blended language score  │
 + optional morph/personal │
             ▼             │
 conservative auto-apply   │
 policy                    │
             └──────┬──────┘
                    ▼
       TypingSession bar assembly
   verbatim slot, field gates, dotted tokens,
       personal/eject and revert affordances
                    │
                    ▼
          suggestions + side effects
```

Three stages must stay conceptually separate:

1. **Discovery:** can the intended candidate enter the pool?
2. **Ranking:** once present, does it beat the alternatives?
3. **Action policy:** even if it wins, is there enough evidence to replace
   what the user typed without a tap on the suggestion?

Many bad fixes come from changing ranking to solve a discovery gap, or lowering
an auto-apply threshold to solve a ranking problem. Diagnose the stage first.

## Boundaries and responsibilities

| Component | Owns | Does not own |
|---|---|---|
| [`TypingSession`](Sources/TypeEngine/TypingSession.swift) | Document-window interpretation, expected-edit ledger, commit detection, current-word parsing, tap/long-press alignment, verbatim and revert state, field gates, buffered learning events | Candidate scoring, persistent storage, UI, threading |
| [`TypeEngine`](Sources/TypeEngine/TypeEngine.swift) | Public synchronous facade, running language-lane posterior, corrector/predictor coordination, injected personal/touch/inflection snapshots | Proxy semantics, persistence, async work |
| [`Corrector`](Sources/TypeEngine/Corrector.swift) | Candidate discovery, exact channel rescoring, ranking, confidence, auto-apply decision | Document history, suggestion-bar presentation, persistent learning |
| [`BeamDecoder`](Sources/TypeEngine/BeamDecoder.swift) | Bounded prefix-range search through frequency lexicons | Final cost, ranking, or autocorrect authority |
| [`BlendedLanguageModel`](Sources/TypeEngine/LanguageModel.swift) | Lexicon calibration, unigram/bigram/context scores, IS/EN blending, validity and typicality, personal boosts, shared optional stores | Search strategy and UI policy |
| [`Predictor`](Sources/TypeEngine/Predictor.swift) | Next-word candidates after a committed context | Correction of a word in progress |
| [`SpatialModel`](Sources/TypeEngine/SpatialModel.swift), [`PerTapCostProvider`](Sources/TypeEngine/PerTapCostProvider.swift), [`FoldPricing`](Sources/TypeEngine/LaneRelaxation.swift) | Static geometry, actual-tap likelihoods, personal touch adaptation, restoration-vs-error channel prices | Language probability and candidate attestation |
| [`CompoundAnalyzer`](Sources/TypeEngine/Compounds.swift) | Productive compound decomposition and its conservative legal-part rules | General grammar or arbitrary compound generation |
| [`InflectionStore`](Sources/TypeEngine/Inflection.swift) | Optional governor/case backoff, paradigm access, personal lemma-sibling lift | Hard grammar rules or valid-form auto-replacement |
| Embedder (`KeyboardExt` or `type-repl`) | One owning queue, artifact loading, text-proxy mutations, reporting self-edits, draining learning events | Reimplementing engine/session behavior |

`TypeEngine` and `TypingSession` are synchronous and not thread-safe. The
caller must confine a session and its engine to one serial execution context.
There is deliberately no dispatch or async machinery in this package.

## Inputs and artifacts

The engine consumes interfaces rather than owning files. Production wires the
following artifacts into those interfaces:

| Evidence | Production artifact | What it means |
|---|---|---|
| Icelandic frequency and context | `data/is/is.lex` via `Lexicon` | Attested surface vocabulary, unigram frequency, bigrams, continuations, prefix search |
| English frequency and context | `data/en/en.lex` via `Lexicon` | Same signals for English |
| Frequency calibration | `data/{is,en}/*-calibration.json` via `LexiconCalibrationProfile` | Generation-bound mean/σ and a bounded warm-up set; avoids recomputing stable corpus statistics on extension activation |
| Icelandic morphology | `data/is/bin-morph.bin` via `MorphologyProviding` | Whether a form is morphologically known, lemma candidates, POS/case analyses, open-class status |
| Paradigms | `data/is/paradigms.bin` via `ParadigmsProviding` | Forms grouped by lemma and morph feature bundle |
| Case government | `data/is/governors.json.gz` via `GovernorsModel` | Statistical `P(case | previous word)` backoff |
| Personal vocabulary | `PersonalVocabulary` snapshot | User-valid words, counts, bigrams, explicit intent, tombstones |
| Personal touch model | `PersonalTouchSnapshot` | Per-key Gaussian aggregates used after the sample gate |
| Current touch evidence | aligned `[TapSample?]` | Per-position likelihood for this pending token |

These sources express different strengths of evidence:

- Frequency-lexicon attestation supports typicality, language attribution,
  contextual ranking, and prediction.
- BÍN validates many legitimate forms that a finite corpus misses, but does
  not by itself prove that a form is common or that it belongs to the current
  language lane. BÍN-only forms therefore receive a low scoring floor and are
  normally offer-only.
- Paradigms and governors are ranking backoffs, not a grammar oracle. Exact
  bigram evidence wins when present.
- Personal evidence is an additive prior and validity source. It never moves
  the base language posterior.
- A tombstone means “do not suggest this.” It still protects the literal word
  when typed; deletion must not turn a word into an autocorrect target.

Optional evidence is injected after engine construction. With no inflection,
personal, or touch snapshot, the associated scoring seams are inert. Preserve
that graceful degradation when adding new evidence sources.

## State ownership

### `TypingSession` state

A session represents one logical text-field interaction. It owns:

- the previous observed document window and parsed current word;
- the expected-edit ledger used to distinguish our proxy mutations from host
  changes, cursor jumps, autofill, paste, and stale reads;
- carried context when iOS truncates the document window at a sentence;
- touch samples aligned to the pending token and long-pressed characters that
  signal deliberate input;
- the last emitted suggestions/autocorrect, which lets the next observation
  recognize an accepted correction;
- dotted-token continuation revert, punctuation attachment, and backspace
  literal-revert memos;
- the verbatim-choice suppression memo;
- pending learning events waiting for the embedder to drain them.

External discontinuities clear adjacency-sensitive state. A cursor jump or
host mutation must not be interpreted as a commit, must not train the language
lane, and must not leave a stale revert or tap record behind.

### `TypeEngine` state

The engine owns the current `P(IS)` lane posterior, initialized at `0.5`. It
also owns the model/corrector/predictor graph plus session-immediate personal
vocabulary. `confirmWord` advances the lane only after the session has proven a
real word commit. Sentence boundaries relax it toward neutral; reset returns it
to neutral.

### Shared model stores and caches

The language model holds injected personal, touch, inflection, compound, and
continuation stores. The beam keeps a bounded shallow-prefix cache. These are
performance and evidence stores inside the same single-queue confinement
contract; they are not independent concurrent services.

Persistent learning is outside this package. `TypingSession` emits typed
`LearningEvent`s; the embedder drains them. The `Learning` package defines the
durable event log and personal model.

## One autocomplete pass

The extension and headless harness both call
`TypingSession.suggestions(for:limit:trace:)`. One pass proceeds as follows.

### 1. Adopt and classify the document window

The session parses the text before the cursor into committed context and the
word in progress. It compares the new window with the previous observation,
consulting the expected-edit ledger first.

The result is one of:

- an explained evolution such as one typed character, backspace, or a
  suggestion replacement;
- a sentence-truncation reset caused by the proxy's limited context;
- an external discontinuity such as a cursor move, host edit, paste, autofill,
  or unexplained stale state.

The embedder should report every text mutation it performs with
`noteSelfEdit(before:after:)`. Shape heuristics remain as a fallback, but the
ledger is the exact source of self-vs-host attribution.

### 2. Confirm commits before replacing pending-word state

If the observed evolution completed the previous current word, the session
reads the committed form back from the document. This is important: an applied
autocorrect commits the corrected surface, not the raw typo.

A real commit:

- calls `TypeEngine.confirmWord` to update the lane posterior;
- emits the appropriate learning event (`wordCommitted`, accepted suggestion,
  revert, or explicit tap path);
- carries sentence-boundary information;
- can arm the one-backspace literal-revert slot.

Multiword host changes are treated as paste/autofill and do not train. The
exception is a multiword string that exactly matches a previously offered
space-miss split; each half is then a genuine ordered commit.

### 3. Reconcile input evidence

Queued touch samples are aligned with the new pending word. A missing or
mismatched sample becomes `nil`, which means static spatial pricing. Evidence
never survives a genuine discontinuity. Long-press signals follow the pending
word and veto restoration relaxation for that deliberate input.

### 4. Build the suggestion bar

The session routes by token shape:

- empty pending word → next-word prediction;
- ordinary token of at least two characters → correction/completion;
- a supported single vowel → the targeted single-letter restoration path;
- dotted or `@` token → verbatim-class handling with tap-only trailing-segment
  suggestions;
- a conservative `word.word` shape may escape dotted-token handling as a
  period-key/spacebar near miss;
- URL, email, search, and secure fields remove restoration suggestions and
  strip all auto-apply flags.

Finally the session adds the literal verbatim slot, or the reserved pre-
autocorrect literal after a backspace, marks ejectable personal suggestions,
and enforces the requested bar size.

The session does not mutate the host document. It returns suggestions and
explicit revert instructions; the embedder performs and reports proxy edits.

## Language lane and context

The lane is a sticky two-state switching model: Icelandic-with-slettur versus
English. It is not a per-word language selector and never removes candidates
from the other language.

For a committed word, each lexicon produces a calibrated unigram z-score.
Calibration is essential because the Icelandic and English corpora have
different sizes and frequency scales. Their difference becomes bounded
emission evidence for the posterior update:

Production does not estimate these stable values on the cold keyboard path.
Each language generation ships a tiny hashed calibration sidecar containing
the exact mean, standard deviation, add-k value, and bounded warm-up words.
Invalid/mismatched profiles fall back to deterministic runtime measurement for
testability; the scorecard manifest audit fails production cohort drift.

```text
predict:  p' = (1-s)·p + s·(1-p)
update:   odds(p) = odds(p') · exp(laneEvidence(committedWord))
```

The low switch prior absorbs one off-lane word; consecutive evidence changes
the lane. Unattested, ambiguous, and personal-only words carry little or no
lane evidence. They must not hijack the lane.

For candidate ranking, each language separately computes an add-k smoothed
unigram or interpolated bigram score, then calibrates it within that lexicon.
The current lane blends the two calibrated readings:

```text
S_lang(w) = log(
    P(IS) · exp(τ · z_IS(w | context))
  + P(EN) · exp(τ · z_EN(w | context))
) + personalBoost(w | context)
```

An unattested lazy-accent context may fold to its dominant accented twin for
bigram lookup (`eg` → `ég`). Personal boosts remain outside the lane evidence
calculation.

## Correction is discovery, scoring, then policy

### Candidate discovery

`Corrector.correct` builds a deduplicated pool. The numbered passes in the
source describe computational order, not ranking priority; every admitted
candidate competes in the same scored pool.

| Pass family | Purpose |
|---|---|
| Shallow prefix-range beam | Primary lexicon search for spatially plausible substitutions, indels, and transpositions |
| One-edit residue | Personal and BÍN-only candidates outside the frequency-lexicon beam |
| Targeted orthography | Acute/orthographic restoration, gemination compositions, English apostrophes |
| Short-token repairs | Carefully bounded double substitutions and context-proposed continuations where the long-token beam is unavailable |
| Prefix completion | Base and personal completions; pools widen under a governor |
| Case-aware completion | Speculative trimmed-prefix completions and unambiguous paradigm siblings in supported cases |
| Shortened/restored-prefix completion | Suffix-error and lazy-accent completion shapes missed by literal-prefix lookup |
| Deep beam | Gated multi-edit decode for longer unknown tokens; optional wider mash-recovery cone is offer-only outside the ordinary cap |
| Compound repair/completion | Hold legal modifiers fixed and repair or complete a plausible head |
| Space-miss split | Gated two-word readings, including substitution of a near-spacebar character for the missing space |

Every bounded source has a stable `CandidateProvider` identifier. The common
first-wins admission pool keeps the historical channel cost when more than one
source reaches the same word, while a requested `CorrectionTrace` records all
of those sources. Production does not allocate provenance storage.

Important properties:

- Search is evidence proposal, not truth. A specialized pass may admit a
  candidate but cannot force its ranking or application.
- Beam costs are pruning currency only. Every emitted beam candidate is
  rescored by the exact dynamic-programming channel model.
- Expensive/wide passes are gated by token shape and the best plausible result
  already found. Ordinary words in progress should not pay deep-search cost on
  every keystroke.
- Tombstoned candidates are rejected through the common admission path.
- Speculative case and compound completions remain distinguishable so later
  ranking and action policy can keep them offer-only or subordinate to splits.

If an intended word is absent from the bar and absent from `:why`, investigate
discovery and its gates before touching score weights.

### Exact channel cost

The channel asks: how costly is it for the user to have produced the typed
characters while intending the candidate?

It is an edit-alignment dynamic program over substitution, insertion,
deletion, and transposition costs. Substitutions come from either static key
geometry or the aligned tap likelihood provider. Personal per-key Gaussians
modify the tap provider after their sample gate.

`FoldPricing` composes lane-specific input methods on top of those physical
costs. In a confident Icelandic lane, typing a base vowel for a long-press
acute is cheap; in a confident English lane, omitting an apostrophe is cheap.
Directional confusions and gemination may be discounted but remain errors.

Each alignment produces a `ChannelCost`:

```text
total cost + count(error-class operations) + count(restoration operations)
```

This decomposition matters. A candidate with only restoration operations can
use restoration policy; a word with several free folds plus one real typo is
still an error-class correction whose meaningful cost is that typo.

Touch evidence is bidirectional:

- a tap leaning toward a neighboring intended key makes that substitution
  cheaper;
- a dead-center tap makes changing the resolved character expensive and raises
  the evidence required for auto-apply.

No usable tap must reproduce the static path.

### Ranking

The base score is:

```text
score(candidate) = -channelCost
                 + languageWeight · S_lang(candidate | context, lane)
                 + optional morphology/compound terms
```

Morphology boosts completion-shaped candidates under a governor only when an
exact bigram does not already carry stronger evidence. Compound completions may
read head typicality and head case fit. Space-miss pairs use a joint same-lane
two-word score so a split cannot cherry-pick Icelandic for one half and English
for the other.

The pool is sorted by score with a deterministic lexical tiebreak. Confidence
is a softmax over the top of this pool. **Confidence is descriptive; it is not
the sole autocorrect threshold.** The action decision uses explicit gates.

If the intended candidate is present but ranked too low, inspect its exact
channel cost, calibrated language score, context lift, personal boost, and
optional morph term with `:why`, `:word`, and `:bigram`.

### Auto-apply policy

Ranking answers “what is the best reading?” Auto-apply answers the riskier
question “may we overwrite the literal without an explicit tap?”

All branches first enforce structural preconditions such as minimum token
length, maximum channel cost, preservation of typed apostrophes, and
preservation of deliberate long-press input. Actual taps can multiply the
required margin through the tap-veto factor.

The decision then follows one of these broad branches:

1. **Unknown single-word repair:** requires score margin and typicality.
   Short and far repairs demand more common winners; junk-tier winners demand
   more margin; speculative mash-recovery-only readings stay offer-only.
2. **Space-miss split:** requires a higher split margin and no plausible close
   attested single-word repair.
3. **Protected skeleton restoration:** a valid unaccented skeleton can only be
   crossed by a restoration-only winner through dominance, contextual support,
   no deliberateness signal, lane/sletta protection, and restoration margin.
4. **Single-letter restoration:** uses its own tightly targeted lane and
   frequency rules instead of the general pipeline.

Typed-word protection includes base lexicons, BÍN, explicit/personal intent,
tombstones, and accepted productive compounds. There are narrow documented
exceptions rather than a blanket bypass: restoration collision gates and an
attested linking-letter repair that may yield an accidental compound
decomposition. These exceptions should remain explicit and scenario-guarded.

Additional policy includes context-vouched short repairs, proper-noun
possessive protection, restoration-specific lower margins, BÍN-vacuum handling,
and short-completion suppression. Read the `Conservatism / autocorrect
decision` section of `Corrector.swift` before changing any threshold.

If the intended candidate is top-ranked but does not auto-apply, this policy
layer—not discovery or ranking—is the first place to inspect. `:why` prints the
selected branch and every evaluated gate.

## Prediction

An empty current word routes to `Predictor` rather than `Corrector`. Prediction
combines exact bigram continuations with a top-unigram fallback, uses the same
calibrated bilingual blend and current lane posterior, applies personal
evidence, and respects tombstones. One off-lane sletta does not permanently
retarget prediction because the sticky lane is the shared context signal.

Do not fix next-word prediction by changing correction candidate passes. They
are distinct entry paths sharing the language model.

## Learning inside the typing path

The engine has two learning timescales:

- **Session-immediate:** an explicit learn/verbatim action enters the in-memory
  personal overlay immediately, so the current session does not wait for app
  compaction.
- **Durable:** the session emits privacy-gated learning events at confirmed
  word boundaries. The embedder drains these into the `Learning` package's
  event log; a later personal snapshot can be injected back into the engine.

Only standard fields emit learning events. Paste/autofill, uncertain proxy
changes, URL/email/search/secure fields, and invalid event tokens do not train.
Touch learning uses confirmed committed text; rejected corrections must not
train the wrong intended key.

Surface forms are the durable truth. Lemma generalization is a smaller
unambiguous-sibling boost, never a merge of homographic counts.

## Debugging workflow

### Reproduce through the real session path

From `Packages/TypeEngine`:

```bash
swift run -c release type-repl
```

The REPL loads the production artifacts and types through `ProxySimulator` and
the same `TypingSession` used by the extension. Useful commands include:

```text
:why                 provider provenance, named score signals, margins, policy branch and gates
:word <word>         IS/EN frequency, calibrated z, BÍN and lane evidence
:bigram <prev> <w>   exact counts and contextual calibrated scores
:gov <word>          governor case distribution
:compound <word>     validity, protection and decomposition
:posterior           current P(IS)
:context             full document versus exposed proxy window
:timing              per-keystroke latency
:tap <c> <dx> <dy>   actual-tap hypothesis
:longpress <chars>   deliberateness hypothesis
```

Use `--no-morph`, `--no-inflect`, or `--personal <model.json>` to isolate an
evidence layer.

### Classify the failure

| Symptom | First question | Likely area |
|---|---|---|
| Intended word never appears | Which discovery pass should be able to reach it, and why was that pass gated? | `Corrector`, `BeamDecoder`, artifact coverage |
| Intended word appears below a rival | Is the difference channel cost, language calibration, bigram context, morph fit, or personal boost? | `SpatialModel`/tap provider, `LanguageModel`, `Inflection` |
| Intended word is top but tap-only | Which auto-apply branch and gate blocked it? | Corrector conservatism; inspect `:why` |
| Wrong word commits or commits twice | Was the suggestion stale, or was a host/proxy change misclassified? | `TypingSession`, expected-edit ledger, embedder apply guard |
| Correct behavior headlessly but not on device | Do touch coordinates, field kind, window truncation/staleness, timing, or application order differ? | Session/embedding boundary; replay captured evidence |
| Lane flips or context feels wrong | Which committed words actually updated the posterior, and what evidence did they carry? | Commit detection, `:posterior`, `:word`, calibration |
| First keystrokes are slow | Is cost artifact loading/page faults or a wide discovery pass? | Embedder warm-up versus `type-repl bench`/candidate gates |

### Turn the observation into a contract

Real typing bugs should become scenarios in `Scenarios/`, exercising the full
proxy/session path. Narrow algorithm rules also deserve unit tests in
`Tests/TypeEngineTests`.

```bash
swift run -c release type-repl run Scenarios/core.scenarios
swift run -c release type-repl run Scenarios/dogfood.scenarios
swift test
```

Use the evaluation tools before accepting ranking or policy movement:

```bash
swift run -c release type-eval
swift run -c release type-eval corpus dev
swift run -c release type-eval ab --config /path/to/overrides.json
swift run -c release type-eval ab --disable-family context
swift run -c release type-eval personal
swift run -c release type-eval scorecard
swift run -c release type-repl bench
swift run -c release type-repl last-mile
```

The held-out corpus is report-only and is not a tuning surface. See
[`scores/README.md`](../../scores/README.md) and
[`data/eval/README.md`](../../data/eval/README.md) for the evaluation
discipline.

Provider-family ablations accept `beam`, `lexical-repair`, `restoration`,
`context`, `completion`, `morphology`, `compound`, and `split`. Use
`--disable-provider <stable-provider-name>` for a narrower diagnosis; the
trace prints those names after `via=`. Ablations change discovery only—ranking
and action policy remain the same—so their dev-corpus delta measures the value
and risk of that candidate source.

## Where an improvement belongs

| Improvement or bug | Preferred home |
|---|---|
| New Icelandic form analysis, lemma/POS/case truth | Upstream language artifact or `LemmaCore`; expose through `MorphologyProviding` |
| Better frequency or phrase evidence | Lexicon build pipeline/artifact, then calibrated language model |
| Candidate is structurally unreachable | A bounded discovery pass or `BeamDecoder`, followed by exact rescoring |
| Fat-finger likelihood is wrong | `SpatialModel`, `PerTapCostProvider`, or personal touch model |
| Missing accents/apostrophes are priced like mistakes | `FoldPricing` and restoration classification |
| Context or cross-language ranking is wrong | `BlendedLanguageModel`, calibration, bigram evidence, or lane model |
| Wrong inflected form leads after a governor | Inflection artifact/backoff and completion scoring—not hard replacement rules |
| Correct candidate wins but should/should not auto-apply | Explicit conservatism gate in `Corrector` |
| Cursor, paste, stale read, or commit behavior is wrong | `TypingSession` and expected-edit ledger |
| Suggestion bar rendering or proxy mutation is wrong | Keyboard embedder, outside TypeEngine |
| Durable counts, deletion, import, or compaction is wrong | `Learning`, outside TypeEngine |

When introducing a new evidence source, prefer this shape:

1. define what question the evidence can legitimately answer;
2. expose it behind a small interface or optional store;
3. use it first to propose or rank, not silently to override invariants;
4. make absence reproduce the old path;
5. add diagnostics that reveal its numerical contribution;
6. guard behavior with unit, scenario, corpus, personal, and latency checks as
   appropriate.

## Decision principles

- **Literal intent is the baseline.** Under-correction is safer than an
  unsupported replacement; the verbatim route must remain available.
- **Input method is not error correction.** Lazy accents and apostrophes can
  use restoration policy, but real substitutions still consume error evidence.
- **Attestation, validity, and typicality are different.** BÍN validity cannot
  substitute for corpus frequency; corpus noise cannot substitute for
  morphology; personal intent must not become language evidence.
- **Context proposes; typed evidence verifies.** A strong bigram can surface or
  lift a reading, but should not make an arbitrary distant word inevitable.
- **Search widening is not policy widening.** A broader beam may fill an empty
  bar while keeping newly reached far candidates offer-only.
- **Exact evidence beats backoff.** Exact bigrams beat case-government
  inference; a whole attested form beats a hypothesized compound.
- **One layer, one reason.** Avoid compensating score constants for proxy-state
  bugs, or special candidate generators for calibration errors.
- **Measure the whole trade.** Bug reports become scenarios; tuning changes
  must survive corpus, personal, false-autocorrect, valid-word, and latency
  gates.

## Source map

| File | Read it when working on |
|---|---|
| [`TypingSession.swift`](Sources/TypeEngine/TypingSession.swift) | Full text-window lifecycle, commits, bar assembly, learning and revert behavior |
| [`TypeEngine.swift`](Sources/TypeEngine/TypeEngine.swift) | Public facade, lane updates, personal/inflection injection, diagnostics |
| [`Corrector.swift`](Sources/TypeEngine/Corrector.swift) | Candidate passes, exact scoring, confidence and autocorrect policy |
| [`CandidateProvider.swift`](Sources/TypeEngine/CandidateProvider.swift) | Stable source provenance, common admission, rank signal ledger and ablation families |
| [`LanguageModel.swift`](Sources/TypeEngine/LanguageModel.swift) | Tunables, validity, calibration, bilingual/context/personal scoring |
| [`BeamDecoder.swift`](Sources/TypeEngine/BeamDecoder.swift) | Prefix-range spatial search and its budgets |
| [`SpatialModel.swift`](Sources/TypeEngine/SpatialModel.swift) | Static Icelandic key geometry and edit costs |
| [`PerTapCostProvider.swift`](Sources/TypeEngine/PerTapCostProvider.swift) | Coordinate likelihoods and adaptive personal Gaussians |
| [`LaneRelaxation.swift`](Sources/TypeEngine/LaneRelaxation.swift) | Restoration pricing and error/restoration decomposition |
| [`Predictor.swift`](Sources/TypeEngine/Predictor.swift) | Next-word continuation and unigram fallback |
| [`Inflection.swift`](Sources/TypeEngine/Inflection.swift) | Governors, paradigm backoff and personal lemma lift |
| [`Compounds.swift`](Sources/TypeEngine/Compounds.swift) | Productive compound acceptance and decomposition constraints |
| [`ExpectedEditLedger.swift`](Sources/TypeEngine/ExpectedEditLedger.swift) | Exact self-edit attribution |
| [`ProxySimulator.swift`](Sources/TypeEngine/ProxySimulator.swift) | Headless model of the `UITextDocumentProxy` contract |
| [`CorrectionTrace.swift`](Sources/TypeEngine/CorrectionTrace.swift) | Numerical `:why` debugging surface |
| [`PersonalVocabulary.swift`](Sources/TypeEngine/PersonalVocabulary.swift) | Snapshot/session personal evidence semantics |
| [`PersonalTouch.swift`](Sources/TypeEngine/PersonalTouch.swift) | Adapter from learned touch aggregates to engine evidence |

## Relationship to the planned Icelandic language architecture

This document treats lexicons, BÍN analysis, paradigms, governor statistics,
compound legality, and spelling evidence as inputs to the typing decoder. A
separate Icelandic language architecture should document how those facts are
produced, their provenance and licenses, what each Miðeind/lemma-is component
can assert, and where their uncertainty lies.

Keeping the boundary explicit is useful: the language architecture should
answer **what Icelandic analyses and evidence are available**; TypeEngine
should answer **how a keyboard combines that evidence with noisy physical
input, personal context, and conservative interaction policy**.
