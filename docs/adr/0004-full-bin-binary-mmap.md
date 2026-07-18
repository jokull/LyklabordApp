# Ship the full 91MB BÍN binary, mmap everything

Status: Accepted
Date: 2026-07-15

Amendment 2026-07-18: the BÍN source was refreshed from the official
2026-07-10 Sigrún export. The primary artifact is now 115,189,168 bytes
(109.9 MiB), with 3,698,020 forms and 347,926 lemmas. This does not change
the decision—ship the full mmap-backed artifact—but the original 91 MB
benchmark remains historical evidence and the refreshed artifact must pass
the same cold-start, touched-page, and lookup-latency gates. Exact provenance
is in `data/is/LANGUAGE_DATA_MANIFEST.json`.

## Context

iOS keyboard extensions run under a strict jetsam (dirty-memory) budget —
roughly 60–70MB in practice. The project's language data is derived from
BÍN (Beygingarlýsing íslensks nútímamáls), a comprehensive Icelandic
morphological database, via the `lemma-is` project's Python build pipeline
(`build-binary.py`, `extract-*grams.py`), reused and extended here.

The original plan (see `research/foundation-options.md`, "Memory fit") was
device-based tiering: ship a smaller lexicon (2–10MB) to memory-constrained
devices and the full set only where headroom allowed. Four tiers were built
and staged in `data/is/`: `lemma-is.bin` (full, 95,416,256 bytes / ~91MB:
3,071,066 word forms, 289,124 lemmas, format v2 with morphological data +
414,007 bigrams), `lemma-is.core.bin` (9.2MB, 350k forms, no morph/bigrams),
`lemma-is.core.top_200k.bin` (5.4MB), and `lemma-is.core.min_100.bin`
(1.8MB).

A Swift mmap benchmark on the actual full binary (2026-07-15) measured:
**+0.28 MB `phys_footprint`** after load plus 1,000 lookups, 124 µs/lookup,
0.4 ms load time. The same measurement on the smallest tier showed no
meaningfully different footprint. The reason: file-backed mmap pages are
demand-paged and do not count against the extension's dirty-memory cap —
only pages the process actually touches and dirties count, and lookups
touch a tiny fraction of a 91MB trie. File size on disk is not the
constraint the memory cap was assumed to impose.

This finding retired the memory-cap risk that had shaped the tiering
strategy from the start (PLAN.md Risks: "~~Memory cap~~ — retired
2026-07-15"). `Packages/Lexicon`'s `FrequencyLexicon` format (`.lex` files
for ranking, distinct from the BÍN validity/morphology `.bin` trie) applies
the identical strategy: lazy offset reads, no upfront parsing, verified via
its own bench (`is.lex`: 0.43 ms load, phys_footprint delta +2.13 MB after
load + 3,000 mixed lookups on a rebuilt 9.21 MB file).

## Decision

**Ship the full `lemma-is.bin`** (all 3.07M word forms, morphology,
bigrams) on every device. mmap makes on-disk file size effectively free
against the extension's runtime memory budget; the only real cost is app
**download size**, which is acceptable for a free app (ADR-0001).

The three smaller tiers are kept, not shipped: `lemma-is.core.bin` remains
useful for fast unit tests, and all three stay staged as a **download-size
escape hatch** only, should app-bundle size ever become a problem
independent of runtime memory.

## Consequences

- Autocorrect and prediction have access to the complete BÍN-derived
  vocabulary and morphology on every device, with no device-tier logic to
  build, test, or maintain in the engine.
- The engine's memory story is now provably safe (`+0.28MB` measured, not
  estimated) — this closes off an entire category of "will this fit"
  uncertainty that had been driving architecture decisions.
- App bundle/download size grows by ~91MB; this is a distribution-channel
  cost only (App Store download size), not a runtime risk, and was accepted
  explicitly as the trade-off.
- BÍN's license conditions (credit required; no raw-paradigm redistribution;
  no publishing of full inflection paradigms) were confirmed navigable for
  this exact use — the app ships only derived trie indices (surface form →
  lemma id, frequency, flags), never raw BÍN paradigm tables, matching the
  precedent already established by `lemma-is` itself. Terms were confirmed
  directly with the Árni Magnússon Institute for Icelandic Studies via email
  (2026-07-15); full attribution lives in `data/ATTRIBUTION.md` and is
  surfaced in the app's Settings → About screen. See ADR-0011 for how this
  interacts with the repo's overall (MIT) license.
- Same mmap strategy is applied uniformly to the separate `.lex` ranking
  tables (`Packages/Lexicon`) and is the reason both the Icelandic and
  English frequency tables can be queried with no upfront parse cost.
- Related: ADR-0005 (the two-lane language model consumes these lexicons),
  ADR-0006 (autocorrect built on BÍN validity), ADR-0011 (data licensing).
