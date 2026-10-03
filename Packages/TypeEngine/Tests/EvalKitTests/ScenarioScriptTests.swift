import XCTest

@testable import EvalKit

/// The scenario-file lexer/validator must reject every authoring mistake the
/// old inline parser silently accepted (harness audit 2026-10). Each test
/// here mirrors a scenario that PASSED under the pre-audit runner while
/// asserting nothing, or asserting against the wrong state.
final class ScenarioScriptTests: XCTestCase {

    private func messages(_ text: String) -> [String] {
        ScenarioScript.parse(text).diagnostics.map(\.message)
    }

    private func lines(_ text: String) -> [Int] {
        ScenarioScript.parse(text).diagnostics.map(\.line)
    }

    // MARK: - Well-formed input is accepted unchanged

    func testWellFormedScenarioHasNoDiagnostics() {
        let script = ScenarioScript.parse(
            """
            # comment
            LIMIT 5

            SCENARIO teh autocorrects
            T "teh "
            EXPECT_LAST_COMMIT the
            EXPECT_BUFFER "the "
            """)
        XCTAssertEqual(script.diagnostics, [])
        XCTAssertEqual(script.scenarioCount, 1)
        XCTAssertEqual(script.directives.map(\.keyword), ["LIMIT", "SCENARIO", "T", "EXPECT_LAST_COMMIT", "EXPECT_BUFFER"])
    }

    func testRealSuitesParseCleanly() throws {
        // Every shipped contract file must satisfy the tightened lexer; a
        // diagnostic here names a malformed scenario by file:line.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scenarios")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".scenarios") }.sorted()
        XCTAssertGreaterThan(files.count, 0, "no .scenarios files found at \(dir.path)")
        for file in files {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let script = ScenarioScript.parse(text)
            XCTAssertEqual(
                script.diagnostics.map { "\(file):\($0)" }, [],
                "\(file) has static defects")
            XCTAssertGreaterThan(script.scenarioCount, 0, "\(file) has no scenarios")
        }
    }

    // MARK: - False passes the old runner produced

    func testEmptyFileIsRejected() {
        let script = ScenarioScript.parse("# nothing here\n\n")
        XCTAssertEqual(script.scenarioCount, 0)
        XCTAssertEqual(script.diagnostics.map(\.message), ["file contains no SCENARIO"])
        XCTAssertEqual(script.diagnostics.first?.line, 0)
    }

    func testScenarioWithoutAssertionsIsADefect() {
        let diagnostics = ScenarioScript.parse(
            """
            SCENARIO types but never checks
            T "teh "

            SCENARIO fine
            T teh
            EXPECT_AUTOCORRECT the
            """
        ).diagnostics
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].line, 1)
        XCTAssertEqual(diagnostics[0].scenario, "types but never checks")
        XCTAssertTrue(diagnostics[0].message.contains("no EXPECT_* assertion"))
    }

    func testMalformedArgumentsAreNotSilentlyDefaulted() {
        let text = """
            SCENARIO misspelled flags
            LIMIT five
            STALE_READS yes
            SWALLOW_EDITS true
            DOT_APPLY 1
            BACKSPACE two
            TRUNCATE_AT ten
            CURSOR_MOVE +abc
            FIELD secret
            T teh
            EXPECT_COMMITS none
            EXPECT_EVENTS 1.5
            EXPECT_POSTERIOR_GT high
            EXPECT_AUTOCORRECT the
            """
        XCTAssertEqual(lines(text), [2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13])
        let m = messages(text)
        XCTAssertTrue(m[0].contains("LIMIT"))
        XCTAssertTrue(m[1].contains("STALE_READS on|off"))
        XCTAssertTrue(m[4].contains("BACKSPACE"))
        XCTAssertTrue(m[6].contains("CURSOR_MOVE"))
        XCTAssertTrue(m[7].contains("FIELD"))
    }

    func testUnknownAndMiscasedDirectivesAreDefects() {
        let m = messages(
            """
            SCENARIO typo in directive
            T teh
            EXPECT_CONTAIN the
            expect_top the
            EXPECT_TOP the
            """)
        XCTAssertEqual(m, ["unknown directive: EXPECT_CONTAIN", "unknown directive: expect_top"])
    }

    func testBareDirectivesRejectArguments() {
        let m = messages(
            """
            SCENARIO stray words
            T teh
            EXPECT_EMPTY bar
            EXPECT_NO_SPLIT ever
            REFRESH now
            EXPECT_TOP the
            """)
        XCTAssertEqual(m.count, 3)
        XCTAssertTrue(m.allSatisfy { $0.contains("takes no argument") })
    }

    func testNegativeAssertionBeforeAnyBarIsVacuous() {
        let text = """
            SCENARIO asserts against the fresh empty bar
            EXPECT_NOT_CONTAINS the
            EXPECT_NO_AUTOCORRECT
            EXPECT_NO_SPLIT
            EXPECT_EMPTY
            T teh
            EXPECT_NOT_CONTAINS tea
            """
        XCTAssertEqual(lines(text), [2, 3, 4, 5])
        XCTAssertTrue(messages(text).allSatisfy { $0.contains("vacuous") })
    }

    func testNoteWindowAndLearnDoNotCountAsBarProducing() {
        let m = messages(
            """
            SCENARIO learn then negative assert
            LEARN kozy
            NOTE_WINDOW
            EXPECT_NO_AUTOCORRECT
            """)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].contains("vacuous"))
    }

    func testEveryBarProducingDirectiveArmsNegativeAssertions() {
        for keyword in ScenarioScript.barProducingDirectives.sorted() {
            let argument: String
            switch keyword {
            case "T", "LONGPRESS", "TAP", "EJECT": argument = "teh"
            case "HOST_SET", "HOST_SET_SILENT": argument = "\"teh \""
            case "CURSOR_MOVE", "CURSOR_MOVE_SILENT": argument = "end"
            default: argument = ""
            }
            let m = messages("SCENARIO x\n\(keyword) \(argument)\nEXPECT_NO_AUTOCORRECT\n")
            XCTAssertEqual(m, [], "\(keyword) should arm negative assertions")
        }
    }

    func testUnquotedTrailingWhitespaceOnFreeTextIsADefect() {
        // "T teh " loses its delimiter to trimming; the following
        // EXPECT_AUTOCORRECT then judges a mid-word bar and passes.
        let m = messages("SCENARIO lost delimiter\nT teh \nEXPECT_AUTOCORRECT the\n")
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].contains("unquoted trailing whitespace"))
        // Quoted is the documented form and is fine; so is a trailing tab-free line.
        XCTAssertEqual(messages("SCENARIO ok\nT \"teh \"\nEXPECT_LAST_COMMIT the\n"), [])
        // CRLF line endings do not count as trailing whitespace.
        XCTAssertEqual(messages("SCENARIO crlf\r\nT teh\r\nEXPECT_TOP the\r\n"), [])
    }

    func testEmptyTypingAndTapArgumentsAreDefects() {
        let m = messages(
            """
            SCENARIO nothing typed
            T
            LONGPRESS ""
            TAP
            T teh
            EXPECT_TOP the
            """)
        XCTAssertEqual(m.count, 3)
    }

    func testWordAssertionsNeedAWord() {
        // A blank-argument assertion is NOT counted as an assertion, so a
        // scenario holding only such lines also trips the no-assertion rule.
        let bare = messages("SCENARIO blank\nT teh\nEXPECT_TOP\nEXPECT_CONTAINS\nEXPECT_LAST_COMMIT\n")
        XCTAssertEqual(bare.filter { $0.contains("needs a word") }.count, 3)
        XCTAssertEqual(bare.filter { $0.contains("no EXPECT_* assertion") }.count, 1)
        let m = messages("SCENARIO blank\nT teh\nEXPECT_TOP\nEXPECT_CONTAINS\nEXPECT_LAST_COMMIT\nEXPECT_TOP the\n")
        XCTAssertEqual(m.count, 3)
        XCTAssertTrue(m.allSatisfy { $0.contains("needs a word") })
    }

    func testDirectivesBeforeFirstScenarioAreDefectsExceptLimit() {
        let m = messages("LIMIT 4\nT teh\nEXPECT_TOP the\nSCENARIO real\nT teh\nEXPECT_TOP the\n")
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m.allSatisfy { $0.contains("before the first SCENARIO") })
    }

    func testEmptyAndDuplicateScenarioNamesAreDefects() {
        let m = messages(
            """
            SCENARIO
            T teh
            EXPECT_TOP the
            SCENARIO twin
            T teh
            EXPECT_TOP the
            SCENARIO twin
            T teh
            EXPECT_TOP the
            """)
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m[0].contains("needs a name"))
        XCTAssertTrue(m[1].contains("duplicate SCENARIO name"))
    }

    func testTouchTapFormMustParseFully() {
        XCTAssertNil(ScenarioScript.validateArgument(keyword: "TAP", argument: "a 0.1 -0.2"))
        XCTAssertNil(ScenarioScript.validateArgument(keyword: "TAP", argument: "stökkleikur"))
        XCTAssertNotNil(ScenarioScript.validateArgument(keyword: "TAP", argument: "a 0.1 x"))
    }

    func testPersonalDirectiveArity() {
        XCTAssertNil(ScenarioScript.validateArgument(keyword: "PERSONAL", argument: "kozy 3"))
        XCTAssertNotNil(ScenarioScript.validateArgument(keyword: "PERSONAL", argument: "kozy"))
        XCTAssertNotNil(ScenarioScript.validateArgument(keyword: "PERSONAL", argument: "kozy three"))
        XCTAssertNil(ScenarioScript.validateArgument(keyword: "PERSONAL_EXPLICIT", argument: "kozy"))
        XCTAssertNil(ScenarioScript.validateArgument(keyword: "PERSONAL_BIGRAM", argument: "a b 2"))
        XCTAssertNotNil(ScenarioScript.validateArgument(keyword: "PERSONAL_BIGRAM", argument: "a b"))
        XCTAssertNil(
            ScenarioScript.validateArgument(
                keyword: "PERSONAL_TOUCH", argument: "a 40 0.1 0.2 0.3 0.3"))
        XCTAssertNotNil(
            ScenarioScript.validateArgument(
                keyword: "PERSONAL_TOUCH", argument: "a 40 0.1 0.2 0.3"))
    }

    func testDiagnosticsByLineGroupsForTheRunner() {
        let script = ScenarioScript.parse("SCENARIO x\nLIMIT five\nT teh\nEXPECT_TOP the\n")
        XCTAssertEqual(script.diagnosticsByLine[2]?.count, 1)
        XCTAssertNil(script.diagnosticsByLine[3])
    }

    func testSplitAndUnquote() {
        XCTAssertEqual(ScenarioScript.split("T \"hestur \"").keyword, "T")
        XCTAssertEqual(ScenarioScript.split("T \"hestur \"").argument, "\"hestur \"")
        XCTAssertEqual(ScenarioScript.unquote("\"hestur \""), "hestur ")
        XCTAssertEqual(ScenarioScript.unquote("hestur"), "hestur")
        XCTAssertEqual(ScenarioScript.split("REFRESH").argument, "")
    }
}
