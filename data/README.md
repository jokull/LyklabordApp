# Language Data Artifacts

This directory contains the language models and frequency tables for the LyklaborÃ° iOS extension. All files are mmap-ed in the app bundle for efficient on-device autocorrect and prediction.

## Icelandic (is/)

### Binary Lemma Models

These are indexed trie-based binary artifacts generated from BÍN (Beygingarlýsing íslensks nútímamáls) via the lemma-is project. Each maps surface forms to (lemma id, frequency, flags) tuples.

- **bin-morph.bin** (115,189,168 bytes) — **PRIMARY**
  - Full BÍN: 3,698,020 word forms, 347,926 lemmas, format v2 with morphological data + 414,007 bigrams
  - Measured 2026-07-18 over three release runs: 1.03–2.17 ms mmap open, 1.6–5.8 µs/lookup over 1000 calls, and phys_footprint +0.25–0.28 MB from process start
  - Ship this. mmap keeps untouched pages file-backed; measured residency depends on pages touched, while the larger artifact still increases app download size

- **bin-morph.core.bin** (10,049,264 bytes)
  - Smaller alternative (350k forms, no morph/bigrams, v1); kept for tests and as a download-size escape hatch

- **bin-morph.core.top_200k.bin** (5,892,036 bytes)
  - Fallback tier for older/memory-constrained devices
  - Top 200k most frequent Icelandic words by corpus frequency
  - Deployment: A/B test or enable on devices with <2GB available memory

- **bin-morph.core.min_100.bin** (2,012,084 bytes)
  - Emergency floor for extremely constrained environments
  - Minimal vocabulary covering only the most essential words (frequency ≥ 100 in corpus)
  - Deployment: Ultra-low-memory devices, if needed for v1 ship

### Frequency Tables

- **unigrams.json.gz** (2,037,976 bytes)
  - Gzipped JSON: word → frequency count
  - Used by the predictor and learning store for next-word prediction
  - Source: Icelandic corpus from lemma-is

- **bigrams.json.gz** (3,041,400 bytes)
  - Gzipped JSON: (word1, word2) → co-occurrence count
  - Used for bigram-based prediction and context weighting
  - Source: Icelandic corpus from lemma-is

### Provenance

All Icelandic data is derived from **BÍN** (Beygingarlýsing íslensks nútímamáls), a comprehensive morphological database of Modern Icelandic.

- **Source**: Árni Magnússon Institute for Icelandic Studies, https://bin.arnastofnun.is
- **Processing pipeline**: lemma-is project (`build-binary.py`, `extract-*grams.py`)
- **Frequency corpus**: Icelandic web corpus and published texts
- **Conversion method**: Lemma-indexed trie with frequency ranks; inflected surface forms mapped to lemma IDs
- **Exact build cohort**: `is/LANGUAGE_DATA_MANIFEST.json` records the BÍN source hash, builder commits, artifact hashes, sizes, and record counts

### License & Attribution

See `ATTRIBUTION.md` for full credit text. In brief:
- Data derived from BÍN, © Árni Magnússon Institute for Icelandic Studies
- License terms: Credit required, no raw-data redistribution, no publishing of inflection paradigms (all cleared for this project; see email thread)
- This keyboard extension stores derived forms only (trie indices + lemma pointers), not raw paradigm data

## English (en/)

### Frequency Dictionary

- **en-80k.txt** (1,282,042 bytes)
  - Plain text: 80,000 most frequent English words, one per line
  - Format: `word<space>frequency_count` (e.g., `the 26548583149`)
  - 80k entries covering ~99% of English text by token frequency
  - Source: SymSpell project (wolfgarbe/SymSpell)
  - Processing: Intersection of Google Ngram dataset with Hunspell dictionary wordlists

### Bigram Dictionary

- **frequency_bigramdictionary_en_243_342.txt** (5,137,213 bytes; 242,342 entries)
  - Format: `word1 word2<space>frequency_count` (e.g., `abcs of 10956800`)
  - Source: SymSpell project, `SymSpell/frequency_bigramdictionary_en_243_342.txt` (MIT)
  - URL: https://raw.githubusercontent.com/wolfgarbe/SymSpell/master/SymSpell/frequency_bigramdictionary_en_243_342.txt
  - Used for English next-word prediction and compound-correction context

### Provenance & License

- **Source**: SymSpell repository (https://github.com/wolfgarbe/SymSpell)
- **License**: MIT
- **Frequency data**: Google Ngrams v2 (public domain) intersected with Hunspell dictionaries (various open licenses)
- **Citation**: See `ATTRIBUTION.md`

## File Roles in the Keyboard Extension

### On-Device Autocorrect

1. User types a word → runs through spatial key-distance model (fat-finger compensation)
2. Corrector stage uses SymSpell edit-distance candidates (English: en-80k.txt; Icelandic: bin-morph.core.bin)
3. Re-rank candidates by language model frequency and language ID estimate (per-word blending)
4. Return top 1–3 suggestions to UI

### Next-Word Prediction

1. User completes a word → reads unigrams.json.gz + bigrams.json.gz (optional, Icelandic only for v1)
2. Score P(next_word | prev_word, LID_estimate)
3. Blend IS/EN via running LID classifier
4. Display top 1–2 predictions in suggestion bar

### On-Device Learning

- Personal unigrams/bigrams log in App Group container (append-only, mmap-ed read)
- Overlay outranks base models in predictor
- Learned words/bigrams synced to iCloud CloudKit (encrypted)
- User can delete individual words/patterns from learned store (tombstone record)

## Tiering Strategy (obsolete — kept for context)

Device-based tiering was designed before the Swift mmap bench demonstrated demand-paged behavior (the original 91 MB full binary measured +0.28 MB after its fixed lookup workload). Decision 2026-07-15: **ship the full bin-morph.bin on all devices**. The smaller tiers remain staged only as a download-size escape hatch and for fast unit tests. The refreshed ~110 MB artifact also measured +0.25–0.28 MB `phys_footprint` over the same 1000-lookup gate; total file size alone is not a memory-residency measurement.

| File | Size | Contents (words / lemmas / bigrams) |
|------|------|--------------------------------------|
| bin-morph.bin (primary) | 109.9 MiB | 3,698,020 / 347,926 / 414,007 (v2, morph) |
| bin-morph.core.bin | 9.6 MiB | 350,000 / 99,680 / 0 (v1) |
| bin-morph.core.top_200k.bin | 5.6 MiB | 200,000 / 80,379 / 0 (v1) |
| bin-morph.core.min_100.bin | 1.9 MiB | 69,155 / 32,915 / 0 (v1) |

**Note**: mmap pages are file-backed and do not count against the extension dirty-memory (jetsam) limit. Paging is lazy and demand-driven.

## .lex artifacts

Compact mmap-able unigram+bigram frequency tables for ranking/prediction,
distinct from the lemma-is `.bin` trie above (which answers "is this a valid
form + what's its lemma", not "how frequent is it"). Built by
`scripts/build-lexicon.py` from the sources documented earlier in this file;
read by `Packages/Lexicon`'s `FrequencyLexicon` (mmap, lazy offset reads, no
upfront parsing — same strategy as `BinaryLemmatizer`). Format is documented
in `Packages/Lexicon/FORMAT.md`.

Each shipping lexicon has a generation-bound calibration sidecar
(`is/is-calibration.json`, `en/en-calibration.json`). It freezes the exact
within-language log-frequency mean/σ and a 64-word warm-up set that used to be
recomputed by scanning thousands of prefix buckets on every extension launch.
The sidecars are required, hashed manifest artifacts; the scorecard verifies
schema, generation, add-k compatibility, bytes, and SHA-256 before replay.

Both builds drop tokens with non-letter characters (digits, punctuation) but
now allow a single **internal** apostrophe (`'`/`'`, curly folded to
straight) so contractions survive — see "Contraction fix" below and
FORMAT.md for the exact filter and the u32-scaling algorithm.

**Rebuilt 2026-07-15** to fix two harness-found quirks (contractions
destroyed in en.lex, unaccented/junk ranking noise in is.lex — see PLAN.md
"Harness-found quirk list"). Old sizes kept here for the record:

| artifact | before (2026-07-15 AM) | after (2026-07-15 PM) |
|---|---|---|
| en/en.lex | 4,265,360 bytes / 4.07 MB — 79,851 unigrams, 240,966 bigrams | 4,267,624 bytes / 4.07 MB — **80,000** unigrams, 240,966 bigrams |
| is/is.lex | 10,935,572 bytes / 10.43 MB — 308,649 unigrams, 381,547 bigrams | 9,658,112 bytes / 9.21 MB — **242,835** unigrams, 380,092 bigrams |

**Rebuilt again 2026-07-16 (en.lex only, format unchanged, v3)** to fix
task #10 (contraction frequencies still 10-40x too low even after the
2026-07-15 presence fix — see "Contraction frequency repair" below).
Unigram/bigram *counts* and file size are unchanged (only frequency
*values* for the 22 curated contractions + a handful of colliding bare
skeletons moved); is.lex untouched by this task.

| artifact | before (2026-07-15 PM) | after (2026-07-16) |
|---|---|---|
| en/en.lex | 4,267,624 bytes / 4.07 MB — 80,000 unigrams, 240,966 bigrams, `don't`=26,863 (scaled) | 4,267,624 bytes / 4.07 MB — 80,000 unigrams, 240,966 bigrams, `don't`=41,418,557 (scaled) |

**Rebuilt again 2026-07-16 (en.lex only, format unchanged, v4)** for the
corpus-dev `contraction_damage` wave: `CONTRACTION_EXPANSIONS` extended
from 22 to 52 entries (the full common contraction inventory), repair-
before-backfill order fix, and the `wed`/`shed` skeleton-fold exemption —
see "Contraction inventory extension (en.lex v4)" below. 80,000 →
**80,011** unigrams (+11 inserted contractions), 4,267,624 →
**4,267,800 bytes**; bigrams and scale divisors unchanged; is.lex
untouched.

**Rebuilt again 2026-07-19 (is.lex only, format unchanged)** for the
date-vocabulary frequency repair (dogfood: "17. juni" autocorrected to
"muni" instead of restoring "júní"). The icegrams-derived unigram source
was counted after Greynir's tokenizer merged date expressions into
composite DATE tokens, so month names — which occur almost exclusively
inside dates — survived at noise level or not at all (júní=353, six months
absent entirely), and weekday nominatives took collateral damage. The
builder now applies curated frequency floors (`ICELANDIC_DATE_VOCAB_FLOORS`
in `build-lexicon.py`: months 400,000, weekday nominatives 25,000) on the
Icelandic path before the BÍN prunes. 242,835 → **242,882** unigrams
(re-surviving months), 380,092 → **380,094** bigrams, 9,658,112 →
**9,659,060 bytes**. Corpus baseline re-blessed for 2 new safety
"false"-ACs (`juli`→`júlí`, `november`→`nóvember` — desired accent
restorations, same class as the 16 already-blessed rows); en.lex untouched.

### Contraction fix (en.lex)

**Root cause**: format v1's builder filter (`WORD_RE = ^[a-zþðæöáéíóúý]+$`)
disallowed apostrophes entirely, so every contraction was silently dropped
after loading — even though `en-80k.txt` already contains them with real
frequencies (`don't 188045`, `i'm 93673`, etc., from the SymSpell/Google
Ngram source). This is what caused the harness-observed corruption
(`don't` → `dont` → autocorrected to `Ibm`). Fix: `WORD_RE` now allows a
single internal apostrophe cluster
(`^[a-zþðæöáéíóúý]+('[a-zþðæöáéíóúý]+)*$`, leading/trailing/doubled
apostrophes still rejected), and the curly apostrophe (U+2019) is folded to
straight (`'`) before matching/storing — both at build time
(`build-lexicon.py`'s `normalize_word`) and at query time
(`FrequencyLexicon.normalizedKey`, since iOS text input commonly emits curly
apostrophes for contractions). No format change was needed — apostrophe is
just another UTF-8 byte in the string pool.

Result: en.lex unigrams 79,851 → 80,000 (+149, all apostrophe forms that
were previously being silently dropped). All 22 curated contractions
(`don't`, `i'm`, `it's`, `can't`, `won't`, `isn't`, `you're`, `we're`,
`they're`, `i've`, `i'll`, `didn't`, `doesn't`, `wasn't`, `aren't`,
`couldn't`, `wouldn't`, `shouldn't`, `that's`, `there's`, `what's`, `let's`)
were already present in the source once the filter allowed them — none
needed the fallback derivation. That fallback (opt-in via
`--contraction-backfill`, English-only) exists for future source drift: if a
curated contraction is ever missing, its frequency is derived as
`bigram_freq(uncontracted_phrase) // 2` from the raw SymSpell bigram source
(e.g. `freq("don't") ≈ bigram_freq("do", "not") // 2` — a same-corpus proxy,
since Google Ngram unigram/bigram counts are comparable orders of
magnitude). The SymSpell bigram source itself contains zero apostrophes, so
contractions get unigram frequencies (ranking) but no bigram/continuation
entries from this source — not fabricated, since there's no grounded way to
derive them.

### Contraction frequency repair (en.lex v3, task #10, 2026-07-16)

The 2026-07-15 fix above made contractions *present* in en.lex again, but
didn't check whether their frequencies were *plausible*. They weren't:
`en-80k.txt`'s own raw unigram count for `don't` is 188,045 — lower than
`font` (2,568,450, a ~13.6x gap), an unremarkable, far-less-common word.
Every one of the 22 curated contractions is undercounted 10-40x against
similarly "ordinary" words at the same rank. This made the beam decoder's
lane-relaxation apostrophe fold (PLAN.md "EN apostrophe folding
`dont`→`don't`... ~ε — the English diacritic") offer-only instead of
auto-applying: `don't`'s frequency was too low to win the ranking once
folded, and for contractions whose bare skeleton is *also* a real word
(`can't`/`cant`, `won't`/`wont`), the skeleton *outranked* the contraction —
backwards for the dominance-gate direction the fold needs.

**Diagnosis table** (raw `en-80k.txt` counts, i.e. before u32 scaling;
`skeleton` = the contraction with its apostrophe stripped, e.g.
`don't`→`dont`; `phrase_est` = the bigram-derived estimate described below):

| contraction | cur_freq | skeleton | skel_freq | phrase_est |
|---|---:|---|---:|---:|
| don't | 188,045 | dont | 0 | 289,929,901 |
| i'm | 93,673 | im | 0 | 60,955,333 |
| it's | 30,796 | its | 684,717,118 | 397,430,153 |
| can't | 52,752 | cant | 996,416 | 143,274,941 |
| won't | 17,453 | wont | 1,862,783 | 62,987,001 |
| isn't | 18,410 | isnt | 0 | 297,999,962 |
| you're | 49,153 | youre | 0 | 89,454,807 |
| we're | 21,055 | were | 1,135,241,275 | 79,813,781 |
| they're | 27,363 | theyre | 0 | 125,357,280 |
| i've | 29,910 | ive | 0 | 14,444,778 |
| i'll | 41,122 | ill | 27,863,718 | 3,620,853 |
| didn't | 37,778 | didnt | 0 | 144,695,663 |
| doesn't | 14,302 | doesnt | 0 | 159,458,475 |
| wasn't | 13,491 | wasnt | 0 | 77,177,815 |
| aren't | 6,764 | arent | 0 | 130,123,197 |
| couldn't | 17,569 | couldnt | 0 | 49,919,822 |
| wouldn't | 14,000 | wouldnt | 0 | 50,854,515 |
| shouldn't | 5,091 | shouldnt | 0 | 37,164,853 |
| that's | 11,638 | thats | 0 | 183,096,597 |
| there's | 3,857 | theres | 0 | 179,345,224 |
| what's | 54,983 | whats | 67,648 | 55,125,185 |
| let's | 18,135 | lets | 3,004,900 | 10,053,872 |

(Full table generated by `scripts/build-lexicon.py --contraction-repair`,
which prints exactly this at build time.)

**Why not just use bigram evidence directly** (`freq("don't") ≈
bigram_freq("do","not")`, the obvious first idea, and what
`--contraction-backfill`'s fallback already does for *missing* entries):
`en-80k.txt` and `frequency_bigramdictionary_en_243_342.txt` are not the
same corpus scale, despite FORMAT.md's older "comparable orders of
magnitude" note — that assumption doesn't hold. Proof: the single most
frequent unigram (`the`=26,548,583,149) is *smaller* than the single most
frequent bigram (`of the`=177,045,273,024), which is logically impossible
within one consistent corpus — a bigram can never occur more often than
either of its own constituent words. And the size of the mismatch isn't a
fixed ratio either: `of the` vs `the` is 6.7x, `in the` vs `in` is 12.3x,
`do not` vs `do` is 37.4x — measured across the full bigram file, the
`bigram_count / min(unigram(w1), unigram(w2))` ratio spans p10=0.17 to
p99=107.6. A single global divisor was tried and rejected during this fix
(it put every contraction above `the` itself).

**Method — conditional probability transfer, not absolute rescaling**: what
*is* stable across the two files is a same-corpus-internal ratio: for a
contraction's expansion `(w1, w2)`, `P(w2 | w1)` computed entirely inside
the bigram file (`bigram_freq(w1,w2) / total bigram mass with w1 as the
first word`) is assumed to transfer reasonably well onto the unigram file's
*trusted* count for `w1` — word-pair grammar doesn't shift much across
corpus vintages even where raw corpus size does. This gives two independent
projections back onto the unigram scale:

```
est_via_w1 = unigram_freq(w1) × bigram_freq(w1,w2) / Σ_x bigram_freq(w1,x)
est_via_w2 = unigram_freq(w2) × bigram_freq(w1,w2) / Σ_x bigram_freq(x,w2)
phrase_estimate = min(est_via_w1, est_via_w2)   # conservative: a skew on
                                                 # either side can only
                                                 # push the estimate down
```

Sanity check against words already trusted in `en-80k.txt`: this puts
`don't` (~290M) in the same tier as `should`/`would`/`could`
(407M/736M/443M) and `can't` (~143M) between `house` (158M) and `will`
(742M) — plausible for words this common in casual, mobile-typed English,
unlike the source's raw `don't`=188,045 (below `font`).

**Reassignment (`new_freq(C) = max(cur_freq(C), phrase_estimate)`)**: never
decreases a contraction, only raises undercounts. **Skeleton fold-down**:
only touches a skeleton that's actually present, and only when
`phrase_estimate > skel_freq` — i.e. only when the independent bigram
evidence alone already exceeds what's sitting in the skeleton's bucket,
meaning the skeleton's observed count doesn't need an "it's also a
genuinely common independent word" explanation to account for it. This
self-consistent gate (no per-word hardcoding) correctly separates the two
cases in the table above:
- **Left alone** (evidence doesn't dominate → real collision word):
  `its` (684,717,118, unchanged — `it's` estimate 397M is *smaller*),
  `were` (1,135,241,275, unchanged), `ill` (27,863,718, unchanged — `i'll`
  estimate is only 3.6M, well under `ill`'s observed count: "ill" the
  adjective is genuinely far more common than people meaning "I'll").
- **Folded down** (evidence dominates → mostly leaked contraction mass):
  `cant` 996,416 → 99,642 (floor), `wont` 1,862,783 → 186,279 (floor),
  `lets` 3,004,900 → 300,490 (floor), `whats` 67,648 → 6,765 (floor).
  `--contraction-skeleton-floor` (default 0.1) keeps 10% of the observed
  skeleton count rather than zeroing it — PLAN.md's "keep a floor so
  genuinely-typed 'dont' still ranks."

**Result — top-10 curated contractions, raw (pre-scale) counts**:

| contraction | before | after | Δ | skeleton after |
|---|---:|---:|---:|---|
| don't | 188,045 | 289,929,901 | ×1,542 | dont: 0 (unchanged) |
| i'm | 93,673 | 60,955,333 | ×651 | im: 0 (unchanged) |
| it's | 30,796 | 397,430,153 | ×12,905 | its: 684,717,118 (unchanged) |
| can't | 52,752 | 143,274,941 | ×2,716 | cant: 996,416 → 99,642 |
| won't | 17,453 | 62,987,001 | ×3,609 | wont: 1,862,783 → 186,279 |
| isn't | 18,410 | 297,999,962 | ×16,187 | isnt: 0 (unchanged) |
| you're | 49,153 | 89,454,807 | ×1,820 | youre: 0 (unchanged) |
| we're | 21,055 | 79,813,781 | ×3,791 | were: 1,135,241,275 (unchanged) |
| they're | 27,363 | 125,357,280 | ×4,581 | theyre: 0 (unchanged) |
| i've | 29,910 | 14,444,778 | ×483 | ive: 0 (unchanged) |

On disk (u32-scaled, divisor=7): `don't` goes from 26,863 to 41,418,557 —
now ~113x `font` (366,921) instead of ~14% of it, and `can't`
(20,467,848 scaled) now outranks `cant` (14,234 scaled) by ~1,438x, well
past the ~10x collision-dominance ratio PLAN.md's accent-folding mirror
case calls for.

**Verification**: `python3 scripts/build-lexicon.py --unigrams
data/en/en-80k.txt --bigrams data/en/frequency_bigramdictionary_en_243_342.txt
--out data/en/en.lex --contraction-backfill --contraction-repair` rebuilds
byte-identical on repeated runs (`cmp` verified) — same 80,000 unigrams,
240,966 bigrams, same 4,267,624-byte file size as before this fix (only
frequency *values* changed, not the unigram/bigram vocabulary or the
u32 scale divisor, since `the` — unaffected — remains the max). Bench
(`swift run -c release lex-bench data/en/en.lex`, macOS, 1000 iterations,
this rebuilt artifact): load 0.15 ms, `frequency()` 1.4 µs/call,
`bigramFrequency()` 2.2 µs/call, `completions()` 135.8 µs/call,
phys_footprint delta after load + 3000 mixed lookups +0.69 MB — flat
against (in fact better than, within normal run-to-run noise) the
2026-07-15 en.lex bench row below.

### Contraction inventory extension (en.lex v4, 2026-07-16)

The corpus-dev `contraction_damage` diagnosis (eval studio, scores/README.md)
showed the v3 repair only covered its 22 curated contractions: damaged
tokens for anything else (`theyd`→`they'd`, `havent`→`haven't`) still lost
to their bare stems because the contraction's en.lex frequency was raw-
undercounted (`haven't`=5,357 raw — below `font`) or absent entirely
(`hasn't`, `weren't`, `would've`). v4 extends `CONTRACTION_EXPANSIONS` in
`scripts/build-lexicon.py` from 22 to 52 entries — the full common English
contraction inventory (haven't/hasn't/hadn't/weren't, they'd/'ll/'ve,
we'd/'ll/'ve, you'd/'ll/'ve, he's/'d/'ll, she's/'d/'ll, i'd, who's, here's,
where's, how's, mustn't, needn't, would've/could've/should've/must've) —
using the same conditional-probability repair. Nothing else changed:

- **Existing 22 entries byte-identical** (each row's estimate is computed
  independently) — asserted by
  `Packages/Lexicon/Tests/.../testEnglishArtifactContractionsPresent`.
- **Order fix**: the repair now runs BEFORE `--contraction-backfill`. The
  backfill's raw `bigram_freq // 2` proxy is on the bigram file's (larger)
  corpus scale; when it ran first it inserted newly-listed absent
  contractions at bogus values the repair's `max()` then kept
  (`would've` landed at 1.48B — above `have`). With repair first, the
  backfill is pure belt-and-braces and inserts nothing today.
- **`CONTRACTION_SKELETON_FOLD_EXEMPT = {"wed", "shed"}`**: the fold
  heuristic's two known false positives. Both are genuine independent
  words whose observed counts sit BELOW their contraction's estimate
  (`wed` 1,014,344 vs `we'd` est ~17.2M; `shed` 6,240,911 vs `she'd` est
  ~14.7M), so the self-consistent gate would have folded them to 10% —
  and a 10%-folded `shed` would put `she'd` past the engine's 10x
  restoration-dominance gate, i.e. a deliberately typed "shed" could
  auto-restore to "she'd". Exempted; their counts are unchanged. The
  gate's other real-word collisions (`well`, `hell`, `shell`, `id`, `its`,
  `were`, `ill`) need no exemption — their observed counts exceed the
  estimates, so the fold never fires (verified in the build report).
  Junk skeletons (`hes` 227,580 → 22,758, `shes`, `whos`, `wheres`,
  `hows`) fold to the 10% floor as designed.

On disk: 80,000 → **80,011** unigrams (+11 newly inserted contractions),
240,966 bigrams unchanged, scale divisors unchanged (7 / 42),
totalUnigramTokens 52,708,346,097. Rebuild is byte-deterministic
(md5-verified across repeated runs) with the same command as v3.

### Ranking-noise pruning (is.lex)

is.lex is **ranking-only** — validity comes from BÍN via `bin-morph.bin` in
the engine, so aggressive pruning here is safe (a pruned word just stops
being suggested/ranked, it doesn't become "invalid"). Two prunes now run via
`--bin-lookup`/`--bin-lemmas` (pointing at lemma-is's
`data-dist/lookup.tsv.gz` and `data-dist/lemmas.txt.gz`):

1. **BÍN-membership prune**: drop any unigram that isn't a BÍN surface form,
   *except* the top 10,000 most frequent non-BÍN words (`--bin-topk`,
   default 10000) and any non-BÍN word at/above frequency 2,000
   (`--bin-high-freq`, default 2000) — these two escape hatches keep
   legitimate non-BÍN vocabulary a news-corpus-trained table is full of:
   foreign proper nouns, sports teams/clubs, orgs, abbreviations, English
   loanwords ("united", "manchester", "arsenal", "esb", "bbc", "rúv", single
   letters used as initials). **Gotcha found during implementation**:
   `lookup.tsv.gz` alone is *not* the full BÍN form set — lemma-is's
   `build-data.py` deliberately omits any word that is its own lemma with no
   other lemma/POS ambiguity (a lemma-lookup index has nothing useful to say
   about a word already equal to its own lemma). That skip rule excludes
   huge swaths of basic vocabulary: pronouns (`hann`, `ég`), nominative
   singular nouns (`hestur`), common adverbs (`einnig`), proper nouns
   (`reykjavík`) — none of these are in `lookup.tsv.gz`, but all are in
   `lemmas.txt.gz`. The builder unions both files; using `lookup.tsv.gz`
   alone would have flagged ~35% of common Icelandic vocabulary as "non-BÍN
   noise" and pruned it. Result: 308,649 → 243,258 unigrams (65,391 dropped
   as non-BÍN noise, 10,000 non-BÍN words kept via the escape hatches).
2. **Accent-dominance filter** (`--accent-ratio`, default 10): drop an
   unaccented word when an accented variant exists (folding `á,é,í,ó,ú,ý,ö`
   — each an NFD-decomposable base+diacritic — down to its ASCII base
   letter; `þ,ð,æ` are independent letters with no ASCII fallback and are
   left alone) whose frequency is ≥10x the unaccented word's. This targets
   the specific "accents dropped by a non-Icelandic input method" noise
   pattern. Result: 243,258 → 242,835 unigrams (423 dropped), e.g. `i`
   (37,299) dominated by `í` (25,371,808), `a` (106,173) dominated by `á`
   (18,227,685), `eg` (6,359) dominated by `ég` (1,907,515).

**Spot-check** (both filters combined, verified in
`Packages/Lexicon/Tests/LexiconTests/FrequencyLexiconTests.swift`):
- `islenskar`/`islensk` (unaccented noise): **gone** — dropped by the
  accent-dominance filter (their accented counterparts `íslenskar`/`íslensk`
  outweigh them >1000x), and also not in the BÍN top-K/high-freq escape
  hatch (freq 5/7, deep in the non-BÍN tail).
- `hester` (junk form, freq 57): **gone** — not a BÍN form (not in
  `lookup.tsv.gz` or `lemmas.txt.gz`), and its frequency puts it well
  outside the top-10,000 non-BÍN escape hatch.
- `íslenskar` (15,388), `íslensk` (37,988), `hestur` (422, kept via
  `lemmas.txt.gz` despite `lookup.tsv.gz`'s gap), `hann` (3,772,234), `ég`
  (1,907,515), `reykjavík` (kept via the non-BÍN top-K escape hatch): **all
  survive** with their real frequencies.

**Total**: is.lex unigrams 308,649 → 242,835 (66,238 dropped, ~21.5%
reduction); bigrams 381,547 → 380,092 (1,455 fewer, since bigrams referencing
a now-pruned word are dropped along with it — same rule as always: bigrams
never grow or preserve vocabulary beyond the unigram table). File size
10.43 MB → 9.21 MB (12% smaller, roughly proportional-ish to the unigram
count drop — string pool + fixed-width arrays both shrink).

Bench (`swift run -c release lex-bench <path>`, macOS, 1000 iterations each,
rebuilt artifacts, 2026-07-15 — en.lex row superseded by the fresh
2026-07-16 bench in "Contraction frequency repair" above; is.lex is
untouched by that later task and this row is still current for it):

| artifact | load | frequency() | bigramFrequency() | completions() |
|---|---|---|---|---|
| en.lex | 0.26 ms | 2.0 µs/call | 5.5 µs/call | 135.5 µs/call |
| is.lex | 0.43 ms | 7.0 µs/call | 5.0 µs/call | 846.5 µs/call |

`completions()` cost is dominated by short single-letter prefixes in the
bench word mix, which hit the documented 20k-entry scan cap on the larger
Icelandic table; real keyboard prefixes are typically ≥2 characters, where
ranges are far smaller. phys_footprint delta after load + 3000 mixed lookups:
+0.86 MB (en.lex), +2.13 MB (is.lex) — both file-backed mmap, so this is
almost entirely the materialized `String`/tuple results, not resident file
pages. Footprint stayed flat vs. the pre-rebuild bench (+0.97 MB / +2.63 MB)
— if anything slightly better, since is.lex itself shrank.

## Inflection intelligence artifacts (is/) — Stage A data (2026-07-16)

PLAN.md "Inflection intelligence": use BÍN morphology to suggest the
grammatically-correct inflected form ("frá hest|" → hesti, not hestur/hestum).
This is the Stage A data pipeline (Python, offline builders); Stage B (Swift
consumption in the engine) is a later wave and is not built yet — the two
artifacts below are its input contract.

### paradigms.bin (22.81 MB)

Generation direction: lemma → every inflected surface form + its feature
bundle (case/number/definiteness for nouns; case/number/gender/degree/
strength for adjectives). The mirror image of bin-morph.bin v2's analysis
direction (surface form → lemma + tag). Full binary layout, join-key
contract with bin-morph.bin, and worked examples: `data/is/PARADIGMS_FORMAT.md`.

- **Scope (v1)**: nouns + adjectives only (verbs are a later wave); lemma
  must have unigram frequency ≥ 10 in `unigrams.json.gz` (39,826 lemma
  groups, 775,858 (form, feature-bundle) entries, 377,688 distinct surface
  forms kept out of BÍN's full 5,560,075 noun/adjective rows).
- **Regenerate**:
  ```
  python3 scripts/build-paradigms.py \
      --src /path/to/lemma-is/data/SHsnid.csv \
      --unigrams data/is/unigrams.json.gz \
      --output data/is/paradigms.bin
  ```
  `--verify` (also run automatically at the end of a build) mmaps the file
  back and checks `hestur` has exactly its 16 forms, `góður` has all 120
  adjective forms, and both access patterns (lemma→forms, form→features)
  resolve correctly.
- **Determinism**: byte-identical across re-builds from the same inputs
  (verified via `cmp`).
- **License**: derived from BÍN, same conditions as bin-morph.bin — see
  `data/ATTRIBUTION.md` ("No publishing of inflection paradigms": this file
  stores per-form data for on-device ranking, same class of use as
  bin-morph.bin's existing morph section; it is not user-facing raw paradigm
  export).

### governors.json.gz (1.4 MB)

Statistical case-government model: for each "governor" word (prepositions,
verbs, or anything else with enough evidence — no hand-written POS filter,
see build-governors.py docstring "Why no POS filter on word1"), the observed
distribution of feature bundles carried by the nouns/adjectives that follow
it in `data/is/bigrams.json.gz`, i.e. `P(case, number, definiteness | prev
word)` per PLAN.md. No grammar rules — "frá takes dative" falls out of
counting BÍN-tagged bigram followers.

- **Fractional credit**: when a followed word (word2) is grammatically
  ambiguous (multiple BÍN analyses), its bigram count is split evenly across
  every distinct noun/adjective analysis rather than guessing the single
  "correct" one (the wordform-overlap principle — never resolve ambiguity
  by fiat).
- **Filters**: `--min-mass` (default 50, weighted-occurrence floor — in
  practice this filtered 0 of 30,619 candidates, since `bigrams.json.gz` is
  already frequency-filtered upstream; the entropy filter does the real
  work here) and `--max-case-entropy-ratio` (default 0.9 — drops governors
  whose *case-only* marginal distribution is close to uniform, i.e. carries
  no case-government signal; dropped 16,870 of 30,619 candidates).
- **Regenerate**:
  ```
  python3 scripts/build-governors.py \
      --src /path/to/lemma-is/data/SHsnid.csv \
      --bigrams data/is/bigrams.json.gz \
      --output data/is/governors.json.gz
  ```
- **Validation** (`--verify`, asserted against known Icelandic grammar —
  built 2026-07-16, 13,749 governors kept):
  ```
  P(case | frá): dominant=þgf (0.675)  expected=þgf  [OK]
  P(case | til): dominant=ef  (0.703)  expected=ef   [OK]
  P(case | um):  dominant=þf  (0.464)  expected=þf   [OK]

  á:   mass=5,353,425  þgf=0.522 þf=0.257 nf=0.172 ef=0.049  (split confirmed)
  með: mass=1,014,074  þgf=0.482 þf=0.242 nf=0.196 ef=0.080  (split confirmed)
  ```
  Top governors by mass: í (8.9M), á (5.4M), er (3.0M), sem (2.6M), til (2.0M),
  ekki (2.0M), við (1.9M), það (1.8M), um (1.8M) — see script output for the
  full top-20 with distributions.
- **Determinism**: JSON content and the gzip wrapper itself (pinned
  `mtime=0`) are byte-identical across re-builds from the same inputs/output
  path.
- **License**: same conditions as above — derived counts/distributions only,
  no raw BÍN paradigm export.

### Open questions for Stage B

1. Join key is the lemma **string** (lowercased), not a numeric id shared
   with bin-morph.bin (whose ids are that file's internal implementation
   detail) — see PARADIGMS_FORMAT.md "Join key / lemma-group identity".
2. Homonym noun lemmas with identical spelling *and* identical gender
   collapse into one paradigm group (BÍN's `bin_id`, which would
   disambiguate them, is not threaded through) — believed harmless since
   Icelandic declension is phonology/gender-driven, not meaning-driven, but
   flagged in case a future use case needs word-sense-level distinction.
3. Verb paradigms/government (tense/mood/person/voice) don't fit the
   case/number/gender/degree bundle shape used here — a later wave needs a
   genuinely different bundle encoding or sibling file, not a bit-squeeze.
4. `governors.json`'s `bundle_distribution` (full case+number+definiteness/
   gender+degree breakdown, not just the case marginal) is included per
   PLAN.md's literal wording but is unvalidated/unused so far — Stage B
   should confirm whether the extra granularity is actually useful before
   building ranking logic against it, or whether the case-only marginal is
   sufficient in practice.

## CI Checks (Future)

- [ ] Verify total binary sizes on each tier ≤ 35 MB in app bundle (ipa)
- [ ] On-device memory ceiling test: launch keyboard with full model stack, confirm dirty memory < 50 MB on iPhone 8 (1 GB baseline + 30 MB model headroom)
- [ ] Frequency table JSON schema validation (gzip integrity + JSON parse)
- [ ] Bigram fallback: if bigrams.json.gz is missing, log warning and degrade to unigrams-only
