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

import Foundation

enum Strings {

    enum Tab {
        static let onboarding = "Byrjun"
        static let dictionary = "Orðasafn"
        static let settings = "Stillingar"
    }

    enum Onboarding {
        static let title = "Lyklaborð"
        static let subtitle = "Íslenskt og enskt lyklaborð sem hugsar um friðhelgi. Ekkert netkóði er í lyklaborðsviðbótinni sjálfri — allt gerist á tækinu þínu."

        static let setupHeading = "Setja upp lyklaborðið"
        static let step1 = "Opnaðu Stillingar → Almennt → Lyklaborð → Lyklaborð"
        static let step2 = "Ýttu á „Bæta við lyklaborði…“ og veldu Lyklaborð"
        static let step3 = "Ýttu aftur á Lyklaborð og virkjaðu „Leyfa fullan aðgang“ (valfrjálst — lyklaborðið virkar að fullu án þess; fullur aðgangur er eingöngu til að samstilla orðasafnið þitt við iCloud í seinni útgáfu)"
        static let openSettingsButton = "Opna Stillingar"

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
        static let explainer = "Þú getur flutt orðasafnið þitt úr SwiftKey yfir í Lyklaborð. Sæktu gögnin þín í SwiftKey (Stillingar → Account → „Download your data“) og veldu síðan skrána „vocabulary.txt“ úr möppunni „SwiftKey Keyboard/Dictionary“ í útflutningnum."
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
        static let errorNoAccess = "Ekki fékkst aðgangur að skránni. Prófaðu að afrita hana fyrst í Skrár (Files) og velja hana þaðan."
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
        static let syncErrorNoAccount = "Ekki skráð inn í iCloud — skráðu þig inn í Stillingum kerfisins"
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
    }
}
