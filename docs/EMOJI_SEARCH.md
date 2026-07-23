# Icelandic emoji search

Research and product storyboard, 2026-07-23. This is a design decision record,
not an implementation spec frozen in code.

## Recommendation

Build an entirely on-device Icelandic emoji search that follows Apple's two
mode interaction:

1. Emoji browse keeps the grid and category rail, with a visible
   `Leita að emoji` control above the grid.
2. Tapping it switches the keyboard to an internal search mode. The grid is
   replaced by a query field, one horizontal result row, and Lyklaborð's own
   alphabetic keys.
3. Query keystrokes update private in-extension state. They never touch the
   host document and never pass through autocorrect, prediction or learning.
4. Tapping a result inserts the emoji through the normal action handler and
   leaves search open. `Lokið` returns to emoji browse and clears the query;
   `ABC` from browse returns to ordinary typing.

Do not put a real focused `UITextField` inside the keyboard extension. A custom
keyboard is itself the active input view; Apple only gives it a proxy for the
host text object and an API to advance to the next enabled keyboard. The safe
model is to render the query and route Lyklaborð's own key actions into an
internal search session. See [Apple's custom keyboard
documentation](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)
and [text interaction
model](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards).

## What leading keyboards do

### Apple

Apple puts a persistent `Search Emoji` field at the top of the emoji browser.
The browse state retains the emoji grid and category rail. In a live iOS 18.4
Simulator capture, focusing search produced:

- the query field at the top;
- one horizontally scrolling result row immediately below it;
- a full alphabetic keyboard below the results;
- a blue `done` key;
- an untouched host text field while `heart` appeared in the internal query.

This is stronger evidence than the support copy alone, but Apple's current
guide also explicitly documents the search field and predictive emoji:
[Use emoji on iPhone and iPad](https://support.apple.com/en-ie/102507).

### Microsoft SwiftKey

SwiftKey uses the same broad model on iOS: enter text into `Search emoji`, then
show matching emoji above that field. Its Android search supports Icelandic,
which validates the label corpus/use case, but Microsoft's published iOS
language list does **not** include Icelandic. This is a real product gap for
Lyklaborð. [Microsoft's current emoji search
guide](https://support.microsoft.com/en-us/topic/how-do-i-use-emoji-search-with-microsoft-swiftkey-9c288512-ec29-4e3e-a028-74241321f3b7).

### Gboard

Gboard established text-to-emoji search on iPhone early (`dancer` → matching
emoji), and later combined emoji, GIF and sticker retrieval. Its public product
material reinforces two principles relevant here: search beats scrolling, and
suggestions can remain on-device. Lyklaborð should copy neither the multi-media
scope nor network search—only the direct text-to-emoji retrieval pattern.
[Google's Gboard introduction](https://blog.google/products-and-platforms/products/search/gboard-search-gifs-emojis-keyboard/)
and [on-device expression suggestions](https://blog.google/products-and-platforms/products/search/may-we-gif-you-suggestion-emojis-and-more-gboard/).

## Detailed storyboard

| State | Screen | User action | Internal behavior | Host document |
|---|---|---|---|---|
| 1. Browse | Search control, emoji grid, categories, ABC and delete | Tap `Leita að emoji` | Create/clear an `EmojiSearchSession`; enter `.emojiSearch` | Unchanged |
| 2. Armed | Empty query, recent/popular emoji row, alphabetic keys | Type `h` | Append to the internal query; search lazily loads | Unchanged |
| 3. Query | `hjarta`; hearts ranked in a horizontal row | Continue typing/backspace/space | Re-rank after each grapheme; backspace edits query; space supports phrases | Unchanged |
| 4. Empty | `hagfræði`; `Ekkert emoji fannst` | Backspace or clear | No fuzzy “best guess” is inserted or promoted | Unchanged |
| 5. Insert | `hjarta`; `❤️` first | Tap `❤️` | Route `.emoji(❤️)` through the normal release action; record emoji frecency | Gains `❤️` |
| 6. Continue | Query and results remain | Tap another result | Allows repeated emoji without retyping | Gains selected emoji |
| 7. Done | Return to browse grid | Tap `Lokið` | Clear query/results; set `.emojis` | Unchanged |
| 8. Exit | Browse grid | Tap `ABC` | Set `.alphabetic` and resume ordinary autocomplete | Unchanged |

Skin tones remain a long-press on a result. Clearing the query shows the user's
emoji frecency row rather than thousands of unranked results. Search state must
reset when the extension disappears or its host text input changes.

## Search corpus and ranking

No LLM-generated label corpus is needed for the base layer. The repository
already has a deterministic Unicode CLDR 48.2 Icelandic corpus for Emoji 17:

- 3,944 fully-qualified emoji records in `data/emoji/is.json` (535,332 bytes);
- names plus Icelandic search keywords;
- 2,501 unique strings in the bundled ISEmojiView picker;
- 1,586 searchable base emoji after picker intersection and skin-tone
  variants are folded behind long-press;
- 3,105 distinct CLDR name/keyword phrases across those base emoji.

A prototype compact picker-only search representation is about 77–86 KB JSON
(2,798 normalized tokens, 6,024 token-to-emoji postings). Load it only when the
user opens search. Do not decode the 535 KB audit corpus at extension launch.
A binary format or trie is premature; sorted token rows plus binary prefix
ranges are enough at this size and are easier to audit.

Recommended rank order:

1. exact full name;
2. exact keyword;
3. exact query token within a multiword name;
4. token-prefix name match;
5. token-prefix keyword match;
6. accent-insensitive versions of 1–5 as a lower-ranked fallback;
7. emoji frecency as a tie-breaker, then stable corpus order.

Never use unrestricted substring matching. For example, `eldur` can occur
inside unrelated Icelandic words such as `heldur`, producing absurd results.
Token boundaries prevent that. Also avoid edit-distance fuzzy matches in v1:
an explicit empty state is cheaper than a confidently wrong pictogram.

Morphology is a later, measurable upgrade. It could normalize queries such as
`hjörtu` to the lemma `hjarta` using the existing BÍN layer, but emoji search
must not wait for the main autocomplete engine to bootstrap. First ship exact
and prefix token search, then add a small reviewed alias/lemma overlay based on
failed-query recordings or tester feedback. Search queries themselves must not
be logged.

## Fit with the current code

The existing seams are better than they initially appear:

- `LyklabordEmojiKeyboard` already owns the custom emoji surface.
- Its `EmojiView_SwiftUI` can be wrapped in a SwiftUI `VStack` with a search
  button; adding the browse header does not require forking ISEmojiView.
- KeyboardKit 9.9.1 already defines `.emojiSearch`. In that mode it renders the
  alphabetic keyboard, suppresses the ordinary autocomplete toolbar, reserves
  emoji toolbar height, and changes Return to Done.
- `KeyboardView` also invokes the emoji builder for `.emojiSearch`, so the
  custom builder can render only the query/result header over the normal keys.

The missing piece is action routing. A shared, main-actor `EmojiSearchSession`
should be created by `KeyboardViewController` and passed to both
`LyklabordEmojiKeyboard` and `LyklabordActionHandler`. While `.emojiSearch` is
active, the handler must consume character, space and backspace gestures before
KeyboardKit's standard action writes through `textDocumentProxy`. Emoji taps
remain normal release actions so insertion, feedback and frecency stay on the
existing path.

The active search layout needs approximately one extra 40–45 point row compared
with the ordinary keyboard: query field + result row + four key rows. Apple
also grows its keyboard substantially during search. The implementation should
first test a dynamic height increase rather than compressing touch targets.
That is the main UI feasibility gate, especially on iPhone SE, landscape and
floating iPad keyboards.

## Cost, risks and decision gates

This is a medium feature, not a new prediction engine. A realistic first pass
is roughly four to seven engineering days including device hardening:

- compact deterministic index + ranking tests;
- shared search state and action interception;
- browse header and active result strip;
- height, rotation, accessibility, skin-tone and memory testing;
- simulator storyboard/replay coverage.

The primary risks are interaction bugs, not search speed:

- a leaked query character entering the host document;
- backspace deleting host text while search is active;
- a transparent emoji overlay intercepting taps on the underlying keys;
- keyboard-height jumps or clipped rows;
- loading the full corpus during ordinary typing;
- stale query state surviving host/app changes.

Gate implementation on three proofs:

1. An action-routing unit test demonstrates that `hjarta`, spaces and
   backspaces mutate only search state, while tapping `❤️` alone mutates the
   proxy.
2. A measured lazy-load prototype stays below a 1 MB dirty-memory delta and
   ranks a query within one frame on the oldest supported simulator/device.
3. ReplayRig captures browse, active query, empty result and inserted-result
   states on compact portrait, landscape and regular-width layouts without
   clipped or undersized keys.

If dynamic height proves brittle, the fallback is a single compact top band
with the query on the left and horizontally scrolling results on the right. It
is less legible than Apple's two-row pattern, but preserves normal key targets
and still keeps query text out of the host document.

## Simulator findings while researching

The live capture exposed two unrelated ReplayRig assumptions that should be
kept fixed:

- iOS 18.4 labels the Settings row `Add New Keyboard` without the ellipsis;
- the presence of `ð/þ/æ/ö` no longer identifies Lyklaborð, because iOS now has
  an `English & Icelandic` bilingual system keyboard. The rig should require an
  Icelandic key **and** Lyklaborð's dedicated alphabetic period key.

The system browse and active-search recordings used for this research are
local-only under `/tmp/lyklabord-emoji-research/`; they are evidence, not app
assets.
