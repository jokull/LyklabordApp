# Lyklaborð — Privacy Policy / Persónuverndarstefna

_Last updated / Síðast uppfært: 2026-07-15_

> This document is the canonical privacy policy for Lyklaborð, published at
> **https://lyklabord.solberg.is/privacy** (the App Store "Privacy Policy
> URL"). The same text lives in the source repository as docs/PRIVACY.md.
>
> Þessi skrá er hin opinbera persónuverndarstefna Lyklaborðs, birt á
> **https://lyklabord.solberg.is/privacy**. Sami texti er í
> frumkóðasafninu sem docs/PRIVACY.md.

Icelandic below / Íslenska er neðar.

---

## English

**Short version: Lyklaborð does not collect your data. Nothing you type is ever sent to us or to anyone else. There is no account, no analytics, and no tracking. The keyboard extension contains no networking code at all — you can read the source and confirm it.**

### What we collect

Nothing. We operate no servers that receive your data, and the app sends us no usage data, diagnostics, crash reports, advertising identifiers, or analytics of any kind. We could not read what you type even if we wanted to — the code to send it does not exist.

### What is stored on your device

To improve autocorrect and prediction over time, the keyboard learns from your typing, entirely on your device:

- **Learned words** you type repeatedly (or accept explicitly), with how often each has been used and a per-language (Icelandic/English) attribution.
- **Word-pair (bigram) counts** — how often one word follows another — used for next-word prediction.
- **Typing statistics** — aggregate per-key touch offsets (where on each key you tend to tap), stored only as running averages, never as individual taps.
- **Words you add or delete by hand** in the dictionary editor, including your deletions (kept so a deleted word is never silently re-learned).

This data is stored in the app's private container on your device. The keyboard never records the contents of password, URL, email, or other secure fields, and never stores anything with a timestamp finer than the calendar day.

### iCloud sync (optional)

If you leave iCloud sync on, your personal dictionary is synced so it follows you across your own devices. This uses **your own private iCloud database** (Apple's CloudKit) — not any server of ours. Before it leaves your device the data is **encrypted with AES-256-GCM**, and the encryption key is stored in **your iCloud Keychain**, which we never see. The data in iCloud is unreadable to anyone but you — including us, and including Apple.

You can turn sync off at any time (local-only mode), and you can delete the iCloud copy at any time from Settings ("Eyða gögnum úr iCloud", or the full "Eyða öllum gögnum").

### If you delete the app

Deleting Lyklaborð removes all of its on-device data immediately. If you used iCloud sync, a copy of your dictionary remains in your own iCloud until you delete it — reinstalling would restore it. Use "Eyða öllum gögnum" (Delete all data) before uninstalling if you want to erase the iCloud copy as well.

### No tracking, no third parties

There is no advertising, no cross-app or cross-site tracking, and no third-party SDKs that receive your data. Because there is no tracking, the app never shows an App Tracking Transparency prompt.

### App Store privacy label

Lyklaborð's App Store privacy label is **"Data Not Collected"**. The iCloud sync described above is your own data, in your own iCloud, initiated by you and encrypted with a key only you hold — it is not data collected by us.

### Lyklaborð+ subscription

The base keyboard is free. An optional subscription, **Lyklaborð+**, enables
the personal layer: the personal dictionary, typo learning (per-key touch
adaptation), and iCloud sync of that personal data. Payments are processed
entirely by Apple through the App Store — we receive no payment details and
run no purchase tracking; the subscription state is checked on your device.
If the subscription lapses, **nothing is deleted**: your learned data stays
on your device, paused, and comes back to life if you resubscribe. Exporting
and deleting your data (below) always works, subscribed or not.

### Your data, your rights

- **Export**: "Flytja út gögnin mín" in Settings or Orðasafn writes everything the keyboard has learned to a single readable JSON file you can keep or move.
- **Delete individual words**: swipe to delete in Orðasafn; deletions stick.
- **Delete everything**: "Eyða öllum gögnum" in Settings wipes the on-device data and the iCloud copy, immediately.

### Developer mode

Debug and developer-signed builds include a hidden "Þróunarhamur" (developer mode) with a typing-session recorder, used to improve autocorrect quality against real typing. It is **off by default** and never present in App Store builds. When switched on, it records **only what you type into the app's own recording pad ("Upptökusvæði") inside this app** — never anything you type in any other app. Recordings (the pad text over time, plus what the keyboard offered and applied) are stored **locally** in the app's own container. As a developer convenience, finished recordings may also be copied to **your own iCloud Drive** — the same private iCloud used for the optional dictionary sync above, never any server of ours — where they appear as a "Lyklaborð" folder in the Files app that you can open, move, or delete yourself. They otherwise leave the device only if the developer explicitly exports or pulls them. The keyboard extension itself still contains no networking or iCloud code at all. Recording arms the keyboard for the recording pad only; it turns itself off automatically after 10 minutes and the instant the app leaves the foreground, and a red indicator is shown the whole time it is active. Secure, URL, email, and search fields are never recorded even in developer mode, and your learned dictionary is completely unaffected.

### Contact

Questions or concerns: open an issue at https://github.com/jokull/LyklabordApp or email jokull@triptojapan.com.

---

## Íslenska

**Í stuttu máli: Lyklaborð safnar ekki gögnunum þínum. Ekkert af því sem þú skrifar er nokkurn tíma sent til okkar eða nokkurs annars. Það er enginn aðgangur, engar greiningar og engin rakning. Lyklaborðsviðbótin inniheldur engan netkóða yfirhöfuð — þú getur lesið frumkóðann og staðfest það.**

### Hverju við söfnum

Engu. Við rekum enga netþjóna sem taka við gögnunum þínum og appið sendir okkur engin notkunargögn, greiningargögn, hrunskýrslur, auglýsingaauðkenni eða greiningar af neinu tagi. Við gætum ekki lesið það sem þú skrifar jafnvel þótt við vildum — kóðinn til að senda það er ekki til.

### Hvað er geymt í tækinu þínu

Til að bæta sjálfvirka leiðréttingu og orðaspá með tímanum lærir lyklaborðið af innslættinum þínum, eingöngu í tækinu þínu:

- **Lærð orð** sem þú skrifar endurtekið (eða samþykkir sérstaklega), ásamt því hversu oft hvert orð hefur verið notað og til hvaða tungumáls það heyrir (íslenska/enska).
- **Tíðni orðapara (tvígrömm)** — hversu oft eitt orð kemur á eftir öðru — sem er notað til að spá fyrir um næsta orð.
- **Tölfræði innsláttar** — samanlögð snertifrávik fyrir hvern lykil (hvar á hvern lykil þú hefur tilhneigingu til að ýta), aðeins geymd sem hlaupandi meðaltal, aldrei sem einstakar snertingar.
- **Orð sem þú bætir við eða eyðir handvirkt** í orðasafnsritlinum, þar á meðal eyðingarnar þínar (geymdar svo að eytt orð sé aldrei lært aftur í kyrrþey).

Þessi gögn eru geymd á einkasvæði appsins í tækinu þínu. Lyklaborðið skráir aldrei innihald lykilorða, vefslóða, netfanga eða annarra öruggra reita og geymir aldrei neitt með nákvæmari tímastimpli en sem nemur almanaksdegi.

### Samstilling við iCloud (valfrjálst)

Ef þú hefur samstillingu við iCloud kveikta er persónulega orðasafnið þitt samstillt svo það fylgi þér á milli tækjanna þinna. Þetta notar **þinn eigin einkagagnagrunn í iCloud** (CloudKit frá Apple) — ekki neinn af okkar netþjónum. Áður en gögnin yfirgefa tækið þitt eru þau **dulkóðuð með AES-256-GCM** og dulkóðunarlykillinn er geymdur í **iCloud-lyklakippunni þinni** (iCloud Keychain), sem við sjáum aldrei. Gögnin í iCloud eru ólæsileg öllum nema þér — þar á meðal okkur og Apple.

Þú getur slökkt á samstillingu hvenær sem er (staðbundin stilling) og þú getur eytt iCloud-afritinu hvenær sem er í stillingum („Eyða gögnum úr iCloud“, eða að fullu með „Eyða öllum gögnum“).

### Ef þú eyðir appinu

Ef þú eyðir Lyklaborði er öllum gögnum þess í tækinu eytt samstundis. Ef þú notaðir samstillingu við iCloud verður afrit af orðasafninu þínu áfram í þínu eigin iCloud þar til þú eyðir því — ef þú setur appið upp aftur verður það endurheimt. Notaðu „Eyða öllum gögnum“ áður en þú fjarlægir appið ef þú vilt eyða iCloud-afritinu líka.

### Engin rakning, engir þriðju aðilar

Það eru engar auglýsingar, engin rakning á milli appa eða vefsíðna og engir hugbúnaðarþróunarpakkar (SDK) frá þriðja aðila sem fá gögnin þín. Vegna þess að það er engin rakning sýnir appið aldrei App Tracking Transparency-beiðni.

### Persónuverndarmerki App Store

Persónuverndarmerki Lyklaborðs í App Store er **„Data Not Collected“**. Samstillingin við iCloud sem lýst er hér að ofan snýst um þín eigin gögn, í þínu eigin iCloud, að þínu frumkvæði og dulkóðuð með lykli sem aðeins þú hefur aðgang að — þetta eru ekki gögn sem við söfnum.

### Lyklaborð+ áskrift

Grunnlyklaborðið er ókeypis. Valfrjáls áskrift, **Lyklaborð+**, virkjar
persónulega lagið: orðasafnið þitt, innsláttaraðlögun (lyklaborðið lærir á
fingurna þína) og iCloud-samstillingu þeirra gagna. Greiðslur fara alfarið í
gegnum Apple og App Store — við fáum engar greiðsluupplýsingar og rekjum
engin kaup; áskriftarstaðan er staðfest í tækinu þínu. Ef áskrift rennur út
er **engu eytt**: lærðu gögnin þín sitja áfram í tækinu, í bið, og lifna við
aftur ef þú gerist áskrifandi á ný. Útflutningur og eyðing gagna (hér að
neðan) virka alltaf, með eða án áskriftar.

### Þín gögn, þín réttindi

- **Flytja út**: „Flytja út gögnin mín“ í stillingum eða Orðasafni vistar allt sem lyklaborðið hefur lært í eina læsilega JSON-skrá sem þú getur geymt eða fært.
- **Eyða stökum orðum**: strjúktu til að eyða í Orðasafni; eyðingarnar haldast.
- **Eyða öllu**: „Eyða öllum gögnum“ í stillingum hreinsar gögnin í tækinu og iCloud-afritið samstundis.

### Þróunarhamur

Þróunar- og villuleitarútgáfur (debug) innihalda falinn „Þróunarham“ með innsláttarupptöku sem er notuð til að bæta sjálfvirka leiðréttingu út frá raunverulegum innslætti. Hann er **sjálfgefið óvirkur** og er aldrei til staðar í App Store-útgáfum. Þegar kveikt er á honum tekur hann aðeins upp það sem þú skrifar á upptökusvæði appsins sjálfs („Upptökusvæði“) — aldrei neitt sem þú skrifar í öðrum forritum. Upptökur (texti svæðisins yfir tíma, ásamt því sem lyklaborðið bauð og beitti) eru geymdar **staðbundið** í gagnasvæði appsins. Til hægðarauka fyrir þróanda er einnig hægt að afrita loknar upptökur í **þitt eigið iCloud Drive** — sama einka-iCloud og valfrjáls samstilling orðasafnsins hér að ofan notar, aldrei neinn netþjónn okkar — þar sem þær birtast sem „Lyklaborð“ mappa í Skrár-appinu sem þú getur opnað, fært eða eytt sjálf/ur. Að öðru leyti fara þær af tækinu einungis ef þróandi flytur þær út eða sækir þær sérstaklega. Lyklaborðsviðbótin sjálf inniheldur eftir sem áður engan net- eða iCloud-kóða. Upptaka virkjar lyklaborðið aðeins fyrir upptökusvæðið; hún slekkur sjálfkrafa á sér eftir 10 mínútur og um leið og appið fer úr forgrunni, og rautt merki er sýnt allan tímann sem hún er virk. Öruggir reitir, vefslóðir, netföng og leitarreitir eru aldrei teknir upp, jafnvel í þróunarham, og lærða orðabókin þín verður fyrir engum áhrifum.

### Hafa samband

Spurningar eða ábendingar: skráðu mál á https://github.com/jokull/LyklabordApp eða sendu tölvupóst á jokull@triptojapan.com.
