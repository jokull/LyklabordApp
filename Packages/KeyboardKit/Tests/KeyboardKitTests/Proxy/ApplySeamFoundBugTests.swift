//
//  ApplySeamFoundBugTests.swift
//  KeyboardKit
//
//  KeyboardKit ↔ TypeEngine apply-seam bugs found by the 2026-10 seam audit.
//  Each test is a minimal deterministic repro wrapped in a STRICT
//  XCTExpectFailure, so the suite stays green today and flips red (remove the
//  wrapper) once the bug is fixed.
//
//  The apply path under test is `UITextDocumentProxy.replaceCurrentWordPreCursorPart`
//  (`Proxy/UITextDocumentProxy+Words.swift`), which every Lyklaborð
//  autocorrect apply / bar tap goes through (`insertAutocompleteSuggestion`).
//  It deletes `(currentWordPreCursorPart as NSString).length` times — UTF-16
//  code units — while UIKit's `deleteBackward()` removes one composed
//  character sequence (grapheme) per call, and removes the whole SELECTION in
//  one call when a selection exists. Both mismatches over-delete text that
//  precedes the word.
//

#if os(iOS) || os(tvOS) || os(visionOS)
import KeyboardKit
import XCTest

final class ApplySeamFoundBugTests: XCTestCase {

    /// Mock with UIKit selection semantics: while `selectedText` is non-nil,
    /// `deleteBackward()` removes the selection (and nothing before it) and
    /// `insertText` replaces it. The stock `MockTextDocumentProxy` models a
    /// plain caret only.
    private final class SelectionAwareProxy: MockTextDocumentProxy {
        override func deleteBackward() {
            if selectedText != nil {
                selectedText = nil
                return
            }
            super.deleteBackward()
        }
        override func insertText(_ text: String) {
            selectedText = nil
            super.insertText(text)
        }
    }

    // MARK: - UTF-16 vs grapheme deletion

    func testReplaceCurrentWordWithNonBMPCharacterDeletesOnlyTheWord() {
        // "halló😀" is 6 Characters but 7 UTF-16 units (the emoji is a
        // surrogate pair). UIKit deletes the emoji with ONE deleteBackward
        // (grapheme), so 7 deletes eat the space before the word as well.
        let proxy = MockTextDocumentProxy()
        proxy.documentContextBeforeInput = "ok halló😀"
        XCTAssertEqual(proxy.currentWordPreCursorPart, "halló😀")
        proxy.replaceCurrentWordPreCursorPart(with: "x")
        XCTExpectFailure(
            "replaceCurrentWordPreCursorPart deletes (word as NSString).length = UTF-16 units, but deleteBackward removes one grapheme: a non-BMP character in the current word over-deletes the text before it",
            strict: true
        ) {
            XCTAssertEqual(proxy.documentContextBeforeInput, "ok ")
            XCTAssertTrue(proxy.hasCalled(\.deleteBackwardRef, numberOfTimes: 6))
        }
    }

    func testReplaceCurrentWordWithDecomposedDiacriticDeletesOnlyTheWord() {
        // "cafe\u{301}" (decomposed é) is 4 Characters / 5 UTF-16 units. A host
        // whose deleteBackward removes the composed sequence as one unit (the
        // documented UIKit contract) is over-deleted by one. Upstream's
        // comment ("Casting to NSString to handle diacritics") targets hosts
        // that delete per scalar instead — the two contracts are
        // irreconcilable with a fixed count; the proxy's own read-back after
        // each delete is the only safe oracle.
        let proxy = MockTextDocumentProxy()
        proxy.documentContextBeforeInput = "ok cafe\u{301}"
        proxy.replaceCurrentWordPreCursorPart(with: "x")
        XCTExpectFailure(
            "replaceCurrentWordPreCursorPart over-deletes by one for a decomposed combining sequence in the current word when the host deletes whole graphemes",
            strict: true
        ) {
            XCTAssertEqual(proxy.documentContextBeforeInput, "ok ")
        }
    }

    // MARK: - Selection

    func testReplaceCurrentWordWithActiveSelectionDeletesOnlyTheWord() {
        // "ok hest|r|" — the user selected the trailing "r" to retype it.
        // documentContextBeforeInput = "ok hest" (ends at the selection start),
        // so the armed autocorrect for "hest" is applied by the next space:
        // the first deleteBackward consumes the selection, the remaining
        // three eat "est" and the apply leaves "ok h" + replacement.
        let proxy = SelectionAwareProxy()
        proxy.documentContextBeforeInput = "ok hest"
        proxy.selectedText = "r"
        XCTAssertEqual(proxy.currentWordPreCursorPart, "hest")
        proxy.replaceCurrentWordPreCursorPart(with: "hestur")
        XCTExpectFailure(
            "replaceCurrentWordPreCursorPart ignores an active selection: UIKit's deleteBackward removes the selection as one unit, so the fixed word-length delete count over-deletes the text before the word",
            strict: true
        ) {
            XCTAssertEqual(proxy.documentContextBeforeInput, "ok ")
        }
        XCTAssertNil(proxy.selectedText)
    }
}
#endif
