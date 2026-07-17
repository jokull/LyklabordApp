# Lyklaborð — App Store screenshot & ASO research

_Researched 2026-07-16. Storefronts analysed: **is** (Iceland) and **us**.
Method: iTunes Search/Lookup API + direct screenshot download of the two
incumbent third-party keyboards. Reference screenshots saved under
`store/research/competitors/{swiftkey,gboard}/`._

---

## 1. Category landscape

### The headline finding: there is no Icelandic keyboard competitor

A search for `lyklaborð` on the **Icelandic storefront returns 0 results**
(`itunes.apple.com/search?term=lyklaborð&country=is` → `resultCount: 0`). The
"keyboard" category on the IS storefront is entirely:

1. **The two global incumbents** — Microsoft SwiftKey, Gboard (both English-UI,
   both treat Icelandic as one of hundreds of afterthought locales).
2. **Emoji / font / theme toys** — Facemoji, Kika, "Fonts Art", "Cool Font",
   "LED Keyboard", "RainbowKey", etc. These dominate the long tail and are not
   real typing tools.

No app in either storefront markets *Icelandic typing quality* as its product.
That is the entire whitespace Lyklaborð occupies — and it dictates the
screenshot strategy: **we are not out-designing SwiftKey, we are claiming a
category that has no incumbent.** Every screenshot should show Icelandic text
doing something no other keyboard on the store can do, rather than competing on
themes/emoji/GIFs (where the toys win and where we deliberately don't play).

| App | Storefront rank signal | Rating | Reviews | Positioning |
|---|---|---|---|---|
| Microsoft SwiftKey AI Keyboard | Top-3 "keyboard" (IS & US) | 4.58 | 120,881 | AI / Copilot / themes |
| Gboard | Top-3 "keyboard" (IS & US) | — | — | Google Search / GIF / glide |
| Facemoji, Kika, Fonts Art … | Long tail | mixed | — | Emoji, fonts, themes |
| **Lyklaborð** | — (unlisted, pre-launch) | — | — | **Icelandic typing quality + privacy** |

### ASO implication of the empty IS field
Because no competitor bids on Icelandic-typing keywords, the IS keyword field is
uncontested. Ranking for `íslenskt lyklaborð`, `íslenska`, `broddar`, `beygingar`
should be cheap. The competition for a share of attention is not other keyboards
— it's the user's inertia with Apple's built-in Icelandic keyboard (the real
incumbent, which ships free and has no App Store page to out-rank).

---

## 2. Competitor screenshot analysis

### Microsoft SwiftKey (`store/research/competitors/swiftkey/`, 8 shots)
- **Style:** solid blue gradient background; large white bold sans caption
  top-center; a floating app-content card (rounded corners, some frameless,
  some in a device frame) below; keyboard visible at the bottom of most shots.
- **Story arc:** #1 **Copilot in Swiftkey** (AI chat — leads with the AI push,
  not typing), #2 themes, #3 **"Fast and accurate"** (the one genuinely good
  shot: a typo `Doxroesappoin` → callout bubble `Doctor's appointment` with a
  hand-drawn blue arrow — autocorrect *in action*), later shots = tone/rewrite,
  translation, emoji.
- **Caption voice:** short, benefit-first, English, 2–4 words ("Fast and
  accurate", "Copilot in Swiftkey").
- **Strength:** the before→after autocorrect shot (#3) is the single most
  legible, most convincing frame — it shows the product working, not a feature
  list. **We copy this pattern directly** (and improve it: our transformation
  is Icelandic-specific and impossible for SwiftKey).
- **Weakness:** screenshots lead with AI/Copilot bloat — exactly the
  "AI over typing quality" grievance documented in
  `research/swiftkey-frustrations.md` #6. Nothing communicates Icelandic. The
  source images are old (5.5"/notch-era, `392x696` masters upscaled) — visibly
  dated, a quality gap we can beat trivially.

### Gboard (`store/research/competitors/gboard/`, 7 shots)
- **Style:** flat dark-blue background; white bold caption top-center;
  **realistic notched iPhone frame** (outdated hardware); feature-per-shot.
- **Story arc:** Google Search in the keyboard, GIF, glide typing, translation,
  emoji — all "Google ecosystem" hooks, none about language correctness.
- **Strength:** clean, consistent, instantly readable one-feature-per-frame.
- **Weakness:** notch frame dates it; nothing about typing *quality*; privacy is
  never mentioned (and can't be — it's Google).

### Cross-competitor pattern summary
| Aspect | SwiftKey | Gboard | **Lyklaborð (chosen)** |
|---|---|---|---|
| Caption position | Top-center | Top-center | **Top-center** (convention) |
| Caption weight | Heavy white bold | Heavy white bold | **Heavy bold, ink-on-warm** (brand, not generic blue) |
| Background | Blue gradient | Flat dark blue | **Warm off-white `#faf9f6`** (site palette — distinct in a sea of blue) |
| Device frame | Mixed / dated | Notch (dated) | **Modern Dynamic-Island frame** |
| Lead shot | AI/Copilot | Google Search | **Product identity: the Ð keycap + "skilur íslensku"** |
| Proof-in-action | 1 shot (#3) | 0 | **3 shots** (accents, blend, BÍN) — our core edge |
| Privacy | none | none | **dedicated shot** (verifiable, uncontested angle) |

---

## 3. Screenshot strategy conclusions

1. **Own the "blue keyboard" contrast.** Every keyboard on the store uses a
   blue/dark marketing background. Lyklaborð's warm paper `#faf9f6` + charcoal
   ink `#1c1b1a` (the exact site palette) makes the listing instantly
   not-SwiftKey, not-Gboard, not-a-toy. Palette *is* differentiation here.

2. **Lead with identity, not a feature.** SwiftKey/Gboard lead with a feature
   (AI, Search). We have no brand recognition yet and a self-explanatory name,
   so shot #1 is the **Ð keycap (Wave-5 marketing render) + wordmark +
   "Lyklaborðið sem skilur íslensku"** — it states what the thing *is* in one
   glance. The keycap is our unfair visual asset; use it as the hook.

3. **Three "impossible on any other keyboard" proof shots.** The conversion
   argument is entirely "does something Apple/SwiftKey can't." Show it, don't
   claim it, using SwiftKey's own proven before→after pattern:
   - **Accents** (`flytjum i bud` → `flytjum í búð`) — the daily Icelandic pain.
   - **Two-lane blend** (`deploya`/`Vercel` mid-Icelandic, *not* auto-mangled) —
     answers frustration #5 (2-language limit) and the "hijacks mid-sentence"
     complaint directly.
   - **Morphology / BÍN** (`frá hest` → `hesti`, dative) — literally the first
     keyboard that inflects; the strongest single differentiator.

4. **Make privacy a screenshot, not a footnote.** No competitor can show this.
   A `grep → 0 results` terminal proof is more credible than any "we respect
   your privacy" claim and matches the repo's verifiable-not-promised voice.

5. **Recreate the real keyboard faithfully, don't stylise it.** Accuracy > gloss
   (per brief). The mockups use the true Icelandic layout
   (`qwertyuiopð / asdfghjklæö / zxcvbnmþ`, bottom row `123 🌐 space . return`)
   and a realistic iOS light keyboard, with the **quoted verbatim literal always
   in the left suggestion slot** — the product's actual escape-hatch behaviour.

6. **Localise text only, keep visuals identical.** is-IS and en-US share every
   pixel of layout and in-device content (Icelandic, because it's an Icelandic
   keyboard); only the caption/subtitle language swaps. en-US captions still sell
   the Icelandic capability to the diaspora / learners / Iceland-based
   English-UI users.

7. **Don't fight the toys on their turf.** No themes, no emoji, no GIF, no fonts
   in the screenshots. Playing that game dilutes the one message that converts
   the target user: this keyboard is *correct* and *private*.

### Final sequence (6 shots, both locales)
| # | File | Caption (is / en) | Job |
|---|---|---|---|
| 1 | `01_hero` | Lyklaborðið sem skilur íslensku / The keyboard that knows Icelandic | Identity hook |
| 2 | `02_accents` | Skrifaðu broddlaust / Type accent-naked | Proof: accents |
| 3 | `03_blend` | Íslenska og enska, blandað / Icelandic and English, blended | Proof: two-lane |
| 4 | `04_bin` | Skilur beygingar / It understands inflection | Proof: morphology (BÍN) |
| 5 | `05_dictionary` | Orðaforðinn þinn — í alvöru þinn / Your vocabulary, truly yours | Ownership + SwiftKey import |
| 6 | `06_privacy` | Ekkert netsamband / Zero networking code | Trust, uncontested |

_90% of users never scroll past shot 3 — so identity (1), the most universal
pain (accents, 2), and the "no other keyboard does this" blend (3) carry the
conversion; 4–6 deepen for the users who scroll._

---

## 4. Keyword research (feeds captions + metadata)

Keywords validated against competitor names/subtitles and the empty IS field.

| Keyword | is-IS priority | en-US priority | Notes |
|---|---|---|---|
| lyklaborð | ★★★ | ★★ | Category term; uncontested on IS |
| íslenska / íslenskt | ★★★ | ★ | Core; nobody else bids on it |
| broddar / broddstafir | ★★ | — | Unique-to-us; high intent |
| beygingar / BÍN | ★★ | — | The morphology differentiator |
| keyboard | ★★ | ★★★ | Generic anchor (en) |
| icelandic | ★ | ★★★ | Primary en discovery term |
| autocorrect / leiðrétting | ★★ | ★★ | Function term |
| privacy / persónuvernd | ★★ | ★★ | Trust seekers; differentiator |
| open source | ★ | ★★ | Reinforces trust cohort |
| swiftkey | ★ | ★ | Switcher intent (import path) |

Captions already embed: `broddlaust`, `beygingar`/`inflection`, `BÍN`,
`íslenska og enska`, `netsamband`/`networking` — the high-intent, uncontested
terms, placed in the indexed caption text (captions are ASO-indexed as of
Apple's June 2025 change).
