//
//  ScreenshotUITests.swift
//  Store-screenshot capture driver (store/screenshots/v2 pipeline).
//
//  Drives the REAL Lyklaborð keyboard in the simulator into the exact states
//  the App Store renders need, then holds the state on screen while the host
//  captures it with `xcrun simctl io screenshot` (which never steals focus).
//
//  Coordination protocol (headless-safe, no timing guesswork): the simulator
//  shares the host filesystem (proven by replay-run.sh's trace loading), so
//  when a shot's state is ready this test writes a marker file
//  `$SHOT_DIR/ready-<shot>` and sleeps `$SHOT_HOLD_S` (default 20) seconds.
//  The host-side script polls for the marker, screenshots, and lets the test
//  finish. No screenshots are taken from inside the test.
//
//  ENV (via TEST_RUNNER_ prefix):
//    SHOT_DIR     (required) host-absolute dir for ready-markers
//    SHOT_HOLD_S  (optional) seconds to hold the state (default 20)
//
//  Keyboard enablement: testEnableKeyboardInSettings automates the one-time
//  Settings dance (General > Keyboard > Keyboards > Add New Keyboard >
//  Lyklaborð) through the accessibility layer — headless, no host input.
//

import XCTest

final class ScreenshotUITests: XCTestCase {

    private var shotDir: String {
        ProcessInfo.processInfo.environment["SHOT_DIR"] ?? ""
    }
    private var holdSeconds: TimeInterval {
        TimeInterval(ProcessInfo.processInfo.environment["SHOT_HOLD_S"] ?? "") ?? 20
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Keyboard enablement (one-time per simulator)

    /// Automates Settings > General > Keyboard > Keyboards > Add New
    /// Keyboard… > Lyklaborð. Idempotent: skips cleanly when already enabled.
    func testEnableKeyboardInSettings() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        func tapFirst(_ queries: [XCUIElement], _ what: String, timeout: TimeInterval = 8) throws {
            for el in queries where el.waitForExistence(timeout: timeout / Double(queries.count) + 1) {
                el.tap()
                return
            }
            throw XCTSkip("Settings automation: could not find \(what)")
        }

        // General — a cell in the root list.
        try tapFirst([settings.cells.staticTexts["General"],
                      settings.staticTexts["General"],
                      settings.buttons["General"]], "General")
        // Keyboard
        try tapFirst([settings.cells.staticTexts["Keyboard"],
                      settings.staticTexts["Keyboard"],
                      settings.buttons["Keyboard"]], "Keyboard")
        // Keyboards (n)
        let kbList = settings.cells.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Keyboards'")).firstMatch
        guard kbList.waitForExistence(timeout: 8) else {
            throw XCTSkip("Settings automation: 'Keyboards' row not found")
        }
        kbList.tap()

        // Already enabled?
        if settings.staticTexts["Lyklaborð"].waitForExistence(timeout: 3) {
            NSLog("SHOT_INFO: Lyklaborð already enabled")
            return
        }
        try tapFirst([settings.cells.staticTexts["Add New Keyboard…"],
                      settings.cells.staticTexts["Add New Keyboard"],
                      settings.staticTexts["Add New Keyboard…"],
                      settings.staticTexts["Add New Keyboard"],
                      settings.buttons["Add New Keyboard…"],
                      settings.buttons["Add New Keyboard"]], "Add New Keyboard")
        try tapFirst([settings.cells.staticTexts["Lyklaborð"],
                      settings.staticTexts["Lyklaborð"]], "Lyklaborð in third-party list")
        // iOS 18 immediately adds it; some builds show a checkmark sheet with
        // a Done button.
        let done = settings.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(settings.staticTexts["Lyklaborð"].waitForExistence(timeout: 8),
                      "Lyklaborð did not appear in the enabled-keyboards list")
        NSLog("SHOT_INFO: Lyklaborð enabled via Settings automation")
    }

    // MARK: - Shots (keyboard states in ReplayHost)

    func testShot01Hero() throws {
        let app = try launchHostWithKeyboard()
        // Dismiss the field's AutoFill callout: one keystroke, then delete.
        type("x", in: app)
        keyElement("delete", in: app).tap()
        usleep(800_000)
        hold("01")
    }

    func testShot02Accents() throws {
        let app = try launchHostWithKeyboard()
        type("ut i bud", in: app)
        hold("02")
    }

    func testShot03Blend() throws {
        let app = try launchHostWithKeyboard()
        // The story is the SURVIVING sletta: "deploya" must be committed
        // (space after it) and left intact while typing continues.
        type("eg þarf að deploya þessu", in: app)
        hold("03")
    }

    func testShot04Inflection() throws {
        let app = try launchHostWithKeyboard()
        // Warm the engine (lazy-loaded lexicon + BÍN artifacts) in a
        // THROWAWAY session, then relaunch the host for a clean field. Do NOT
        // clear via backspace — deleting an applied correction teaches the
        // engine a veto (by design), which would sabotage the demo.
        type("fra hesti og fra konum", in: app)
        sleep(1)
        app.terminate()
        let app2 = try launchHostWithKeyboard()
        // Continuous human-cadence typing, settle only at the end: a pause
        // MID-word flips the engine into its phrase-marked state (whole field
        // marked, phrase candidate in the bar) — not the completion story.
        // Demo (owner-verified in the engine): `fra Akureyr` → bar shows
        // „Akureyr“ · Akureyri (dative, armed) · Akureyrar.
        type("fra Akureyr", in: app2)
        sleep(1)
        hold("04")
    }

    /// Orðasafn — an app screen, not the keyboard. Run AFTER shots 2–4 so the
    /// learning store has honestly-learned words to show.
    func testShot05Dictionary() throws {
        let app = XCUIApplication(bundleIdentifier: "is.solberg.lyklabord")
        app.launch()
        let tab = app.tabBars.buttons["Orðasafn"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Orðasafn tab not found")
        tab.tap()
        sleep(1)
        // Populate through the app's own add-word flow ("Mín orð") — typed on
        // the real Lyklaborð keyboard inside the sheet.
        for word in ["deploya", "vercel", "gunnsi", "feedbackið", "standupp"] {
            guard !app.staticTexts[word].exists else { continue }
            let add = app.buttons["Bæta við orði"].firstMatch
            guard add.waitForExistence(timeout: 5) else { break }
            add.tap()
            let field = app.textFields["Nýtt orð"]
            guard field.waitForExistence(timeout: 5) else { break }
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 8)
            type(word, in: app)
            app.buttons["Vista"].tap()
            usleep(600_000)
        }
        sleep(1)
        hold("05")
    }

    /// Diagnostic: dump the keyboard's accessibility tree (labels of keys and
    /// buttons) so key-resolution failures are debuggable from the log.
    func testDebugKeyboardTree() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SCREENSHOT_MODE"] = "1"
        app.launch()
        let field = app.textFields["replay-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        NSLog("SHOT_DEBUG keyboards.count=\(app.keyboards.count)")
        let keys = app.keyboards.keys.allElementsBoundByIndex.map { $0.label }
        NSLog("SHOT_DEBUG keys=\(keys)")
        let buttons = app.keyboards.buttons.allElementsBoundByIndex.map { $0.label }
        NSLog("SHOT_DEBUG kbButtons=\(buttons)")
        let otherButtons = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }
        NSLog("SHOT_DEBUG appButtons=\(otherButtons)")
    }

    /// Wave 45 acceptance: search text is owned by the keyboard, never the
    /// host field; selecting the result inserts only the emoji and leaves the
    /// search surface active for another pick. Screenshots become the browse
    /// and active-query storyboard evidence in the xcresult bundle.
    func testEmojiSearchFirewallAndInsertion() throws {
        let app = try launchHostWithKeyboard()
        let field = app.textFields["replay-input"]

        keyElement("Emoji", in: app).tap()
        let search = app.buttons["emoji-search-button"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "emoji browse search affordance missing")
        attachScreenshot(app, name: "emoji-browse")
        XCTAssertEqual(field.value as? String, "")

        search.tap()
        let searchBand = app.descendants(matching: .any)["emoji-search-band"]
        XCTAssertTrue(searchBand.waitForExistence(timeout: 5))
        type("hjarta", in: app)
        XCTAssertEqual(field.value as? String, "", "search query leaked into host text")
        attachScreenshot(app, name: "emoji-search-hjarta")

        let result = app.buttons["rautt hjarta"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "red-heart result missing")
        result.tap()
        XCTAssertEqual(field.value as? String, "❤️")
        XCTAssertTrue(searchBand.exists, "picker closed after insertion")

        app.buttons["Hreinsa emoji-leit"].tap()
        type("hagfræði", in: app)
        XCTAssertEqual(field.value as? String, "❤️", "empty-result query leaked into host text")
        XCTAssertTrue(app.staticTexts["Engin emoji fundust"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "emoji-search-empty")

        keyElement("Lokið", in: app).tap()
        XCTAssertTrue(app.buttons["emoji-search-button"].waitForExistence(timeout: 5))
        keyElement("ABC", in: app).tap()
        XCTAssertTrue(keyElement("ð", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "❤️")
    }

    // MARK: - Helpers

    private func launchHostWithKeyboard() throws -> XCUIApplication {
        let app = XCUIApplication()  // ReplayHost (test target's TEST_TARGET_NAME)
        app.launchEnvironment["SCREENSHOT_MODE"] = "1"
        app.launch()
        let field = app.textFields["replay-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "host text field not found")
        field.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("No software keyboard appeared (hardware-keyboard mode?)")
        }
        // Lyklaborð check: ð/þ/æ/ö exist on no system keyboard. If a system
        // keyboard came up, cycle with the globe key.
        for _ in 0..<5 {
            if isKeyboardActive(app) { break }
            let globe = app.buttons["Next keyboard"]
            guard globe.waitForExistence(timeout: 3) else { break }
            globe.tap()
            // Extension processes cold-start slowly; poll for the ð key.
            for _ in 0..<10 {
                if isKeyboardActive(app) { break }
                usleep(600_000)
            }
        }
        guard isKeyboardActive(app) else {
            throw XCTSkip("Lyklaborð is not the active keyboard — run "
                + "testEnableKeyboardInSettings first (and reboot the sim if needed)")
        }
        NSLog("SHOT_INFO: Lyklaborð active")
        return app
    }

    private func isKeyboardActive(_ app: XCUIApplication) -> Bool {
        // iOS 18 can expose a system "English & Icelandic" keyboard with the
        // Icelandic letters, so those alone no longer identify Lyklaborð.
        // Our iPhone layout also has a dedicated period key in alphabetic
        // mode; the system bilingual layout does not.
        let hasIcelandicLetter = ["ð", "þ", "æ", "ö"].contains {
            keyElement($0, in: app).exists
        }
        return hasIcelandicLetter && keyElement(".", in: app).exists
    }

    /// Tap out a string on the on-screen keyboard, dead-center taps, human-ish
    /// cadence. Uppercase letters tap shift first when a shift key is found;
    /// autocapitalization handles sentence starts on its own.
    private func type(_ text: String, in app: XCUIApplication) {
        for ch in text {
            if ch == " " {
                keyElement("space", in: app).tap()
            } else {
                let s = String(ch)
                if s != s.lowercased() {
                    // Engage shift unless autocap already engaged it. KeyboardKit
                    // exposes the shift key with label "shift" (case-insensitive
                    // predicate below); harmless no-op tap otherwise.
                    let shift = keyElement("shift", in: app)
                    if shift.exists { shift.tap(); usleep(150_000) }
                }
                let el = keyElement(s, in: app)
                guard el.exists else {
                    NSLog("SHOT_INFO: key '\(s)' not found — skipped")
                    continue
                }
                el.tap()
            }
            usleep(180_000)
        }
        // Let the async suggestion pipeline settle before the hold.
        usleep(600_000)
    }

    /// Same key-resolution strategy as ReplayRigUITests (kept in sync).
    private func keyElement(_ token: String, in app: XCUIApplication) -> XCUIElement {
        let labels: [String] = token == "space" ? ["space", "bil", " "] : [token]
        for label in labels {
            let predicate = NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@",
                                        label, label)
            let key = app.keyboards.keys.matching(predicate).firstMatch
            if key.exists { return key }
            let button = app.keyboards.buttons.matching(predicate).firstMatch
            if button.exists { return button }
        }
        return app.buttons[labels[0]]
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Write the ready-marker for the host capture script, then hold the state.
    private func hold(_ shot: String) {
        guard !shotDir.isEmpty else {
            NSLog("SHOT_INFO: SHOT_DIR not set — holding without marker")
            Thread.sleep(forTimeInterval: holdSeconds)
            return
        }
        let path = "\(shotDir)/ready-\(shot)"
        do {
            try "ready".write(toFile: path, atomically: true, encoding: .utf8)
            NSLog("SHOT_INFO: marker written -> \(path)")
        } catch {
            NSLog("SHOT_INFO: marker write FAILED (\(error)) — holding anyway")
        }
        Thread.sleep(forTimeInterval: holdSeconds)
    }
}
