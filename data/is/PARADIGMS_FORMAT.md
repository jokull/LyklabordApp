# paradigms.bin format (v1)

Produced by `scripts/build-paradigms.py`, consumed by Stage B (the Swift
engine — not built yet; this document is its contract). Same mmap-and-binary-
search philosophy as `Packages/Lexicon/FORMAT.md` and lemma-is's `.bin`
format: the file is memory-mapped and never parsed into an in-memory
collection; every lookup is a handful of offset reads plus a couple of
binary searches over sorted byte arrays.

`paradigms.bin` is the GENERATION direction of BÍN morphology (lemma -> every
form + its grammatical feature bundle). lemma-is.bin v2 already ships the
ANALYSIS direction (surface form -> lemma + morph tag); this is deliberately
a separate artifact rather than an extra section bolted onto lemma-is.bin,
because it has a different scope (nouns + adjectives only, frequency-
filtered — see "Scope" and "Size budget" below) and a different primary sort
key need (lemma-first, not just surface-form-first).

## Scope (v1)

- **Parts of speech**: nouns (BÍN word classes `kk`/`kvk`/`hk` — masculine/
  feminine/neuter) and adjectives (`lo`). Verbs (`so`) and everything else
  (pronouns, numerals, etc.) are **out of scope** for v1 — a later wave.
- **Lemma frequency filter**: only lemma groups whose lemma has unigram
  frequency `>= --min-lemma-freq` (default **10**) in `data/is/unigrams.json.gz`
  are included. This is a deliberate size/coverage tradeoff, not a modeling
  choice — see "Size budget" below for the sweep that picked the default.
  Rare/archaic/proper-noun paradigms are the ones dropped; they contribute
  little to completion/prediction quality relative to their size cost.

## Source data

BÍN's raw "Sigrúnarsnið" CSV, `SHsnid.csv` — semicolon-delimited, columns
`lemma;bin_id;word_class;domain;word_form;mark`, ~315 MB, 6,332,065 rows
total (5,560,075 of them `kk`/`kvk`/`hk`/`lo`). This is the **same raw file**
lemma-is's own `scripts/build-data.py` and `scripts/build-binary.py` read
(`DATA_DIR / "SHsnid.csv"`) to build `lookup.tsv.gz`/`lemmas.txt.gz` and
`lemma-is.bin`'s v2 morph section, respectively — i.e. this pipeline and
lemma-is.bin both derive from the identical upstream source, just extracting
different columns/directions from it.

It was found locally at `/Users/jokull/Code/lemma-is/data/SHsnid.csv`
(not downloaded fresh for this task — already present in that checkout).
lemma-is's `build-data.py` docstring/error message says to get it from
**https://bin.arnastofnun.is/DMII/LTdata/data/** if it's missing. It is
**not redistributed** in this repo or in lemma-is's own `data-dist/`/dist
output (only derived, non-raw artifacts are shipped) — see
`data/ATTRIBUTION.md` ("No raw-data redistribution").

`mark` field survey (full enumeration, see `bin_morph.py` docstring for the
worked substring-matching rules):
- Nouns: case (`NF`/`ÞF`/`ÞGF`/`EF`) + number (`ET`/`FT`), optional `gr`
  suffix (article-suffixed = definite, e.g. `ÞGFETgr`), optional trailing
  digit (`EFET2`, `EFETgr3`) marking a BÍN-internal *alternate spelling for
  the same grammatical slot* (not a new feature — both spellings get an
  entry with the identical feature bundle; e.g. `aðalaðili`'s genitive
  singular has both `aðalaðila` and `aðalaðilja`, both `no:ef:et:ngr`).
- Adjectives: degree+strength prefix (`FSB`=positive/strong, `FVB`=positive/
  weak, `MST`=comparative, `ESB`=superlative/strong, `EVB`=superlative/weak)
  — `MST` (comparative) carries **no** strong/weak distinction in BÍN itself
  (Icelandic comparatives always decline weak); the builder records
  `strength=vb` for `MST` rows by convention so the strength axis stays
  2-valued (see `bin_morph.parse_adj_mark` docstring) — `-`-joined gender
  (`KK`/`KVK`/`HK`), then case+number in the same form as nouns. One
  irregular tag observed in the wild: `MST-SB-HK-ÞGFET` (an apparent BÍN data
  quirk on a single lemma) — the substring-based parser handles it
  correctly without special-casing since it still contains `MST`, `HK`,
  `ÞGF`, `ET` as substrings.

## Header (32 bytes, little-endian)

| offset | size | field         | meaning                                          |
|-------:|-----:|---------------|---------------------------------------------------|
| 0      | 4    | magic         | `0x50415231` ("PAR1" as bytes P,A,R,1)             |
| 4      | 4    | version       | format version, `1`                                |
| 8      | 4    | stringPoolSize| bytes in the string pool (padded to 4)             |
| 12     | 4    | groupCount    | number of lemma groups                             |
| 16     | 4    | entryCount    | number of (form, feature bundle) entries           |
| 20     | 4    | formCount     | number of distinct surface form strings            |
| 24     | 4    | minLemmaFreq  | the `--min-lemma-freq` threshold used to build this|
| 28     | 4    | reserved      | must be 0                                          |

All multi-byte integers little-endian. All reads should use unaligned loads
(mirrors `Packages/Lexicon/FORMAT.md`) — no field is guaranteed naturally
aligned relative to file start once you're inside a record.

## Sections (immediately after the 32-byte header, back to back)

1. **String pool** (`stringPoolSize` bytes) — concatenated UTF-8 bytes of
   every distinct lemma string and every distinct surface form string
   (deduplicated against each other too: a nominative-singular-indefinite
   form is frequently spelled identically to its lemma, e.g. `hestur`, and
   only stored once). No separators; offsets/lengths delimit each string.
   Padded with zero bytes to a multiple of 4.

2. **Lemma group table** (`groupCount` × 16 bytes) — one record per distinct
   `(lemma, pos, gender)` key (see "Join key / lemma-group identity" below).
   Sorted ascending by `(lemma bytes, pos, gender)` — primarily by the
   lemma's UTF-8 byte order, so a binary search on lemma alone finds the
   start of its (small, usually size-1) run of groups.

   | field       | size | meaning                                          |
   |-------------|-----:|---------------------------------------------------|
   | lemmaOffset | u32  | byte offset of the lemma string in the string pool |
   | lemmaLen    | u8   | UTF-8 byte length of the lemma string              |
   | pos         | u8   | `0` = noun, `1` = adjective                        |
   | gender      | u8   | noun: `0`=kk,`1`=kvk,`2`=hk. adjective: `0xFF` (n/a — gender is a per-form axis for adjectives, not a lemma property) |
   | pad         | u8   | `0`                                                 |
   | entryStart  | u32  | index of this group's first entry in the Entries array |
   | entryCount  | u32  | number of entries belonging to this group          |

3. **Entries array** (`entryCount` × 12 bytes) — ordered grouped by lemma
   group (i.e. group `g`'s entries occupy indices
   `[entryStart, entryStart+entryCount)`, matching the table above); within
   a group, sorted ascending by `(featureBundle, form bytes)`.

   | field        | size | meaning                                    |
   |--------------|-----:|-----------------------------------------------|
   | lemmaGroupIdx| u32  | index into the Lemma group table (section 2)   |
   | formOffset   | u32  | byte offset of the surface form in the string pool |
   | formLen      | u8   | UTF-8 byte length of the form                  |
   | bundle       | u16  | packed feature bundle (see "Feature bundle encoding") |
   | pad          | u8   | `0`                                             |

4. **Surface form table** (`formCount` × 16 bytes) — one record per distinct
   surface form string across the whole file (a form can come from many
   lemma groups). Sorted ascending by form bytes, for binary search.

   | field      | size | meaning                                          |
   |------------|-----:|-----------------------------------------------------|
   | formOffset | u32  | byte offset of the form string in the string pool    |
   | formLen    | u8   | UTF-8 byte length                                    |
   | pad        | 3×u8 | `0,0,0`                                              |
   | permStart  | u32  | index of this form's first entry in the Permutation array |
   | permCount  | u32  | number of entries for this exact form string         |

5. **Permutation array** (`entryCount` × u32) — each element is an index
   into the Entries array (section 3). Ordered so that a surface form's
   `[permStart, permStart+permCount)` slice (from section 4) lists exactly
   the entries (across every lemma group) whose form string equals it, in
   ascending entry-index order.

No trailing padding after section 5; file length is exactly the end offset
of section 5.

## Feature bundle encoding

A `uint16`, one per entry. Bits 0-3 are common to both POS; the meaning of
bits 4+ depends on bit 3 (`pos`).

```
bit(s)  field                values
0-1     case                 0=nf 1=þf 2=þgf 3=ef
2       number               0=et 1=ft
3       pos                  0=noun 1=adjective
--- if pos == noun (bit 3 = 0): ---
4       definiteness         0=indefinite 1=definite (article-suffixed)
5-15    (unused, always 0)
--- if pos == adjective (bit 3 = 1): ---
4-5     gender               0=kk 1=kvk 2=hk
6-7     degree               0=frumstig(positive) 1=miðstig(comparative) 2=efsta stig(superlative)
8       strength             0=sterk beyging(strong) 1=veik beyging(weak)
9-15    (unused, always 0)
```

A noun has at most 4×2×2 = **16** possible bundles (matches PLAN.md's
"hestur has 16 forms" — case × number × definiteness, exactly what's
enumerated for `hestur` in the worked example below). An adjective has at
most 4×2×3×5 = **120** possible bundles (case × number × gender ×
degree/strength combos — `FSB`,`FVB`,`MST`,`ESB`,`EVB` map to 5 valid
degree/strength pairs, not the full 3×2=6, since `MST` doesn't have a strong
variant) — confirmed exactly by `góður`, which has all 120.

`bin_morph.py` (`pack_noun_bundle`, `pack_adj_bundle`, `unpack_bundle`,
`bundle_to_string`) is the single source of truth for this encoding, shared
by both `build-paradigms.py` and `build-governors.py` — never re-implement
the bit layout ad hoc; import it (Swift Stage B should keep its own decode
logic in exactly one place too, mirroring this).

`bundle_to_string()` renders a bundle as a human-readable string, e.g.
`no:þgf:et:gr` or `lo:þgf:et:kk:fst:sb`. This string form is used in
`governors.json` and CLI/debug output; **not** stored in `paradigms.bin`
itself (which always stores the packed `uint16`).

## Join key / lemma-group identity — what Stage B needs to know

Per PLAN.md's explicit instruction ("reference forms by their existing
lemma-is string identity ... likely the surface string + lemma string since
lemma-is.bin ids are internal"), **`paradigms.bin` shares no numeric ids with
`lemma-is.bin`** — the join key across the two artifacts is the lemma
**string** (lowercased UTF-8), plus POS where ambiguity matters. This is
robust to lemma-is.bin being rebuilt/re-versioned independently (its
internal lemma indices are an implementation detail of that file, not a
stable identifier).

A "lemma group" is not simply "a lemma" — it's `(lemma string, pos, gender)`
for nouns (gender is intrinsic to a noun lemma in Icelandic — a given noun
spelling with a given gender always inflects the same way) and
`(lemma string, pos)` for adjectives (gender is a per-form agreement axis,
not a lemma property, so it's not part of the adjective key — `gender=0xFF`
sentinel in the group table). **Caveat**: true homonym noun lemmas with
identical spelling AND identical gender (rare — e.g. two unrelated
loanwords, or a common-noun/place-name collision) collapse into a single
group; since Icelandic declension is governed by phonological shape and
gender rather than meaning, this essentially never produces a wrong
inflection (both meanings share the same paradigm), it just means the group
can't distinguish *why* a form exists. This is flagged as an open question
for Stage B in the pipeline report — if a use case ever needs word-sense
disambiguation at this level, BÍN's own `bin_id` (present in `SHsnid.csv`
column 2) would need to be threaded through, which `paradigms.bin` currently
discards.

## Access patterns

- **(a) lemma -> all forms + features** (inflection-aware completion:
  "typed `frá hest|`, want {hestur, hesti, hestum, ...}"): binary search the
  Lemma group table (section 2) for the lemma string; because it's the
  primary sort key, all matching groups (rare: >1, e.g. a noun/adjective
  spelling collision) form a contiguous run immediately following the
  found index. For each group, read `[entryStart, entryStart+entryCount)`
  from the Entries array for its forms+bundles.
- **(b) surface form -> feature bundle(s)** (wrong-form correction, personal-
  lemma paradigm-sibling lift): binary search the Surface form table
  (section 4) for the exact form string; read its `[permStart,
  permStart+permCount)` slice of the Permutation array (section 5), each
  element an Entries-array index; each entry gives `lemmaGroupIdx` (dereference
  section 2 directly, no search — it's a direct index) + `bundle`.

Both are the same two-binary-searches-plus-bounded-scan shape as
`Packages/Lexicon/FORMAT.md`'s `completions`/`continuations`, just over
different key spaces (lemma vs. surface form).

## Determinism

Fixed sort orders throughout (lemma groups by `(lemma bytes, pos, gender)`;
entries within a group by `(bundle, form bytes)`; string pool populated by
walking those same sorted structures) plus a fully deterministic single-pass
CSV scan with no wall-clock/PID/hash-randomization dependence anywhere in
the algorithm. Verified: two builds from identical inputs (`--src`,
`--unigrams`, `--min-lemma-freq` held fixed) produce byte-identical output
(`cmp` returns no diff).

## Size budget

Target from PLAN.md: "≤ 25MB". The `--min-lemma-freq` threshold controls the
size/coverage tradeoff (unigrams.json.gz's own floor is frequency 5 — every
word in it already cleared that bar in the source corpus, so
`--min-lemma-freq` values below 5 have no additional effect):

| min-lemma-freq | lemma groups | entries | estimated total size |
|---------------:|-------------:|--------:|----------------------:|
| 5  | 46,256 | 910,995 | ~28.1 MB |
| **10 (default, shipped)** | **39,826** | **786,658 candidates → 775,858 after mark-parse/dedup** | **22.81 MB (measured)** |
| 15 | 35,395 | 699,742 | ~21.3 MB |
| 20 | 32,271 | 638,902 | ~19.4 MB |
| 30 | 28,311 | 560,601 | ~17.0 MB |

`--min-lemma-freq 10` was chosen as the default: comfortably under budget
(22.81 MB measured vs. the 25 MB target) while keeping ~40k of the most
common Icelandic noun/adjective lemmas — freq-5-9 lemmas (the ones cut going
from 5→10) are the rarest tier already in `unigrams.json.gz` and contribute
disproportionately to size (more distinct rare forms) relative to their
completion/prediction value.

## Worked example (`--verify` output against the shipped build)

```
lemma "hestur" -> 16 entries:
  hestur          no:nf:et:ngr        hest       no:þf:et:ngr
  hesti           no:þgf:et:ngr       hests      no:ef:et:ngr
  hestar          no:nf:ft:ngr        hesta      no:þf:ft:ngr
  hestum          no:þgf:ft:ngr       hesta      no:ef:ft:ngr   (homograph with þf:ft — syncretism)
  hesturinn       no:nf:et:gr         hestinn    no:þf:et:gr
  hestinum        no:þgf:et:gr        hestsins   no:ef:et:gr
  hestarnir       no:nf:ft:gr         hestana    no:þf:ft:gr
  hestunum        no:þgf:ft:gr        hestanna   no:ef:ft:gr

form "hestinum" -> 1 analysis: lemma=hestur no:þgf:et:gr
lemma "góður" (adjective) -> 120 entries (all 4×2×3×5 combos present)
```

## Open questions for Stage B

1. **Homonym lemma collapse** (see "Join key" above) — is BÍN's `bin_id`
   ever needed downstream, or is `(lemma, pos, gender)` sufficient forever?
   Current bet: sufficient, because declension is phonology/gender-driven,
   not meaning-driven, in Icelandic.
2. **Verb wave**: this format has no verb section. When verbs are added,
   decide whether they're a new `pos` value in the same bundle scheme (verb
   feature bundles — tense/mood/person/number/voice — don't fit the
   case/number/gender/degree axes used here at all, so likely a genuinely
   different bundle shape/section, not a bit-squeeze into this one) or a
   sibling file (`paradigms-verbs.bin`).
3. **Multi-word/compound lemmas**: BÍN lemma strings can contain hyphens
   (`a-deild`, `68-kynslóð` seen in the raw data) — these pass through
   unchanged (just another byte sequence in the string pool); Stage B should
   not assume a lemma is a single "clean" word if it does anything
   spelling-sensitive with it.
