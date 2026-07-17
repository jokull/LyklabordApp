# App Store metadata — en-US

_Voice sourced from README.md and lyklabord.solberg.is. Character limits noted
in parentheses; counts verified in `store/metadata/charcheck.txt`._

**This is the primary — and only — App Store Connect localization.** ASC has
no Icelandic metadata locale, so `metadata/is.md` is not a second upload
target; see `store/README.md` §A.1.

## App name (≤30)
`Lyklaborð – Icelandic Keyboard`
<!-- 30 chars incl. spaces & en-dash. Fallback if 30 is rejected by ASC
     dash-counting: `Lyklaborð: Icelandic Keys` (25). Brand-only fallback:
     `Lyklaborð` (9). -->

## Subtitle (≤30)
`Accents & inflection, private`
<!-- 29 chars -->

## Promotional text (≤170)
`Free, open source, network-free — the Icelandic keyboard that places accents for you, understands BÍN inflection, and learns your words on-device. Coming soon.`
<!-- 159 chars -->>

## Keywords (≤100, comma-separated, no spaces)
`iceland,íslenska,typing,autocorrect,prediction,open source,offline,no tracking,swiftkey,morphology`
<!-- 98 chars. Deliberately omits words already in the name/subtitle
     (icelandic, keyboard, accents, inflection, private) — Apple indexes those
     separately, so keyword slots go to non-duplicate terms. -->

## Description (≤4000)

The keyboard that actually knows Icelandic — and types excellent English on the same layout.

Lyklaborð is what a third-party keyboard should have been for Iceland: one Icelandic layout that fluently blends Icelandic and English as you type, autocorrect that understands Icelandic inflection, on-device learning you fully control, and a hard privacy guarantee you can verify in the source. Free. Open source. No account. No telemetry. No AI bloat.

WRITE ACCENT-NAKED
Dropping accents is an input method, not a typo. Type "flytjum i bud" at full speed and get "flytjum í búð" — the keyboard restores the accents for you, so you never have to reach for a long-press.

THE FIRST KEYBOARD THAT UNDERSTANDS INFLECTION
All 3 million word forms from BÍN (Beygingarlýsing íslensks nútímamáls) are valid vocabulary, and suggestions follow case and context — "frá" takes the dative, and the keyboard knows it. No other keyboard on any platform actually inflects Icelandic.

ICELANDIC AND ENGLISH, ON ONE LAYOUT
A two-lane language model follows you between languages. One-off English words — a "deploy", a brand name — never derail you, and the keyboard never hijacks your language mid-sentence. When you genuinely switch to English, it comes with you. No 2-language limit, no language toggle.

CORRECTS LESS, NOT MORE
A word that's valid in either language is never silently replaced, and the exact word you typed always sits in the suggestion bar, quoted, as an escape hatch. URLs, emails, and abbreviations are left alone. When the spacebar's neighbour is the more likely key, it's treated as a hypothesis, not a typo ("smelirna" → "smellir á").

YOUR VOCABULARY, TRULY YOURS
The keyboard learns the words you type, entirely on your device. You can inspect every learned word, delete them one by one — and deletions stick, so a removed word is never silently re-learned. Switching from SwiftKey? Import your vocabulary from a SwiftKey data export in one step. Nothing you type in password, URL, or email fields is ever recorded.

ZERO NETWORKING CODE
The keyboard extension contains no network code at all — no phoning home, no analytics, no data collection, no terms to accept. This isn't a promise; it's verifiable in the source. The whole app and keyboard are open source under the MIT license, so you can read exactly what it does. The App Store privacy label is "Data Not Collected."

Optional iCloud sync keeps your personal dictionary with you across your own devices — encrypted with AES-256-GCM before it leaves your device, with the key held only in your iCloud Keychain. Not our server. Not readable by us, or by Apple.

BUILT FOR SWITCHERS
Familiar muscle memory: a "." key with a long-press punctuation cluster, spacebar cursor control, and double-space period. Works fully without Full Access — typing, autocorrect, and prediction never need it; Full Access only turns on personal-dictionary sync and typing haptics (iOS blocks keyboard haptics without it).

Icelandic language data is derived from BÍN, © Árni Magnússon Institute for Icelandic Studies, used under the BÍN conditions.

Made in Iceland.

## What's New (v1.0)
First release. One Icelandic-and-English layout with morphology-aware autocorrect built on all 3 million BÍN word forms, automatic accent restoration, on-device learning with a personal dictionary you fully control, SwiftKey import, and a keyboard extension with zero networking code. Open source under MIT.

## Support URL
https://lyklabord.solberg.is

## Marketing URL
https://lyklabord.solberg.is

## Privacy Policy URL
https://github.com/jokull/LyklabordApp/blob/main/docs/PRIVACY.md
<!-- Interim. PRIVACY.md notes a hosted policy page will replace this before
     submission; swap to the lyklabord.solberg.is/privacy URL once it exists. -->

## Category
- Primary: **Utilities**
- Secondary: Productivity
<!-- Matches SwiftKey's own Utilities+Productivity pairing. -->
