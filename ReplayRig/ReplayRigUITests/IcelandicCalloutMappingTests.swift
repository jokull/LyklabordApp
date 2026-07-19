//
//  IcelandicCalloutMappingTests.swift
//  Unit-style assertions over the PRODUCTION long-press callout data
//  (issue #7). KeyboardExt has no unit-test target, so this XCTestCase
//  lives in the ReplayRig UI-test bundle, which additionally compiles
//  `KeyboardExt/IcelandicCalloutMappings.swift` (see project.yml) — the
//  exact file the keyboard extension ships. No fixture copies: a mapping
//  edit in production is immediately visible to (and checked by) these
//  tests. The data file is deliberately KeyboardKit-free to make this
//  cross-target compilation possible.
//
//  These tests run in the XCUITest runner process without touching the
//  host app, so they're plain fast assertions despite the bundle type.
//

import XCTest

final class IcelandicCalloutMappingTests: XCTestCase {

    /// The exact ordered lowercase menus from the issue #7 v1 table
    /// (nearest → farthest, base character first).
    private let expectedLowercase: [Character: String] = [
        "a": "aáåäàâãāăąǎ",
        "c": "cçćčċ",
        "d": "dď",
        "e": "eéèêëēėę",
        "g": "gğġ",
        "h": "hħ",
        "i": "iíïìîīĩǐ",
        "k": "kķ",
        "l": "lłļľ",
        "n": "nñńņň",
        "o": "oóøœòôõōőǒ",
        "r": "rř",
        "s": "sßśšŝṣș",
        "t": "tțť",
        "u": "uúüùûūũǔ",
        "w": "wŵ",
        "y": "yýÿŷ",
        "z": "zźžż",
    ]

    private var mappings: [Character: IcelandicCalloutMapping] {
        Dictionary(
            uniqueKeysWithValues: IcelandicCalloutMappings.alphabetic.map { ($0.base, $0) }
        )
    }

    // MARK: - Lowercase table

    /// Every lowercase menu matches the issue table exactly — same keys,
    /// same characters, same order. String equality checks order, not
    /// just membership.
    func testLowercaseMenusMatchIssueTableExactly() {
        let actual = mappings
        XCTAssertEqual(
            Set(actual.keys), Set(expectedLowercase.keys),
            "Exactly the 18 table keys get an alphabetic callout — no more, no fewer"
        )
        for (base, expected) in expectedLowercase {
            XCTAssertEqual(
                actual[base]?.lowercase, expected,
                "Ordered lowercase menu for '\(base)'"
            )
        }
    }

    /// The base character is always the first (nearest/default) option,
    /// so releasing on the origin inserts the pressed key.
    func testBaseCharacterIsFirstInBothCases() {
        for mapping in IcelandicCalloutMappings.alphabetic {
            XCTAssertEqual(
                mapping.lowercase.first, mapping.base,
                "Lowercase menu for '\(mapping.base)' must start with the base"
            )
            XCTAssertEqual(
                mapping.uppercase.first.map(String.init),
                String(mapping.base).uppercased(),
                "Uppercase menu for '\(mapping.base)' must start with the uppercase base"
            )
        }
    }

    /// The Icelandic acute vowels are always the nearest non-base choice.
    func testAcuteVowelsAreNearestNonBaseChoice() {
        let acutePairs: [Character: Character] = [
            "a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý",
        ]
        for (base, acute) in acutePairs {
            let menu = Array(mappings[base]?.lowercase ?? "")
            XCTAssertEqual(
                menu.count >= 2 ? menu[1] : nil, acute,
                "'\(acute)' must be the nearest non-base choice under '\(base)'"
            )
        }
    }

    // MARK: - Uppercase

    /// Uppercase menus are the one-to-one uppercase equivalents in the
    /// same semantic order. Verified per character via full Unicode
    /// uppercasing EXCEPT for ß, whose full mapping ("SS") is exactly the
    /// expansion the production data must avoid — asserted separately.
    func testUppercaseMenusAreOneToOneEquivalentsInSameOrder() {
        for mapping in IcelandicCalloutMappings.alphabetic {
            let lower = Array(mapping.lowercase)
            let upper = Array(mapping.uppercase)
            XCTAssertEqual(
                upper.count, lower.count,
                "Uppercase menu for '\(mapping.base)' must pair 1:1 with lowercase"
            )
            for (lo, up) in zip(lower, upper) where lo != "ß" {
                XCTAssertEqual(
                    String(lo).uppercased(), String(up),
                    "Uppercase counterpart of '\(lo)' in '\(mapping.base)' menu"
                )
            }
        }
    }

    /// The uppercase S menu is exactly S ẞ Ś Š Ŝ Ṣ Ș — with the capital
    /// sharp s ẞ (U+1E9E), never "SS" from blind string uppercasing.
    func testUppercaseSMenuUsesCapitalSharpS() {
        let sMenu = mappings["s"]?.uppercase
        XCTAssertEqual(sMenu, "SẞŚŠŜṢȘ")
        XCTAssertTrue(
            sMenu?.unicodeScalars.contains("\u{1E9E}") ?? false,
            "ẞ must be U+1E9E LATIN CAPITAL LETTER SHARP S"
        )
        XCTAssertFalse(
            sMenu?.contains("SS") ?? true,
            "No SS expansion from uppercasing ß"
        )
    }

    // MARK: - Uniqueness

    /// No menu contains duplicate actions (also catches the duplicate
    /// trailing "u" KeyboardKit's stock English u list carries).
    func testMenusContainNoDuplicates() {
        for mapping in IcelandicCalloutMappings.alphabetic {
            let lower = Array(mapping.lowercase)
            let upper = Array(mapping.uppercase)
            XCTAssertEqual(
                lower.count, Set(lower).count,
                "Duplicate character in lowercase '\(mapping.base)' menu"
            )
            XCTAssertEqual(
                upper.count, Set(upper).count,
                "Duplicate character in uppercase '\(mapping.base)' menu"
            )
        }
        // Base keys themselves are unique — no key defined twice.
        let bases = IcelandicCalloutMappings.alphabetic.map(\.base)
        XCTAssertEqual(bases.count, Set(bases).count, "Duplicate base key in mapping")
    }

    // MARK: - Dedicated Icelandic keys are not duplicated

    /// ð, þ, æ and ö (and their capitals) have dedicated always-visible
    /// keys on the Icelandic layout, so no callout menu may repeat them.
    func testDedicatedIcelandicLettersAppearInNoMenu() {
        let dedicated: Set<Character> = ["ð", "þ", "æ", "ö", "Ð", "Þ", "Æ", "Ö"]
        for mapping in IcelandicCalloutMappings.alphabetic {
            for char in mapping.lowercase + mapping.uppercase {
                XCTAssertFalse(
                    dedicated.contains(char),
                    "Dedicated key '\(char)' duplicated in '\(mapping.base)' menu"
                )
            }
        }
    }

    // MARK: - Character sanity

    /// Every option is a single NFC/precomposed Character with exactly
    /// one Unicode scalar, so each callout cell displays and inserts
    /// exactly the character it shows (no combining-mark surprises).
    func testAllOptionsAreSingleScalarPrecomposed() {
        for mapping in IcelandicCalloutMappings.alphabetic {
            for char in mapping.lowercase + mapping.uppercase {
                XCTAssertEqual(
                    char.unicodeScalars.count, 1,
                    "'\(char)' in '\(mapping.base)' menu must be a single precomposed scalar"
                )
            }
        }
    }
}
