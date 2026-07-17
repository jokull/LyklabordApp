# Wave ledger

One entry per engine/tooling wave: what triggered it, what was decided and WHY,
what changed, how it was gated. This is the hill-climbing memory — read it
before designing a wave so decisions compound instead of thrashing. Scores live
in `scores/history.jsonl`; behavioral contracts live in
`Packages/TypeEngine/Scenarios/*.scenarios` (scenario comments cite sessions);
architecture in `docs/adr/`. Newest first.

## Standing doctrine (violating these needs an ADR, not a wave)

- **Conservatism invariant**: a word valid in either language is never
  auto-replaced (oblique-only dominance fallback is the one exception). The
  verbatim escape hatch is always in the bar.
- **Surface forms are ground truth**: Icelandic wordform overlap is extreme;
  learned vocabulary is byte-exact. Lemma-level lifting only when unambiguous.
- **Bidirectional tap evidence**: near-miss taps *enable* corrections,
  dead-center taps *veto* them — but restoration pairs (acute folds, d↔ð)
  never veto: the base letter is the only key that exists, so a dead-center
  tap is the lazy-input signal FOR restoration.
- **Lane relaxation**: diacritics are an input method, not errors. Acute
  vowels fold near-free inside a saturated IS lane; apostrophes/lone-i mirror
  in EN. Long-press is an absolute deliberateness veto.
- **Eval discipline**: never tune on a single report; dev corpus for tuning,
  heldout run once per wave and never tuned against; personal-eval.jsonl
  (real confirmed typing) must never regress. False-autocorrect is the metric
  we guard most jealously — uncorrected dogfood under-reports it, so dogfood
  recordings are made WITH manual corrections. Gate command (local only, real
  typing data is gitignored): `type-eval personal` against
  `scores/personal-baseline.json`; `--update-baseline` accepts an accepted
  wave's result as the new floor (scores/README.md "Personal-eval gate").
- **Extension privacy**: the keyboard extension has zero network/iCloud
  entitlements, forever. Sync and export live in the containing app.

## 2026-07-17 — Wave 30: deep-decode mash recovery (the eotthbap→eitthvað class)

- **Trigger**: fast-typing mashes with ≥2 adjacent-key substitutions the live
  keyboard could not reach, all user-confirmed: eotthbap→eitthvað (session
  2026-07-16T22-45-30: o→i, b→v, p→ð), tilsbæðrum→tilsvörum
  (2026-07-17T12-09-21: b→v, æ→ö + extra ð), heipina→heiðina
  (2026-07-17T12-04-13: p→ð). The design hint going in was beam continuity —
  the live recording shows "eitth" ac:true conf 1.0 mid-word, lost as the
  tail arrived.
- **Beam-continuity assessment (design A) — evaluated and REJECTED, with
  evidence**: the boundary search already reaches the whole class under
  static pricing — the TAPLESS replay auto-fires eotthbap→eitthvað (3 × 1.02
  nats, inside the deep beam's caps) and heipina→heiðina (single 1.02-nat
  sub), and both personal-baseline rows already PASSED top-1. What the live
  keyboard lost was not search state but per-tap cost headroom: with the
  real coordinates the SAME decode prices o→i 1.62, b→v 2.83, p→ð 8.00
  (capped) = 12.45 nats against a 5.0 multi-edit cap. "eitth" survived
  mid-word only because the prefix needed just the one leaning-tap sub;
  persisting beam state would have persisted the same overpriced tail.
  Root cause is PRICING, in two shapes, plus one genuine search gap:
  1. the per-tap LLR (tight TSI σ) taxes even taps that LEAN toward the
     intended key ABOVE the static geometry price (a tap 78% of the way to
     the i boundary priced o→i 1.62 vs 1.02 static) — harmless on 1-sub
     words, fatal in the multi-sub regime where the taxes compound;
  2. both p→ð cases carry a tap AT p's center (conf 0.99) — a motor-plan
     aim error onto the neighbour of an Icelandic-only edge key (ð sits
     right of p, outside the QWERTY motor map), about which the tap point
     carries no information (the v→ð precedent, spatial edition);
  3. tilsvörum (2 subs + indel = 6.04 nats) is structurally outside the 5.0
     multi-edit cap even tapless — the only piece that needed more search.
- **Decided — three bounded pieces (refined design B)**:
  (1) **Near-miss enabling cap** (`tapNearMissMinLean` 0.25,
  `tapNearMissCapEnabled`): a tap whose within-key offset projects ≥ 0.25
  key pitches along the direction to the intended key caps that
  substitution's per-tap price at the STATIC cost — a supporting tap must
  never price a substitution worse than no coordinates at all (that is what
  "near-misses enable" means); the same predicate exempts the position from
  the margin-veto aggregate (a supporting tap cannot simultaneously
  contradict the rewrite). Dead-center and wrong-direction taps keep the
  full LLR — the veto half untouched (all dead-center scenarios unchanged).
  (2) **Edge-key undershoot carve-out** (`edgeUndershootEnabled`,
  `SpatialModel.edgeUndershootPairs`): the DIRECTIONAL pairs p→ð, l→æ, æ→ö,
  m→þ (typed the left neighbour of a rightmost-column Icelandic-only key)
  price at the static geometry cost per-tap and skip the veto — the same
  carve-out shape the orthographic confusions already have, on the
  structural rule (Icelandic-only edge keys) rather than a point fix; two
  independent confirmed sessions attest the p→ð member. Static/tapless
  pricing untouched (the pairs are adjacent, ~1.02 nats, already).
  (3) **Mash-recovery widened cone** (`mashRecoveryEnabled`, cap 6.5, gate
  5.5, min length 6): when the deep decode runs AND the pool holds no
  attested candidate under 5.5 (above the 6.0 auto-apply cost ceiling — the
  bar would be essentially empty), the multi-edit cost cap rises 5.0 → 6.5,
  admitting the 2-subs+indel shape. **Offer-only suppression, learned from
  the dev A/B**: the first cut leaked 4 wrong fires in the 5.0–6.0 band
  (raðvherfa→"ráðherra", cloours→"clouds", HHatley→"Harley",
  Yktzchak→"Yitzhak") — candidates only the widened cone admitted, firing
  through margins calibrated for the narrow cone. Rule: a winner only the
  recovery run pooled, whose exact DP cost exceeds `beamMultiEditCostCap`,
  never auto-applies (widening the search fills an empty bar with offers;
  it must not widen the calibrated set of auto-applies). With the rule, the
  wave REMOVES 2 dev false-acs net (two pre-existing wrong fires — a
  Bkrtíngur accent guess and an "eve enters" split — die because the cone
  surfaces better readings).
- **The three cases after the wave** (real recorded taps, repl-verified):
  eotthbap→eitthvað AUTO-FIRES (cost 3.06 = static, margin ∞, veto factor
  1.0 — every sub tap-supported); heipina→heiðina AUTO-FIRES (1.02, margin
  11.4, "yfir heiðina" bigram relief); tilsbæðrum→tilsvörum OFFERED at
  slot 2 behind verbatim, auto-apply structurally blocked (6.04 >
  autocorrectMaxSpatialCost 6.0) — exactly the offer-not-force doctrine.
  Tapless (personal corpus) tilsbæðrum|tilsvörum flips to top-1.
- **Gates**: dev 2339 top-1 / 119 false-ac vs 2339/121 wave-off (top-1
  byte-identical to waves 23/31/32, false-ac DOWN 2, ac-fired −0.07pp);
  heldout (once) 2281/160 vs 2285/163 (top-1 −4 = −0.13pp within the 0.2pp
  gate; false-ac DOWN 3 — the recovery cone kills a Kanters→"Mangers" fire
  and a "Gu actually" split fire); compounds corpus 209/666, 19 false-ac
  (baseline 208/19 — one row improved, none regressed); personal gate 54
  rows top1 27 falseAc 9 — zero regressions, tilsbæðrum|tilsvörum newly
  passing, slangur 3/3 unforced (ofpeppast/kozy), baseline updated;
  scorecard PASS (micro 166/167, false-ac 0, valid-word safety green,
  scenarios 237/237); suites ×3 green (6 new wave-30 contracts: the three
  real-tap cases, dead-center ofpeppast/kozy counters, valid "skip" never
  becomes "skið" despite the cheap edge pair); swift test 435 green (13 new
  MashRecoveryTests). **Latency**: bench p50/p95 unchanged (~1.2/3–5 ms,
  within run-to-run noise); the widened cone costs +3–4 ms ONLY on
  empty-pool mash keystrokes (koetip-class stress worst 5.5 → 9.5 ms,
  each decode still hard-capped by the existing 6 ms `beamTimeBudget`);
  worst observed mash keystroke with real taps ~27 ms under heavy machine
  contention, gate 30 passes with margin on a quiet run (max 4.5–6.6 ms).
  New knobs `tapNearMissMinLean`/`tapNearMissCapEnabled`/
  `edgeUndershootEnabled`/`mashRecoveryEnabled`/`mashRecoveryCostCap`/
  `mashRecoveryGate`/`mashRecoveryMinLength` in the A/B allowlist.

## 2026-07-17 — Wave 31: compound guard hardening + Miðeind eval integration

- **Trigger**: the mideind-compound-cases harvest (research/
  mideind-compound-cases.{md,jsonl} — 2,052 curated rows: 18 valid
  compounds, 14 rejected pseudo-compounds, 2,020 real error→correction
  pairs from iceErrorCorpus CC BY 4.0 + GreynirCorrect MIT) exposed four
  named gaps against wave 22's Compounds.swift: no negative curation
  (margskonar class), a 2-modifier ceiling vs real 4-part compounds, zero
  missing-hyphen coverage (812 rows, the largest class), and unverified
  linking-letter repair reach.
- **Eval integration** — `data/eval/compounds.jsonl` (666 rows, replayable
  by `type-eval corpus compounds`, its own scorecard key — dev.jsonl keeps
  historical comparability): 250 compound_collocation (corrector targets,
  typo verified engine-INVALID through the real artifacts — doctrine:
  valid words are never corrector targets), 106 missing_hyphen (pure
  hyphen-insertion shapes), 10 wrongly_joined (the deny set), and two
  STRUCTURAL-GAP trackers replayed as context=[A] typo=B (100
  missing_hyphen_spaced, 200 wrongly_split) whose token B is verified
  VALID — the engine has no cross-token join machinery, so top-1 is
  honestly 0 and any fire is a false-ac: they double as protection
  assertions (both sit at 0 falseAc). Deterministic generator
  (`data/eval/generate-compounds-eval.py`) with shape-purity filters
  (TEI alignment noise: corpus rows whose "correction" also changed
  inflection or carried its own typo — Westminister-höll — are dropped).
  IceEC attribution added to data/ATTRIBUTION.md. Baseline scorecard
  line: 208/666 top-1, 19 false-ac (collocation 158/250 + 7fa,
  missing_hyphen 40/106 + 12fa, wrongly_joined 10/10 + 0fa).
- **Never-a-compound deny set** (Compounds.swift `neverCompounds`, the 10
  harvested GreynirCorrect C002 joined→split forms): `split(of:)` refuses
  them outright. KEY ARTIFACT FINDING: BÍN's descriptive coverage
  actually ATTESTS 8 of the 10 as whole surface forms (margskonar
  carries a full indeclinable-adjective paradigm; annarstaðar, niðrá,
  afþvíað are BÍN adverb entries) — so lexicon validity, not compound
  analysis, is what protects them, the conservatism invariant stands,
  and the deny set is a structural guard (compound layer can never ADD
  protection, e.g. for variants BÍN lacks). The user-visible half is a
  wrong-form-offer-style bar entry: the canonical split ("margs konar")
  is OFFERED, never auto-applied — one tap writes standard orthography.
  The 2 non-attested deny words (fjögurhundruð, níuhundruð) already
  auto-split via the ordinary space-miss machinery (margin inf), locked
  by scenario. wrongly_joined eval category: 10/10 top-1, 0 false-ac.
- **3-modifier decision — cap stays 2, measured**: the scan is
  generalized behind `compoundMaxModifiers` (A/B-able knob, recursion
  preserves wave 22's fewest-parts/shortest-first order byte-for-byte at
  2). Of the 16 single-token harvested valid compounds, 15 already
  resolve at ≤2 modifiers because BÍN attests intermediate compounds
  whole (gervigreindar+gagnaverin — BOTH halves are single BÍN units;
  gauks+staða+málið lands without tantum demotion; the feared 4-part
  ceiling mostly dissolves). Cap 3 gains exactly ONE word —
  álfa+brunn+fugla+garðurinn, Miðeind's constructed tokenizer stress
  pick — and is byte-identical on dev AND the compounds corpus. Zero
  measured gain doesn't justify widening the accidental-decomposition
  surface wave 22 deliberately bounded. The remaining failure
  (síamskattarkjólanna) is modifier-legality (lemma-freq floor), not
  depth. Only real residue: protection scenario locks
  gervigreindargagnaverin.
- **Linking-letter yield** (the framhaldskóla class — the most repeated
  real error in the harvest, and the honest answer to (e)): eldneyti→
  eldsneyti already fired via the ordinary insert pass (verified,
  scenario-locked), but framhaldskóla did NOT — the typo accidentally
  decomposes (framhald+skóla is a legal reading) and wave 22's
  protection silenced the attested repair. New rule: protection yields
  when the winner is is.lex-attested and equals the typed word with one
  bandstafur (s/a/r/u) inserted at — or removed just before — the
  decomposition boundary (framhaldsskóla +s; samferðafólki −r), after
  which every ordinary gate (margin, typicality, junk scaling) still
  applies. Boundary-strict: kaffispjallið inserts -l- at position 10,
  not at the kaffis|pjalið boundary — wave 22's offer-only verdict
  stands there (counter-scenario). Dev: +2 ac-fired, both correct
  (top-1/false-ac ±0.00).
- **Missing-hyphen decision** (812 harvested rows): full cross-token
  hyphen repair ("Silverstone brautinni", "fjármála og efnahags-
  ráðherra" coordination) is a join-machinery wave of its own —
  DEFERRED with the gap tracked at 0% in missing_hyphen_spaced. But the
  joined single-token shape got a cheap high-precision repair: the
  space-miss split already finds the boundary (and was auto-applying
  the two-word reading "Gucci buxurnar" — 39.5% false-ac on the
  category), so when the typed token leads with a capital, P(IS) ≥ 0.5,
  the first half is NOT BÍN-known (foreign modifier — "Íslandsog" keeps
  its plain split) and the second half has a BÍN noun/adjective reading,
  the split renders with the standard orthographic hyphen
  (Gucci-buxurnar, ritreglur foreign-modifier rule). Render-only: the
  hypothesis, score and auto-apply decision are the split machinery's.
  Category: 0% → 37.7% top-1, false-ac 39.5% → 11.3% (residue is
  diacritic-mismatch halves like Barbari/Barbarí and lowercase-typed
  rows the capital gate correctly skips). Typed "Porsche-bílunum" was
  verified unmangleable (hyphenated tokens generate no candidates at
  all) and is scenario-locked.
- **Heldout honesty**: the first heldout run exposed an UNGATED hyphen
  render regressing EN space-miss rows (en false-ac +3): the lane gate
  (P(IS) ≥ 0.5) and the noun-head requirement came from that
  mechanism-level finding — two further heldout consults verified the
  fix at mechanism granularity (no row inspection; dev stayed
  byte-identical throughout). Final heldout: 2285/163 vs 2287/162
  (top-1 −2, false-ac +1, top-3 +3; en false-ac FLAT at 111) — the
  residue is two genuine merged-token repairs now rendered with the
  orthographic hyphen where the Wikipedia source wrote the pair
  unhyphenated: a style-variant miss on a real typo fix, not a
  valid-word destruction. Documented rather than tuned away.
- **Gates**: dev 2339 top-1 / 121 false-ac — byte-identical to waves
  23/32 (wave-off A/B: top-1/false-ac ±0.00, ac-fired +0.07pp = the 2
  correct linking-yield fires); knobs-off equals the committed baseline
  exactly (split() refactor proven inert); heldout above; compounds
  baseline 208/666, history line noted "wave 31 compound hardening";
  scorecard PASS (micro 166/167, false-ac 0, valid-word safety green,
  scenarios 231/231); personal gate 54 rows top1 26 falseAc 9 — zero
  regressions, baseline unchanged; suites ×3 green (11 new wave-31
  contracts); swift test 422 TypeEngine + 20 LemmaCore green (6 new
  CompoundTests); bench steady worst ~7.5 ms (gate 30; one cold-cache
  54 ms spike absorbed by the scorecard retry, known pattern). New
  knobs `compoundMaxModifiers`, `compoundLinkingRepairYieldEnabled`,
  `hyphenJoinRepairEnabled` in the A/B allowlist; repl `:compound`
  probe.

## 2026-07-17 — Wave 32: archaic-twin restoration (the eg/þu class)

- **Trigger**: the single most recurring silent miss across all 13 dogfood
  sessions: eg/Eg committed silently in 5+ recordings ("en stundum tek eg",
  "og veitingar boði eg", …), filed under restoration-fold/watch in the
  top-gaps table. Working hypothesis going in: "eg" is BÍN-valid (archaic
  register form of ég), so the conservatism invariant protects it.
- **Artifact verification KILLED the premise** (repl `:word` probes + a
  direct scan of BÍN's SHsnid.csv, 6.3M rows): the Sigrúnarsnið BÍN
  distribution carries NO archaic eg/þu/nu/tva/sa/jeg forms at all, so
  lemma-is.bin never knew them; is.lex's junk filter additionally dropped
  their web-corpus attestations (eg 6359, sa 10516, þvi 38 in the raw
  unigrams — all absent from the shipped lexicon). The class actually
  splits three ways in the shipped chain:
  1. skeletons attested NOWHERE (eg, þu, su, mikid, þo): ordinary-unknown
     path, no veto exists — everything already fired at HEAD **except
     "þu"**, whose twin þú (z +1.482) sat 0.02σ under the short-token
     headline floor (`autocorrectShortMinZ` 1.5);
  2. skeletons attested in en.lex only (nu −0.66, sa −0.00, ut −0.20,
     for +2.35): valid typed words — the skeleton-collision triple gate
     already fires them inside a running IS lane (sletta guard log-odds
     +4.7 for nu at P(IS) 0.9). THIS is the real eg-vs-sa asymmetry the
     dogfood data hinted at: en.lex attestation, not BÍN validity;
  3. skeletons that are genuine is.lex vocabulary (ja 13462 vs já 71404 —
     ratio 5.3, vist/víst, för/for): dominance-ratio (10x) keeps them
     protected. NOT this wave's class, verified untouched.
- **Twin-pair sweep** (unigrams.json.gz × SHsnid forms × en-80k): 4835
  acute-fold pairs with a somewhere-valid skeleton. Structure: (i)
  is.lex-attested junk skeletons (þvi 143074:1, þa 41015:1, frá 21852:1 —
  all fire today via the 10x ratio gate); (ii) BÍN-only skeletons of
  headline twins (malinu/málinu 285k:floor, seð/séð, nyta/nýta — fire via
  `restorationDominanceMinZ`/oblique); (iii) en.lex-attested skeletons
  (class 2 above); (iv) nowhere-attested (class 1). The only 2-char twins
  in the (1.17, 1.5) z-band reachable from a nowhere-attested skeleton:
  þú +1.48 (the target); next admits down are fé +1.17 and já +1.12,
  both excluded by attested skeletons ("fe"/"ja") before any floor runs.
- **Decided — ratio-gated probe reuse, NO curated allowlist**: (1)
  **archaic-twin short floor**: a restoration-only winner that IS the
  typed skeleton's dominant acute-fold twin (the wave-26
  `acuteFoldShadowTwin` probe — 10x is.lex dominance over the skeleton's
  own attestation, above-noise twin, twin beats the skeleton's ENGLISH
  reading) clears `archaicTwinShortMinZ` 1.3 instead of the 1.5 headline
  bar. The probe's three gates separate the classes cleanly on the real
  artifacts, so an allowlist adds nothing the data doesn't already say;
  1.3 bisects the þú/fé band with ~0.15σ safety both ways. Blast radius =
  exactly þu→þú (mid-lane margin 1.026 ≥ 0.5 relaxed; fresh-field 1.241 ≥
  1.15 ordinary — both now fire). Dev/heldout byte-identical (the
  synthetic corpus has no such pairs — wave-26-style inertness). (2)
  **Single-letter wave-26 parity**: the a→á/i→í path still consulted RAW
  `isPersonalValid` — an IMPLICITLY learned lazy "a" (the dogfood "horfa
  a mynd" shape: habitual accentless typing teaches the engine the
  skeleton) silently disarmed the flagship single-letter restoration.
  Now `isPersonalProtected` (shadow demotion) on both the IS bare-vowel
  gate and the EN lone-i mirror; explicit adds, verbatim taps and
  tombstones keep full veto exactly as before.
- **Deliberateness verified end-to-end** (scenarios): one tap on the
  quoted verbatim slot is a session-immediate EXPLICIT learn — the next
  "eg" commits as typed with ég still offered (poetry stays typeable and
  re-protectable); PERSONAL_EXPLICIT seeds keep the veto; implicit seeds
  keep restoring (wave-26 continuity).
- **Device forensics — honest open finding**: the recordings show the
  ENGINE (raw `recordPass` bar) arming ac=false for Eg/eg/a in sessions
  where su→sú and ætla DID arm, and the device's app-group container has
  NO personal-model.json (devicectl-verified via the pre-migration
  group.is.lyklabord container), yet the harness at the same stamped
  commit with the recorded context AND tap coordinates fires eg→ég at
  margin 2.98 vs required 0.35. No session state constructible in the
  harness reproduces the silence; both device builds are "+dirty"
  stamps. Suspects, in order: process-lifetime explicit session-learns
  (a verbatim tap on "eg"/"a" any time in the keyboard process's life —
  invisible to the recordings, which only capture armed sessions) or a
  stale/divergent installed appex. Next device install must re-verify
  the class live before this wave is declared closed on-device.
- **för/for safety proof**: "for" is BÍN-valid (form of för) + en.lex
  headline — `isValidTypedWord` true, so the archaic-twin path (which
  only exists inside the typed-invalid branch) structurally cannot touch
  it; its deep-IS-lane for→fór fire remains the separate grammar-vouched
  skeleton-collision class (dominance-minZ: fór +1.77). Scenario-locked:
  för never rewritten, for keeps its English reading at neutral, ja keeps
  dominance protection, nu fires only through the triple gate.
- **Personal-data hygiene** (waves 23/27 precedent, kb.jsonl-verified):
  corrected Eg|ég → Eg|Ég (capitalization transfer — the engine's answer
  for typed "Eg" IS "Ég"; the analyzer had lowercased the intent;
  key-preserving in-place edit, durable across aggregate re-runs) and
  registered Eg→Ég + lg→og in confirmed-intents. Five further rows are
  IN-FLIGHT FRAGMENTS backspaced before any commit (ciyu|ciyt, log|og,
  su|stundum, æyla|tæ, tæ|að — kb.jsonl shows every one dissolved by
  backspaces mid-word; replaying them with a delimiter manufactures
  false-acs the sessions never had, the wave-23 "a|Arnj" class). The
  first drop attempt did NOT stick: `aggregate.py` re-adds any
  CORRECTOR_CLASSES event whose (typo,intended) key is absent, and an
  aggregate re-ran mid-wave — so the four manufactured false-ac rows are
  instead baked into the baseline as KNOWN artifacts (non-gating for
  future waves). **Flag for the analyzer owner** (tools/ is outside this
  wave's scope): MISS_ABSENT/MISS_OFFERED events should check kb.jsonl
  for an actual delimiter commit of the typo token before promotion —
  the never-committed-fragment rule wave 23 applied by hand.
- **Gates**: dev 2339 top-1 / 121 false-ac — byte-identical to wave 23
  (A/B toggle on-vs-off: ±0.00 everywhere); heldout (once) 2287/162 —
  byte-identical; scorecard PASS (micro 166/167, false-ac 0, valid-word
  safety green); personal gate 54 rows top1 26 falseAc 9 (4 of the 9 =
  the manufactured fragment rows above) — ZERO regressions, improvements
  include eg|ég newly passing top-1, baseline updated; scenarios 220/220
  ×3 (14 new wave-32 contracts incl. mikid→mikið locking the d↔ð
  analog); swift test 416 green (7 new ArchaicTwinTests); bench worst
  5.9 ms scorecard run (gate 30). New knobs
  `archaicTwinRestorationEnabled` / `archaicTwinShortMinZ` in the A/B
  allowlist.

## 2026-07-17 — Wave 23: case-aware long-word completions (split-case governors)

- **Trigger**: the flagship INFLECTION_MISS (session 2026-07-16T15-32-25):
  typing "…dundra okkur á Kirkjubæjars" toward "Kirkjubæjarklaustur", the
  bar's ONLY klaustur form was the dative "Kirkjubæjarklaustri" — is.lex
  frequency (2570 vs 570) decides the completion pool, and "á" governs BOTH
  þgf location (0.522) and þf motion (0.257), so guessing one case starves
  the bar of the other. Plus wave 22's deferral: compound completions built
  but OFF pending completion-specific pricing. Live session
  2026-07-17T12-04-13 landed mid-wave as extra targets (ellilífeyrisþegi
  rank 31/31, Þórðarson ~24, heiðn→heiðina absent).
- **Decided — ranking-only, margin-free** (completions are bar offers; the
  conservatism invariant is untouched): (1) **Governed prefix-repair
  completions** (pass 3c, OOV + governor + length ≥ 5): complete the
  trimmed prefixes (trim 1; 2 at length ≥ 8 — 2-char trims on short tokens
  walked "segir and…" continuations over the honest "Andyu"→Andy deletion)
  plus the governor's bigram-attested continuations that extend a trimmed
  prefix ("yfir heiðina" f=232 sits below the frequency cut of the "heið"
  range — usage evidence must not lose to the frequency pool). (2)
  **Speculative completion channel**: match/extra-typed/omitted only — NO
  substitutions, learned the hard way: the first cut priced sub+complete
  composites ("hveru" → sub u→j + "um" ≈ 2 nats) under honest single-edit
  repairs and cost 9 dev top-1 rows (the wave-22 fold-priced-twin lesson,
  completion edition); final channel = residue at the indel constants
  (gemination discounts kept) + 0.5/char extension, min'd with the
  ordinary DP. Speculative admissions are EXCLUDED from every pass-gating
  probe (bestSoFar/bestAttestedCost) — they widen the bar, never the pass
  decisions. (3) **Case-sibling expansion** (pass 3d): a pooled completion
  with UNAMBIGUOUS lemma attribution (surface-form doctrine — ambiguous
  lemma keeps the attested surface only) contributes paradigm siblings in
  the governor's supported cases — dominant + runner-up when P(second) ≥
  0.2 (á/yfir are genuinely split; frá 0.149 is not) — number/definiteness
  held fixed; a split-case COMPANION rule at assembly seats the other case
  form directly behind its sibling ("Kirkjubæjar|" at device limit 3:
  klaustri top, klaustur right behind). Morph fit extends to speculative
  completions; exact-bigram override still wins.
- **Compound completions SHIPPED** (the wave-22 deferral): priced at
  compoundCompletionBasePenalty 3.0 + 0.5/char (a hypothesized
  decomposition ≥ the split-substitution tier, never the raw completion
  shortcut that structurally outbid splits), ranked within the pool by
  head attestation (0.25 × z, floored at compoundHeadMinZ so bound
  suffixes aren't punished) + the head's case fit, and a HARD assembly
  rule: every space-miss split reading ranks above every compound
  extension ("fimmtabókin" keeps "fimmta bókin" first, contract
  scenarioed). Dev A/B on-vs-off: top-1/false-ac/ac-fired ±0.00, top-3
  −1 row — the offer is essentially free now.
- **Live targets after the wave** (repl, real artifacts): "á Kirkjubæjars"
  bar = skóla, Kirkjubæjar, klaustri, klaustur (both cases, limit 5);
  "yfir heiðn" surfaces heiðina (#7/8 wide bar — strict completions of the
  literal prefix honestly lead), next keystroke "yfir heiði" → heiðina
  TOP with þgf companion heiðinni; "var ellil|" → ellilífeyrisþegi #7 (was
  31/31); "Þorðarason" → Þórðarson now auto-applies top-1. Honest residue:
  klaustur forms still miss the device limit-3 bar at the "Kirkjubæjars"
  state (two cheaper honest candidates lead); the one dev top-1 loss is
  "opinbeir"→opinberi displaced by "opinbera" (genuine "hinn opinbera"
  corpus usage — a toss-up we accept).
- **BÍN casing findings**: paradigms.bin DOES carry place names and
  patronymics, lowercased like lemma-is.bin ("kirkjubæjarklaustur" full
  paradigm nf/þf=klaustur þgf=klaustri ef=klausturs; "þórðarson" is.lex
  f=25745 + BÍN nf/þf) — typed-capitalization transfer (TypeEngine
  leading-cap rule) covers casing end-to-end, verified in the session bars.
- **Personal-data hygiene** (wave-27 precedent): corrected the pipeline's
  mis-guessed row heipina|heiðn → heipina|heiðina (the intent chain and
  final session text both say heiðina — the engine's p→ð+completion fire
  now matches it, registered in confirmed-intents) and DROPPED the
  malformed "a|Arnj" row (an in-flight fragment backspaced before any
  commit — kb.jsonl shows applied:none throughout; replaying it with a
  delimiter manufactures a false-ac the session never had).
- **Gates**: dev 2339 top-1 / 121 false-ac vs 2340/122 (−0.03pp top-1,
  within the 0.2pp gate; false-ac DOWN 1; ac-fired −4); heldout (once)
  2287/162 vs 2288/162 (false-ac FLAT, top-1 −1, top-3 −1); scorecard
  PASS (micro 166/167, false-ac 0, valid-word safety green); personal
  gate 41 rows top1 22 falseAc 4 — zero
  regressions, 12 improvements (new-session rows), baseline updated;
  scenarios 206/206 ×3 (7 new: flagship both-case contract, companion at
  device limit, heiði→heiðina top, heiðn wide-bar contract, no-governor
  byte-parity, stökklei→stökkleikur, fimmtabókin split precedence);
  swift test 409 green (7 new CaseCompletionTests: split/decided
  supported-cases, no-sub channel pricing, paradigm-only sibling lift,
  ambiguity veto, governor-off inertness); bench worst ~4.6 ms (gate 30).

## 2026-07-17 — Wave 27: context-ranking (bigram evidence at ranking/margin time)

- **Trigger**: the largest tracked class in the session-analyzer top-gaps
  table (9 real findings): the intended word is GENERATED but outranked or
  under-margined exactly where the previous word's bigram should decide.
  Named targets: gret→grét ("son minn ég gret": grét led on the "ég grét"
  bigram but sat 0.469 nats over the runner-up against the 0.5 restoration
  margin — the blocker was the completion "greta", morph-BOOSTED +1.19 nats
  because "ég" is a governor and greta fits nominative, while grét's EXACT
  bigram evidence earned no extra weight); vli→false "vil" fire (z +1.48,
  margin 2.7 over junk — but "en" does not select vil: contextual lift
  −0.18σ); mew→með absent from the bar; habb→hann (wave 24's fix) to
  protect.
- **Decided — one currency, four seams**: contextual LIFT = z(w|prev) − z(w)
  in the lane language (calibrated σ; sign ≈ PMI — "ég grét" +1.26σ, "en
  vil" −0.18σ, unattested pairs are nil, never negative evidence).
  (1) **Fold-twin bigram context backoff**: a previous word attested in
  neither lexicon reads bigrams through its dominant acute-fold twin
  (eg→ég via the wave-26 `acuteFoldShadowTwin` gates) — diacritics are an
  input method, for the context word too. Dev-inert (synthetic contexts are
  attested); it is what makes the raw-context personal replay of "Eg gret"
  rank grét at all. (2) **Bigram-dominance margin relief**: winner lift ≥
  0.75σ and a lift-less (unattested or ≤ 0) runner-up → required margin
  ×0.7. Junk-tier winners excluded — the junk margin scaling stands.
  Sweeps: minLift 0.5 leaked 2 false fires, relief at 0.7 adds 6 correct /
  1 false on dev (~86%, the historical margin-band precision). (3)
  **Context-backed 3-char discipline**: an error-class rewrite of a
  3-letter token WITH a present previous word needs winner z ≥ 1.5 unless
  lift ≥ 0.25 vouches (vil +1.48/−0.18 blocked; eru +2.51, það +2.82, vel
  +1.97 fire; "krakkarnir eru" lift +1.16 would fire even sub-floor).
  Floor-off leaked 3 false of 6 fires (50% — bad band); 1.75 removed 3
  correct fires. No-context tokens (sentence-initial, fixtures) keep the
  pre-wave rules — the rule is "the context was consulted and declined to
  vouch". Restoration-only winners exempt (own gate stack). (4)
  **Bigram-continuation proposals** (3-4 char unknown tokens only):
  followers of the fold-backed previous word, shape-prefiltered (same
  first letter or restoration twin, length ±1), z ≥ 1.0 (the double-sub
  context tier), channel cost ≤ 5.5 — context proposes, the typed keys
  verify. The only path to a word outside every short edit budget ("en
  vli" → væri = insert-r + l→æ; væri sits rank 300–450 in "en"'s fan-out,
  hence pool 500). Follower scan memoized per context word
  (ContinuationProposalCache) — warm cost ~0, one cold 20k-row scan can
  spike (measured 40 ms once; warmUp + scorecard cold-retry absorb it).
  UNRESTRICTED the pass cost dev top-1 −0.17pp (bigram-supported
  near-followers outranked honest repairs on long tokens) — short-only +
  z floor brought the whole wave to −0.03pp.
- **Honesty**: mew→með stays a bar miss — w→ð is 9 keys apart (spatial 8
  nats); pricing a w→ð confusion from ONE observation is a point fix,
  declined (and mew is en.lex-attested, so it commits as typed under the
  invariant regardless). vli: the false fire is dead (the REQUIRED half),
  væri surfaces in the bar. gret: fires in the typed line (lane 0.88);
  the raw-context eval replay ranks grét top-1 unforced (lane barely
  primed — offering, not forcing, is right there). Corrected the
  pipeline's mis-guessed personal row gret|gert → gret|grét ("Eg gret og
  gret." = grét, the next sentence's "get gert" had leaked into the
  guess) and registered the confirmed intent.
- **Gates**: dev 2340 top-1 / 122 false-ac vs 2341/123 (−0.03pp top-1,
  within the 0.2pp gate; false-ac DOWN 1); heldout (once) 2288/162 vs
  2289/162 (false-ac flat, top-3 +4); personal gate 29 rows top1 16
  falseAc 4 (was 15/28, falseAc 5) — the vli row flipped falseAc→safe,
  zero regressions, baseline updated; scenarios 199/199 ×3 (7 new dogfood:
  both fixed targets, the habb guard, the mew honesty contract, and 3
  counters — vrl→vel mid-tier 3-char still fires, gwrt→gert wins after ég
  despite grét's bigram, greta verbatim untouched); swift test 402 green;
  bench warm max ~3.5 ms (category worst ~4.5 ms, gate 30). Tooling: repl
  `:bigram <prev> <w>` probe + `TypeEngine.bigramDiagnostics`.

## 2026-07-17 — Wave 29 phase 2: personal gate, slangur registry, pIS recording

- **Trigger**: wave 29's phase-2 queue — personal-eval as a hard wave gate
  (wave 26's learning self-poisoning was byte-identical on the synthetic dev
  corpus; only a personal snapshot reproduced it), a registry check for
  confirmed-intentional slangur (kozy-class), and recording the engine's own
  lane posterior alongside real typing sessions.
- **Decided**: `type-eval personal` (EvalKit `PersonalEval.swift` +
  type-eval `Personal.swift`) replays `tools/session-analyzer/
  personal-eval.jsonl` (gitignored, real confirmed typing) keyed per-row by
  `typo|intended` (lowercased) against `scores/personal-baseline.json`
  (also gitignored — derived from personal text). Gate: (a) a baseline
  top-1 pass that fails now is a REGRESSION; (b) any NEW false-autocorrect —
  including on a brand-new row — is a REGRESSION (false-ac stays the most-
  guarded metric, held even for rows with no baseline history); (c) new or
  newly-passing rows are improvements, listed but non-gating.
  `--update-baseline` rewrites the baseline after a wave is accepted. A
  missing personal-eval.jsonl (fresh checkout, CI) is a clean no-op, exit 0
  — the gate is only as available as the local personal data, by design.
  Same command additionally loads `confirmed-intents.jsonl`'s
  `intentional: true` rows and replays each at a NEUTRAL lane posterior (no
  priming context — the most permissive the engine ever runs a keystroke
  in), asserting no forced auto-apply; a failure is its own regression
  (false-positive class), independent of the baseline.
- **pIS recording**: `SessionRecorder.recordPass` gained an optional
  `pIcelandic` parameter; `BetterKeyboardAutocompleteService` threads
  `session.probabilityIcelandic` (the same accessor `type-repl`'s `P(IS)`
  prints) through on every pass. Encoded as `pIS` (3 decimals) in
  `kb.jsonl`, omitted (not `null`) when absent — Swift's synthesized
  `Encodable` calls `encodeIfPresent` for `Optional` properties, verified
  with a throwaway encode. `analyze.py`'s `KBRecord` construction reads
  fields via `dict.get(...)` one at a time (no `**r` splat) — confirmed by
  reading it (read-only; the analyzer itself is another agent's scope this
  wave) — so the new key is additive and silently ignored until the
  analyzer opts in.
- **Gates**: established the initial baseline against commit `24d7ec0e`:
  25 personal rows, top-1 13/25, autocorrected 14, falseAc 4 — matches the
  discipline note above (these rows are drawn FROM real corrector misses,
  so a lower top-1 rate than the synthetic corpus is expected, not a
  regression). Slangur check 1/1 (kozy survives unforced). 13 new unit
  tests (EvalKitTests/PersonalEvalTests.swift) against a fixture baseline
  and a DictLexicon fixture engine — never the real personal file. Dev
  corpus byte-identical to wave 22 (no Corrector/LanguageModel touched);
  192/192 scenarios; swift test green (402 tests); simulator build green
  (xcodegen + Debug/iOS-Simulator).

## 2026-07-17 — Wave 29: eval-studio v2 (tooling, in flight)

- **Trigger**: process review — iteration loop is dogfood recordings; needed
  context-efficient triage, compounding evaluations, roadmap from data.
- **Decided**: findings are pre-triaged against a class taxonomy (known vs
  NOVEL); lane posterior timelines rendered per session (Love-Island
  whiplash signature); AGGREGATE.md leads with a top-gaps table = the
  next-wave queue. Phase 2 after wave 22: personal-eval as hard wave gate,
  slangur registry, pIcelandic recorded per pass.

## 2026-07-17 — Wave 22: compound acceptance

- **Trigger**: stökklrikanum→stökkleikanum UNRESOLVABLE (session
  2026-07-16T14-59-28); Icelandic compounding is productive, no lexicon holds
  it all. Symmetric hazard: valid OOV compounds get no conservatism shield.
- **Decided**: port the BinPackage/Greynir decomposition RULES
  (TypeEngine/Compounds.swift): head = longest BÍN suffix in an OPEN class
  (no/so/lo — their `_OPEN_CATS`), carrying the inflection; modifier = noun
  genitive (indefinite — the -s-/-ar-/-a-/-u- linking letters ARE genitive
  endings, no separate machinery), noun stem slot (kk þf.et / kvk nf.et /
  hk nf|þf.et), or strong-positive adjective genitive; ≤ 2 modifiers.
  Modifier legality reads paradigms.bin (only artifact with the
  DEFINITENESS bit — rule precision vs Miðeind's shipped prefix list is
  0.83 with it, 0.43 without; its lemma-freq≥10 floor stands in for their
  curation). BÍN's 358 bound suffix forms (ord.suffix.csv utg=-1:
  -leikanum, -menningur…) embedded as a static set — "leikanum" exists in
  no other artifact. Deviations, all tightening: min part lengths 4/4
  (dev sweep: 3/3 protects 2.7% of typo rows, 4/4 → 1.2%, positives kept),
  no adjective stems, no suffix-removals port, no tantum demotion.
- **Wiring — protection ≠ generation**: compound validity feeds ONLY the
  auto-apply veto (`isProtectedTypedWord`) + the restoration branch (lazy
  skeletons like "tungumal"=tungu+mal still restore via the triple gate);
  generation passes still gate on raw validity, so suggestions/splits for
  compound-shaped tokens are unchanged (protecting the split OFFERS was
  worth −1.3pp top-1 in the naive wiring). Repair pass 5b holds a legal
  modifier prefix fixed and single-edits the head — ERROR-class subs only
  (fold-priced twins walked junk compounds over honest repairs:
  prentletu→"prent+létu"), no strict-prefix extensions (completion pricing
  0.5/char structurally beats splits: "fimmtabókin"→"fimmtabókina"),
  generated heads need z ≥ −1.6 (junk tier "legan"/"legs" flooded the
  faralega bar), gate 4.5 (an honest single-insert repair at 4.0 —
  eldsnyti→eldsneyti — must shut the pass). Compounds score at frequency
  floor 1, STRICTLY below the BÍN floor 2: a whole word BÍN attests
  outranks any hypothesized decomposition at equal cost, mirroring
  Miðeind's whole-word-lookup-first order. Compound completions
  (stökklei→stökkleikur) built but DEFAULT OFF pending completion-specific
  pricing (wave 23 with the Kirkjubæjarklaustur split-case class).
- **Gates**: dev A/B compound on-vs-off: top-1 +0.13pp, false-ac ±0.00pp,
  ac-fired −0.60pp (protection veto); 192/192 scenarios ×3 (new
  compounds.scenarios: flagship offer, 4 typed-valid compounds protected,
  linking-letter case, dlmk/habb/eotthbap unharmed); swift test green both
  packages; bench max 3.2–6.1 ms (gate 30).

## 2026-07-17 — Small wave: sync staging leak + analyzer junk-tier gap (87b4b73, f4e7686)

- **Trigger**: 21×1.6MB lyklabord-sync-*.bin leaked in app tmp; analyzer
  missed "lss"→las because is.lex attests web junk.
- **Decided**: staging file deleted on success AND failure + day-old sweep at
  sync start. Analyzer: an is.lex attestation only counts when BÍN knows the
  word or z ≥ −1.0 — **BÍN validity is the signal separating junk from rare
  real words**, a pure z floor cannot (gil/snefil sit at lss's z).

## 2026-07-17 — Wave 28: stale-autocorrect apply guard (da3ed4d, 1f3b627)

- **Trigger**: "Lovr"+space applied the PREVIOUS word's autocorrect
  ("Þátturinn Þátturinn", Love destroyed), session 2026-07-17T08-30-35 —
  async race between engine queue and autocompleteContext at delimiter time.
  Collateral: mangled word flipped lane posterior, blocking a→á downstream.
- **Decided**: every bridged suggestion already carries its pending token
  (pendingTokenInfoKey); auto-apply refuses on token mismatch
  (AutocorrectApplyGuard, pure + unit-tested, fail-closed on missing stamp);
  delivery side drops results superseded by a newer request for different
  text. Ledger unaffected (snapshots actual before→after, nothing pre-armed).
  Skipped applies recorded as kind "stale-skip" — recurrence = regression.
- **Note**: 1f3b627 restored the CloudDocuments entitlement the wave's cleanup
  had mistakenly reverted (generated file lagged the committed spec).

## 2026-07-17 — CloudDocuments entitlement (dead70b)

- **Trigger**: OTA session export never reached the Mac; ubiquity folder
  never materialized.
- **Root cause**: icloud-services listed only CloudKit — CloudDocuments is
  the service that actually runs iCloud Drive document sync. Bundle version
  bumped 1→2 (iCloud Drive re-reads NSUbiquitousContainers only on version
  change). App-only; extension keeps zero iCloud.

## 2026-07-16 — Wave 26: learning self-poisoning (b458efe)

- **Trigger**: session 2026-07-16T22-45-30 — mid-sentence Title Case
  (furir→Fyrir, frabær→Frábær, nyju→Nýju, syba→Sýna) and dead restoration
  (þvi/þer/gret/eg/sa silent, bar ranked accented form 0.8–0.99 but ac=false).
  Device-only; harness reproduced ONLY with PERSONAL seeds → root cause was
  in-memory learned vocabulary, not code/data drift.
- **Decided**: (1) leading-cap learned surface folds to pipeline casing when
  lowercase is common base vocab (typicality test, NOT BÍN casing —
  lemma-is.bin lowercases everything); sentence-initial commits strip autocap
  at capture. Miðeind-class OOV caps preserved. (2) implicitly-learned pure
  acute-fold twins of ≥10×-dominant base words lose the conservatism veto;
  their personal counts TRANSFER to the twin (the lazy commits were commits
  of the twin — this transfer is what made grét clear the margin). Explicit
  adds, verbatim taps, tombstones keep full veto.
- **Gate note**: dev corpus byte-identical (machinery inert without personal
  snapshot) — personal-state bugs are invisible to the synthetic corpus,
  hence phase-2 requirement that personal-eval gates waves.

## 2026-07-16 — Wave 24: session-findings precision wave (08f4ae1)

- **Trigger**: first four real recordings (kozy→jozy false fire, læt.hann
  dotted-escape, sivan→síðan v↔ð, MEÐ/NEW all-caps bar junk, hega→geta).
- **Decided**: junk-tier margin scaling (winner z < −1.0 → margin ×3) instead
  of a blunt z floor — A/B showed 88% of blunt-floor removals were CORRECT
  fires; v→ð directional confusion priced; all-caps learned-surface guard
  (precursor of wave 26's full fix); determinism: childList byte-sorted.
- **Also**: context-vouched short-double-sub admission (20a5ab1): edit-cost
  cap 1.2→1.4 (g→t vertical-diagonal ≈1.25 nats) + admission requires
  attested bigram with previous word + calibrated z ≥ 1.0 — blunt z lowering
  regressed corpus top-1 by 0.10pp, context vouching didn't.

## 2026-07-16 — Session pipeline (ab8d3a8, dda3396, 6007645, ed2fb78)

- Recorder (dev-mode pad only, dual JSONL + tap coordinates + bar snapshots),
  analyzer v2 (silent-miss scan via type-repl attestation, alignment fix),
  proxy-edit ledger (azooKey pattern — exact self-edit attribution so user
  edits aren't misread as engine corrections), OTA via user's own iCloud
  ubiquity container, build stamping (engineCommit; "+dirty" is a false
  positive — the stamp script dirties its own tracked file), aggregates.
- **Decided**: recordings are personal data — sessions/, personal-eval.jsonl,
  confirmed-intents.jsonl gitignored forever.

## 2026-07-16 — Confirmed-intents (27b9e54)

- **Trigger**: analyzer pending-review queue had no way to absorb the user's
  answers ("dlmk = dæmi").
- **Decided**: confirmed-intents.jsonl maps typo→intended (or intentional:
  true for slangur like "kozy") and promotes contested/UNRESOLVABLE silent
  misses into personal-eval.jsonl with source=user-confirmed. Intentional
  marks are the seed of the slangur registry.

## Pre-ledger foundation (2026-07-15 and earlier, see ADRs + git log)

Beam decoder over lexicon prefix ranges; two-lane HMM (switch 0.08, calibrated
z emissions, sletta absorption); lane relaxation (FoldPricing, skeleton-
collision triple gate); per-tap 2D Gaussians (TSI-seeded σ); inflection
paradigms + statistical governors (P(þgf|frá)=0.675); learning/EventLog with
2-distinct-day promotion + tombstones; AES-GCM sync with roaming keychain key;
KeyboardKit vendored at 9.9.1 (last MIT tag); verbatim/URL protection layers;
spacebar 3 modes; eval studio v1 (dev/heldout 3000 pairs, disjoint; scorecard
hard gates: false-ac=0 on micro-set, <30ms, all scenarios).
