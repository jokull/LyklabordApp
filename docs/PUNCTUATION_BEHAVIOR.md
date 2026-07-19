# Punctuation, comma, dot & space behavior — spec, table-stakes, and open decisions

> Scope: the micro-behaviors around **space, period, comma, and sentence
> boundaries** — the stuff no vendor documents and every keyboard reimplements.
> This is the inventory + the decisions that need an owner (you).

## How this is sourced

There is **no vendor spec** for these behaviors (confirmed: Apple's Custom
Keyboard guide gives you `insertText`/`deleteBackward` and nothing else; a
custom keyboard inherits *none* of the system keyboard's punctuation/space
smarts and must reimplement them). So "the spec" comes from three places:

1. **Code (authoritative for *our* behavior)** — `Keyboard.StandardKeyboardBehavior`
   + the `UITextDocumentProxy` sentence/word/autocomplete extensions in the
   vendored KeyboardKit, plus our overrides in `LyklabordActionHandler` and
   `LyklabordAutocompleteService`. This is deterministic; it *is* what we do.
2. **Empirical harvest (validation)** — `ReplayRig` replays a deterministic
   catalog (`ReplayRig/traces/behavior-catalog.json`) through the real keyboard
   in the simulator and records the per-step buffer (`STEP_CAPTURE=1`). Catches
   emergent interactions between the layers. *(Pending the one-time sim
   keyboard-enable; see "Next steps".)*
3. **Reference (the bar)** — native iOS + SwiftKey behavior, captured manually
   (XCUITest can't drive their internals reliably) and encoded as the
   `expected` column in the catalog.

---

## Current spec — what Lyklaborð does today

### Inherited from KeyboardKit (base layer)

| # | Behavior | Rule (from code) |
|---|---|---|
| B1 | **Double-space → ". "** | On **space release**, fires iff: two taps within **3.0s** (`endSentenceThreshold`) · cursor at a **new word** · **not** already a new sentence · buffer ends with **two spaces**. (`shouldEndCurrentSentence`) |
| B2 | **Space collapse on sentence-end** | `endSentence(". ")` **deletes *all* trailing spaces** then inserts ". " → `word  ` becomes `word. `. Collapse only happens *as part of* B1, not on its own. |
| B3 | **Auto-capitalization** | Sentence-case: first letter of a new sentence capitalized (`preferredKeyboardCase`, context `.sentences`). |
| B4 | **Switch to letters after punctuation** | After sentence-ending punctuation the layout returns to alphabetic. |
| B5 | **`.`/`!`/`?` are the sentence delimiters** | `String.sentenceDelimiters`; `isCursorAtNewSentence` keys off them. |

### Our overrides (Lyklaborð layer)

| # | Behavior | Rule (from code) |
|---|---|---|
| L1 | **Deferred period-autocorrect** | The `.` keystroke **never** applies autocorrect inline; the correction for the token still at the cursor is applied *then* the `.` is added — so `þvi.` → `því.` (`shouldApplyAutocorrectSuggestion` returns false for `.`, deferred branch re-checks). |
| L2 | **Punctuation attachment** | `word . ` → `word. ` — after a period auto-replaces, an armed memo lets the **next space re-attach** the period (deletes the space before it); any other keystroke discards the memo, so `.net` / `example.com` survive. (`pendingPunctuationAttachment`) |
| L3 | **Revert-on-continuation** | If a `.` auto-replaced a token and the next key is a letter/digit, the replacement is **undone** — URLs/domains self-heal. (`pendingContinuationRevert`) |
| L4 | **Spacebar mode 2 (optional)** | If the user picks "always insert a prediction", a space with **no word in progress** inserts the top prediction before the space. **Side effect:** the buffer no longer ends in `  `, so it can *suppress* B1 (double-space→period). Default mode does not do this. |
| L5 | **Long-press = deliberate** | A char chosen from a long-press callout is flagged deliberate (no touch-model sample, no near-miss autocorrect). |

---

## Table-stakes — behaviors we must match (and our status)

These are the ones users notice immediately if missing. ✅ = we do it, ⚠️ = partial/at-risk, ❓ = needs the empirical harvest to confirm.

| Behavior | Native / SwiftKey | Lyklaborð | Status |
|---|---|---|---|
| Double-space → ". " (with the "." shortcut on) | yes | B1 | ✅ |
| Collapse the two spaces when doing so | yes | B2 | ✅ |
| Auto-cap after ". " | yes | B3 | ✅ |
| Autocorrect the word when you end it with punctuation | yes | L1 | ✅ |
| Don't fight URLs/emails/domains | yes | L3 + field-kind guards | ✅ |
| Return to letters after sentence punctuation | yes | B4 | ✅ |
| Smart quotes → **Icelandic `„ …"`** on the IS locale | native: yes; SwiftKey: inconsistent | — | ⚠️ **gap** (see D1) |
| Smart dashes `--` → `—`, `...` → `…` | yes | — | ❓ (see D6) |
| No double-space→period after a number/ordinal (`3.` ) | native: mostly | B1 has no number guard | ⚠️ (see D4) |

**The one clear table-stakes gap: Icelandic smart quotes.** Everything else is either in place or needs the harvest to confirm.

---

## Open decisions — what I think you'll want to decide

Grouped by type. Each has my recommendation, but these are genuinely your calls.

### Icelandic-specific (where we can be *correct* where others aren't)

- **D1 — Icelandic smart quotes `„ …"`.** Icelandic opens with `„` (low) and
  closes with `"` (high), not `" "` or straight quotes. Most keyboards get this
  wrong on the IS locale. Should typing `"` auto-produce the correct
  contextual Icelandic quote (open vs close based on preceding char)?
  **Rec: yes — it's a signature "actually knows Icelandic" win.** Ties into
  backlog #38 (don't force-correct `„`-quoted foreign words).
- **D2 — Decimal comma / thousands dot.** Icelandic writes numbers as
  `1.000,50` (dot = thousands, comma = decimal). Punctuation smarts (attachment,
  sentence-end, autocorrect) must **not** fire *inside a number*. Should we add
  a "cursor is inside a number" guard that suppresses L1/L2/B1?
  **Rec: yes — mis-handling `,`/`.` in prices/quantities is a very visible bug.**
- **D3 — Ordinals.** Icelandic ordinals are `1.`, `2.`, `21.`. A period after a
  digit is an ordinal, not a sentence end. Should B1/B3 (double-space→period,
  auto-cap) be suppressed after `<digit>.`?
  **Rec: yes, at least suppress an *extra* period; auto-cap after an ordinal is
  usually still wrong too.**

### Improvements over Apple (deliberate divergence)

- **D4 — Collapse a stray double-space even when B1 doesn't fire.** Native
  leaves `  ` (two spaces) whenever the period-shortcut conditions fail (already
  a new sentence, >3s apart, after punctuation). **This is almost certainly your
  reported quirk.** Do we want to *also* collapse an accidental `  ` → ` ` in
  those cases? **Rec: cautious yes for the "already ended sentence" case (`. ` +
  space → don't grow to `.  `); leave the rest to B1 to avoid eating deliberate
  double spaces (code, ASCII art).** This is backlog #39.
- **D5 — Reconcile Spacebar mode 2 with double-space→period (L4 vs B1).** In
  mode 2, inserting a prediction on the first space suppresses the double-space
  period. Decision: in mode 2, should a *second* immediate space still end the
  sentence? **Rec: yes — detect the "space space" intent before the prediction
  insert.** (Only affects users who opt into mode 2.)
- **D6 — Smart dashes / ellipsis (`--`→`—`, `...`→`…`).** Apple does this; we
  don't yet. Cheap to add. **Rec: add ellipsis (common in IS), make em-dash a
  toggle (some dislike it).**
- **D7 — Space-before-punctuation cleanup beyond period.** L2 attaches a
  stray space before a *period*. Extend the same to `, ! ? : ;`?
  **Rec: yes for `,`/`!`/`?`; skip `:`/`;` (rarer, riskier).**

### Settings / user control (mirror iOS's own toggles)

- **D8 — Which of these are user-toggleable?** iOS exposes "." Shortcut, Smart
  Punctuation, Auto-Correction as settings. **Rec: ship toggles for
  double-space-period (D-B1), smart quotes (D1), and smart dashes/ellipsis (D6);
  keep the rest always-on.** A custom keyboard can't read the *system* "."
  Shortcut toggle, so we need our own.

---

## Your reported double-space quirk — likely cause

Given the code: `word  ` collapses to `word. ` **only** when B1's four
conditions all hold. It does **not** collapse when the buffer is already at a
new sentence, when the taps are >3s apart, or — in Spacebar mode 2 — when a
prediction was inserted between the spaces (L4). So the two spaces you saw
"failing to collapse" are B1 declining to fire, which is technically
Apple-equivalent (Apple also leaves two spaces there). Whether we should be
*better* than Apple here is exactly **D4 / D5** above. The empirical harvest
will tell us which specific condition your case hit.

---

## Next steps

1. **Empirical harvest** (validates the spec above + fills the `expected`
   column): the `ReplayRig` pipeline is wired and runs end-to-end, but needs the
   **one-time sim keyboard-enable** (XCUITest can't flip Settings toggles):
   on the `ReplayRig` simulator — Settings → General → Keyboard → Keyboards →
   Add → Lyklaborð → Allow Full Access → then globe-select it once. After that
   `STEP_CAPTURE=1 scripts/replay-run.sh ReplayRig/traces/behavior-catalog.json`
   runs unattended and records per-step behavior + a video.
2. **Decide D1–D8** (or a subset) → each becomes a spec'd, catalog-tested behavior.
3. **Reference pass**: one manual capture of native + SwiftKey on the same
   catalog → fills `expected` → every divergence is now a tracked, regressable row.
```
