//
//  Strings.swift
//  BetterKeyboard
//
//  All user-facing copy lives here (M2 app track). Icelandic-first — this is
//  an Icelandic product — with English where it reads more naturally
//  (technical terms, brand names). Hardcoded rather than a .strings catalog
//  for now: gathering everything in one enum keeps a future localization
//  pass a single-file diff instead of a scavenger hunt.
//
//  COPY RULE — iOS UI labels are ALWAYS verbatim English. iOS is not
//  localized to Icelandic, so every Icelandic user's Settings/Files app is
//  in English. When copy quotes a system menu or toggle, name it exactly as
//  iOS shows it: "Settings", "General", "Keyboard", "Keyboards",
//  "Add New Keyboard…", "Allow Full Access", "Files", etc. Keep the
//  surrounding prose Icelandic. The same applies to other un-localized
//  third-party apps we reference (e.g. SwiftKey). The keyboard's own name,
//  "Lyklaborð", is a brand name and stays as-is. (These strings render
//  through SwiftUI's `Text(String)` overload, which does NOT parse markdown
//  — do not use `**` for emphasis here; it shows as literal asterisks.)
//

import Foundation

enum Strings {

    /// Canonical outbound URLs. Not localized — these are addresses. Kept in
    /// one place so the About links, the privacy policy, and the export
    /// file's `$schema` pointer never drift apart.
    enum Links {
        static let website = "https://lyklabord.solberg.is"
        static let githubRepo = "https://github.com/jokull/LyklabordApp"
        static let privacyPolicy = "https://github.com/jokull/LyklabordApp/blob/main/docs/PRIVACY.md"
        static let exportFormat = "https://github.com/jokull/LyklabordApp/blob/main/docs/EXPORT_FORMAT.md"
        static let bin = "https://bin.arnastofnun.is"
    }

    enum Tab {
        static let onboarding = "Byrjun"
        static let dictionary = "Orðasafn"
        static let settings = "Stillingar"
    }

    enum Onboarding {
        static let title = "Lyklaborð"
        /// Hero tagline, matched verbatim to the landing page (lyklabord.solberg.is).
        static let tagline = "Íslenskt lyklaborð sem kann íslensku."
        /// Accessibility label for the keycap hero image.
        static let heroAccessibilityLabel = "Þrívíður Ð-hnappur — merki Lyklaborðs"
        static let subtitle = "Íslenskt og enskt lyklaborð sem hugsar um friðhelgi. Ekkert netkóði er í lyklaborðsviðbótinni sjálfri — allt gerist á tækinu þínu."

        static let setupHeading = "Setja upp lyklaborðið"
        static let step1 = "Opnaðu Settings → General → Keyboard → Keyboards"
        static let step2 = "Ýttu á „Add New Keyboard…“ og veldu Lyklaborð"
        static let step3 = "Ýttu aftur á Lyklaborð og virkjaðu „Allow Full Access“"
        static let step3Detail = "Valfrjálst. Lyklaborðið skrifar, leiðréttir sjálfkrafa og kemur með orðauppástungur að fullu án hans. Fullur aðgangur kveikir aðeins á samstillingu orðabókarinnar þinnar við þitt eigið iCloud og snertiviðbragði (iOS lokar á titring lyklaborðs án hans). Viðbótin inniheldur engan netkóða hvort sem er."
        static let fullAccessMoreLink = "Meira um fullan aðgang og persónuvernd"
        static let openSettingsButton = "Opna Settings"

        static let tryHeading = "Prófaðu það"
        static let tryBody = "Skiptu yfir í Lyklaborð með hnettinum (🌐) og skrifaðu hér:"
        static let tryPlaceholder = "Skrifaðu eitthvað…"
    }

    enum Dictionary {
        static let navigationTitle = "Orðasafn"
        static let searchPrompt = "Leita að orði"

        static let learnedSectionTitle = "Lærð orð"
        static let userAddedSectionTitle = "Mín orð"

        static let addWordButton = "Bæta við orði"
        static let addWordTitle = "Bæta við orði"
        static let addWordPlaceholder = "Nýtt orð"
        static let addWordSave = "Vista"
        static let addWordCancel = "Hætta við"
        static let addWordInvalid = "Þetta er ekki gilt stakt orð — engin bil eða tákn, að minnsta kosti einn bókstafur."

        static let deleteButton = "Eyða"
        static let undoButton = "Afturkalla"
        static func deletedMessage(_ word: String) -> String { "„\(word)“ eytt" }

        static let containerUnavailableTitle = "Sameiginleg gagnageymsla ekki tiltæk"
        static let containerUnavailableBody = "Þetta kemur venjulega fyrir í hermi (Simulator) án réttra heimilda fyrir App Group. Á alvöru tæki virkar orðasafnið eðlilega — orð sem lyklaborðið lærir birtast hér."

        static let emptyStateTitle = "Ekkert í orðasafninu ennþá"
        static let emptyStateHowItWorks = "Lyklaborðið lærir orð sem þú skrifar. Orð telst lært eftir að hafa verið samþykkt tvo mismunandi daga — eða strax ef þú ýtir á það í tillögustikunni (skýrt merki um að orðið sé rétt)."
        static let emptyStatePrivacy = "Þetta gerist eingöngu á tækinu þínu. Orðasafnið fer aldrei neitt nema í þitt eigið iCloud — lyklaborðsviðbótin sjálf snertir aldrei netið."

        static let noSearchResults = "Ekkert orð fannst"
    }

    enum SwiftKeyImport {
        static let actionTitle = "Flytja inn úr SwiftKey"
        static let sheetTitle = "Flytja inn úr SwiftKey"
        static let explainer = "Þú getur flutt orðasafnið þitt úr SwiftKey yfir í Lyklaborð. Sæktu gögnin þín í SwiftKey (Settings → Account → „Download your data“) og veldu síðan skrána „vocabulary.txt“ úr möppunni „SwiftKey Keyboard/Dictionary“ í útflutningnum."
        static let explainerNote = "Innflutt orð verða strax gild lærð orð. Orð sem þú hefur áður eytt hér verða ekki flutt inn aftur — þín eyðing gildir."
        static let chooseFileButton = "Velja skrá"
        static let cancelButton = "Hætta við"

        static let resultTitle = "Innflutningi lokið"
        static func importedMessage(_ count: String) -> String { "\(count) orð flutt inn" }
        static func skippedInvalidMessage(_ count: String) -> String { "\(count) línum sleppt (ekki gild orð)" }
        static func skippedTombstonedMessage(_ count: String) -> String { "\(count) orðum sleppt (þú hafðir eytt þeim hér)" }
        static let resultOK = "Í lagi"

        static let errorTitle = "Innflutningur mistókst"
        static let errorUnreadable = "Ekki tókst að lesa skrána. Athugaðu að þetta sé „vocabulary.txt“ úr SwiftKey-útflutningnum (SwiftKey Keyboard/Dictionary/vocabulary.txt)."
        static let errorNoAccess = "Ekki fékkst aðgangur að skránni. Prófaðu að afrita hana fyrst í Files og velja hana þaðan."
    }

    enum Settings {
        static let navigationTitle = "Stillingar"

        static let spacebarSectionTitle = "Bilslá"
        static let spacebarSectionFooter = "Hvað gerist þegar þú ýtir á bilslána meðan þú skrifar orð."
        static let spacebarModeCompleteTitle = "Klára orð"
        static let spacebarModeCompleteDetail = "Bil klárar orðið sem er í vinnslu með tillögunni í miðjunni."
        static let spacebarModePredictionTitle = "Setja alltaf inn tillögu"
        static let spacebarModePredictionDetail = "Bil setur inn tillöguna í miðjunni, jafnvel þótt ekkert sé skrifað — heil setning með bilslánni."
        static let spacebarModeSpaceTitle = "Bara bil"
        static let spacebarModeSpaceDetail = "Bil er alltaf bara bil. Leiðréttingar eru eingöngu gerðar með því að ýta á tillögustikuna."

        static let aboutSectionTitle = "Um Lyklaborð"
        static let aboutOpenSourceTitle = "Opinn hugbúnaður"
        static let aboutOpenSourceDetail = "Kóðinn er opinn og öllum aðgengilegur — hægt er að skoða nákvæmlega hvað lyklaborðið gerir."
        static let aboutBinTitle = "Beygingarlýsing íslensks nútímamáls (BÍN)"
        static let aboutBinDetail = "Beygingargögn koma frá BÍN, © Stofnun Árna Magnússonar í íslenskum fræðum (bin.arnastofnun.is). Sjá ATTRIBUTION.md í grunnkóðanum fyrir nánari skilmála."
        static let aboutNoTelemetryTitle = "Engin fjarmæling"
        static let aboutNoTelemetryDetail = "Engin notkunargögn, engin greiningargögn, engin skilaboð til neins netþjóns. Lyklaborðsviðbótin sjálf inniheldur engan netkóða."

        // Tappable trust links (v1-blocker: "audit the repo" needs a link).
        static let aboutWebsiteTitle = "Vefsíða Lyklaborðs"
        static let aboutWebsiteDetail = "lyklabord.solberg.is — kynning á lyklaborðinu og eiginleikum þess."
        static let aboutGithubTitle = "Frumkóði á GitHub"
        static let aboutGithubDetail = "Sjáðu nákvæmlega hvað lyklaborðið gerir — allt smáforritið og lyklaborðið eru opinn hugbúnaður."
        static let aboutPrivacyTitle = "Persónuverndarstefna"
        static let aboutPrivacyDetail = "Hverju er safnað, hvað er geymt og samstillt — á mannamáli. Ekkert fer af tækinu þínu nema þín eigin dulkóðaða orðabók, í þitt eigið iCloud."

        static let syncSectionTitle = "iCloud samstilling"
        static let syncToggleTitle = "iCloud samstilling"
        static let syncSectionFooter = "Orðasafnið þitt og innsláttarvenjur samstillast dulkóðuð við þitt eigið iCloud — án reiknings eða netþjóns frá okkur. Dulkóðunarlykillinn er geymdur í iCloud-lyklakippunni þinni og gögnin eru ólæsileg öllum öðrum, líka okkur."
        static let syncStatusTitle = "Staða samstillingar"

        static let syncStatusNever = "Ekki samstillt ennþá"
        static let syncStatusSyncing = "Samstilli…"
        static let syncStatusDisabled = "Samstilling er óvirk"
        static let syncStatusNotActivated = "Verður virkt í næstu útgáfu — iCloud-tengingin er ekki enn virkjuð í þessari smíð."
        static let syncOutcomeUpToDate = "Allt uppfært"
        static let syncOutcomePushed = "Sent í iCloud"
        static let syncOutcomePulled = "Sótt úr iCloud"
        static let syncOutcomeMerged = "Sameinað við iCloud"
        static let syncErrorNoAccount = "Ekki skráð inn í iCloud — skráðu þig inn í Settings"
        static let syncErrorNetwork = "Ekkert netsamband — reynt verður aftur síðar"
        static let syncErrorQuota = "iCloud-geymslan þín er full"
        static let syncErrorConflict = "Árekstur við annað tæki — reynt verður aftur síðar"
        static let syncErrorKeyUnavailable = "Bíð eftir dulkóðunarlykli úr iCloud-lyklakippunni"
        static let syncErrorCannotDecrypt = "Gögnin í iCloud eru dulkóðuð með öðrum lykli — eyddu þeim hér fyrir neðan og samstilltu svo aftur"
        static let syncErrorNewerSchema = "Gögnin í iCloud koma frá nýrri útgáfu af Lyklaborði — uppfærðu appið"
        static let syncErrorGeneric = "Samstilling mistókst — reynt verður aftur síðar"

        static let syncDeleteButton = "Eyða gögnum úr iCloud"
        static let syncDeleteConfirmTitle = "Eyða gögnum úr iCloud?"
        static let syncDeleteConfirmMessage = "Dulkóðaða afritið af orðasafninu þínu verður fjarlægt úr iCloud. Orðasafnið á þessu tæki helst óbreytt."
        static let syncDeleteConfirmAction = "Eyða"
        static let syncDeleteCancel = "Hætta við"
        static let syncDeleteDone = "Gögnum eytt úr iCloud"
        static let syncDeleteFailed = "Ekki tókst að eyða gögnunum úr iCloud"

        // Data-lifecycle section (export + delete-all).
        static let dataSectionTitle = "Gögnin mín"
        static let dataSectionFooter = "Þú ræður alfarið yfir gögnunum þínum — taktu afrit hvenær sem er, eða eyddu öllu."
    }

    /// "Export my data" — the symmetric counterpart to the SwiftKey import.
    enum DataExport {
        static let button = "Flytja út gögnin mín"
        static let footer = "Vistaðu allt sem lyklaborðið hefur lært — lærð orð og tíðni þeirra, orðin sem þú bættir við og orðin sem þú hefur eytt — sem eina læsilega skrá sem þú getur geymt eða fært annað. Þetta er spegilmyndin af SwiftKey-innflutningnum: gögnin þín eru þín til að taka með þér."
        /// Human-readable note embedded in the exported JSON file itself.
        static let fileNote = "Þessi skrá er þín persónulega Lyklaborð-orðabók: lærð og handvirkt viðbætt orð, eyðingar, tíðni orðapara og innsláttartölfræði. Hún hefur aldrei farið af tækinu þínu nema þú hafir deilt henni rétt í þessu. Sjá $schema fyrir nákvæmt snið."
        static let preparing = "Undirbý útflutning…"
        static let failed = "Ekki tókst að búa til útflutningsskrána."
        /// Base filename (before the date suffix + .json). ASCII so it's a
        /// tidy filename on every filesystem/share target.
        static let filePrefix = "Lyklabord-ordasafn"
    }

    /// "Delete all data" — the nuclear escape hatch, behind double
    /// confirmation. Deliberately contrasts SwiftKey: total and instant.
    enum DeleteAll {
        static let button = "Eyða öllum gögnum"
        static let footer = "Þetta hreinsar alla persónulegu orðabókina þína á þessu tæki — hvert einasta lærða orð, tíðni allra orðapara, innsláttartölfræðina þína — og fjarlægir einnig afritið í iCloud. Eyðingin hér er algjör og tafarlaus. Ólíkt SwiftKey er enginn reikningur á netþjóni til að elta uppi og engin bið: gögnin eru farin um leið og þú staðfestir."

        // First confirmation.
        static let confirm1Title = "Eyða öllum gögnum?"
        static let confirm1Message = "Þetta fjarlægir hvert lært orð, innsláttartölfræðina þína og iCloud-afritið. Ekki er hægt að afturkalla þetta. Orð sem þú bættir við handvirkt og eyðingarnar þínar fara líka — orðabókin byrjar tóm."
        static let confirm1Action = "Halda áfram"

        // Second confirmation.
        static let confirm2Title = "Ertu alveg viss?"
        static let confirm2Message = "Ekki er hægt að afturkalla þetta. Öllu sem Lyklaborð hefur lært á þessu tæki og í iCloud verður eytt varanlega."
        static let confirm2Action = "Eyða öllu"

        static let cancel = "Hætta við"
        static let doneTitle = "Búið"
        static let done = "Öllum gögnum eytt. Orðabókin er tóm."
        static let remoteFailed = "Gögnunum þínum á þessu tæki var eytt, en ekki tókst að fjarlægja iCloud-afritið — athugaðu nettenginguna og reyndu aftur."
        static let ok = "Í lagi"
    }

    /// Honest Full Access explainer, shown in onboarding and Settings.
    enum FullAccess {
        static let title = "Fullur aðgangur"

        static let worksWithoutTitle = "Innsláttur virkar að fullu án fulls aðgangs"
        static let worksWithoutBody = "Þú getur skrifað, notað sjálfvirka leiðréttingu og fengið orðauppástungur þótt slökkt sé á fullum aðgangi — ekkert við innsláttinn sjálfan þarfnast hans. Lyklaborðið er fullkomlega nothæft á þennan hátt."

        static let enablesTitle = "Hvað fullur aðgangur gerir"
        static let enablesBody = "Með því að veita fullan aðgang geta lyklaborðið og þetta smáforrit deilt sömu orðabók, þannig að orð sem þú lærir við innslátt birtast hér og samstillast við iCloud. Það kveikir einnig á snertiviðbragði (titringi) við innslátt — iOS lokar á titringsvélina fyrir öll lyklaborð frá þriðja aðila þar til fullur aðgangur er veittur; þetta er takmörkun sem við ráðum ekki við, ekki val sem við tókum."

        static let noNetworkTitle = "Það tengist samt aldrei netinu"
        static let noNetworkBody = "Fullur aðgangur bætir engri nettengingu við lyklaborðið. Viðbótin inniheldur engan netkóða yfirhöfuð, hvort sem kveikt er á honum eða ekki — þú getur lesið frumkóðann og staðfest það."
        static let viewSourceLink = "Skoða frumkóðann á GitHub"

        static let passwordTitle = "Í lykilorðareitum muntu stuttlega sjá eigið lyklaborð Apple"
        static let passwordBody = "Þegar þú velur lykilorðareit eða annan öruggan reit, skiptir iOS yfir í kerfislyklaborðið og til baka af sjálfu sér. Þetta er öryggisregla í iOS sem á við um öll lyklaborð frá þriðja aðila — þetta er eðlilegt, ekki villa."

        static let uninstallTitle = "Ef þú eyðir smáforritinu"
        static let uninstallBody = "Að eyða Lyklaborði fjarlægir öll gögn þess af þessu tæki tafarlaust. Ef þú notar iCloud-samstillingu verður afrit af orðabókinni þinni eftir í þínu eigin iCloud þar til þú eyðir því — ef þú setur smáforritið upp aftur endurheimtist það. Til að hreinsa allt, þar með talið iCloud, notaðu „Eyða öllum gögnum“ áður en þú fjarlægir smáforritið."
    }
}
