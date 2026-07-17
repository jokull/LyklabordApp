# App Store Connect — review answers, age rating & privacy label

Everything a reviewer/questionnaire needs, justified against `docs/PRIVACY.md`
and `research/tablestakes-roadmap.md §1`.

App: bundle `is.solberg.lyklabord` (+ keyboard extension
`is.solberg.lyklabord.keyboard`), personal Apple Developer team (Team ID
`RDC8539AWM`). Commercial model: base keyboard free forever; **"Lyklaborð+"**
is a $19/year auto-renewable subscription gating personal-vocabulary + typo
learning (learned words, dictionary editor, iCloud sync). See
`store/README.md` for the full ASC recreation + subscription setup runbook.

---

## Age rating (Apple questionnaire)

Target rating: **4+**. Answer every content question **None / No**:

| Question | Answer |
|---|---|
| Cartoon/Fantasy Violence, Realistic Violence, Prolonged Violence | None |
| Sexual Content or Nudity, Profanity or Crude Humor | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Mature/Suggestive Themes, Horror/Fear Themes | None |
| Gambling (simulated or real), Contests | None |
| Medical/Treatment Information | None |
| Unrestricted Web Access | **No** (the keyboard has no web view and no network code) |
| User-Generated Content / social features | **No** |
| Data collection used for tracking | **No** |

Result: **4+**, no age gate.

---

## App privacy label — "Data Not Collected"

Declaration: **Data Not Collected** (App Store Connect → App Privacy →
"We do not collect data from this app").

Justification (per `docs/PRIVACY.md`):
- The keyboard extension contains **no networking code** — there is no code path
  that transmits anything off device. Verifiable in the open source.
- No analytics, no diagnostics, no crash reporting, no advertising identifiers,
  no third-party SDKs.
- On-device learning (learned words, bigram counts, per-key touch averages,
  user edits/tombstones) stays in the app's private container and is **not
  collected by us** — it never reaches any server we operate (we operate none).
- **iCloud sync nuance (the one thing to get right):** optional sync writes an
  AES-256-GCM-encrypted copy of the user's personal dictionary to the user's
  **own** CloudKit private database, initiated by the user, with the key held
  only in the user's iCloud Keychain. This is the user's data in the user's own
  iCloud — **not data collected by the developer**, and not "linked to identity"
  in Apple's taxonomy. It does not change the "Data Not Collected" answer.
  (If ASC's questionnaire pushes on "data used to provide sync/backup," the
  honest framing: the developer neither receives nor can read this data.)
- **StoreKit subscription purchases (added with Lyklaborð+) do not change
  this answer.** Purchase processing, receipt/transaction verification, and
  renewal state are handled entirely by Apple's StoreKit — the app calls
  Apple's on-device APIs and never operates a server that receives purchase
  or payment data. Apple's own App Privacy guidance is explicit that data
  collected by Apple's frameworks on Apple's own behalf (e.g. StoreKit
  purchase processing) does not need to be declared by the developer unless
  the developer's own code additionally collects or links it — this app's
  code does neither: no analytics event fires on purchase/renewal/cancel, no
  purchase or subscription-status data is sent anywhere. The on-device
  "is subscribed" entitlement flag used to gate personal-vocabulary features
  is cached locally only, exactly like the existing learned-word data —
  never transmitted, so it does not change the "not collected" analysis
  already established for on-device learning above.
  - **Verdict: no privacy-label change required.** "Data Not Collected"
    still holds after adding subscriptions. Flag honestly: if a server-side
    receipt-validation step or any purchase analytics is added later, this
    verdict must be re-run — it depends entirely on purchases staying
    client-side/StoreKit-only.

## App Tracking Transparency
**No ATT prompt.** Zero IDFA, zero cross-app/cross-site tracking, zero ad SDKs —
nothing to declare, so the app never presents the ATT prompt. (Worth stating in
review notes so its absence doesn't read as an oversight.)

---

## Export compliance (`ITSAppUsesNonExemptEncryption`)
- Once CryptoKit AES-GCM sync ships, set **`ITSAppUsesNonExemptEncryption = YES`**
  in `App/Info.plist` **and** claim the standard exemption in ASC (Apple's own
  CryptoKit used for its intended purpose → exempt, no BIS filing).
- Until sync code is in the build, either the key is absent (sync not present)
  or set to `NO`. **This flag blocks TestFlight builds if unanswered once crypto
  lands** — see roadmap §1.

---

## App Review notes (paste into "Notes for Reviewer")

> Lyklaborð is an Icelandic/English keyboard extension. The base keyboard —
> layout, autocorrect, prediction, Icelandic/English blend — is free and
> fully functional with no account and no purchase. An optional
> subscription, "Lyklaborð+" ($19/year), unlocks a personal-vocabulary and
> typo-learning layer on top (see PAYWALL below).
>
> FULL ACCESS ("RequestsOpenAccess = YES"): Full Access is used **only** to
> share the App Group container between the app and the keyboard (for the
> personal-dictionary and optional iCloud sync) and to enable typing haptics
> (iOS blocks the haptic engine for third-party keyboards without Full Access).
> It is **not** used for networking — the extension contains no networking code
> at all. Typing, autocorrect, and prediction are fully functional with Full
> Access DENIED (Guideline 4.4.1); only sync, personal-vocabulary learning, and
> haptics degrade.
>
> To verify with Full Access off: General → Keyboard → Keyboards → Lyklaborð →
> turn Allow Full Access OFF, then type — autocorrect and predictions still work.
>
> PAYWALL: the Lyklaborð+ purchase and restore flow is presented **only in
> the containing app** (Settings), never inside the keyboard extension —
> extensions cannot host a StoreKit purchase sheet. The extension checks a
> locally cached entitlement flag written by the app; it makes no purchase
> calls itself. What subscribing unlocks is stated plainly at the point of
> purchase: on-device learning of the words you type, a dictionary editor to
> inspect/delete learned words, and optional encrypted iCloud sync of that
> dictionary across your devices. Everything else — the keyboard layout,
> autocorrect, prediction, and the Icelandic/English blend — works
> identically whether or not Lyklaborð+ is active.
>
> PRIVACY: No analytics, no tracking, no ads, no third-party SDKs, no network
> calls from the extension. Privacy label is "Data Not Collected," including
> after adding the subscription — purchases are processed entirely by
> Apple's StoreKit; we operate no server and collect no purchase data.
> Optional iCloud sync uses the user's own CloudKit private database,
> encrypted before leaving the device. The full source is public:
> https://github.com/jokull/LyklabordApp
>
> The globe key (next-keyboard) is present on every keyboard layout. In secure
> (password) fields iOS switches to the system keyboard by design — expected
> platform behavior, not a bug.

---

## Review-risk notes (keyboard extension + subscription friction)

Keyboard extensions and subscriptions each draw extra reviewer scrutiny;
combining them draws both. Preemptive answers, ready to paste or adapt:

- **Full Access justification (4.4.1 / keyboard extension guidelines).**
  Answered above in the reviewer notes: Full Access exists solely for the
  App Group (dictionary + sync) and haptics, never networking, and typing
  works fully with it denied. This is the single most common keyboard-app
  rejection reason (vague or missing justification) — the notes above name
  the exact two uses and nothing else, so there's no ambiguity for the
  reviewer to escalate on.
- **Paywall must not live in the extension (3.1.1).** Confirmed by
  construction: the purchase/restore UI is in the containing app only; the
  extension only reads a cached entitlement flag. State this explicitly in
  the reviewer notes (done above) since reviewers specifically look for
  keyboard extensions that try to gate typing itself behind IAP inside the
  extension process — this app doesn't, and saying so up front heads off a
  clarification request.
- **Subscription value clarity (3.1.2 — subscriptions must unlock ongoing,
  clearly-described value, not a one-time unlock dressed as a subscription).**
  Personal-vocabulary learning is a genuinely ongoing service (the dictionary
  keeps growing/improving with use, and iCloud sync is a recurring
  cross-device service), which supports the subscription (vs. one-time
  purchase) model on review. Make sure the subscription's ASC description
  and the in-app purchase screen both state, in plain language, (a) what's
  included, (b) that the base app works without it, and (c) price + duration
  + auto-renewal terms per Apple's required subscription disclosure format
  (this is enforced by ASC's own subscription-detail template, not just a
  suggestion).
- **Restore Purchases.** Guideline 3.1.1 requires a visible "Restore
  Purchases" action wherever the paywall is shown — confirm this exists in
  the Settings purchase screen before submitting; flag as an engineering
  checklist item if not yet built (out of scope for this store/ pass to
  verify in code).
- **No web view / no unrestricted web access** — still true with
  subscriptions added; StoreKit's purchase sheet is a system UI, not an
  in-app web view, so the age-rating "Unrestricted Web Access: No" answer is
  unaffected.

---

## Bundle / account facts to confirm before submission
- Bundle IDs: app `is.solberg.lyklabord`, keyboard extension
  `is.solberg.lyklabord.keyboard` — confirmed against `project.yml`.
- App Group `group.is.solberg.lyklabord`, CloudKit container
  `iCloud.is.solberg.lyklabord` — confirmed against `project.yml`.
- Apple Developer team: personal team, Team ID `RDC8539AWM` (previously an
  org team; the old ASC record on that team, Apple ID `6791665837`, bundle
  `is.lyklabord.ios`, is being deleted and replaced — see `store/README.md`
  "Personal team migration").
- Repo name in URLs is **LyklabordApp** (`github.com/jokull/LyklabordApp`) —
  confirmed current via `git remote -v`.
- **Primary language: English (U.S.).** Correction from an earlier draft of
  this file, which recommended Icelandic as primary — App Store Connect does
  not offer Icelandic as a metadata locale at all, so it cannot be primary
  (or secondary). `metadata/en.md` is the only uploadable listing;
  `metadata/is.md` is reference/site copy, not an ASC localization.
