# App Store screenshot copy — edit freely, I'll wire it into the new renders

One section per screenshot. `Title` lines break where the `/` is. Both locales
live here; the en-US set is what ASC gets, is-IS is for the website. Note for
edits: #5 is now the Lyklaborð+ (subscription) shot — copy should say so
honestly.

## 1 · Hero

- Title (is): Lyklaborðið sem / skilur íslensku
- Sub (is): Frítt. Opinn hugbúnaður. Deilir ekki gögnum.
- Pitch (is): Íslenskt lyklaborð sem skilur íslensku.
- Meta (is): Opinn hugbúnaður · Þú átt gögnin
- Title (en): The keyboard that / knows Icelandic
- Sub (en): Free. Open source. Privacy first.
- Pitch (en): The Icelandic keyboard that actually knows Icelandic.
- Meta (en): Open source · Privacy first

## 2 · Accent restoration

- Title (is): Skrifaðu broddstafi / án broddstafa
- Sub (is): Ef þú sleppir broddstaf birtast þeir samt — `ut i bud` verður `út í búð`.
- Title (en): Type / accent-naked
- Sub (en): Dropping accents is an input method, not a typo — `ut i bud` becomes `út í búð`.

## 3 · Bilingual blending

- Title (is): Íslenska og enska, / blandað saman
- Sub (is): Slettur og enska leyfð og líka leiðrétt. Þú þarft ekki að skipta um lyklaborð.
- Title (en): Icelandic and / English, blended
- Sub (en): One-off English words never derail you. The keyboard never hijacks your language mid-sentence.

## 4 · Inflection (BÍN)

- Title (is): Skilur / beygingar
- Sub (is): Byggt á öllum 3 milljón orðmyndum úr BÍN — „frá“ kallar á þágufall, og lyklaborðið veit það.
- Title (en): It understands / inflection
- Sub (en): Built on all 3 million BÍN word forms — “frá” takes the dative, and the keyboard knows it.

## 5 · Personal vocabulary (→ Lyklaborð+)

- Title (is): Að ógleymdum — / orðaforðanum þínum
- Sub (is): Með Lyklaborð+ byggir lyklaborðið upp grunn af nýyrðum, nöfnum og slangri — á tækinu sjálfu. Þitt að skoða, eyða — og flytja inn úr SwiftKey.
- Title (en): Your vocabulary, / truly yours
- Sub (en): With Lyklaborð+, the keyboard learns your new words, names, and slang — on-device. Yours to inspect, delete — and import from SwiftKey.

## 6 · Privacy / data ownership

- Title (is): Þú átt / gögnin
- Sub (is): Það sem þú skrifar fer aldrei af tækinu. Aukaorðin þín fara bara í þitt eigið iCloud — aldrei til okkar.
- Title (en): Your data / stays yours
- Sub (en): What you type never leaves your device. Your learned words sync only to your own iCloud — never to us.

## Typed content shown on the keyboard/screen per shot

(the demo text the capture driver types — ScreenshotUITests.swift. These are
ENGINE-VERIFIED with `swift run -c release type-repl run` (2026-09-16): from a
cold neutral start the engine leans English on `ut i bud` (top "bus") and
leaves bare `fra` uncorrected, so each string opens with one Icelandic word to
prime the lane. Keep them in sync with the tests.)

- 1: `Godan daginn ` → `Góðan daginn ` (Icelandic next-word predictions; an
  empty field predicts English: account / ai / 4G)
- 2: `Eg fer ut i bud` → `Ég fer út í bud` with **búð armed on the blue spacebar**
- 3: `eg þarf að deploya þessu` → `ég þarf að deploya þessu` (sletta survives)
- 4: `Vid keyrdum fra Akureyr` → `Við keyrðum frá Akureyr`; `Akureyri` shows in
  the bar but is NOT armed on the sim (the headless harness arms it — open question)
- 5: Orðasafn view / learned words list
- 6: (no typing — code/privacy visual)
