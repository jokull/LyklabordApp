# Miðeind compound-word case harvest

Context: wave 22 ported the RULES of Miðeind's compound decomposition
algorithm into `Packages/TypeEngine/Sources/TypeEngine/Compounds.swift`
(read-only for this research pass — not touched). Wave 23 is building
compound *completions*. This doc harvests real compound-word test cases
from Miðeind's open-source NLP stack and one CC-BY error corpus to
strengthen `data/eval/*` and stress-test `Compounds.swift`'s documented
deviations from Miðeind's shipped analyzer. Research + a curated case file
only — no engine or `Packages/` changes.

Machine-readable output: `research/mideind-compound-cases.jsonl` (2,052
rows: 18 valid compounds, 14 rejected pseudo-compounds, 2,020 error→
correction pairs). Every row carries `source_repo`, `source_file`, and
`license`.

## Sources mined, per-repo yield and license

| Source | License (verified) | What it offered | Rows harvested |
|---|---|---|---|
| `mideind/BinPackage` (`test/test_bin.py`, `src/islenska/resources/suffix-removals.txt`) | **MIT** (code); the *word forms* in `suffix-removals.txt` are BÍN data (CC BY-SA 4.0, Árni Magnússon Institute) | The gold mine for class 1 & 3: `test_compounds`, `test_soft_hyphenate*`, `test_gauksstadamal_uses_deepest_split`, `test_capitalized_word_in_bin_not_compounded`, `test_non_latin1_words` — literal assertions pinning real compound decompositions, tantum-demotion behavior, and negative/robustness controls. `suffix-removals.txt` is BinPackage's 127k-line list of BÍN forms excluded as legal compound-head suffixes — sampled illustratively only (see caution below) | 18 valid, 4 rejected (clean), 3 rejected (CAUTION sample) |
| `~/Forks/GreynirEngine` (local fork, release 3.6.1; `test/test_reynir.py`) | **MIT** | `test_compounds()` — but it's all coordination-reduction ("fjármála- og efnahagsráðherra"), a different mechanism (cross-token ellipsis) our single-word splitter doesn't touch. `test_compounds_with_numbers` is fully commented out (no runnable cases) | 2 valid (flagged out-of-scope) |
| `~/Forks/Tokenizer` (local fork; `test/toktest_large_gold_perfect.txt`, `Overview.txt`) | **MIT** | One deliberately-extreme gold-corpus stress compound (`álfabrunnfuglagarðurinn`, 4 parts) plus the `og`/`eða` hyphen-coordination special-case code (same coordination mechanism as above, not single-word) | 1 valid |
| `mideind/GreynirCorrect` (`test/test_allkinds.py`) | **MIT** | `test_wrong_compounds` (C002 — wrongly-*joined* pseudo-compounds that must stay two words) and `test_split_compounds` (C003 — wrongly-*split* real compounds). Small (16 pairs) but clean and directly schema-shaped | 16 error pairs (10 C002, 6 C003) |
| `antonkarl/iceErrorCorpus` (not a `mideind` repo — Anton Karl Ingason et al., the corpus underlying GreynirCorrect's error taxonomy; `allErrors.tsv`, `errorCodes.tsv`) | **CC BY 4.0** (`cc-by-4-0.txt` in repo; README states it explicitly) | `allErrors.tsv` = 56,703 total annotated error rows across 5 categories × subcategories. Filtered to the 5 compound-shaped error codes (`compound-collocation`, `missing-hyphen`, `split-compound`, `split-word`, `split-words`): 2,559 raw rows → 2,004 kept after cleaning (dropped 555 rows with punctuation/multi-sentence alignment noise or >4-char length drift — bad TEI-alignment artifacts, not real pairs) | 2,004 error pairs |
| `mideind/iceErrorCorpusSpecialized`, `mideind` org repo list (`gh api users/mideind/repos`) | n/a | No `mideind/iceErrorCorpus` exists — it's `antonkarl/iceErrorCorpus` (confirmed via `gh search repos`). Org listing checked for anything else compound-relevant: nothing else surfaced beyond what's above | 0 |

**Total: 2,052 rows** — 18 valid compounds, 14 rejected pseudo-compounds,
2,020 compound-error→correction pairs (2,004 CC BY 4.0 + 16 MIT).

### Licensing discipline notes

- Everything from `BinPackage`, `GreynirEngine`, `Tokenizer`, `GreynirCorrect`
  is **MIT** (each repo's `LICENSE.txt` fetched and read directly, not
  inferred from GitHub's license API — GreynirCorrect's API `license` field
  reported `NOASSERTION` but the actual `LICENSE.txt` content is
  copyright-Miðeind MIT, matching GreynirEngine's and Tokenizer's headers).
  Full literal copying to our public MIT repo is clean.
- `iceErrorCorpus` is **CC BY 4.0**. Per our own `data/ATTRIBUTION.md`
  pattern (BÍN / SymSpell sections), committing derived data under CC BY
  requires attribution. **Attribution needed if these rows are merged into
  `data/eval/`**: credit "Anton Karl Ingason, Lilja Björk Stefánsdóttir,
  Þórunn Arnardóttir, Xindan Xu. 2021. The Icelandic Error Corpus (IceEC).
  Version 1.1. https://github.com/antonkarl/iceErrorCorpus", license CC BY
  4.0, link to the license text. This has **not** been added to
  `ATTRIBUTION.md` — flagging only, per the task's read-only instruction for
  that file.
- **Flagged, not bulk-copied**: `BinPackage`'s `src/islenska/resources/suffix-removals.txt`
  is code-MIT but its *contents* are inflected BÍN word forms — the same
  category of data our own `ATTRIBUTION.md` restricts ("no raw-data
  redistribution" of BÍN). It's 127,423 lines. Only 3 illustrative forms
  are included in the JSONL (`accordsbréf`, `ránarsængurnar`,
  `stórfetaðastrar`), each tagged `CAUTION` in its `license` field. **Do
  not** bulk-import this file into the repo without separately clearing it
  the way BÍN itself was cleared (see `data/ATTRIBUTION.md`'s BÍN section
  and the memory note "BÍN license cleared").
- Two `rejected_pseudo_compound` rows are marked `N/A (derived reasoning,
  not copied data)` — they're constructed from the *design rule* documented
  in Miðeind's code (and restated in our own `Compounds.swift` header
  comment), not copied from any literal Miðeind test assertion. Flagged so
  they're never mistaken for observed test data.

## The 20 most instructive examples

### Valid compounds (protect these — never mangle)

1. **`alþjóðaviðskiptastofnunin`** = alþjóða+viðskipta+stofnunin (3 parts,
   real word, "international trade organization"). Two genitive modifiers
   chained — exactly at our engine's supported ceiling (`≤ 2 modifiers`).
2. **`gervigreindargagnaverin`** = gervi+greindar+gagna+verin (4 parts, "AI
   data centers"). **A real, modern, unremarkable compound that EXCEEDS our
   2-modifier cap** — our `split()` never tries a 3-modifier reading, so
   this word cannot be decomposed at all today. Tricky because it isn't an
   edge case linguistically, just structurally deep.
3. **`gauksstaðamálið`**: BinPackage's own analyzer must actively *choose*
   between two legal-looking splits — 2-part `gauks+staðamál` (head is a
   plurale tantum, i.e. defective paradigm) vs. 3-part `gauks+staða+mál`
   (head has a full paradigm) — and demotes the tantum reading. Our engine
   explicitly does **not** port tantum demotion (documented deviation) and
   our loop tries the *longest head first*, i.e. the 2-part reading, first
   — meaning we likely reproduce exactly the bug BinPackage fixed.
4. **`Suðvesturkjördæmið`** = Suðvestur+kjör+dæmið: capitalized 3-part
   compound where the directional modifier `Suðvestur` stays whole (doesn't
   itself split into suð+vestur in "natural" mode) while the head chain
   still recurses. Tests casing-preservation + modifier-atomicity together.
5. **`morgunverðarhlaðborð`** = morgun+verðar+hlað+borð (4 parts, "breakfast
   buffet"): the possessive modifier `verðar` (genitive of `verður`) is
   itself unpacked from the surface `morgunverðar`. Same 4-part ceiling
   problem as #2, plus a genitive-of-genitive nesting our engine's flat
   2-modifier scan can't reach.
6. **`rauðvínsglas`** = rauð+víns+glas ("wine glass"): the linking `-s-`
   between `rauðvín` and `glas` is genuine BÍN genitive morphology
   (`víns` = gen. of `víni`), the exact mechanism our
   `isModifier()`/genitive-caseCode==3 branch is built to recognize.
7. **`Hallgrímskirkja`** = Hallgríms+kirkja: proper-noun genitive modifier
   (a person's name) as compound head-former — tests that personal-name
   stems clear the paradigms.bin lemma-frequency floor.
8. **`Vestur-Þýskaland`**: a hyphenated compound that is a *whole BÍN
   entry* (West Germany), not resolved by the compounder at all. Boundary
   case: confirms compound logic must never re-split words BÍN already
   has whole — directly analogous to our own "Æðarvarp" guard (below).
9. **`álfabrunnfuglagarðurinn`** = álfa+brunn+fugla+garðurinn (4 parts,
   "elf-well-bird-garden-the") — Miðeind's own tokenizer gold-corpus
   stress word, deliberately picked to be at the edge of plausible
   compounding. Same 4-part-ceiling problem as #2/#5, in a form clearly
   designed by Miðeind as a stress test rather than found "in the wild."
10. **`fjármála- og efnahagsráðherra`** ("Finance and Economic Affairs
    Minister"): coordination-reduction — the shared head `ráðherra`
    elides from the first conjunct, leaving a dangling hyphen
    (`fjármála-`). **Category we have zero coverage for**: this is a
    cross-token phenomenon (tokenizer-level, not our single-word
    `CompoundAnalyzer`), and Miðeind's own Tokenizer has dedicated special-
    case code for exactly this hyphen pattern.

### Rejected pseudo-compounds (negative controls)

11. **`Æðarvarp`**: capitalized form of the real BÍN word `æðarvarp`
    (eider-duck nesting ground). Must resolve via the whole-word entry,
    **not** be split as æðar+varp. BinPackage's guard: the compounder only
    runs when the word is genuinely absent from BÍN in *any* casing.
12. **`ogłosiły` / `będzie` / `zajmowała`** (Polish): non-Icelandic words
    with non-Latin-1 characters must return "no split" cleanly, not crash
    the DAWG lookup. Pure robustness controls — useful as fuzz-style
    negative cases for our own `chars.allSatisfy(\.isLetter)` gate.
13. **`margskonar` / `annarstaðar` / `mikilsháttar` / `samskonar`**
    (GreynirCorrect C002, "wrong compounds"): each *looks* like a legal
    genitive-modifier + noun-head join (e.g. `margs` = strong genitive of
    the adjective/pronoun `margur`, `konar` = a genitive noun form) — the
    exact shape our `isModifier()`/`isHead()` rules are built to accept —
    but the correct spelling is **always** two words. **This is a real gap
    in our over-acceptance guard**: nothing in `Compounds.swift` currently
    distinguishes "morphologically legal join" from "conventionally never
    joined." If a user types one of these as one word, our compound
    protection may wrongly veto the autocorrect split that should fix it.
14. **`accordsbréf` / `ránarsængurnar` / `stórfetaðastrar`** (BinPackage
    `suffix-removals.txt`, CAUTION-flagged): real BÍN-attested inflected
    forms that Miðeind's shipped analyzer deliberately excludes as legal
    compound-head suffixes because every reading is archaic/poetic
    register. Our own header comment documents that we do **not** port
    this list ("suffix-removals.txt is NOT ported... the cost of a bad
    head is a weaker correction, not a wrong one") — these three are the
    concrete forms that decision affects.

### Compound errors ↔ corrections (the corrector-eval gold mine)

15. **`framhaldskóla` → `framhaldsskóla`** (compound-collocation, appears
    twice independently in the corpus — a genuinely common real error):
    the linking genitive `-s-` is dropped at the modifier/head boundary
    (`framhalds` + `skóla` loses one `s`). This sits exactly on the
    modifier-legality boundary our `isModifier()` genitive check enforces,
    and is the shape wave 22's "repair pass 5b" (hold a legal modifier
    prefix fixed, single-edit the head) is built to catch — a real
    corpus attestation that the mechanism has a real target.
16. **`eldneyti` → `eldsneyti`** (compound-collocation): same missing-
    linking-`-s-` class as #15, and close kin to the exact WAVES.md wave-22
    gate example (`eldsnyti→eldsneyti`, a transposition of the same word) —
    independent real-corpus confirmation this error family is common
    enough to matter.
17. **`jafnaðar geði` → `jafnaðargeði`** (split-compound): textbook
    wrongly-split compound — a genitive modifier (`jafnaðar`) typed with a
    trailing space before its head. This is the **mirror image** of our
    existing `space_miss` eval category (which merges two separate words
    that should stay separate) — we have **no eval coverage in the
    opposite direction** (a single compound wrongly split by an inserted
    space).
18. **`Aðal inngangur` → `Aðalinngangur`** (GreynirCorrect C003): same
    wrongly-split direction as #17, MIT-licensed and clean — pairs well
    with iceErrorCorpus's much larger but noisier CC-BY sample.
19. **`Porschebílunum` → `Porsche-bílunum`** (missing-hyphen, the largest
    single error class in the filtered corpus at 812/2,020 rows): a
    foreign brand/proper-noun modifier joined to an Icelandic head without
    the required hyphen. **Likely out of scope** for `Compounds.swift`
    (which has no hyphen-insertion logic at all), but flagged because it's
    the single largest compound-adjacent error category we have zero
    engine coverage for, by a wide margin.
20. **`suðvestur horni` → `suðvesturhorni`** (split-compound): a
    directional-compound sibling of #4 (`Suðvesturkjördæmið`) — same
    modifier family, but here it's the corpus-attested *error* rather than
    Miðeind's own hand-picked test, showing the pattern is real, not just
    theoretical.

## The 5 cases most likely to stress current `Compounds.swift` rules

Ranked by how directly each maps onto a **documented, deliberate deviation**
in the file's own header comment (i.e., these aren't hypothetical — the
code already tells us where it diverges from Miðeind):

1. **`gauksstaðamálið`** (case 3 above) — tests the "no tantum demotion"
   deviation directly. Our longest-head-first loop order means we likely
   pick the *wrong* 2-part split BinPackage itself had to fix with tantum
   logic.
2. **`gervigreindargagnaverin` / `morgunverðarhlaðborð` / `álfabrunnfuglagarðurinn`**
   (cases 2, 5, 9) — tests the "≤ 2 modifiers" ceiling. These are three
   independent real 4-part compounds (one modern-tech, one everyday,
   one Miðeind's own stress pick) that our engine cannot decompose at all
   today — a false-negative (fails-to-protect) risk, not a false-positive
   one.
3. **`margskonar` / `annarstaðar` / `mikilsháttar` / `samskonar`**
   (case 13) — tests the *complete absence* of an over-acceptance guard
   analogous to Miðeind's curated "never actually a compound" list. Our
   rule accepts anything where modifier+head both clear BÍN's
   morphological bar; Miðeind additionally curates against real usage.
   This is the one class where our engine's precision (documented as 0.83
   vs Miðeind's list, with the DEFINITENESS-bit paradigms.bin fix) was
   measured **on acceptance of valid splits**, not on rejection of
   these specific never-compounds — worth an explicit dev-set check.
4. **`framhaldskóla`→`framhaldsskóla` / `eldneyti`→`eldsneyti`**
   (cases 15–16) — directly exercises the genitive-linking-letter
   modifier-legality rule + repair pass 5b, with two independent
   real-corpus attestations of the exact error shape wave 22's gate
   analysis was built around.
5. **`Æðarvarp`** (case 11) — tests whether compound analysis is correctly
   gated to OOV-only lookups. Our engine's docstring says "protection ≠
   generation" and compound validity should only run when a word isn't
   otherwise resolvable; this is Miðeind's own explicit regression test for
   exactly that gate (a real BÍN word whose capitalized surface form must
   not be mis-split).

## Categories with no coverage at all

- **Coordination-reduction / elliptical compounds** (`fjármála- og
  efnahagsráðherra`, `tösku- og hanskabúðina`): cross-token phenomenon,
  a completely different mechanism from single-word splitting. Zero
  engine coverage; likely out of scope for `CompoundAnalyzer` as designed,
  but worth a conscious decision rather than silent absence.
- **Missing-hyphen errors** (812/2,020 of the curated corpus, the single
  largest class found): foreign/proper-noun modifier + Icelandic head
  without the required hyphen. No hyphen-insertion logic exists anywhere
  in the engine.
- **3+ modifier chains**: real, unremarkable modern compounds (AI/tech
  vocabulary especially) routinely need 3 modifiers; engine caps at 2.
- **Tantum/defective-paradigm demotion**: documented as skipped; confirmed
  as a real behavioral gap via `gauksstaðamálið`.
- **Curated "never a real compound" list** (Miðeind's negative curation
  beyond pure morphological legality): `margskonar`-class errors have zero
  guard today.
- **Register/archaic-form exclusion** (`suffix-removals.txt`): documented
  as not ported; a bad head can surface in generated suggestions (though
  not in auto-apply, per the "protection ≠ generation" wiring).

## Files produced

- `research/mideind-compound-cases.md` — this file.
- `research/mideind-compound-cases.jsonl` — 2,052 rows, schema:
  `{"cls": "valid_compound"|"rejected_pseudo_compound"|"compound_error",
  ...class-specific fields..., "source_repo", "source_file", "license"}`.
  `compound_error` rows use `{typo, intended, subtype, error_code}` to
  match `data/eval/dev.jsonl`'s `{typo, intended}` shape (context/lang/seed
  are not populated — these are cross-corpus rows, not drawn from our own
  eval sentence pool, so merging into `data/eval/` would need a deliberate
  follow-up pass, not a blind concat).
