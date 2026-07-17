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
  recordings are made WITH manual corrections.
- **Extension privacy**: the keyboard extension has zero network/iCloud
  entitlements, forever. Sync and export live in the containing app.

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
