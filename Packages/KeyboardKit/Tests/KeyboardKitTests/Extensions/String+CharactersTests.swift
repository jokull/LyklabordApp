//
//  String+CharactersTests.swift
//  KeyboardKit
//
//  Created by Daniel Saidi on 2023-01-26.
//  Copyright © 2023-2025 Daniel Saidi. All rights reserved.
//

import KeyboardKit
import XCTest

class String_CharactersTests: XCTestCase {

    func testStringDefinesCharacters() {
        XCTAssertEqual(String.carriageReturn, "\r")
        XCTAssertEqual(String.newline, "\n")
        XCTAssertEqual(String.space, " ")
        XCTAssertEqual(String.tab, "\t")
        XCTAssertEqual(String.zeroWidthSpace, "\u{200B}")
    }

    func testStringDefinesCharacterCollections() {
        let alphabeticSwitches = String.alphabeticAccentSwitches
        XCTAssertEqual(alphabeticSwitches, "’’’‘`".chars)

        let autoTriggers = String.autocorrectTriggers.joined()
        let autoTriggersPrefix = ".,:;!¡?¿{}<>«»"
        XCTAssertTrue(autoTriggers.hasPrefix(autoTriggersPrefix))

        let sentenceDelims = String.sentenceDelimiters
        XCTAssertEqual(sentenceDelims, ".:!¡?¿".chars)

        let wordDelims = String.wordDelimiters.joined()
        let wordDelimsPrefix = ".,:;!¡?¿()[]{}<>«»་།"
        XCTAssertTrue(wordDelims.hasPrefix(wordDelimsPrefix))

        // Lyklaborð fork: double quotes are word delimiters, matching
        // TypeEngine's delimiterPunctuation — otherwise applying a
        // suggestion right after an opening quote deletes the quote.
        XCTAssertTrue("\"".isWordDelimiter)
        XCTAssertTrue("\u{201E}".isWordDelimiter)  // „ Icelandic opener
        XCTAssertTrue("\u{201C}".isWordDelimiter)  // “
        XCTAssertTrue("\u{201D}".isWordDelimiter)  // ”

        XCTAssertEqual([String].sentenceDelimiters, String.sentenceDelimiters)
        XCTAssertEqual([String].wordDelimiters, String.wordDelimiters)
    }

    func testStringCanCheckForCollectionMembership() {
        XCTAssertTrue(String.autocorrectTriggers.allSatisfy { $0.isAutocorrectTrigger })
        XCTAssertFalse("a".isSentenceDelimiter)

        XCTAssertTrue(String.sentenceDelimiters.allSatisfy { $0.isSentenceDelimiter })
        XCTAssertFalse("a".isSentenceDelimiter)

        XCTAssertTrue(String.wordDelimiters.allSatisfy { $0.isWordDelimiter })
        XCTAssertFalse("a".isWordDelimiter)
    }
}
