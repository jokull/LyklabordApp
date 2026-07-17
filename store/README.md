# store/ — App Store submission asset pack

Everything needed to submit **Lyklaborð** to the App Store, generated locally.
**Nothing here has been uploaded.**

The project moved from an org Apple Developer team to **Jökull's personal
team (Team ID `RDC8539AWM`)**, with new identifiers: app bundle
`is.solberg.lyklabord`, keyboard extension `is.solberg.lyklabord.keyboard`,
App Group `group.is.solberg.lyklabord`, CloudKit container
`iCloud.is.solberg.lyklabord`. The old App Store Connect record (Apple ID
`6791665837`, name "Lyklaborð", bundle `is.lyklabord.ios`) lives on the old
team and will be **deleted**; a new record gets created on the personal team
under the identifiers above. See "Personal team migration" below for the
order of operations — read it before touching App Store Connect.

Commercial model: base keyboard **free forever** (layout, autocorrect,
prediction, blend). **"Lyklaborð+"** is a $19/year auto-renewable
subscription that gates the personal-vocabulary + typo-learning layer
(learned words, dictionary editor, iCloud sync). See "Subscription setup"
below for the ASC-side steps.

Generated 2026-07-16 for iPhone **6.9"** (1260 × 2736), the single required
iPhone screenshot size (per the app-store-screenshots skill and Apple's current
spec). Note: the brief mentioned 1320×2868 / 1284×2778 — those are **superseded**;
the skill and Apple's current reference both give **1260 × 2736** as the correct
6.9" size, which is what was produced. To also emit 6.5" (1284 × 2778), change
`W,H` in `screenshots/build/generate.py` + `render.sh` and re-run.

---

## What's in here

```
store/
├── research.md                      Competitor + ASO analysis → screenshot strategy
├── research/competitors/            Downloaded SwiftKey & Gboard screenshots (reference)
├── metadata/
│   ├── en.md                        en-US: name, subtitle, promo, keywords, description, what's-new, URLs, category
│   ├── is.md                        is-IS: same, description Gemini-proofed
│   ├── app-review.md                Age rating, privacy label worksheet, ATT, export compliance, reviewer notes
│   └── charcheck.txt                Character-limit verification for every capped field
├── assets/
│   ├── keycap.png                   Wave-5 keycap render (opaque)
│   ├── keycap-float.png             Wave-5 keycap, background knocked out (used in hero)
│   └── appicon.png                  Wave-6 app icon (1024)
└── screenshots/
    ├── build/generate.py            Data-driven HTML builder (faithful Icelandic keyboard recreation)
    ├── build/render.sh              Headless-Chrome → PNG at exact 1260×2736 (no GUI, no upload)
    ├── build/html/                  12 generated standalone HTML pages
    ├── export/is-IS/ (6 PNG)        Final Icelandic screenshots
    ├── export/en-US/ (6 PNG)        Final English screenshots
    └── preview/index.html           Side-by-side preview of all 12
```

### Regenerating screenshots
```bash
cd store/screenshots/build
python3 generate.py      # rebuild HTML from data/captions
./render.sh              # render all → export/{locale}/*.png (verifies dimensions)
open ../preview/index.html
```
Captions/content live in the `CONTENT` dict and the per-screenshot builders in
`generate.py`. Palette + fonts are copied verbatim from the live site.

### Re-verifying metadata character limits
```python
python3 - <<'PY'
for f,lim in [("name",30),("subtitle",30),("promo",170),("keywords",100),("desc",4000)]:
    pass  # counts recorded in metadata/charcheck.txt; edit fields then recount len(str)
PY
```

---

## Screenshot set (6 per locale × 2 locales = 12)

| # | File | Caption is-IS / en-US |
|---|---|---|
| 1 | `01_hero` | Lyklaborðið sem skilur íslensku / The keyboard that knows Icelandic |
| 2 | `02_accents` | Skrifaðu broddlaust / Type accent-naked |
| 3 | `03_blend` | Íslenska og enska, blandað / Icelandic and English, blended |
| 4 | `04_bin` | Skilur beygingar / It understands inflection |
| 5 | `05_dictionary` | Orðaforðinn þinn — í alvöru þinn / Your vocabulary, truly yours |
| 6 | `06_privacy` | Ekkert netsamband / Zero networking code |

All 12: exactly **1260 × 2736**, PNG, < 1 MB each (well under Apple's 8 MB cap).

---

## Submission checklist

### A. Ready now (in this pack — review these)
- [x] Research + ASO strategy (`research.md`)
- [x] 6 screenshots × 2 locales at 1260×2736 (`screenshots/export/`)
- [x] Metadata is-IS + en-US, all fields within limits (`metadata/`) — **but
      see A.1 below: only `metadata/en.md` is uploadable as the ASC listing.**
- [x] Age rating answers (→ 4+), privacy-label worksheet, reviewer notes (`metadata/app-review.md`)
- [x] Privacy Policy URL (interim GitHub `docs/PRIVACY.md` link)

### A.1 Locale correction — read before touching Content in ASC
App Store Connect's supported metadata locales do **not** include Icelandic.
There is no `is` / `is-IS` option in the App Information → Localizations
picker. Consequence:
- **Primary language = English (U.S.).** The earlier assumption in this pack
  (and in older `app-review.md` notes) that Icelandic would be the primary
  ASC locale was wrong and has been corrected below.
- `metadata/en.md` is the **only** listing that gets uploaded to ASC.
  `metadata/is.md` is not dead weight — it's the source voice for the
  marketing site (`site/src/pages/index.astro`, which is already
  Icelandic-first) and for any future in-app localized strings — but it does
  not get pasted into a second ASC localization because that slot doesn't
  exist.
- If Nordic/EU storefront reach matters later, the nearest available ASC
  locales are Danish/Norwegian/Swedish — out of scope for v1.

---

## Personal team migration — order of operations
Do these **in order**. Steps 2–4 are a race window; have everything staged
before you start deleting anything.

1. **Stage first, delete second.** Before touching the old app record,
   confirm this pack is upload-ready: `metadata/en.md` finalized, all 6
   `screenshots/export/en-US/*.png` reviewed, `metadata/app-review.md`
   answers current (this file already reflects the personal-team facts).
2. **Delete the old app record**: App Store Connect (old org team) → My Apps
   → "Lyklaborð" (Apple ID `6791665837`, bundle `is.lyklabord.ios`) → App
   Information → Delete App.
   > ⚠️ **Name-race warning.** The app name "Lyklaborð" is reserved
   > globally across the whole App Store, not per-team. The instant the old
   > record is deleted, any other developer (on any team) can reserve that
   > name. Do not leave the account in a deleted-but-not-recreated state —
   > go straight to step 3.
3. **Immediately create the new app record** on the personal team
   (`RDC8539AWM`):
   - Register identifiers first in Certificates, Identifiers & Profiles (or
     let Xcode automatic signing do it on first archive with the personal
     team selected): app bundle `is.solberg.lyklabord`, keyboard extension
     `is.solberg.lyklabord.keyboard`, App Group `group.is.solberg.lyklabord`,
     iCloud container `iCloud.is.solberg.lyklabord`.
   - New app record: Platform iOS, Name "Lyklaborð", **primary language =
     English (U.S.)** (see A.1), bundle ID `is.solberg.lyklabord`, SKU (e.g.
     `lyklabord-ios`), category **Utilities** (secondary Productivity).
4. Paste metadata from `metadata/en.md` into the en-US localization only.
5. Enter the App Privacy questionnaire as **Data Not Collected** per
   `metadata/app-review.md` (mind the CloudKit-sync and subscription
   nuances — both are covered there).
6. Paste the reviewer notes (Full Access + subscription-value justification)
   from `metadata/app-review.md`.
7. Set age rating to 4+ using the answers in `metadata/app-review.md`.

---

## Subscription setup — "Lyklaborð+" ($19/year)
Requires the base app record to exist first (above).

- [ ] **Agreements, Tax, and Banking**: sign the Paid Apps Agreement and
      enter banking + tax info in ASC. Required for *any* IAP/subscription,
      even though the app itself is free — this is the step people forget
      and then can't understand why the subscription won't save.
- [ ] **Features → Subscriptions → create a Subscription Group** (e.g.
      "Lyklaborð+"), localized display name in en-US only (A.1 applies here
      too — no `is` locale for subscription metadata either).
- [ ] **Create one auto-renewable subscription**: product ID e.g.
      `is.solberg.lyklabord.plus.annual`, duration **1 year**, price point
      the nearest tier to **$19.00 USD** (Apple auto-generates the other
      territory price points from the tier — no need to hand-set every
      country). Subscription display name + description (en-US). Optional
      1024×1024 subscription image.
- [ ] **Review notes for the subscription**: state plainly what it unlocks —
      personal-vocabulary learning, typo/autocorrect learning, the
      dictionary editor, and iCloud sync of the personal dictionary. State
      that the base keyboard (layout, autocorrect, prediction, blend) is
      fully functional and free without it — reviewers specifically check
      that a subscription isn't gating table-stakes functionality.
- [ ] **Terms of Use (EULA)**: default to Apple's standard EULA (no action
      needed beyond confirming App Information → License Agreement is left
      on "Apple's Standard License Agreement") unless a custom EULA is
      wanted. Apple's guidelines require either the standard EULA link or a
      custom one to be reachable from the app description when
      auto-renewable subscriptions are offered — flagged as a copy action
      item in `messaging-audit.md` rather than applied to `metadata/en.md`
      here (that file's prose is out of scope for this pass).
- [ ] **Privacy Policy URL is mandatory for subscriptions** (ASC checks for
      it explicitly, separately from the general Data Not Collected
      review). Keep the current interim GitHub `docs/PRIVACY.md` link — the
      site (`site/src/pages/index.astro`) has no `/privacy` route today
      (checked `site/src`: only `index.astro` + `scripts/hero.js` exist), so
      do not point at `lyklabord.solberg.is/privacy` until that page is
      actually built.
- [ ] **Submit the subscription for review together with the first app
      version** — standard flow for a subscription added to a brand-new app
      record; it does not need a separate review request the first time.
- [ ] **Paywall placement**: the purchase UI must live in the **containing
      app**, never in the keyboard extension — extensions cannot present
      StoreKit purchase sheets reliably and Apple review checks this
      (Guideline 3.1.1). Confirm this is how the app is built before
      submitting; see the review-risk notes in `metadata/app-review.md`.

---

### B. Screenshot upload (once an App Store Connect API key exists)
_The app-store-screenshots skill's Workflow 9 automates this. Requirements:_
- [ ] App Store Connect **API key** (`.p8`), Key ID, Issuer ID — see
      "TestFlight / API key" below for how self-serve creation works on the
      personal team.
- [ ] An editable version in `PREPARE_FOR_SUBMISSION`.
- [ ] Upload via the skill's API flow: create `appScreenshotSet` with
      display type **`APP_IPHONE_67`** (the 6.9" images map to the 67 slot —
      `APP_IPHONE_69` does not exist in the API), reserve → upload binary →
      commit each PNG, for the **en-US** localization (per A.1, `is` is not
      a valid ASC localization to attach screenshots to).
- [ ] Order 01→06 as listed above.

### C. Build / entitlement gates (engineering, before the binary ships)
- [ ] **`ITSAppUsesNonExemptEncryption`** in `App/Info.plist` once CryptoKit
      sync lands, + claim the standard exemption in ASC. **Blocks TestFlight
      builds if unanswered.** (roadmap §1)
- [ ] **Production CloudKit schema deploy:** the container is
      `iCloud.is.solberg.lyklabord` — brand-new under the personal team (any
      schema that existed under the old team's container is irrelevant; this
      is a from-scratch deploy). Promote Development → Production in the
      CloudKit Console (or `cktool`) under the **personal team's** CloudKit
      dashboard before any public/TestFlight build uses sync — records
      written against a Dev-only schema fail in production. Pair with the
      export-compliance flag above (both are sync-gated).
- [ ] Confirm globe (next-keyboard) key is present on every layout, and
      manual QA pass with **Full Access denied** (typing/autocorrect/
      prediction must still work) — roadmap §1 v1-blocker.
- [ ] Host the privacy policy at a stable URL (`lyklabord.solberg.is/privacy`)
      and swap the Privacy Policy URL in both metadata files (currently the
      interim GitHub link) — **not yet possible**: `site/src` has no
      `/privacy` page built. Until it exists, the GitHub link is the correct
      URL to submit, not a placeholder to fix first.

### D. TestFlight / API key (personal team)
- [ ] **App Store Connect API key is self-serve on a personal (Individual /
      Sole Proprietor) team**: Users and Access → Integrations → App Store
      Connect API → Generate API Key, role "App Manager" or "Admin". The
      account holder can do this directly with no organizational-admin
      approval step — this was the slow/blocked part on the old org team;
      on the personal team it's immediate.
- [ ] Archive in Xcode → upload build to App Store Connect.
- [ ] Resolve the export-compliance prompt (see C) — it recurs every build until the Info.plist key is set.
- [ ] Internal TestFlight first (no review); then external TestFlight (needs a short Beta App Review + the same reviewer notes).
- [ ] Verify on a real device: keyboard enable flow, Full-Access-off typing, accents/inflection/blend behaviors that the screenshots promise, SwiftKey import, and the subscription purchase/restore flow in the containing app.
- [ ] Submit for App Review with the notes from `metadata/app-review.md`.

---

## Notes / decisions
- **Screenshots recreate the real keyboard in HTML/CSS** (true Icelandic layout, quoted verbatim suggestion slot) rather than capturing the simulator — accuracy over gloss, per brief, and reproducible without a running build. When the app is device-runnable, consider re-shooting hero/feature frames from real captures for the final pass.
- **Palette/typography** are copied verbatim from `site/dist/index.html` (`--bg #faf9f6`, `--ink #1c1b1a`, keycap `#d7d2c8`, system sans / ui-monospace) so the listing matches the marketing site.
- **Icelandic description + what's-new** were proofed through Gemini (`translate-to-icelandic` skill); two spelling/casing hand-fixes are logged at the bottom of `metadata/is.md`. Short capped fields (subtitle/keywords/promo) were hand-crafted from the site's native voice to hit exact limits. `metadata/is.md` is retained as source voice for the site and any future in-app strings — see A.1 above for why it is not itself uploadable to ASC.
- **No uploads** have been made to App Store Connect. This pack is versioned in the repo; screenshots and renders are intentionally committed alongside the metadata so the submission pack stays reproducible from git history.
