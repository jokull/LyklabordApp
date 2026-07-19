//
//  IcelandicCalloutMappings.swift
//  LyklabordKeyboard
//
//  Long-press callout menu data for the Icelandic layout (issue #7).
//
//  PURE DATA on purpose: this file has no KeyboardKit (or any other)
//  dependency so the exact menus can be unit-tested from the production
//  source (ReplayRigUITests compiles this same file — see project.yml)
//  without copying the lists into a test fixture. The KeyboardKit glue
//  that turns these strings into `Callouts.Actions` lives in
//  `KeyboardViewController.swift` (`Callouts.Actions.icelandic`).

/// One long-press menu: a base key plus its full ordered option lists.
///
/// Both option strings INCLUDE the base character first, matching how
/// KeyboardKit's stock mappings are written ("a": "aàá…"): the base is
/// the default/nearest selection, so releasing on the origin inserts it.
///
/// Ordering is semantic nearest → farthest. KeyboardKit turns that into
/// the correct PHYSICAL order on both sides of the keyboard: trailing-
/// aligned callouts get `actions.reversed()` plus a mirrored index
/// resolution (vendored `CalloutContext.swift`), so index 0 here is
/// always the character physically nearest the pressed key.
struct IcelandicCalloutMapping {
    /// The lowercase base key character (the key that is long-pressed).
    let base: Character
    /// Ordered lowercase menu, base first, then nearest → farthest.
    let lowercase: String
    /// Ordered uppercase menu — EXPLICIT, not derived.
    ///
    /// Never generate this by uppercasing `lowercase`: Unicode case
    /// mapping is not one-to-one per scalar. The trap that motivates
    /// this field is ß, whose full uppercase mapping is "SS" — blindly
    /// uppercasing "sßśš…" and splitting per character yields "S S S Ś…".
    /// The correct single-character capital is ẞ (U+1E9E LATIN CAPITAL
    /// LETTER SHARP S), listed explicitly below.
    let uppercase: String
}

/// The complete alphabetic long-press mapping for the Icelandic layout.
enum IcelandicCalloutMappings {

    /// Ordered menus for every key that gets an alphabetic callout.
    ///
    /// Product rule (issue #7): Icelandic-first, then useful foreign
    /// variants. Where an Icelandic acute form of the base letter exists
    /// (á é í ó ú ý) it is always the nearest non-base choice; common
    /// Nordic/German/Spanish/French/Portuguese variants follow; rarer
    /// Latin variants sit farthest away.
    ///
    /// Dedicated Icelandic letters are deliberately NOT duplicated here:
    /// ð, þ, æ and ö all have dedicated always-visible keys on the
    /// Icelandic layout (see `KeyboardLayout.InputSet.icelandic`), so
    /// there is no ð under d, no þ under t, no æ under a and no ö under
    /// o — their would-be slots go to characters that cannot otherwise
    /// be typed. (The dedicated ö key already covers German/Swedish ö;
    /// the dedicated æ key covers Danish/Norwegian æ.)
    ///
    /// Keys not listed (b f j m p q v x, and the dedicated ð æ ö þ keys)
    /// intentionally have no alphabetic callout.
    static let alphabetic: [IcelandicCalloutMapping] = [
        // Icelandic/Spanish á, Swedish å, German/Swedish ä, then
        // French/Italian/Portuguese and rarer Latin. No æ (dedicated key).
        .init(base: "a", lowercase: "aáåäàâãāăąǎ", uppercase: "AÁÅÄÀÂÃĀĂĄǍ"),
        // French/Portuguese ç first, then Polish/Central European.
        .init(base: "c", lowercase: "cçćčċ", uppercase: "CÇĆČĊ"),
        // Czech/Slovak ď only. No ð (dedicated key).
        .init(base: "d", lowercase: "dď", uppercase: "DĎ"),
        // Icelandic/Spanish é first, then French/Italian, German, Baltic/Polish.
        .init(base: "e", lowercase: "eéèêëēėę", uppercase: "EÉÈÊËĒĖĘ"),
        // Turkish/Maltese.
        .init(base: "g", lowercase: "gğġ", uppercase: "GĞĠ"),
        // Maltese.
        .init(base: "h", lowercase: "hħ", uppercase: "HĦ"),
        // Icelandic/Spanish í first, then French, Italian, Portuguese.
        .init(base: "i", lowercase: "iíïìîīĩǐ", uppercase: "IÍÏÌÎĪĨǏ"),
        // Latvian.
        .init(base: "k", lowercase: "kķ", uppercase: "KĶ"),
        // Polish/Baltic/Central European.
        .init(base: "l", lowercase: "lłļľ", uppercase: "LŁĻĽ"),
        // Spanish ñ first, then Polish/Baltic/Central European.
        .init(base: "n", lowercase: "nñńņň", uppercase: "NÑŃŅŇ"),
        // Icelandic/Spanish ó, Danish/Norwegian ø, French œ, then
        // Italian/Portuguese and rarer Latin. No ö (dedicated key).
        .init(base: "o", lowercase: "oóøœòôõōőǒ", uppercase: "OÓØŒÒÔÕŌŐǑ"),
        // Czech.
        .init(base: "r", lowercase: "rř", uppercase: "RŘ"),
        // German ß first, then Central European/Romanian. Uppercase uses
        // the one-to-one capital ẞ (U+1E9E) — see `uppercase` doc above.
        .init(base: "s", lowercase: "sßśšŝṣș", uppercase: "SẞŚŠŜṢȘ"),
        // Romanian/Czech/Slovak. No þ (dedicated key).
        .init(base: "t", lowercase: "tțť", uppercase: "TȚŤ"),
        // Icelandic/Spanish ú, German ü, then French/Italian/Portuguese.
        // (Also drops the duplicate trailing "u" in KeyboardKit's stock
        // English u list.)
        .init(base: "u", lowercase: "uúüùûūũǔ", uppercase: "UÚÜÙÛŪŨǓ"),
        // Welsh.
        .init(base: "w", lowercase: "wŵ", uppercase: "WŴ"),
        // Icelandic ý first, then French, Welsh.
        .init(base: "y", lowercase: "yýÿŷ", uppercase: "YÝŸŶ"),
        // Polish/Central European.
        .init(base: "z", lowercase: "zźžż", uppercase: "ZŹŽŻ"),
    ]
}
