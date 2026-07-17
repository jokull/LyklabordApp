# Messaging audit — Lyklaborð+ subscription launch

**Scope note: this file is a report only. Nothing in `README.md` (repo root)
or `site/` was edited to produce it** — those are owned by other work. This
audit exists so whoever *does* touch that copy has a punch list and
honest-phrasing suggestions ready, rather than starting from scratch.

## Why this matters

The commercial model decided: base keyboard **free forever** (layout,
autocorrect, prediction, Icelandic/English blend). **"Lyklaborð+"** ($19/year)
gates the personal-vocabulary + typo-learning layer (on-device learned words,
dictionary editor, iCloud sync).

Every piece of copy below currently promises "Free. Open source. No account."
as an unqualified headline, and features "Learning you own" / the personal
dictionary as a **free, included** headline capability. Both claims become
partially inaccurate the moment Lyklaborð+ ships. This is a correctness
problem, not just a nice-to-have — App Review will also read this copy
against the actual paywall (see `store/metadata/app-review.md`'s review-risk
notes on subscription value clarity), so overclaiming "free" here creates
review risk on top of a user-trust risk.

The good news: nothing here requires a dishonest walk-back. The keyboard
*is* still free, open source, and account-free at its base — the fix is
precision, not retraction: **"free" needs a qualifier (the base keyboard),
and "learning/personal dictionary" needs to be named as the paid layer.**

---

## Every location that needs a wording update

### 1. `README.md` (repo root)

**Line 22** (below the one-paragraph pitch):
> Free. Open source. No account. No telemetry. No AI bloat.

Risk: reads as a blanket claim covering the whole feature set, including the
now-paid learning layer.

Suggested replacement:
> Base keyboard free forever. Open source. No account for the free tier. No
> telemetry. No AI bloat. Personal-vocabulary learning is an optional
> subscription (Lyklaborð+) — see below.

**Lines 20–21** (the "what SwiftKey should have been" pitch paragraph):
> ...on-device learning with a personal dictionary you fully control, and a
> hard privacy guarantee...

Risk: lists "on-device learning with a personal dictionary" alongside
inherently-free capabilities (blend, morphology, privacy) with no signal that
it's the one paid feature in the list.

Suggested replacement: split the sentence so free and paid capabilities are
visually/grammatically distinct, e.g.:
> ...one Icelandic layout that fluently blends Icelandic and English as you
> type, morphology-aware autocorrect built on BÍN, and a hard privacy
> guarantee: the keyboard extension contains zero networking code. An
> optional Lyklaborð+ subscription adds on-device learning with a personal
> dictionary you fully control.

**Line 34** (feature bullet):
> - **Learning you own**: words are learned on-device (2 distinct days, or
>   instantly when you tap the verbatim suggestion), individually
>   deletable — deletions stick, and importable from a SwiftKey data export.
>   Nothing you type in password, URL, or email fields is ever recorded.

Risk: this bullet sits in a flat list of free features with no indication
it's gated.

Suggested replacement: prefix with a tag, e.g. `**Learning you own
(Lyklaborð+):**`, or move it to its own short subsection titled "Lyklaborð+ —
$19/year" beneath the free feature list, so the free/paid boundary is
structural, not just a word choice.

**Note**: `README.md` is a developer-facing repo README, not App Store copy —
lower review risk than the store listing, but it's the first thing anyone
opens on GitHub (including from the "verify it in the source" claim repeated
everywhere else), so it should not contradict what App Review and the store
listing say.

---

### 2. `site/src/pages/index.astro`

**Line 5** (meta description):
> Lyklaborð er opið og ókeypis iOS-lyklaborð fyrir íslensku og ensku í senn:
> leiðréttingar sem skilja beygingar (byggðar á BÍN), broddar settir
> sjálfkrafa, ekkert netsamband. Væntanlegt í App Store.

`ókeypis` ("free") is used as a blanket adjective for the whole app. This is
still true of the described feature set in this sentence (autocorrect,
accents, no networking) — none of those are gated — so this specific line is
actually *safe as written* as long as the personal-dictionary feature isn't
folded into the same sentence later. Flagging only because it sets the
site-wide "ókeypis" framing that line 87–92 below breaks.

**Lines 86–93** (feature card "Orðaforðinn þinn — í alvöru þinn" / "Your
vocabulary, truly yours"):
> Lyklaborðið lærir orðin þín á tækinu sjálfu. Þú getur skoðað hvert og eitt,
> eytt þeim hverju fyrir sig — og flutt orðaforðann þinn inn úr SwiftKey.

Risk: presented as one of six flat feature cards, same visual weight and
"free" framing as the zero-networking card next to it. A visitor reading the
page has no way to know this one card is the subscription.

Suggested replacement: keep the card, but add a small badge/label in the
card (e.g. a "Lyklaborð+" pill next to the `<h2>`) and adjust the copy to
name the subscription, e.g.:
> Með Lyklaborð+ lærir lyklaborðið orðin þín á tækinu sjálfu. Þú getur skoðað
> hvert og eitt, eytt þeim hverju fyrir sig — og flutt orðaforðann þinn inn
> úr SwiftKey.
(English equivalent: "With Lyklaborð+, the keyboard learns the words you
type on-device...")

**Lines 122–132** (English section, full paragraph):
> Lyklaborð is a free, open-source, privacy-first iOS keyboard for Icelandic
> that also types excellent English — on a single layout, with no language
> switching. Autocorrect is morphology-aware, built on the BÍN database of 3
> million Icelandic word forms; type accent-naked and the accents are
> restored for you. **Everything the keyboard learns stays on your device,
> individually inspectable and deletable, with SwiftKey import.** The
> keyboard extension contains zero networking code — a claim you can verify
> in the source, not just a promise. Coming to the App Store.

Risk: the bolded sentence above states the paid feature as unconditional
fact in the same breath as "free, open-source." This is the single biggest
wording risk on the whole site — it's the canonical English pitch paragraph,
likely to be quoted/screenshotted, and it's now inaccurate as written.

Suggested replacement:
> Lyklaborð is a free, open-source, privacy-first iOS keyboard for Icelandic
> that also types excellent English — on a single layout, with no language
> switching. Autocorrect is morphology-aware, built on the BÍN database of 3
> million Icelandic word forms; type accent-naked and the accents are
> restored for you. The keyboard extension contains zero networking code — a
> claim you can verify in the source, not just a promise. An optional
> subscription, Lyklaborð+, adds on-device learning of your own words and
> phrases — inspectable and deletable, with SwiftKey import — synced
> privately to your own iCloud. Coming to the App Store.

**Trust section (lines 104–117)** is unaffected — it talks about open source
and the privacy policy, not the feature/pricing split. No change needed.

---

### 3. Store descriptions (`store/metadata/en.md`, `store/metadata/is.md`)

These are the highest-stakes copy: they go through App Review, and
`store/metadata/app-review.md`'s new review-risk notes explicitly call out
that reviewers check subscription copy for honesty about what's gated.
**Not edited in this pass** (out of scope per task instructions — the prose
itself belongs to whoever runs the subscription-copy pass), but every
instance below needs the same fix as README/site.

**`en.md` line 30** (opening description paragraph):
> ...on-device learning you fully control, and a hard privacy guarantee you
> can verify in the source. **Free. Open source. No account. No telemetry.
> No AI bloat.**

Same issue as `README.md` line 22 — "Free" reads as covering the whole
sentence, including "on-device learning you fully control."

Suggested replacement:
> ...and a hard privacy guarantee you can verify in the source. **Free base
> keyboard. Open source. No account required. No telemetry. No AI bloat.**
> On-device learning of your own words is an optional subscription,
> Lyklaborð+.

**`en.md` lines 17** (promotional text, 170-char field — tight budget):
> Free, open source, network-free — the Icelandic keyboard that places
> accents for you, understands BÍN inflection, and learns your words
> on-device. Coming soon.

Risk: "learns your words on-device" stated as a free, unconditional
capability in a 170-char field that App Review reads directly against the
paywall.

Suggested replacement (within budget — needs a recount against the 170
limit before use):
> Free, open source, network-free Icelandic keyboard: accents restored for
> you, BÍN inflection understood. Lyklaborð+ adds on-device word learning.

**`en.md` lines 44–45** (the "YOUR VOCABULARY, TRULY YOURS" section header
and body) — entirely reframe as the subscription section. Suggested header:
`YOUR VOCABULARY, TRULY YOURS (LYKLABORÐ+)`, with a lead sentence naming the
subscription explicitly before the existing body copy.

**`en.md` line 60** (What's New v1.0):
> First release. One Icelandic-and-English layout with morphology-aware
> autocorrect built on all 3 million BÍN word forms, automatic accent
> restoration, **on-device learning with a personal dictionary you fully
> control**, SwiftKey import, and a keyboard extension with zero networking
> code. Open source under MIT.

Suggested replacement: name Lyklaborð+ explicitly, e.g. "...automatic accent
restoration, a keyboard extension with zero networking code, and an optional
Lyklaborð+ subscription for on-device personal-vocabulary learning with
SwiftKey import. Open source under MIT."

**`is.md`**: mirror every fix above once the English wording is settled —
run the finalized English replacements through the `translate-to-icelandic`
skill (Gemini) rather than hand-translating, per this repo's established
practice (see `is.md`'s own proofing note). Same line numbers apply
structurally: line 31 (opening description "Ókeypis. Opinn frumkóði. Enginn
aðgangur nauðsynlegur."), line 19 (promotional text), lines 45–46 ("ÞINN
ORÐAFORÐI, RAUNVERULEGA ÞINN"), line 61 (What's New).

---

### 4. `docs/PRIVACY.md`

This one is different in kind: it's a legal/factual document, not marketing,
so the fix isn't "soften the free claim" — it's **disclose which tier a data
behavior belongs to**, so a free-tier user isn't surprised to learn the
policy describes learning behavior they haven't actually enabled.

**Lines 26–35 / 79–88** ("What is stored on your device"): currently
describes learned words, bigram counts, touch stats, and manual
add/delete as things "the keyboard" does unconditionally. Once learning is
subscription-gated, a free-tier user reading this section could reasonably
wonder whether it applies to them.

Suggested addition (one sentence at the top of the section, both languages):
> Personal-vocabulary learning (learned words, the dictionary editor, and
> iCloud sync described below) is available with the optional Lyklaborð+
> subscription. The base keyboard does not learn or store any of the
> following without it.

This is a factual/legal correction, not a tone one — flagging it here
because it's the one place in the audit where the fix is disclosure
accuracy rather than marketing honesty, and because `docs/PRIVACY.md` is
explicitly out of scope for edits in this task (owned elsewhere per the
task's SUBSCRIPTION.md note) even though it was read for context.

---

## Ranked by risk (biggest wording risk first)

1. **`site/src/pages/index.astro` English section (lines 122–132)** — the
   single paragraph most likely to be quoted verbatim elsewhere, states the
   paid feature as free fact in the same sentence as "free, open-source."
2. **`store/metadata/en.md` description + promo text** — goes through App
   Review directly; review-risk notes in `app-review.md` now explicitly flag
   that reviewers check this against the paywall.
3. **`README.md` line 22 "Free. Open source. No account."** — lower
   real-world risk (developer-facing, not store-facing) but highest
   visibility as the literal first line under the project pitch.
4. **`site/src/pages/index.astro` feature card (lines 86–93)** — same issue
   as #1 but lower risk since it's one card among six rather than the
   canonical pitch paragraph.
5. **`docs/PRIVACY.md`** — lowest urgency (legal doc, not promotional), but
   the fix is a disclosure-accuracy one, not just tone, so it shouldn't be
   skipped once the tiering is final.

## What stays exactly as-is

- "Open source" claims — true regardless of tier; the open-source build
  includes everything, paid and free (per the task's framing: "open-source
  builds include everything").
- "Zero networking code" / privacy claims — unaffected by the subscription
  (see `store/metadata/app-review.md`'s new privacy-label section).
- "No account" for the **free tier** — still true; a subscription purchase
  goes through the user's existing Apple ID via StoreKit, not a new account
  system. Worth being explicit about "no *new* account" if any copy gets
  more detailed here, since "no account" and "pay via your Apple ID" can
  read as mildly in tension to a skeptical reader even though both are true.
