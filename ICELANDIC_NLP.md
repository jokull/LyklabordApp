# Icelandic language intelligence architecture

*Architecture harvest: 2026-07-18. Companion to the current
[`TypeEngine` architecture](Packages/TypeEngine/README.md).*

This document is the mental model for improving Lyklaborð's Icelandic+English
language intelligence. It maps what the current keyboard can already know, what
the Icelandic software and data ecosystem can assert, where those assertions
are uncertain, and how to turn them into incremental typing-UX improvements
without compromising latency, privacy, or literal user intent.

The boundary between the two architecture documents is deliberate:

- The TypeEngine document answers **how noisy touch input, context, personal
  evidence, ranking, and conservative action policy become a typing result**.
- This document answers **what linguistic evidence can be produced, where it
  comes from, how expensive and trustworthy it is, and which engine seam may
  consume it**.

`PLAN.md` and `docs/WAVES.md` remain the product roadmap and chronological
decision ledger. This is a capability map and a decision framework, not a
promise to ship every technique described here.

## Executive thesis

The best unconstrained architecture is still a hybrid architecture:

```text
touches + document state
          │
          ▼
bounded deterministic bilingual decoder
spatial channel + IS/EN lexicons + BÍN + compounds
          │ N-best candidates with exact channel costs
          ▼
optional contextual evidence
trigrams + richer morphology + compact neural rescorer
          │ calibrated score contributions
          ▼
separate asymmetric action policy
offer / auto-apply / preserve literal / abstain
```

This is not a compromise between an old engine and a fashionable neural one.
It is the structure supported by production keyboard research. Google's mobile
decoder represents literal input, spatial errors, correction, completion, and
prediction under tight latency constraints; later neural work injects context
into a constrained search rather than replacing it with free generation
([Ouyang et al., 2017](https://arxiv.org/abs/1704.03987),
[Zhang et al., 2024](https://aclanthology.org/2024.emnlp-industry.93/)).

The architecture has seven consequences:

1. **The current decoder remains authoritative and immediately usable.** A
   neural component may reorder or narrowly propose candidates; it never gets
   independent permission to overwrite text.
2. **Miðeind is primarily a knowledge, compiler, teacher, and evaluation
   stack.** Its Python parser and corrector are not keyboard-extension runtime
   dependencies.
3. **`lemma-is` already supplied the essential bridge.** Its binary BÍN
   analysis format is ported to Swift and memory-mapped by `LemmaCore`. The
   keyboard already adds generation, case-government evidence, a bilingual
   lane, touch decoding, learning, and a stronger compound analyzer.
4. **Morphology is not intent.** BÍN can establish that a form and analysis are
   possible. It cannot establish that the form is common, belongs to the
   current language, or is what this user meant.
5. **Language is per candidate and contextual, never a keyboard mode.** The
   Icelandic layout is a physical input surface, not a declaration that every
   token is Icelandic.
6. **Cold start is part of correctness.** The keyboard UI never waits for file
   I/O, model construction, decompression, or a page-fault-heavy warm-up.
   Optional evidence must degrade to the deterministic path.
7. **Real typing traces are the scarce strategic asset.** Corpora teach
   language; only recordings with touches, corrections, accepts, and reverts
   teach the actual keyboard channel and the cost of being wrong.

## North-star user experience

Lyklaborð should feel like one Icelandic keyboard that understands the way
Icelanders actually write:

- Icelandic and English can mix inside the same sentence without a mode switch.
- `ð`, `þ`, `æ`, and `ö` remain first-class keys; skipped acute accents are a
  fast input method, not automatically evidence of carelessness.
- Inflected forms, productive compounds, names, loanwords, abbreviations,
  handles, URLs, code, and deliberate unusual words remain reachable.
- Context helps choose and order forms, but never turns grammatical plausibility
  into silent authority over valid literal text.
- The first key feels immediate after a cold activation, and every optional
  intelligence layer has a correct fallback.
- Learning is local, inspectable, deletable, and subordinate to explicit user
  actions.

“No constraints” here means no artificial limit on ambition. The physical
constraints of an iOS extension—launch time, memory, energy, partial document
context, process death, and user trust—are part of the problem definition.
Apple gives custom keyboards a separate process
([custom keyboard documentation](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)).
Its extension guidance also calls out lower memory limits, aggressive
termination, short launch budgets, and the requirement not to block the main
run loop
([extension performance guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)).

## The whole system

```text
                           OFFLINE ARTIFACT FACTORY

 BÍN/DIM versioned snapshot ─► morphology analysis ─┬─► lemma-is.bin / future morph.v3
                                             └─► paradigms.bin

 IGC + Icegrams + EN corpora ─► normalize/filter/calibrate ─► is.lex / en.lex
                          └────► top-K trigram and continuation artifacts

 Tokenizer + GreynirEngine + GreynirCorrect ─► distilled token/rule features
 GreynirCorpus + IceEC + MIM-GOLD ───────────► gold/eval slices and hard cases
 IceBERT/Yfirlestur/GreynirSeq ─────────────► teacher labels + synthetic pairs
 real Lyklaborð sessions ────────────────────► touch/error/policy calibration

 Every artifact: source version + license + builder commit/config + hash + tests


                            ON-DEVICE RUNTIME

 main/UI context                         one owning engine queue
 ┌────────────────────┐                 ┌───────────────────────────────┐
 │ render keys/bar    │── observations ►│ TypingSession                 │
 │ capture touch      │                 │ document continuity + commits │
 │ apply proxy edits  │◄─ suggestions ──│                               │
 └────────────────────┘                 │ deterministic TypeEngine      │
        never waits for artifacts       │ beam + exact channel + LM     │
                                        │ morphology + compounds        │
                                        │                               │
                                        │ optional ready snapshots      │
                                        │ trigram/context rescorer       │
                                        │ richer morph/grammar signals  │
                                        └───────────────────────────────┘
                                                       │
                                                       ▼
                                           conservative action policy
```

The app and offline tooling may do expensive parsing, compaction, training, and
artifact construction. The keyboard extension consumes immutable, bounded,
preferably mmap-able outputs.

## Deadline lanes

Every new capability must declare which deadline lane it occupies.

| Lane | Deadline and allowed work | Examples | Forbidden work |
|---|---|---|---|
| UI activation | First paint; main thread | Construct views, enqueue bootstrap, display literal/fallback state | Opening models, decompression, parsing JSON, corpus work, synchronous engine calls |
| Per keystroke | Bounded work on the owning engine queue | Window reconciliation, touch alignment, shallow beam, exact channel score, lexicon/morph lookup, policy | Unbounded candidate enumeration, model loading, full-sentence parsing, waiting for another queue |
| Word boundary | May use slightly wider bounded context | Lane update, next-word continuation, personal event, trigram/context score | Work whose tail latency delays the next key |
| Idle / punctuation | Cancelable and generation-checked | Optional sentence analysis, deferred grammar offers, neural state refresh | Applying results to changed text, silent valid-form replacement |
| Containing app | Outside typing interaction | Learning compaction, artifact validation, export/sync | Raw keystroke upload, dependence required for base typing |
| Offline build | Minutes or hours | Full Miðeind stack, corpus mining, teacher inference, distillation, evaluation generation | Shipping source licenses or uncertainty without a manifest |

The current extension already has important cold-start foundations: bootstrap
is queued off the UI thread, the Swift reader maps the file and reads only its
header, and paradigms/governors arrive later as optional evidence. However,
off-main bootstrap is not the same as a usable first suggestion: today the
session is published only after lexicon calibration and `engine.warmUp()`, so
early requests can still return an empty result. Measure the whole path from
activation to engine-ready to first non-empty suggestion, and make each stage
incrementally usable rather than treating mmap-open time as cold-start time.
Apple's extension guidance says extensions should launch well under a second
and must not block the main run loop
([extension performance guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)).

## The Icelandic evidence ladder

The central debugging discipline is to ask what a source can legitimately
assert. Sources higher in this table do not automatically supersede lower ones;
they answer different questions.

| Evidence | Legitimate assertion | Cannot establish by itself | Current consumer |
|---|---|---|---|
| Touch coordinates/long press | Physical plausibility and deliberateness | Word validity or language | `PerTapCostProvider`, `FoldPricing`, policy |
| Literal surface form | Exactly what the user entered | Whether it was intended or complete | `TypingSession`, verbatim/revert paths |
| IS/EN frequency lexicon | Attestation, typicality, prefix reachability | Morphological legality or user intent | `BlendedLanguageModel`, beam, predictor |
| BÍN analysis | Known form, candidate lemma/POS/features | Frequency, correct sense, current language | `MorphologyProviding`, protection/discovery |
| Paradigm generation | Possible siblings of an analyzed lemma | Which sibling belongs in this sentence | `InflectionStore`, compound analysis |
| Bigram/trigram counts | Local contextual association | Grammar, semantics, or truth | ranking/prediction |
| Compound analysis | A plausible legal decomposition | Attestation or intended compound boundary | protection/discovery/ranking |
| Tokenizer | Token kind, normalization, boundary, source span | Intended correction | session/token-shape logic |
| Parser/tagger | Contextual syntactic/morphological hypothesis | Certainty on fragments, typos, or unseen grammar | offline teacher; possible idle signal |
| Error corpus/rules | Observed error classes and reference corrections | This user's current error | evaluation and candidate proposals |
| Personal model | Repeated or explicit user preference | General Icelandic correctness or lane evidence | additive ranking/protection |

### Four objects that must not collapse into one

For `hestinum`, keep these concepts distinct:

```text
surface form:     hestinum
lemma candidate: hestur
analysis:         noun + masculine + singular + dative + definite
paradigm:         the set of related forms of hestur
```

A surface can map to several lemmas and analyses. A lemma can generate many
surfaces. Corpus counts belong to observed surfaces/context; learning belongs
to the committed surface unless disambiguation is strong enough to add a
smaller lemma-sibling boost. This is why “lemmatize everything” is not a viable
keyboard architecture.

### Icelandic-specific pressure points

- **Inflection creates valid near-neighbors.** A distance-based corrector can
  easily move between grammatical forms while making the sentence worse.
- **Compounding makes the vocabulary open-ended.** Whole-word lookup alone
  cannot cover it; unrestricted splitting also hallucinates validity.
- **Homographs make lemma credit dangerous.** `á` and many other surfaces have
  multiple analyses; context must not leak learning between them.
- **Acute vowels are costly to type.** In the Icelandic lane, restoration is a
  separate channel class with separate safety rules.
- **English appears as normal discourse, not exceptional foreign text.** A
  strong Icelandic prior must absorb a sletta without decorating or correcting
  it into Icelandic.
- **Names and foreign stems can take Icelandic morphology.** This is a useful
  future bridge class, but generic suffix stripping is too permissive for
  automatic replacement.
- **Fragments dominate keyboard context.** A parser trained on sentences may
  be least reliable exactly while the user is typing.

## What Lyklaborð already owns

The language stack is not starting from zero. Production already has:

- full BÍN surface analysis behind `MorphologyProviding`, memory-mapped by
  [`BinaryLemmatizer`](Packages/LemmaCore/Sources/LemmaCore/BinaryLemmatizer.swift);
- calibrated Icelandic and English unigram/bigram artifacts and prefix search;
- BÍN-derived paradigm generation for nouns/adjectives;
- a statistical governor model used as a backoff rather than a hard rule;
- productive compound protection, repair, and completion;
- lane-sensitive accent/apostrophe restoration;
- exact touch/noisy-channel scoring and personal touch adaptation;
- personal surface counts, bigrams, explicit intent, and tombstones;
- the discovery → ranking → action-policy split, with numerical traces;
- scenario, corpus, personal, latency, and cold-start diagnostics.

Read the [TypeEngine source map](Packages/TypeEngine/README.md#source-map) before
placing a change. In particular, do not port `lemma-is` compound splitting over
[`Compounds.swift`](Packages/TypeEngine/Sources/TypeEngine/Compounds.swift), and
do not insert a parser between a keystroke and the existing bounded decoder.

## Miðeind architecture harvest

The repositories below were inspected at their upstream default branches on
2026-07-18. Links are commit-pinned so this document remains auditable as the
projects evolve.

| Project | Architectural role | Best use for Lyklaborð | Runtime verdict |
|---|---|---|---|
| [Tokenizer](https://github.com/mideind/Tokenizer/tree/7ce5d949ae0840c3ce76d13794a6e458b3b921f5) | Icelandic lexical segmentation, normalization, token kinds, sentence boundaries, source alignment | Port semantics and edge cases into an incremental cursor-local tokenizer | Do not run its multi-pass Python pipeline per key |
| [BinPackage](https://github.com/mideind/BinPackage/tree/8c077ff543bd60db77c6cdd8178f30c391236b96) | BÍN lookup/generation, metadata, compound DAWGs | Artifact compiler/reference for richer morphology and compound legality | Offline; consume custom mapped artifacts |
| [GreynirEngine](https://github.com/mideind/GreynirEngine/tree/cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42) | BÍN-annotated tokens, CFG parse forest, reducer, tree API | Teacher for agreement, valency, phrase and case features | Full parser is incompatible with hot-path memory/cold start |
| [GreynirCorrect](https://github.com/mideind/GreynirCorrect/tree/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d) | Token correction followed by optional sentence grammar correction | Harvest orthographic rules, error taxonomy, safety patterns, test cases | Offline/reference; distill narrow rules |
| [Icegrams](https://github.com/mideind/Icegrams/tree/5538250cfcce9faca83cb6a630aed9e838ff1865) | Compact Icelandic uni/bi/trigram counts and successors | Teacher/source for top-K trigram and continuation artifacts | Recompile; do not use Python runtime or all-child sorting |
| [GreynirCorpus](https://github.com/mideind/GreynirCorpus/tree/deb60c4b2775a4e0c709a6890c28678b913f44aa) | Parsed copper/silver/gold corpus tiers | Grammar-feature distillation and evaluation slices | Offline data only |
| [GreynirSeq](https://github.com/mideind/GreynirSeq/tree/3240405e48d4f67985d70cc9bb0ebf5cdbdbcf09) | Fairseq research, tagging/translation, synthetic error generation | Generate morphology-aware training/eval pairs | Training/offline only; model licenses vary |
| [IceBERT-PoS](https://github.com/mideind/IceBERT-PoS/tree/9616942e62efdf817f89f048af481df28a852783) | Neural POS/morph tagging over caller-owned HF models | Teacher for a future tiny tagger or contextual labels | Not a cold-start dependency |
| [GreynirServer](https://github.com/mideind/GreynirServer/tree/3e6eebe7040eab4cb81b8cecd8bb330e0e00e61f) | Production web/Postgres integration of the stack | Understand operational pipeline and mine corpora | GPL/server reference, not embedded code |

### Tokenizer: copy the contract, not the implementation

Tokenizer distinguishes words, punctuation, dates, amounts, URLs, email and
other deep token kinds while preserving original text and character-origin
alignment
([README](https://github.com/mideind/Tokenizer/blob/7ce5d949ae0840c3ce76d13794a6e458b3b921f5/README.md#L15-L28),
[`Tok` source contract](https://github.com/mideind/Tokenizer/blob/7ce5d949ae0840c3ce76d13794a6e458b3b921f5/src/tokenizer/tokenizer.py#L107-L166)).
The public pipeline is lazy at the generator boundary but still runs several
forward passes and initializes abbreviation configuration on first use
([pipeline](https://github.com/mideind/Tokenizer/blob/7ce5d949ae0840c3ce76d13794a6e458b3b921f5/src/tokenizer/tokenizer.py#L3277-L3306),
[abbreviation initialization](https://github.com/mideind/Tokenizer/blob/7ce5d949ae0840c3ce76d13794a6e458b3b921f5/src/tokenizer/abbrev.py#L312-L350)).

The keyboard opportunity is an incremental token contract:

```text
TokenSpan {
    originalRange
    normalizedText
    kind: word | abbreviation | url | email | number | punctuation | code-like
    editGeneration
}
```

Only a dirty region around the cursor should be retokenized. Source ranges must
survive normalization so a suggestion can replace exactly the intended span.
This would consolidate today's dotted-token, abbreviation, punctuation, and
field-shape protections without handing the hot path to a whole-document
tokenizer.

### BinPackage/BÍN: morphology truth with explicit limits

BinPackage documents more than 3.1 million surface forms, roughly 300,000
lemmas, compressed binary lookup, mmap, and prefix/suffix DAWGs for compounds
([overview](https://github.com/mideind/BinPackage/blob/8c077ff543bd60db77c6cdd8178f30c391236b96/README.md#L13-L41),
[compound algorithm](https://github.com/mideind/BinPackage/blob/8c077ff543bd60db77c6cdd8178f30c391236b96/README.md#L105-L130)).
Its APIs expose all analyses, lemma/category, variants, grammatical cases, and
usage/correctness metadata
([lookup APIs](https://github.com/mideind/BinPackage/blob/8c077ff543bd60db77c6cdd8178f30c391236b96/src/islenska/bindb.py#L745-L918),
[case variants](https://github.com/mideind/BinPackage/blob/8c077ff543bd60db77c6cdd8178f30c391236b96/src/islenska/bindb.py#L1015-L1117)).

The same source explicitly warns that context-free case casting is simplistic:
it cannot fully resolve adjective definiteness or even decide whether a surface
such as `við` is a preposition
([warning](https://github.com/mideind/BinPackage/blob/8c077ff543bd60db77c6cdd8178f30c391236b96/src/islenska/bindb.py#L1119-L1143)).
That warning is the correct design posture: generation proposes variants;
context ranks them; valid-form-to-valid-form grammar assistance stays
offer-only.

The official BÍN/DIM language-technology data is updated once a month and
contains
several formats plus usage/acceptability information
([LT data](https://bin.arnastofnun.is/DMII/LTdata/),
[resource description](https://bin.arnastofnun.is/DMII/aboutDMII/)). Every
Lyklaborð build should therefore record the exact BÍN source snapshot rather
than treat “BÍN” as an immutable corpus.

### Icegrams: valuable teacher, wrong runtime shape

Icegrams contains approximately 14 million trigrams trained on more than 100
million tokens drawn from a manually selected collection of documents, exposes
successor queries, and reports
microsecond-scale mapped lookups
([README](https://github.com/mideind/Icegrams/blob/5538250cfcce9faca83cb6a630aed9e838ff1865/README.md#L11-L48)).
Its unmodified runtime still decompresses vocabulary into memory on load and
enumerates/sorts every child for a successor query
([load path](https://github.com/mideind/Icegrams/blob/5538250cfcce9faca83cb6a630aed9e838ff1865/src/icegrams/ngrams.py#L1617-L1659),
[`succ`](https://github.com/mideind/Icegrams/blob/5538250cfcce9faca83cb6a630aed9e838ff1865/src/icegrams/ngrams.py#L975-L1043)).

The keyboard artifact should instead store, for each retained one- or two-word
context, a precomputed top-K successor list plus compact backoff statistics. It
should be rebuilt from a modern, domain-balanced corpus and calibrated against
English rather than inheriting Icegrams' Icelandic-only 2017 web-corpus/domain
prior.

### GreynirEngine: a teacher for structure

GreynirEngine's conceptual pipeline is:

```text
Tokenizer → BÍN meanings → CFG parse forest → heuristic reducer → tree API
```

Its overridable token pipeline is a useful map of stage ownership: correction,
static phrases, BÍN meanings, entities, spelling hooks, numeric/currency/person
handling, disambiguation and final correction are distinct passes
([overview](https://github.com/mideind/GreynirEngine/blob/cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42/doc/overview.rst#L63-L88),
[pipeline](https://github.com/mideind/GreynirEngine/blob/cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42/src/reynir/bintokenizer.py#L2096-L2189)).

The parser is process-lazy, but initialization reads grammar material and loads
a binary grammar; its token-terminal cache alone is documented around 5 KB per
distinct token and can reach roughly 125 MB at its cap
([initialization](https://github.com/mideind/GreynirEngine/blob/cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42/src/reynir/fastparser.py#L787-L861),
[cache](https://github.com/mideind/GreynirEngine/blob/cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42/src/reynir/fastparser.py#L738-L746)).

Harvest outcomes, not the parser:

- distributions over governor sense and governed case;
- common subject/verb person-number patterns;
- phrase and abbreviation boundary facts;
- agreement features on corpus contexts;
- parser disagreement/failure slices for evaluation;
- compact decision tables or teacher scores for a small student.

### GreynirCorrect: proposals, taxonomy, and safety patterns

GreynirCorrect deliberately separates faster token correction from slower
sentence grammar correction
([overview](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/doc/overview.rst#L23-L45)).
Its token pipeline covers compounds, multiword errors, capitalization,
unknown-word spelling, wording/style, and later merge/capitalization passes
([pipeline](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/src/reynir_correct/errtokenizer.py#L2993-L3090)).

The spelling generator is especially harvestable. It combines Icelandic
phonology/orthography substitutions, bounded edit operations, BÍN/Icegrams
filters, trigram backoff, and explicit penalties
([generator](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/src/reynir_correct/spelling.py#L152-L400),
[scoring](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/src/reynir_correct/spelling.py#L458-L624)).
TypeEngine should import useful Icelandic confusion classes as proposal/eval
data, then apply its real touch geometry and exact channel model instead of the
uniform keyboard edits that GreynirCorrect leaves commented out.

Two safety patterns deserve explicit adoption:

- retain original analyses beside corrected analyses so later context can
  reverse a locally plausible proposal
  ([source](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/src/reynir_correct/errtokenizer.py#L1809-L1832));
- in the default spelling-candidate path, foreign-looking/non-Icelandic tokens
  remain suggestion-only when `apply_suggestions` is false; this is a useful
  pattern, not a package-wide invariant
  ([source](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/src/reynir_correct/errtokenizer.py#L1907-L1928)).

Its error-code taxonomy should seed evaluation slices rather than become a
monolithic runtime rule engine
([taxonomy](https://github.com/mideind/GreynirCorrect/blob/625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d/doc/errorcodes.rst#L15-L88)).

### Corpora and neural projects: supervision, not dependencies

- GreynirCorpus provides roughly 10 million mechanically parsed sentences,
  selected silver data, and a smaller manually verified gold tier
  ([contents](https://github.com/mideind/GreynirCorpus/blob/deb60c4b2775a4e0c709a6890c28678b913f44aa/README.md#L11-L54)).
  It is valuable for feature distillation, but its news/government domain and
  parser-derived labels are not conversational ground truth.
- GreynirSeq's synthetic noising can generate spelling and grammar pairs with
  parse/POS-aware rules
  ([noising overview](https://github.com/mideind/GreynirSeq/blob/3240405e48d4f67985d70cc9bb0ebf5cdbdbcf09/src/greynirseq/noising/README.md#L1-L14),
  [dataset](https://github.com/mideind/GreynirSeq/blob/3240405e48d4f67985d70cc9bb0ebf5cdbdbcf09/src/greynirseq/noising/ieg/dataset.py#L24-L72)).
  Synthetic linguistic errors must be reweighted against real phone traces;
  recent mobile GEC work likewise treats synthesis and mobile-domain
  adaptation as a paired problem
  ([mobile error adaptation](https://research.google/pubs/synthesizing-and-adapting-error-correction-data-for-mobile-large-language-model-applications/)).
- IceBERT-PoS returns structured IFD morphology with character ranges, but
  materializes token batches and depends on Transformers/PyTorch
  ([interface](https://github.com/mideind/IceBERT-PoS/blob/9616942e62efdf817f89f048af481df28a852783/src/icebert_pos/interface.py#L202-L282),
  [dependencies](https://github.com/mideind/IceBERT-PoS/blob/9616942e62efdf817f89f048af481df28a852783/pyproject.toml#L6-L14)).
  It is a labeling teacher, not a keyboard bootstrap component. Its interface
  loads caller-selected Hugging Face models with `trust_remote_code=True`, so
  model weights and remote code require a separately pinned revision, license,
  hash, and code review before even offline teacher use.

## `lemma-is` architecture harvest

Audited architecture version: local tag `v0.11.0` / commit `f6804d0`; the next
remote commit changes only the PostgreSQL BM25 example. The project is a
high-recall Icelandic lemmatizer for search, not a typing decoder. That
distinction explains both what Lyklaborð should reuse and what it should leave
behind
([positioning](https://github.com/jokull/lemma-is/blob/v0.11.0/README.md#L42-L90)).

### What it contributed

The central artifact is a single ArrayBuffer-friendly binary:

```text
32-byte header
deduplicated UTF-8 string pool
sorted lemma table
sorted surface-form table
CSR-like surface → packed analysis ranges
optional sorted bigram pairs and counts
```

The reader constructs typed views over those sections, binary-searches the
surface table, and returns lemmas, POS, or compact morph features
([layout/reader](https://github.com/jokull/lemma-is/blob/v0.11.0/src/binary-lemmatizer.ts#L79-L183),
[lookup APIs](https://github.com/jokull/lemma-is/blob/v0.11.0/src/binary-lemmatizer.ts#L256-L398)).
The Python writer orders competing analyses by corpus evidence before packing
them
([writer](https://github.com/jokull/lemma-is/blob/v0.11.0/scripts/build-binary.py#L340-L472)).

That format is already ported to Swift. The current `LemmaCore` reader maps the
file, reads only its header/section offsets at initialization, and binary
searches raw mapped UTF-8 bytes lazily. This is the important bridge between
the Icelandic data ecosystem and TypeEngine—not the TypeScript search pipeline.

Current local artifacts:

| Artifact | Shape | Keyboard role |
|---|---|---|
| `lemma-is.core.bin` | 10,049,264 bytes; v1; 350,000 forms; 99,680 lemmas; no morph/bigrams | Tests and a possible staged compact/download escape hatch; not a production fallback today |
| `lemma-is.bin` | 115,189,168 bytes; v2; 3,698,020 forms; 347,926 lemmas; 414,007 bigrams | Production morphology source today |

The JavaScript cold-start benchmark synchronously reads and copies the entire
file, so its tens-of-milliseconds full-artifact results are not representative
of Swift mmap. Local Swift microbenchmarks recorded by this project are roughly
1 ms to open the full file, sub-microsecond lookup over a fixed small lookup set
after broad warmup, and less than half a megabyte of additional physical
footprint in that benchmark. These are component results, not a bound on varied
real-session lookups or first usable suggestions. Keep measuring on real iOS
devices; do not infer extension behavior from Node/Bun buffer loading.

### What the search pipeline does

`lemma-is` composes tokenization, normalization, cached lookup, optional unknown
suffix stripping, compound expansion, shallow disambiguation, stopword removal,
and search helpers
([pipeline](https://github.com/jokull/lemma-is/blob/v0.11.0/src/pipeline.ts#L145-L374)).
Its disambiguator is an ordered first-winner cascade:

```text
unambiguous
→ hand preference rule
→ shallow grammar rule
→ left/right lemma-bigram score
→ stored-order fallback
```

([phases](https://github.com/jokull/lemma-is/blob/v0.11.0/src/disambiguate.ts#L98-L313)).

That is appropriate for recall-first indexing, where returning extra lemmas is
often cheaper than missing a document. It is not an autocorrect confidence
model. In particular:

- unknown suffix stripping keeps the original and stripped forms and may strip
  twice; use it only as bounded offer-only discovery for foreign-name/Icelandic
  morphology bridges
  ([source](https://github.com/jokull/lemma-is/blob/v0.11.0/src/pipeline.ts#L170-L240));
- the compound splitter tries binary boundaries and linking-letter removal,
  then chooses one heuristically scored split; Bloom membership permits false
  positives
  ([splitter](https://github.com/jokull/lemma-is/blob/v0.11.0/src/compounds.ts#L258-L452),
  [Bloom filter](https://github.com/jokull/lemma-is/blob/v0.11.0/src/bloom.ts#L21-L57));
- shallow case-government and subject/verb heuristics are useful hypotheses,
  not a parser
  ([mini grammar](https://github.com/jokull/lemma-is/blob/v0.11.0/src/mini-grammar.ts#L218-L452)).

TypeEngine's current compound analyzer is stronger for the keyboard use case:
it understands paradigm-valid modifiers, open-class heads, multiple modifiers,
caching, and curated negative cases. Do not replace it with the search splitter.

### Data freshness is now explicit and reproducible

The architecture audit found that the previous ignored local
`data/SHsnid.csv` selected by the default `lemma-is` builder had 6,332,066
records, maximum BÍN id 508,309, a preserved filesystem timestamp of
2020-05-10, and SHA-256
`3a760bc39ed2f43ee7a44e82f169494261b4139a5a2e8f3e356ada00dce4c84d`.
A clean rebuild from that CSV plus the local frequency artifacts is byte-for-byte
identical to both the then-current `lemma-is/data-dist/lemma-is.bin` and
Lyklaborð's then-current bundled
`data/is/lemma-is.bin`: SHA-256
`31fa4bf8be637a6f0da85fa78ea14277d0457d947fdeb94d30733ce80155e4b9`.
That proved the old production morphology payload came from the 2020-era CSV.

For comparison, the official Sigrún-format export fetched on 2026-07-18 has
7,425,931 records, maximum BÍN id 569,933, and SHA-256
`9c10d70d73c03168f05f152616b8cafa6e4275e7db8701338f5f3c48a45b7ab6`—about
1.09 million more inflection records. The official source says the LT data is
updated monthly
([LT data](https://bin.arnastofnun.is/DMII/LTdata/)). On 2026-07-18 the full,
core, compact, paradigm, and governor artifacts were rebuilt as one cohort from
that current export. The production binary now has 3,698,020 surface forms and
347,926 lemmas; freshness probes including `spjallmenni`, `rafskúta`,
`rafmynt`, `streymisþjónusta`, `kórónuveira`, and `loftslagsverkfall` moved
from unknown to known. Exact inputs, builders, hashes, sizes, and counts are in
[`LANGUAGE_DATA_MANIFEST.json`](data/is/LANGUAGE_DATA_MANIFEST.json).

This closes the immediate stale-data defect, but freshness remains a release
discipline: missing modern names, loanwords, preferred forms, or metadata can
otherwise masquerade as decoder defects again.

Before adding a more sophisticated model, make the morphology build
reproducible:

```text
source URL + retrieval date + upstream version/hash
builder repository commit + exact flags/config
input hashes + output hashes
record counts + feature coverage
license/clearance identifier
gold smoke cases + recent-vocabulary OOV report
```

An artifact-age gate should fail CI or require an explicit waiver. A small list
of recent Icelandic people, organizations, products, slang, and loanwords
should make source staleness visible independently of ranking quality.

### Do not inherit these format limitations

The current v2 binary was intentionally compact and search-oriented:

- “unknown/no number” and singular both encode as zero, while the reader
  exposes zero as singular
  ([writer](https://github.com/jokull/lemma-is/blob/v0.11.0/scripts/build-binary.py#L148-L154),
  [reader](https://github.com/jokull/lemma-is/blob/v0.11.0/src/binary-lemmatizer.ts#L381-L394));
- morph features retain only case, gender, and number—no definiteness,
  adjective degree/strength, or verb person/tense/mood/voice
  ([types](https://github.com/jokull/lemma-is/blob/v0.11.0/src/types.ts#L56-L120));
- the embedded 414,007 bigrams derive from the same source as `lemma-is`'s
  search disambiguator, but no production keyboard caller uses
  `BinaryLemmatizer.bigramFreq`; TypeEngine instead uses
  `FrequencyLexicon.bigramFrequency`. The section is redundant for the current
  keyboard and costs install bytes, though not dirty memory unless its mapped
  pages are touched;
- writer comments and packed-bit descriptions have drifted over time, so the
  reader/writer byte contract—not prose—is the source of truth.

There are also search-pipeline gaps that should remain quarantined from the
keyboard: some hand preference rules cannot select a candidate whose lemma is
different from the surface, declared phrase rules are not in the disambiguation
cascade, and contextual-stopword behavior loses POS on common call paths. These
are reasons to harvest ideas with contract tests, not to import modules whole.

### A keyboard-specific morphology v3

The next artifact should be designed from TypeEngine's questions rather than
from npm/search constraints. A plausible v3 would:

- retain mmap and raw-byte sorted lookup;
- normalize lookup keys consistently to lowercase NFC in both writer and
  reader, with NFC/NFD golden vectors; the current exact-byte morphology
  contract differs from the NFC-normalized frequency lexicon;
- distinguish missing features from grammatical singular;
- retain all analyses needed for protection and measured ranking cases;
- add BÍN correctness/register/acceptability flags from a comprehensive BÍN
  source such as the 15-field Kristín format, not the current six-field Sigrún
  input;
- expose explicit validity tiers: standard/protected,
  valid-but-marked/offer-only, nonstandard-correction-source, and excluded;
- replace the current Boolean-only `MorphologyProviding.isKnown` decision seam
  with richer analysis and tier queries before using those flags in policy;
- remove duplicate general bigrams;
- co-design or share indexes with `paradigms.bin` to reduce duplicated strings;
- preserve generation for noun/adjective forms and add verb features only when
  a measured product case justifies them;
- publish an artifact manifest and golden reader/writer compatibility vectors;
- keep absence/backward compatibility inert behind `MorphologyProviding`.

This is an optimization and correctness project, not a prerequisite for using
fresh BÍN. Rebuilding today's compatible binary from a current source should
come first.

### Highest-value context upgrade from `lemma-is`

The useful insight in its mini grammar is not “run a grammar cascade.” It is
that the *sense of the governor* changes the useful morphology. For example,
`á` as a preposition and `á` as a form of `eiga` should not share one aggregate
case distribution. Prior subject context such as `ég/Jón á …` is evidence for
the verb reading; the following completion can then favor the relevant object
case.

Model this as a soft latent-sense/context feature:

```text
P(features_next | previous surface, previous sense evidence, wider context)
```

It belongs in `InflectionStore`/prediction scoring, below exact observed
bigram/trigram evidence, and it must never auto-replace a correctly typed
governor. This is much narrower, cheaper, and more testable than sentence
parsing.

## Frontier research: what changes the architecture

Research belongs here only if it changes a concrete decision, experiment, or
evaluation slice.

### Constrained decoding remains the base

The production evidence favors a deterministic first pass plus bounded context
intelligence:

- Mobile FST decoding supports literal paths, corrections, completions,
  prediction, personalization, and post-correction under keyboard latency and
  memory limits
  ([Ouyang et al., 2017](https://arxiv.org/abs/1704.03987)).
- Google's “Neural Search Space” dynamically injects contextual neural output
  into constrained keyboard search and reports reduced Words Modified Ratio
  across locales with acceptable added latency
  ([Zhang et al., 2024](https://aclanthology.org/2024.emnlp-industry.93/)).
- SwiftKey's 2025 report uses a quantized, roughly 6 MB, four-layer GPT-2-like
  model as one context source inside its Fluency decoder—not as the whole
  decoder. Reported aggregate flight gains over the production GRU are small,
  and the dynamic user model erases much of the difference for established
  users
  ([architecture and results](https://arxiv.org/html/2505.05648v1#S3.SS3)).

The last point matters: personal learning and a high-quality deterministic
channel may buy more UX than a static model upgrade. A neural experiment must
beat that opportunity cost on real sessions.

Google's UIST 2024 work found that raw capacitive touch images can improve
mobile keyboard decoding beyond point coordinates
([study](https://research.google/pubs/can-capacitive-touch-images-enhance-mobile-keyboard-decoding/)).
No public third-party iOS keyboard API exposing those raw heatmaps was found as
of 2026-07-18; treat the technique as unavailable pending platform
verification, while using its result to motivate richer analysis of the touch
signals iOS does expose
([Apple custom keyboard API](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard)).

### Code-switching needs a soft gate, not hard LID

Apple's short-string LID work exists specifically because predictive and
multilingual typing need fast language evidence from little text; it chose a
shallow recurrent architecture under responsiveness/resource constraints
([Apple research](https://machinelearning.apple.com/research/language-identification-from-very-short-strings)).
A mobile multilingual texting paper combines per-language character trigrams,
calibration, and recent-word weighting, reporting microsecond-scale inference
and substantial suppression of cross-language false corrections
([Gothe et al., 2021](https://arxiv.org/abs/2101.03963)).

TypeEngine already has the better product abstraction: sticky `P(IS)` with both
candidate lanes always available. Evolve it with additional emissions rather
than replacing it with a word label:

```text
lane emission = calibrated surface frequency difference
              + calibrated character-trigram evidence
              + morphology/open-class evidence
              + recent contextual surprisal difference
              + token-kind preservation evidence
```

The state transition retains hysteresis. Names, code-like spans, URLs, shared
words, and personal-only terms should carry low lane-training weight. Candidate
ranking may use their evidence without letting them permanently flip the lane.

### Whole words + morphology + bindable subwords

Google reports around a 20% word-error-rate reduction across compounding
languages from subword units annotated with binding types, which tell the
decoder when pieces may legally join
([Kabel et al., 2022](https://research.google/pubs/handling-compounding-in-mobile-keyboard-input/)).
That suggests a hierarchy rather than an unlimited subword generator:

1. attested whole surface forms;
2. BÍN-valid analyzed/generated forms;
3. legally bindable compound modifiers and heads;
4. character/subword fallback for unseen forms and names;
5. explicit/personal vocabulary.

For a future neural model, train an Icelandic+English-specific tokenizer.
Language-specialized tokenizers generally improve monolingual downstream
performance over a generic multilingual vocabulary
([Rust et al., 2021](https://aclanthology.org/2021.acl-long.243/)), while
unigram subword regularization is a practical robustness baseline
([Kudo, 2018](https://aclanthology.org/P18-1007/)).

Byte-level models avoid unknown tokens and are compelling teachers for spelling
noise, but they lengthen sequences and increase runtime cost
([ByT5](https://aclanthology.org/2022.tacl-1.17.pdf)). Icelandic byte-level GEC
has outperformed subword variants after synthetic pretraining and curated-error
fine-tuning
([Ingólfsdóttir et al., 2023](https://aclanthology.org/2023.acl-long.402/)).
Use this first for offline teacher scoring, error generation, and deferred
sentence-level experiments—not every key.

### Ranking confidence and replacement safety are different models

Neural probabilities are not automatically calibrated; temperature scaling is
a strong simple baseline
([Guo et al., 2017](https://proceedings.mlr.press/v70/guo17a.html)). Google's
large-scale grammar checker pairs a correction model with a separate
grammaticality classifier to control the precision/recall trade
([architecture](https://research.google/blog/grammar-checking-at-google-search-scale/)).

TypeEngine should preserve the same conceptual split even without a learned
safety classifier:

```text
ranker:       which candidate best explains touch + language + context?
safety model: is replacing the literal safer than leaving it?
policy:       are explicit structural invariants satisfied?
```

The economic threshold is asymmetric:

```text
(1 - p_intended) × cost(false correction)
<
p_intended × cost(missed correction)
```

False-correction cost is high, so a candidate can lead the suggestion bar long
before it earns auto-apply. Calibrate restoration, ordinary correction,
space-split, cross-language correction, grammar offer, and next-word prediction
separately.

### Personalization is nearer-term than federated learning

Gboard research validates per-key Gaussian offset/covariance personalization
and reports small but significant decoder/speed gains across languages
([Sivek & Riley, 2022](https://research.google/pubs/spatial-model-personalization-in-gboard/)).
A closed-loop study combining spatial and language personalization reduced WER
from 5.7% to 4.6%
([Fowler et al., 2015](https://research.google/pubs/effects-of-language-modeling-and-its-personalization-on-touchscreen-typing-performance/)).

This supports the current local-first program:

- exact surface counts and recency;
- personal bigrams/continuations;
- explicit learn/verbatim and persistent tombstones;
- per-key touch distributions;
- later, a small local context interpolation or user embedding.

Federated keyboard LM training is proven at large scale
([Hard et al., 2019](https://research.google/pubs/federated-learning-for-mobile-keyboard-prediction/)),
and Gboard now combines it with formal user-level differential privacy
([Xu et al., 2023](https://research.google/pubs/federated-learning-of-gboard-language-models-with-differential-privacy/)).
Federated learning alone is not a privacy guarantee, and Lyklaborð does not yet
have the population or secure aggregation infrastructure to justify it. Keep it
as a later program, not an architectural prerequisite.

### Model optimization is an experiment, not a checkbox

Core ML supports quantization, pruning, and palettization; Apple recommends
profiling each model/hardware combination because decompression and compute-unit
behavior vary
([optimization overview](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html)).
iOS 18 stateful models can retain recurrent state or transformer caches
([stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)).

Compression can hide slice-level regressions behind a stable aggregate metric
([Hooker et al., 2020](https://research.google/pubs/characterising-bias-in-compressed-models/)).
Every compressed candidate rescorer must therefore be compared on Icelandic
tail forms, compounds, code-switch boundaries, names, and accent restoration,
not just total top-1.

### Deployability table

| Technique | Status | First use |
|---|---|---|
| Bounded deterministic beam + exact channel | Shipped | Remains authoritative |
| Personal touch Gaussian | Shipped/further calibration | More real coordinate traces and sample-gate tuning |
| Character-trigram IS/EN evidence | Deployable now | Additional lane/ranking emission, shadow first |
| Modern top-K trigram continuations | Deployable now | Prediction and contextual ranking |
| BÍN freshness/metadata | Deployable now | Rebuild + artifact manifest + measured filters |
| Tokenizer span/abbreviation semantics | Deployable incrementally | Cursor-local token contract |
| Sense-conditioned morphology | Deployable as compact statistics/rules | Inflection and prediction boost, offer-only grammar |
| Quantized bilingual candidate rescorer | Near-term experiment | Async load; bounded synchronous N-best reranking once ready; async inference remains shadow-only |
| Tiny POS/agreement student | Later experiment | Idle/boundary scoring, never launch dependency |
| Full IceBERT/Greynir/Yfirlestur runtime | Offline teacher | Labels, distillation, eval, adversarial examples |
| Federated learning/analytics | Later infrastructure program | Only with scale, secure aggregation, DP, governance |
| Raw capacitive heatmaps | Research-only on third-party iOS | Dataset insight; no public third-party keyboard API was found as of 2026-07-18 |

## Target language-artifact factory

The offline pipeline should become a first-class product subsystem. Its output
is executable evidence; stale or mislabeled evidence can create behavior that
looks like an engine bug.

### Required manifest

Every shipped artifact should have a machine-readable manifest containing:

```json
{
  "artifact": "morphology-v3",
  "formatVersion": 3,
  "languageDataGeneration": "BIN-snapshot-or-cohort-id",
  "builtAt": "ISO-8601",
  "inputs": [
    { "name": "BIN_LT", "version": "...", "sha256": "...", "license": "..." }
  ],
  "builder": { "repository": "...", "commit": "...", "config": { } },
  "output": { "sha256": "...", "bytes": 0, "records": { } },
  "featureCoverage": { },
  "evaluation": { "goldSuite": "...", "resultHash": "..." }
}
```

The runtime should verify magic/version/size and fail closed to the previous
evidence layer. Morphology, paradigms, and governors must also share a
`languageDataGeneration` (or exact BÍN snapshot hash); CI should reject mixed
cohorts, and the runtime should disable the mismatched higher layer rather than
combine semantically incompatible evidence. CI should also verify hashes,
determinism, source age, reader/writer gold vectors, license inventory, and
representative semantic queries.

### Proposed artifact family

| Artifact | Answers | Format goal | Refresh cadence |
|---|---|---|---|
| `is.lex`, `en.lex` | Surface frequency, prefix reachability, bigrams, continuations | Existing mmap format, calibrated metadata | Corpus/version driven |
| `morphology.bin` | Surface validity and analyses | lemma-is-compatible now; keyboard v3 later | Each BÍN snapshot |
| `paradigms.bin` | Lemma→forms/features | Shared string/form IDs with morphology where practical | Each BÍN snapshot |
| `context3.bin` | Top-K next words and trigram/backoff features | Mmap; no runtime all-child sort | Corpus/version driven |
| `charlid.bin` | IS/EN character emissions | Tiny quantized tables + calibration | Corpus/domain driven |
| `governors.bin` | Sense/context-conditioned feature distribution | Compact mapped table, not gzipped JSON | Corpus+BÍN driven |
| `orthography.bin` | Miðeind/IceEC-derived confusion proposals/classes | Small generated tables with provenance | Rule/corpus releases |
| optional Core ML model | Candidate context score/safety score | Async-loadable, quantized, versioned | Only after gated eval |

Artifact construction should be reproducible without npm/Python objects leaking
into the runtime format. Each artifact answers one question; avoid another
all-purpose 100 MB file whose sections evolve for unrelated reasons.

## Target runtime seams

New evidence should fit small interfaces and make absence reproduce the old
path.

### Incremental token evidence

```swift
protocol IncrementalTokenizing {
    func update(window: DocumentWindow, edit: ObservedEdit) -> TokenWindow
}
```

This owns source spans and token kinds, not spelling decisions. It should be
tested against harvested Tokenizer examples and hostile proxy windows.

### Character language evidence

```swift
protocol CharacterLanguageScoring {
    func evidence(for token: String, recent: [String]) -> LaneEvidence
}
```

It contributes calibrated evidence to lane/ranking. It never filters out the
other language or independently trains lane state.

### Context scoring

```swift
protocol ContextScoring {
    func score(candidate: String, context: ContextWindow) -> ContextScore?
    func propose(context: ContextWindow, prefix: String, limit: Int) -> [Proposal]
}
```

The deterministic trigram artifact and a later neural model can implement the
same conceptual seam. Proposals enter normal deduplication, exact channel
rescoring, tombstone filtering, and policy. Scores should be named/traceable;
never hide them inside a single unexplained constant.

### Grammar/morphology signals

```swift
protocol MorphosyntacticScoring {
    func features(for candidate: String, context: ContextWindow) -> [NamedSignal]
}
```

Signals might include governor sense, case fit, subject/verb agreement, or
compound binding. They are additive evidence with reliability and provenance,
not rewrite commands.

### Optional candidate rescorer

Model loading and warmup belong in an **embedder/service-layer** async seam;
live candidate selection still belongs to TypeEngine's single owning queue.
Once ready, a model may synchronously rescore a bounded first-pass pool only
within a measured per-keystroke budget.

```swift
protocol CandidateRescoring {
    func rescore(
        context: ContextWindow,
        candidates: [ScoredCandidate]
    ) throws -> [CandidateAdjustment]
}
```

Runtime requirements:

- load asynchronously after the deterministic engine is usable;
- operate on a bounded N-best list;
- perform live inference synchronously on the owning engine queue with a hard
  time budget and deterministic fallback;
- expose per-candidate adjustments in `CorrectionTrace`;
- remain ranking-only until shadow evaluation proves policy value;
- never bypass exact channel cost, literal protection, field gates, or
  auto-apply branches;
- unloading/failure produces the deterministic result.

Async inference may run in offline or shadow/idle experiments, but under the
current `TypingSession` contract no late result may update the live suggestion
bar. Generation matching alone is insufficient: accepted-correction
recognition, last-emitted suggestions, learning, and revert state all belong to
the session transition. A future two-phase session API would need to update
that accounting atomically before progressive live refinement could be safe.

## Incremental roadmap

The order below maximizes information and user value before model complexity.
Each wave has one primary hypothesis and must be independently reversible.

### Wave A — language artifact bill of materials and BÍN refresh

**Status 2026-07-18:** the current BÍN snapshot, compatible morphology tiers,
paradigms, governors, and first machine-readable cohort manifest are rebuilt.
Keep the validation gates and automate source-age/cohort enforcement before
considering the wave permanently closed.

**Hypothesis:** a material share of OOV/protection failures comes from stale or
opaque data rather than search/ranking.

- Add manifests and deterministic build verification for every language
  artifact.
- Fetch a current permitted BÍN LT snapshot; preserve the existing artifact for
  A/B comparison.
- Rebuild the current compatible morphology/paradigm/governor outputs before
  designing v3.
- Produce diffs: added/removed forms, changed analyses, OOV changes on real
  sessions and recent-vocabulary probes.
- Gate memory, cold open, lookup latency, scenario suites, and false correction.

Completing its automated age/cohort checks reduces uncertainty for every later
change; after that, Wave B is the next language-capability wave.

### Wave B — error/resource harvest into evaluation, not runtime

**Hypothesis:** a better taxonomy reveals which missing capabilities matter to
native mobile typing.

- Map GreynirCorrect error codes, IceEC, the Icelandic Confusion Set, and
  IceStaBS:SP into candidate evaluation slices.
- Keep native phone errors, L2/child/dyslexia errors, formal orthography, and
  synthetic touch noise labeled separately.
- Import only license-compatible derived cases with provenance.
- Add clean identity/hard-negative examples: valid inflections, rare BÍN forms,
  names, code-switches, and compounds that must not change.

IceEC contains tens of thousands of categorized errors under CC BY 4.0
([CLARIN record](https://repository.clarin.is/repository/xmlui/handle/20.500.12537/105)).
IceStaBS:SP provides standardized Icelandic spelling/punctuation examples tied
to official rules
([Ármannsson et al., 2025](https://aclanthology.org/2025.nodalida-1.4/)).
These are excellent coverage/evaluation sources but not direct estimates of
phone-error frequency.

### Wave C — modern trigram/top-K context artifact

**Hypothesis:** a compact third-order context feature improves prediction and
ranks inflection/cross-language rivals without widening touch search.

- Build top-K successors and backoff features from an approved modern Icelandic
  corpus, with source-domain weighting.
- Add equivalent English evidence and cross-lane calibration.
- Measure prediction recall@3, candidate pairwise wins, lane/code-switch slices,
  artifact load/page behavior, and per-key tail latency.
- Exact bigram evidence and literal/touch channel remain visible separately.

The Icelandic Gigaword Corpus is continuously developed, tagged/lemmatized, and
exposes frequency and up-to-trigram resources
([official site](https://igc.arnastofnun.is/)). Its automatically tagged text is
frequency/context evidence, not a gold grammar corpus.

### Wave D — character-trigram lane emission

**Hypothesis:** surface-character evidence reduces IS↔EN ranking errors on OOV,
prefix, and early-session tokens before word frequency becomes decisive.

- Train tiny IS and EN character models on balanced mobile-like text.
- Calibrate their relative emissions on held-out monolingual and code-switch
  tokens.
- Shadow-log contribution only in local traces first.
- Exclude or downweight names, URLs, handles, code-like spans, and tokens too
  short to identify.
- Add it to the lane emission without allowing a single token to hard-switch or
  remove candidates.

### Wave E — incremental token/span semantics

**Hypothesis:** precise token kinds and source spans remove clusters of URL,
abbreviation, punctuation, numeric, and replacement-range bugs.

- Define the cursor-local token contract and dirty-window update.
- Harvest Tokenizer's accepted/gold tests for abbreviations, punctuation,
  composite words, URLs/email, dates, and normalization.
- Migrate existing shape gates one family at a time.
- Require byte-exact replacement spans and generation checks.

This is session architecture, not a new corrector pass.

### Wave F — context-conditioned inflection

**Hypothesis:** sense-aware case/agreement backoff improves correct-form
completion and prediction where exact n-grams are sparse.

- Split ambiguous governors when cheap context strongly identifies their sense.
- Measure case-form top-1 after governors, exact-context override, and
  valid-form protection.
- Add verb person/number features only after a corpus experiment shows useful
  coverage and precision.
- Keep wrong-valid-form correction offer-only.

Start with a few high-mass, testable governor classes rather than a generic
grammar engine.

### Wave G — compound binding artifact

**Hypothesis:** typed/bindable modifier-head units improve unseen compound
completion without making arbitrary splits valid.

- Compare current compound rules to BinPackage DAWG behavior and Google's
  binding-type formulation.
- Learn/compile frequent heads, legal linking shapes, modifier feature classes,
  and negative controls.
- Score whole-form attestation above decomposition and exact touch evidence
  above linguistic possibility.
- Never auto-insert spaces into a plausible Icelandic compound solely because a
  split has higher corpus mass.

### Wave H — optional bilingual candidate rescorer

**Hypothesis:** longer context can improve ordering of an already-good bounded
pool enough to justify model cost.

Prerequisites:

- candidate recall is already high, so ranking is the demonstrated bottleneck;
- enough real sessions exist to build mobile/code-switch validation slices;
- deterministic trigram/context baselines exist;
- Core ML load, first inference, p95/p99, RSS, energy, and device-class fallback
  can be measured.

Experiment sequence:

1. train an offline teacher/baseline on candidate pairwise ranking;
2. distill a small recurrent or shallow transformer student;
3. run offline N-best rescoring only;
4. deploy async inference in local shadow mode with no UI effect;
5. after the model is loaded, allow only budgeted synchronous suggestion-bar
   reranking on the owning engine queue, still with no policy effect; a late
   async UI update requires a formal two-phase `TypingSession` API first;
6. consider a separately calibrated policy feature only after false-correction
   and revert metrics improve.

If the model does not beat trigram + personal evidence on real typing effort,
do not ship it merely because aggregate perplexity improves.

### Continuous work — record sessions

More recordings are useful, but language work should not wait for a large
dataset. Record continuously while Waves A–G improve deterministic evidence.
Preserve:

- intended and resulting text;
- per-key timestamps and coordinates where available;
- candidate bar and score/policy trace;
- tap, space, punctuation, suggestion, backspace, revert, and long-press events;
- field kind, cold/warm state, device/layout geometry, and artifact versions;
- explicit privacy filtering and local retention rules.

The rescorer wave is the point at which dataset quantity and representativeness
become a real blocker.

## Evaluation architecture

Language intelligence is only valuable if it improves the whole typing trade.
Measure the engine stages separately so a failed experiment is diagnosable.

### Stage metrics

| Stage | Primary metrics | Diagnostic question |
|---|---|---|
| Discovery | intended recall@K, pool-miss rate, pool size/cost | Can the right reading enter the pool within budget? |
| Ranking | top-1, MRR, pairwise wins once gold is present | Does added evidence order reachable candidates better? |
| Action | auto-apply precision, false-correction rate, missed-correction rate, risk/coverage | Does the engine act at the right confidence? |
| Interaction | revert/backspace rate, suggestion acceptance, attention cost, elapsed typing time | Did the change make typing feel easier and safer? |
| Performance | cold first usable result, warm p50/p95/p99, max, RSS, energy | Is the gain available without making the keyboard feel late or fragile? |

Also track word/character error rate, corrected and uncorrected error rate,
Words Modified Ratio, keystroke savings, Brier score/ECE, and abstention curves.
Do not optimize suggestion acceptance alone: a CHI study found that more
suggestions can reduce actions while increasing elapsed time through attention
cost
([Quinn & Zhai, 2016](https://research.google/pubs/a-costbenefit-study-of-text-entry-suggestion-interaction/)).

### Required slices

- Icelandic, English, and within-sentence IS↔EN switches;
- cold start, first word, early neutral lane, and established lane;
- missing-acute restoration versus real edit errors;
- valid unaccented/accented skeleton collisions;
- BÍN-common, BÍN-tail, OOV-recent, nonstandard/register-marked forms;
- same-lemma inflection rivals and ambiguous lemma surfaces;
- simple, linking-letter, multi-part, false-positive, and mixed-language
  compounds;
- names, organizations, products, acronyms, handles, URLs, email, code-like
  spans, numbers, dates, and abbreviations;
- personal learned words, tombstones, explicit verbatim, and long press;
- actual centered/boundary touch, synthetic touch, and text-only errors;
- device generation, compressed/uncompressed model, artifact-ready/fallback.

### Hard gates

The following should remain behavioral contracts, not blended score goals:

- a literal/verbatim route is always available;
- secure/URL/email/search protections remain intact;
- deliberate long-press input is not folded away;
- a tombstoned suggestion does not resurrect;
- valid-form grammar assistance does not silently replace another valid form;
- optional evidence absent/late/failed reproduces the deterministic path;
- stale async results never mutate or rerank a new text generation;
- artifact corruption/version mismatch fails safely;
- held-out and personal gates do not regress;
- cold/UI work never introduces main-thread file or model loading.

### Icelandic gold and stress resources

| Resource | Use | Caveat |
|---|---|---|
| [MIM-GOLD](https://clarin.is/en/resources/gold/) | Manually corrected POS/morph supervision | Written corpus, not typing behavior |
| [IceEC](https://repository.clarin.is/repository/xmlui/handle/20.500.12537/105) | General spelling/grammar error taxonomy and pairs | Error prevalence differs from phone typing |
| [IceL2EC](https://repository.clarin.is/repository/xmlui/handle/20.500.12537/280) | Learner-error stress tests | Never mix with native-frequency estimates |
| [Icelandic Confusion Set Corpus](https://repository.clarin.is/repository/xmlui/handle/20.500.12537/13?locale-attribute=is) | Context-sensitive valid-word confusions | Context/corpus domain must be retained |
| [IceStaBS:SP](https://aclanthology.org/2025.nodalida-1.4/) | Standard spelling and punctuation | Standardization is not always auto-apply intent |
| [IGC](https://igc.arnastofnun.is/) | Large frequency/context training source | Automatic analyses; domain/license partitions |
| [GreynirCorpus](https://github.com/mideind/GreynirCorpus) | Parse-feature teacher and grammar slices | Parser-derived silver/copper labels |
| Real Lyklaborð traces | Touch channel, policy cost, bilingual mobile reality | Private, small, owner-biased until broader dogfood |

The Icelandic checker literature strongly supports test-driven hybrid systems:
Tokenizer, morphology, parser, word lists, trigram evidence, error grammar and
tree patterns were developed against error-corpus evidence
([Óladóttir et al., 2022](https://aclanthology.org/2022.lrec-1.496/)).
The keyboard should reuse that discipline while keeping its own mobile-error
distribution and asymmetric auto-apply objective.

## Debugging with the two architecture documents

Start in the TypeEngine architecture, classify the failure as discovery,
ranking, policy, or session/proxy behavior, then use this document to inspect
the evidence source.

| Symptom | Language question | Likely experiment |
|---|---|---|
| Modern Icelandic word is unknown | Is the BÍN/corpus artifact stale or filtered? | Manifest/source diff and OOV vintage report |
| Valid form appears but is too weak | Does BÍN supply validity while frequency/context is absent? | Corpus/top-K context rebuild; do not inflate BÍN floor globally |
| Wrong inflection leads after context | Is exact n-gram absent, governor sense merged, or feature schema incomplete? | Inspect bigram/trigram, analysis candidates, sense-conditioned morph signal |
| English word gets Icelandicized | Did lane/context/char evidence lose to BÍN validity? | Cross-language score trace, sletta guard, token preservation class |
| Lane flips on a name/OOV | Did a weak-evidence token train state? | Lane-emission trace and commit classification |
| Compound missing | Is the head/modifier unreachable, illegal, or merely unattested? | Compound decomposition trace and binding class |
| Ordinary word split into a compound | Is a false-positive membership or permissive linker acting as validity? | Whole-form priority, negative controls, decomposition evidence |
| Candidate becomes good only after full sentence | Is the useful parser signal distillable into left-context statistics? | Teacher analysis; add one named soft feature, not parser runtime |
| First suggestions are late | Which artifact/model caused open, page fault, decompression, or warm-up? | Cold signposts, artifact-off A/B, page/read profile |
| Neural result differs unpredictably | Is the model stale, uncalibrated, or hiding a source contribution? | Generation IDs, shadow trace, per-slice calibration, deterministic fallback |

When an external source claims a correction, ask:

1. Did it analyze the same surface span and normalization?
2. Did it have full right context unavailable to the keyboard?
3. Is its output a gold annotation, parser hypothesis, corpus frequency, or
   rule-generated proposal?
4. Does it represent standard edited text, learner text, or actual mobile
   input?
5. Would the candidate improve ranking, or does the request actually concern
   auto-apply policy?

## Decision rules for future improvements

- **Keep touch, language, morphology, and policy separately inspectable.** A
  single learned score is not an architecture.
- **Compile knowledge; do not embed toolchains.** Python/Hugging Face projects
  can produce immutable Swift-consumable artifacts.
- **Prefer a named signal over a new heuristic pass.** It is easier to trace,
  ablate, calibrate, and remove.
- **Use grammar to back off sparse context.** Exact observed context normally
  beats generalized grammar; literal validity still beats grammar auto-apply.
- **Use neural models where they generalize.** Longer context and pairwise
  candidate ordering are better first targets than spelling generation.
- **Broaden discovery without broadening action.** A new source can fill the
  bar while remaining offer-only.
- **Make freshness observable.** A source without version/hash/age is not a
  trustworthy production dependency.
- **Optimize user effort and trust.** Perplexity, top-1, and acceptance are
  proxies; time, residual errors, reverts, and false corrections are outcomes.
- **Keep the bilingual pair deep rather than generic.** Icelandic+English
  calibration, Icelandic layout geometry, and mixed morphology are the product
  wedge.
- **Make every optional layer disposable.** If removing it breaks base typing,
  it is no longer optional and must meet the hot-path bar.

## Licensing and provenance discipline

Code licenses and data/model licenses differ, sometimes within one repository.
Never infer permission for a data file from the package's code license.

| Source | Provenance concern |
|---|---|
| BÍN/DIM | Current project-specific clearance and attribution apply to the current derived use. Record the exact source/terms for every refresh; do not copy BinPackage's bundled database under an assumed code license. |
| BinPackage | Package code is MIT; its documented bundled BÍN data terms are separate. |
| Tokenizer, GreynirEngine, GreynirCorrect, Icegrams | Audit repository license and any included configuration/data separately before copying tables or test corpora. |
| GreynirCorpus | CC BY 4.0 according to its repository; preserve attribution and label parser-derived tiers. |
| GreynirSeq | Toolkit and downloadable model/data licenses vary; inspect each artifact. |
| IceBERT-PoS | Interface code is MIT, but caller-selected weights and custom Hugging Face remote code are a separate supply chain. Pin revision/hash, verify the model license, and review remote code before teacher use. |
| GreynirServer | GPLv3 integration reference; do not copy code into the MIT runtime without a deliberate licensing decision. |
| IceEC and related error corpora | Preserve dataset version, row provenance, transformations, and CC attribution. |
| IGC | Corpus partitions and downstream rights require explicit review; record which partitions produce redistributed derived counts. |
| Neural model cards | Missing license/training/evaluation detail means research-only until resolved. |

The authoritative local attribution inventory remains
[`data/ATTRIBUTION.md`](data/ATTRIBUTION.md). Artifact manifests should point to
specific entries there rather than repeat prose that can drift.

## Source registry and evidence confidence

### Primary local sources

- [TypeEngine architecture](Packages/TypeEngine/README.md)
- [TypeEngine runtime sources](Packages/TypeEngine/Sources/TypeEngine)
- [LemmaCore reader](Packages/LemmaCore/Sources/LemmaCore/BinaryLemmatizer.swift)
- [Paradigm builder](scripts/build-paradigms.py)
- [Governor builder](scripts/build-governors.py)
- [Lexicon builder](scripts/build-lexicon.py)
- [Language artifact notes](data/README.md)
- [Architecture decisions](docs/adr/README.md)
- [Wave ledger](docs/WAVES.md)

### Miðeind source snapshots

- Tokenizer `7ce5d949ae0840c3ce76d13794a6e458b3b921f5`
- BinPackage `8c077ff543bd60db77c6cdd8178f30c391236b96`
- GreynirEngine `cd7d97e736ea7eb7ccf2cce972fcd0b9f7fe2b42`
- GreynirCorrect `625e8b3e555ffd3c8df8b3387a6bc5c2f162f27d`
- Icegrams `5538250cfcce9faca83cb6a630aed9e838ff1865`
- GreynirCorpus `deb60c4b2775a4e0c709a6890c28678b913f44aa`
- GreynirServer `3e6eebe7040eab4cb81b8cecd8bb330e0e00e61f`
- GreynirSeq `3240405e48d4f67985d70cc9bb0ebf5cdbdbcf09`
- IceBERT-PoS `9616942e62efdf817f89f048af481df28a852783`

### Research anchors

- [Mobile keyboard FST decoding](https://arxiv.org/abs/1704.03987)
- [Neural Search Space for keyboard decoding](https://aclanthology.org/2024.emnlp-industry.93/)
- [Handling compounding in mobile keyboard input](https://research.google/pubs/handling-compounding-in-mobile-keyboard-input/)
- [Spatial-model personalization in Gboard](https://research.google/pubs/spatial-model-personalization-in-gboard/)
- [SwiftKey privacy-preserving transformer](https://arxiv.org/html/2505.05648v1)
- [Apple short-string language identification](https://machinelearning.apple.com/research/language-identification-from-very-short-strings)
- [Icelandic spell/grammar checker architecture](https://aclanthology.org/2022.lrec-1.496/)
- [Icelandic byte-level grammatical correction](https://aclanthology.org/2023.acl-long.402/)
- [IceBERT and IC3](https://aclanthology.org/2022.lrec-1.464/)
- [Icelandic standard orthography benchmark](https://aclanthology.org/2025.nodalida-1.4/)

Code and official data documentation are direct architectural evidence. Papers
are evidence for measured methods in their reported domains, not guarantees on
Lyklaborð. Proposed runtime seams, artifact formats, and roadmap ordering are
engineering inferences from those sources and must be validated by the gates
above.

## Recommended reading order

For a new engine investigation:

1. Read [The shortest useful TypeEngine model](Packages/TypeEngine/README.md#the-shortest-useful-model).
2. Classify the issue with its
   [debugging workflow](Packages/TypeEngine/README.md#debugging-workflow).
3. Use the evidence ladder in this document to identify which language source
   can answer the missing question.
4. Read the commit-pinned upstream source, not only its README.
5. Reproduce through `type-repl`, add a scenario/eval slice, and inspect latency.
6. Make one evidence contribution visible in `CorrectionTrace` before tuning
   interaction policy.

The practical next move is to finish Wave A's automated source-age/cohort gates,
then begin Wave B. Continue recording sessions in parallel. The refreshed base
gives subsequent trigram, language-lane, morphology, compound, and neural
experiments a trustworthy foundation—and makes it possible to tell whether they
are truly improving the keyboard rather than compensating for stale language
data.
