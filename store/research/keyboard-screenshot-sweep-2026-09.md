# Keyboard category screenshot sweep — 2026-09-16

_Why: the v2 store set (Blender-rendered tilted phone on a dark stage) reads
badly at listing size. Before redesigning, harvest what the keyboard category
actually does and find the shots that work. Sources: iTunes Search API, US/GB
storefronts, 12 generic + 37 named queries. 30 apps, 182 screenshots saved to
`competitors/_sweep-2026-09/<app>/` (with `meta.json`); contact sheets in
`competitors/_sheets/sheet1-4.png`; the strongest single frames side by side
in `competitors/_sheets/best.png`. Re-run with `harvest.py` + `harvest2.py`._

## 1. What is wrong with v2 (precisely)

Not "3D looks bad". The product occupies the bottom third of a phone that is
itself about half the frame, tilted, on a dark stage that fights the light
keyboard. At the App Store's thumbnail size the keyboard is unreadable, and
all six shots share one silhouette, so the listing scrolls as six identical
dark tiles with different captions. The captions do all the work; the
picture does none. Most of the category has the same disease.

## 2. The category, in three bands

| Band | Apps | Screenshot style | Relevance |
|---|---|---|---|
| Toys (fonts/emoji/themes) | Facemoji, Kika, V Keyboard, Fonts Art, Simeji, Bobble | Saturated gradients, script headlines, sticker collage, 8–10 shots | None. We don't play here. Their visual language is the thing to look *unlike*. |
| Serious typing tools | SwiftKey, Gboard, Grammarly, Typewise, Wispr Flow, TypeAI, CorrectMe, ParagraphAI | Flat single-colour stage, white bold caption top-centre, phone frame (mostly notch-era), one feature per shot | Direct peers on presentation. SwiftKey/Gboard have not updated in years. |
| Language-first keyboards | Desh (Bangla/Hindi/Tamil), Manglish, Kal (Amharic), Georgian, Kurdish, Persian/Greek/Ukrainian/Arabic "translator" clones | Mostly raw simulator screenshots with no design at all, or a template blue stage | Our true category (a language nobody else serves). The bar is on the floor. Desh is the only competent one. |

## 3. The frames that actually work, and why

| Frame | What it does | Take |
|---|---|---|
| **SwiftKey #3** "Fast and accurate" | Typo `Doxroesappoin` in the field, corrected phrase lifted into a big white chip with an arrow | The one proof-in-action shot in the whole category. Transformation is the picture. |
| **Kika #10** "AI Auto Correction" | Same pattern, chip + arrow, on a toy stage | Confirms the pattern is legible even at toy density. |
| **Kurdish #3** | Keyboard cropped huge, tilted, bleeding off the frame; headline in the corner | The keyboard as the design element. First time in the sweep the keys are readable at thumbnail. |
| **Typewise #3** "World Class Autocorrection" | Keyboard cropped at the text field, fills the lower 60% straight-on | Same lesson without the tilt. Clean. |
| **Wispr Flow (all six)** | Cream paper background, serif headline, straight-on phone, black keyboard-slab base | Proves "not blue" reads as premium in this category. Closest aesthetic peer to our site palette. |
| **Desh Bangla #2–4** | Real WhatsApp-style chat in the target language, keyboard below, plain headline + one-line sub | The competent language-keyboard template. Chat context makes the language visible. |
| **Grammarly #2/#8** | Dark green stage, light app card, correction shown inline with strike + replacement | Inline strike/replace is a second way to draw a correction. |
| **Lingo #1** | Headline at the *bottom*, keyboard at top | Bottom captions are unusual and scan differently in the carousel. Worth one shot, not six. |

## 4. Patterns to adopt / avoid

Adopt
- **Crop, don't frame.** Cut the device at the top of the text field. Field,
  suggestion bar and keyboard run near full 1260 width. Keep at most the
  rounded lower device edge.
- **Transformation in display type.** `ut i bud → út í búð` at headline size
  in the caption zone. That is the message at thumbnail scale; the suggestion
  strip beneath it is the proof.
- **Light stage.** Paper `#faf9f6` + ink `#1c1b1a` (site tokens). The iOS
  light keyboard sits on paper naturally instead of glowing out of a void.
- **Lifted chip + arrow** for at least one correction shot (SwiftKey #3).
- **ð æ ö þ are the brand mark.** Four keys nobody else's keyboard has. Use
  them as the graphic in the hero instead of an empty phone.
- **Vary the silhouette.** At least one chat-context shot, one type-led shot,
  one app-UI shot, so the carousel does not read as six copies.

Avoid
- Tilted 3D phone (v2), notch frames (Gboard, Typewise), dark stage with light
  keyboard, gradients, script fonts, stickers, more than ~8 words of body copy.

## 5. Proposed v3 set (presentation change only; copy.md stands)

| # | Shot | Silhouette | Graphic |
|---|---|---|---|
| 1 | Hero | Type-led, keyboard bleed at bottom | ð æ ö þ keycaps as the mark (option D) |
| 2 | Accents | Keyboard crop full width | `ut i bud → út í búð` in display type (option A) or chip+arrow (B) |
| 3 | Blend | Chat context | Icelandic/English mixed thread, suggestion bar showing both lanes untouched |
| 4 | Inflection | Keyboard crop, chip + arrow | `frá Akureyr` → `frá Akureyri` chip |
| 5 | Lyklaborð+ | Straight phone crop (only app-UI shot) | Orðasafn list |
| 6 | Privacy | Type-led, no keyboard | `grep -r URLSession → 0 results` block on paper |

Style options for the accents shot, all from the real capture:
`store/screenshots/v3/options/{A,B,C,D}.png`, sheet `options.png`, and
`options-thumbs.png` for how they read at listing size. Mood drafts from the
GPT image model (looser, not pixel-accurate) in `store/screenshots/v3/codex/`.

## 6. Pipeline implication

Stage A (real simulator captures via `v2/capture.sh`) stays; it is the thing
that makes the keyboard accurate. Stage B (Blender) is dropped. Stage C
becomes a flat Pillow compose from the captures, which `v3/options.py`
already sketches. Delete `v2/blender/`, `build_scene.py`, `render-all.sh`
once v3 replaces them.
