# Attribution & Licensing

## Icelandic Language Data: BÍN (Beygingarlýsing íslensks nútímamáls)

### Credit

This application uses language data derived from **BÍN** (Beygingarlýsing íslensks nútímamáls), a comprehensive morphological database of Modern Icelandic.

**© Árni Magnússon Institute for Icelandic Studies**  
https://bin.arnastofnun.is

Icelandic morphological data and lemma information is provided courtesy of the Árni Magnússon Institute for Icelandic Studies.

### License Terms (as applied to this project)

The BÍN dataset is made available under conditions that permit:

1. **Use in software applications** — Permitted. This keyboard extension uses BÍN-derived lemma indices and inflection mappings to power morphology-aware autocorrect.

2. **Credit required** — This attribution is displayed in the app's Settings → About section (containing app code credits).

3. **Restrictions on redistribution**:
   - **No raw-data redistribution**: The raw BÍN inflection paradigm data is not redistributed or republished.
   - **No publishing of inflection paradigms**: Users of this app are not presented with, and the app does not export, complete inflection paradigms from BÍN. The app shows only:
     - Lemmatized forms (base word)
     - Individual inflected suggestions (matched to user keystrokes)
     - Frequency ranks and grammatical categories (parts of speech)
   - Raw paradigm tables (all cases, numbers, genders for a single lemma) are never displayed or exported.

### Clearance

These terms were confirmed via email with the Árni Magnússon Institute (dated 2026-07-15) for this specific use case. The lemma-is project has previously navigated the same restrictions and precedent applies.

---

## English Language Data: SymSpell

### Credit

This application uses English frequency dictionary data from the **SymSpell** open-source project.

**SymSpell**  
https://github.com/wolfgarbe/SymSpell  
Author: Wolf Garbe

### License

SymSpell and the bundled frequency dictionaries are distributed under the **MIT License**.

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Frequency Data Attribution

The English frequency dictionary (`en-80k.txt`) derives from:

1. **Google Books Ngram Dataset v2** (public domain)  
   https://storage.googleapis.com/books/ngrams/books/datasetsv2.html

2. **Hunspell Dictionaries** (multiple open-source licenses: LGPL, GPL, MPL, etc.)  
   https://github.com/wooorm/dictionaries

SymSpell combines these two sources by intersection to produce a high-quality frequency dictionary suitable for spell-checking and autocorrect use cases.

---

## Evaluation Data: Icelandic Error Corpus (IceEC)

### Credit

The compound-error evaluation slice (`data/eval/compounds.jsonl`, wave 31) derives from the **Icelandic Error Corpus (IceEC)**:

> Anton Karl Ingason, Lilja Björk Stefánsdóttir, Þórunn Arnardóttir, Xindan Xu. 2021. **The Icelandic Error Corpus (IceEC)**. Version 1.1.  
> https://github.com/antonkarl/iceErrorCorpus

### License

IceEC is distributed under the **Creative Commons Attribution 4.0 International license (CC BY 4.0)** — https://creativecommons.org/licenses/by/4.0/. The derived rows in `data/eval/compounds.jsonl` (typo→correction pairs filtered to the compound error classes, selected and reshaped by `data/eval/generate-compounds-eval.py`) are redistributed under the same terms with this attribution. Changes made: filtering to compound-shaped error codes, dedup, shape normalization, and replay-form transformation — documented in the generator script and `data/eval/README.md`.

A further 16 rows in the same file derive from **GreynirCorrect** test assertions (Miðeind ehf., MIT license — https://github.com/mideind/GreynirCorrect); each row's `source` field records its origin. The full harvest provenance is in `research/mideind-compound-cases.md`.

Evaluation data only: these files feed `type-eval` and are not part of the shipped app bundle.

---

## Icelandic Emoji Labels: Unicode CLDR

The Icelandic emoji names and search keywords in `data/emoji/is.json` are
extracted from **Unicode Common Locale Data Repository (CLDR) 48.2** and
matched against the **Unicode Emoji 17.0** fully-qualified repertoire.

Copyright © 1991–2026 Unicode, Inc. Distributed under the permissive
**Unicode License v3** (`Unicode-3.0`). Source URLs, versions, and SHA-256
checksums are embedded in the generated file and pinned by
`scripts/build-emoji-labels.py`.

- https://cldr.unicode.org/
- https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt
- https://www.unicode.org/license.txt

Changes made: Icelandic annotation and derived-annotation XML are joined,
limited and ordered by the Emoji 17.0 fully-qualified sequence list, and
serialized as deterministic JSON. No labels are machine-translated or
otherwise altered.

---

## Summary for App Distribution

### What we ship

- Compiled binary lemma indices derived from BÍN (custom `.bin` format)
- Gzipped JSON frequency tables (Icelandic unigrams, bigrams)
- Plain-text English frequency dictionary (SymSpell)

### What we do NOT ship

- Raw BÍN inflection paradigms or database exports
- SymSpell source code (only the data files)
- Google Ngrams raw files
- Any raw corpus texts

### Compliance checklist

- [x] BÍN credit displayed in app Settings
- [x] SymSpell MIT license included in app source code repository
- [x] This ATTRIBUTION.md file included in the distributed app bundle (or linked from About screen)
- [x] No raw-data redistribution to third parties
- [x] No publishing of Icelandic inflection paradigms
- [x] All licenses honored in any forks or modifications
