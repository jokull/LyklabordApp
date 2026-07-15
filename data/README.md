# Language Data Artifacts

This directory contains the language models and frequency tables for the better-keyboard iOS extension. All files are mmap-ed in the app bundle for efficient on-device autocorrect and prediction.

## Icelandic (is/)

### Binary Lemma Models

These are indexed trie-based binary artifacts generated from BÍN (Beygingarlýsing íslensks nútímamáls) via the lemma-is project. Each maps surface forms to (lemma id, frequency, flags) tuples.

- **lemma-is.bin** (95,416,256 bytes) — **PRIMARY**
  - Full BÍN: 3,071,066 word forms, 289,124 lemmas, format v2 with morphological data + 414,007 bigrams
  - Measured (Swift mmap bench, 2026-07-15): phys_footprint +0.28 MB after load + 1000 lookups; 124 µs/lookup; 0.4 ms load
  - Ship this. mmap makes file size irrelevant to the extension memory cap; only cost is app download size

- **lemma-is.core.bin** (9,669,628 bytes)
  - Smaller alternative (350k forms, no morph/bigrams, v1); kept for tests and as a download-size escape hatch

- **lemma-is.core.top_200k.bin** (5,638,556 bytes)
  - Fallback tier for older/memory-constrained devices
  - Top 200k most frequent Icelandic words by corpus frequency
  - Deployment: A/B test or enable on devices with <2GB available memory

- **lemma-is.core.min_100.bin** (1,932,984 bytes)
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
2. Corrector stage uses SymSpell edit-distance candidates (English: en-80k.txt; Icelandic: lemma-is.core.bin)
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

Device-based tiering was designed before the Swift mmap bench proved footprint is independent of file size (all tiers measure ~+0.25 MB phys_footprint; even the 91 MB full binary measures +0.28 MB). Decision 2026-07-15: **ship the full lemma-is.bin on all devices**. The smaller tiers remain staged only as a download-size escape hatch and for fast unit tests.

| File | Size | Contents (words / lemmas / bigrams) |
|------|------|--------------------------------------|
| lemma-is.bin (primary) | 91.0 MB | 3,071,066 / 289,124 / 414,007 (v2, morph) |
| lemma-is.core.bin | 9.2 MB | 350,000 / 81,587 / 0 (v1) |
| lemma-is.core.top_200k.bin | 5.4 MB | 200,000 forms (v1) |
| lemma-is.core.min_100.bin | 1.8 MB | freq ≥ 100 forms (v1) |

**Note**: mmap pages are file-backed and do not count against the extension dirty-memory (jetsam) limit. Paging is lazy and demand-driven.

## CI Checks (Future)

- [ ] Verify total binary sizes on each tier ≤ 35 MB in app bundle (ipa)
- [ ] On-device memory ceiling test: launch keyboard with full model stack, confirm dirty memory < 50 MB on iPhone 8 (1 GB baseline + 30 MB model headroom)
- [ ] Frequency table JSON schema validation (gzip integrity + JSON parse)
- [ ] Bigram fallback: if bigrams.json.gz is missing, log warning and degrade to unigrams-only
