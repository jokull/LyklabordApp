# better-keyboard: Foundation Research

*Researched 2026-07-15. Goal: pick the open-source foundation for a privacy-first SwiftKey alternative on iOS — Icelandic + English bilingual typing, zero phone-home from the keyboard, learned patterns encrypted and synced via iCloud.*

## Recommendation (TL;DR)

- **UI/layout foundation: KeyboardKit (MIT)** — the only actively maintained, production-grade open-source iOS keyboard framework. Free core covers keyboard views, layout engine, action handling, feedback, localization. v10.7.2 released July 2026.
- **Prediction/autocorrect: build it ourselves** on **SymSpellSwift (MIT)** for correction + a custom n-gram/trie model for next-word prediction. No complete open-source iOS prediction engine exists; KeyboardKit's autocomplete is paywalled (Pro), Fleksy is proprietary, and Android engines aren't portable.
- **Icelandic data: reuse ~/Code/lemma-is** — it already embeds BÍN in compact tiered binaries (1.9–27MB) with unigram/bigram frequency tables and a Python build pipeline; port the binary reader to Swift. hunspell-is (CC BY-SA / public domain) as a supplementary wordlist.
- **Privacy architecture: extension never touches the network.** Keyboard extension reads/writes learned data in an App Group container; the containing app performs CloudKit sync using `encryptedValues` (record-level E2E encryption, keys in iCloud Keychain). Extension can keep `RequestsOpenAccess` semantics minimal — Full Access is needed for the App Group on iOS, but no networking code ships in the extension.

---

## Candidates Evaluated

### KeyboardKit — recommended base (pinned to 9.9.1)
- **Repo:** https://github.com/KeyboardKit/KeyboardKit — MIT license *label*, but **CORRECTION (2026-07-15, verified by diffing Package.swift across tags): v10.0+ ships as a closed-source binary XCFramework gated by a LicenseKit dependency** (license validation ⇒ implied network calls). v10.7.2 has no Sources/, just a binaryTarget zip.
- **Use v9.9.1** — last tag with full MIT Swift source, no license machinery. Frozen foundation: the layout/callout APIs we use are marked deprecated-in-10. Long-term expectation: maintain our own fork of 9.9.1 (MIT permits it), since we only use the shell UI layer.
- **Status:** v9.9.1 (2025); Swift 5.9+, iOS 13+
- **Free tier:** keyboard views + layout engine, action handling, haptic/audio feedback, localized UI strings, basic emoji keyboard
- **Pro (paid):** localized keyboard layouts, autocomplete/autocorrect, AI prediction, themes
- **Implication:** we use the free MIT core for UI/layout (define our own Icelandic layout — layouts are customizable in the free tier) and write our own autocomplete service (KeyboardKit exposes an autocomplete service protocol we can implement)
- **Telemetry:** none documented in the open-source core

### azooKey — architecture reference
- **Repo:** https://github.com/azooKey/azooKey — MIT; active (v3.0.2 Oct 2025, commits through June 2026)
- Japanese-only kana-kanji IME, but the best existing example of a **fully offline, on-device conversion/prediction engine in Swift** (modular: AzooKeyCore, CustardKit). Worth reading for engine architecture, memory management under the keyboard-extension cap, and SwiftUI layout customization.

### Tasty Imitation Keyboard — not viable
- BSD-3, abandoned (~2020, pre-SwiftUI), no autocomplete. Educational reference only.

### Fleksy — not viable
- Keyboard SDK is proprietary B2B ($269+/mo); only their **Kebbie** testing framework is open source (MIT, https://github.com/FleksySDK/kebbie) — potentially useful for benchmarking our autocorrect quality.

### Android keyboards (HeliBoard, FlorisBoard, FUTO) — not portable
- Kotlin/Java, tightly coupled to Android's InputMethodService; no reusable C++ core published. FUTO's transformer approach (llama.cpp + Patricia trie dictionaries) is a useful *design* reference, but the iOS keyboard-extension memory cap (~60-70MB) rules out shipping an LLM in the extension.
- **Design takeaway:** trie-based dictionary + lightweight n-gram model is the proven offline architecture.

### Smaller 2025–2026 projects
- **sayboard**, **dictus-ios** (Whisper/CoreML on-device voice input) — relevant later if we add on-keyboard dictation (a top SwiftKey complaint).
- **SimpleKeyboard** — SwiftUI stock-keyboard clone, reference only.

---

## Head Start: ~/Code/lemma-is (Jökull's own repo)

The single biggest accelerator. lemma-is already embeds BÍN in compact custom binaries with tiered size/recall trade-offs, plus extracted unigram and bigram frequency data — i.e., most of the Icelandic language-model groundwork for a keyboard already exists:

- **Data artifacts (`data-dist/`):** `lemma-is.core.bin` 9.7MB (~18.5MB loaded, 95.996% IFD recall), tiered variants from 1.9MB (`min_100`) to 27MB (`top_1m`), plus `unigrams.json.gz` and `bigrams.json.gz` — exactly the frequency tables a next-word predictor needs.
- **Build pipeline (`scripts/`):** Python scripts (`build-binary.py`, `extract-unigrams.py`, `extract-bigrams.py`) that turn BÍN + corpora into the binary artifacts. Reusable to emit keyboard-tuned artifacts; only a Swift *reader* for the binary format needs porting (reader logic lives in `src/binary-lemmatizer.ts`).
- **Linguistic machinery:** compound splitting (critical for Icelandic!), bigram + grammar-rule disambiguation, Bloom-filter lemma lookup for low memory — all TypeScript, but the algorithms port directly.
- **Memory fit:** the core tiers (2–10MB on disk) fit comfortably inside the iOS keyboard-extension memory cap even alongside an English model.
- **BÍN licensing (already navigated in lemma-is):** MIT code; BÍN data conditions are: credit Árni Magnússon Institute in the product, don't redistribute raw data separately, don't publish inflection paradigms without permission ([conditions](https://bin.arnastofnun.is/DMII/LTdata/conditions/)). Embedding derived binaries in an app with attribution appears fine — same model lemma-is uses.

Keyboard-specific relevance beyond search: inflection awareness means autocorrect can rank all 16 forms of a noun, and the lemma→forms direction (prediction needs *generation*, lemma-is does *analysis*) can be built from the same BÍN source data with the existing pipeline.

## Icelandic Language Resources

| Resource | What | License | Notes |
|---|---|---|---|
| **BÍN / DMII** (bin.arnastofnun.is) | 355,923 inflected word forms | © Árni Magnússon Institute; downloadable at https://bin.arnastofnun.is/DMII/LTdata/data/ | Redistribution/commercial terms not clearly published — **contact the institute to confirm** |
| **hunspell-is** (github.com/nifgraup/hunspell-is) | Hunspell .dic/.aff spellcheck dictionary | Dictionary CC BY-SA 3.0; wordlist/software public domain | Used by LibreOffice/Firefox; Hunspell is C++, wrappable via bridging header, or parse the wordlist directly |
| **Risamálheild** (Icelandic GigaWord) | Large corpus for n-gram frequencies | Unclear from search; needs direct check (clarin.is) | Would power next-word prediction frequencies |
| **GreynirEngine / Tokenizer** (Miðeind) | Icelandic NLP, tokenization | Open source, Python | Python won't run in an extension; useful offline for *building* the shipped model artifacts |

**Approach:** build dictionary + frequency model offline (Python/Greynir/corpus tooling), ship compact binary artifacts (trie + n-gram tables) in the app bundle. Bilingual IS/EN: score candidates against both language models simultaneously rather than hard-switching — this directly addresses SwiftKey's "foreign word triggers keyboard switch" and 2-language-limit complaints.

## Prediction/Autocorrect Building Blocks

- **SymSpellSwift** (https://github.com/gdetari/SymSpellSwift, MIT) — native Swift symmetric-delete spelling correction; orders of magnitude faster than naive edit-distance; tested at 82k+ terms. Good correction core.
- **UILexicon** — available in keyboard extensions but only supplies contact names + text-replacement shortcuts, *not* Apple's dictionary. Use it to seed proper nouns.
- **UITextChecker** — available; can supplement English spellcheck.
- Next-word prediction: custom n-gram (bigram/trigram) model over Icelandic + English corpora, with an on-device user-frequency layer (the "learns your patterns" store).

## Privacy + iCloud Sync Architecture (confirmed feasible)

1. **Keyboard extension:** zero network code. Reads dictionaries from bundle, reads/writes the user-learning store in the **App Group** shared container (use `NSFileCoordinator` for cross-process safety — known source of subtle bugs otherwise).
2. **Containing app:** owns all networking. Syncs the learning store to **CloudKit private database** using `encryptedValues` (record-level end-to-end encryption; keys distributed via iCloud Keychain, inaccessible to Apple with Advanced Data Protection). Docs: https://developer.apple.com/documentation/cloudkit/encrypting-user-data
3. Optionally encrypt payloads ourselves (e.g., CryptoKit AES-GCM with a key in the iCloud Keychain) before writing to CloudKit, so the sync layer only ever sees ciphertext — the pattern used by e.g. TurboClipboard.
4. **Full Access caveat:** iOS requires the user to grant "Allow Full Access" for the extension to share the App Group container. Marketing/story: the extension binary contains no networking code and this is auditable in the open-source repo.

## What We Build vs. Reuse

| Layer | Source |
|---|---|
| Keyboard UI, layouts, gestures, feedback | KeyboardKit (MIT, free tier) |
| Icelandic layout definition | Custom (KeyboardKit layout API) |
| Spelling correction | SymSpellSwift + hunspell-is wordlist |
| Next-word prediction (IS+EN bilingual) | Custom n-gram/trie engine (azooKey/FUTO as design references) |
| User pattern learning | Custom store in App Group container |
| Encrypted iCloud sync | Containing app + CloudKit `encryptedValues` / CryptoKit |
| Autocorrect quality benchmarking | Fleksy's Kebbie test harness |

## Competitive Landscape: What Incumbents Use for Icelandic

### SwiftKey
- Icelandic supported since Feb 2015 on iOS (one of 600+ language packs; þðæö handled). ([simon.is announcement](https://simon.is/2015/02/swiftkey-iphone-islenska/), [MS language list](https://support.microsoft.com/en-us/topic/what-languages-are-currently-supported-for-microsoft-swiftkey-keyboard-661bce6a-8446-435d-a6aa-9ea006ee8353))
- **Base data:** the classic "Fluency" engine is a 3–4-gram statistical model per language pack, trained on **web-crawled text** (blogs, news, Twitter; ~1B words for English-scale packs), language-tagged by their crawler. No evidence of licensed Icelandic sources (BÍN, academic corpora) — Icelandic is almost certainly just crawled surface-form n-grams with **no morphological awareness**.
- **Neural upgrades** (2015+ neural LM; 2025 paper on a ~6MB on-device transformer with differential-privacy fine-tuning, [arXiv:2505.05648](https://arxiv.org/html/2505.05648v1)) target major languages — English-focused in the published work; small languages like Icelandic likely still ride the old n-gram packs.
- **Dual-language mechanism:** per-word language estimation over the enabled languages (same-script languages need no manual switching); candidates effectively scored across both packs. iOS caps at 2 simultaneous languages (Android 5). Exact blending strategy is undocumented.

### Apple iOS keyboard
- Icelandic gets a **layout** and benefits from Apple's generic bi-LSTM language identification for multilingual typing ([Apple ML research](https://machinelearning.apple.com/research/language-identification-from-very-short-strings)), but:
- **Autocorrect quality is documented as broken**: Apple Community threads report common words ("borða", "koma") corrected into rare alternatives — "hundreds of ridiculous autocorrections" ([discussions.apple.com/thread/250184251](https://discussions.apple.com/thread/250184251)).
- The **iOS 17 transformer autocorrect** rollout shows no evidence of including Icelandic (major languages only).
- Apple ships **no Icelandic spellcheck dictionary** even on macOS — users manually install community hunspell-is into `~/Library/Spelling`.
- Predictive text (QuickType) availability for Icelandic is unconfirmed on Apple's feature matrix; likely absent or minimal.

**Takeaway:** nobody in the market does morphology-aware Icelandic. SwiftKey = crawled surface-form n-grams; Apple = near-nothing. A BÍN-backed, inflection-aware engine (via lemma-is data) + SwiftKey-style per-word bilingual blending would be genuinely differentiated, not just "SwiftKey but maintained."

## Open Questions

- BÍN/DMII licensing: lemma-is already ships derived binaries under the published conditions (credit, no raw redistribution, no paradigm publishing). A commercial keyboard likely satisfies these the same way, but confirm the "publish inflection paradigms" clause doesn't cover showing inflected suggestions — an email to Árni Magnússon Institute would settle it.
- Risamálheild access terms for building frequency models.
- Whether KeyboardKit Pro is worth paying for to bootstrap (autocomplete + localized layouts) vs. fully custom — Pro is closed-source, which cuts against the "auditable, never phones home" story.
- Memory budget: keep total extension footprint well under the ~60-70MB jetsam limit with both language models loaded.
