/// Realistic small wordlists that seed the DictLexicon doubles for the
/// micro-eval. Frequencies are rough Zipf-shaped counts (think "per ~100k
/// tokens"), hand-assembled — good enough to exercise ranking; the real .lex
/// files replace these in the wiring wave.
enum EvalWordlists {

    static let english: [String: UInt32] = [
        // function words / top of Zipf
        "the": 6000, "be": 3500, "to": 3400, "of": 3200, "and": 3000,
        "a": 2800, "in": 2200, "that": 1500, "have": 1300, "it": 1250,
        "for": 1150, "not": 1100, "on": 1000, "with": 950, "he": 900,
        "as": 870, "you": 860, "do": 840, "at": 800, "this": 780,
        "but": 760, "his": 740, "by": 720, "from": 700, "they": 680,
        "we": 660, "say": 640, "her": 620, "she": 600, "or": 580,
        "an": 560, "will": 540, "my": 520, "one": 500, "all": 480,
        "would": 460, "there": 440, "their": 430, "what": 420, "so": 400,
        "up": 380, "out": 360, "if": 340, "about": 320, "who": 300,
        "get": 290, "which": 280, "go": 270, "me": 260, "when": 250,
        "make": 240, "can": 230, "like": 220, "time": 210, "no": 200,
        "just": 195, "him": 190, "know": 185, "take": 180, "people": 175,
        "into": 170, "year": 165, "your": 160, "good": 155, "some": 150,
        "could": 145, "them": 140, "see": 135, "other": 130, "than": 125,
        "then": 120, "now": 118, "look": 116, "only": 114, "come": 112,
        "its": 110, "over": 108, "think": 106, "also": 104, "back": 102,
        "after": 100, "use": 98, "two": 96, "how": 94, "our": 92,
        "work": 90, "first": 88, "well": 86, "way": 84, "even": 82,
        "new": 80, "want": 78, "because": 76, "any": 74, "these": 72,
        "give": 70, "day": 68, "most": 66, "us": 64, "ten": 30,
        "real": 55, "really": 90, "here": 85, "very": 88,
        // targets for the classic-typo pairs
        "address": 42, "receive": 38, "separate": 30, "definitely": 36,
        "occurred": 24, "until": 60, "friend": 55, "believe": 50,
        "calendar": 22, "embarrass": 10, "environment": 34, "government": 58,
        "guard": 26, "happened": 44, "immediately": 32, "knowledge": 36,
        "necessary": 40, "occasion": 20, "publicly": 16, "successful": 30,
        "truly": 24, "basically": 26, "tomorrow": 46, "weird": 28,
        "accommodate": 12, "true": 48, "success": 34, "public": 52,
        // split-pair halves (space-miss category)
        "is": 2400, "world": 60, "hello": 40,
    ]

    static let englishBigrams: [String: UInt32] = [
        "of the": 600, "in the": 550, "to the": 400, "on the": 300,
        "with the": 250, "and the": 240, "to be": 220, "for the": 200,
        "i think": 60, "thank you": 55, "see you": 40, "good day": 12,
    ]

    static let icelandic: [String: UInt32] = [
        // function words / top of Zipf
        "og": 5800, "að": 5600, "í": 4400, "á": 3800, "er": 3200,
        "sem": 2600, "um": 1900, "en": 1700, "var": 1600, "til": 1500,
        "með": 1400, "ekki": 1350, "það": 1300, "við": 1250, "hann": 1200,
        "hún": 900, "ég": 1100, "þú": 700, "af": 680,
        "fyrir": 660, "svo": 500, "þeir": 380, "þær": 200, "þau": 260,
        "eru": 640, "hafa": 500, "hefur": 480, "verður": 300, "vera": 460,
        "fara": 340, "koma": 320, "sjá": 280, "gera": 360, "segja": 300,
        "þetta": 800, "hér": 240, "þar": 300, "núna": 180, "kannski": 120,
        "mjög": 260, "bara": 400, "líka": 320, "þá": 540, "allt": 340,
        "ekkert": 200, "eitthvað": 190, "gott": 240, "góður": 200,
        "góðan": 160, "gaman": 150, "takk": 220, "já": 480, "nei": 260,
        // content words
        "dagur": 140, "dag": 260, "daginn": 200, "kvöld": 130, "morgun": 110,
        "morgunmatur": 14, "matur": 120, "borða": 90, "hestur": 70,
        "hestar": 30, "hesti": 16, "hest": 24, "hús": 160, "húsið": 90,
        "bíll": 90, "bíllinn": 50, "barn": 130, "börn": 110, "börnin": 60,
        "maður": 300, "menn": 180, "kona": 170, "konur": 90,
        "íslenska": 120, "íslensku": 100, "ísland": 200, "íslandi": 160,
        "skóli": 90, "skólinn": 60, "skóla": 100, "vinna": 150, "vinnu": 120,
        "bók": 110, "bækur": 60, "vatn": 100, "vatnið": 40, "kaffi": 90,
        "mjólk": 60, "brauð": 70, "fiskur": 80, "fisk": 60,
        "veður": 140, "veðrið": 90, "sól": 90, "sólin": 60, "rigning": 50,
        "snjór": 40, "vetur": 90, "sumar": 120, "sumarið": 60, "haust": 50,
        "vor": 40, "ár": 220, "árið": 150, "mánuður": 40, "vika": 60,
        "vikan": 24, "klukkan": 90, "gleði": 40, "göngum": 26, "ganga": 90,
        "strákur": 60, "stelpa": 60, "fjall": 70, "fjöll": 40,
        "fallegur": 70, "falleg": 60, "fallegt": 60, "stór": 110,
        "lítill": 80, "lítið": 130, "nýr": 90, "nýtt": 100, "gamall": 60,
        "sæll": 70, "blessaður": 30, "halló": 60, "heim": 110, "heima": 130,
        "verða": 200, "vel": 240, "fá": 300, "fær": 140, "fékk": 130,
    ]

    static let icelandicBigrams: [String: UInt32] = [
        "að vera": 300, "það er": 500, "er að": 400, "og það": 200,
        "ég er": 260, "er ekki": 240, "góðan dag": 90, "góðan daginn": 60,
        "gott kvöld": 30, "takk fyrir": 130, "í dag": 220, "á morgun": 90,
        "gott veður": 26, "fallegt veður": 12, "borða mat": 8,
        "fara heim": 30, "koma heim": 22,
    ]
}
