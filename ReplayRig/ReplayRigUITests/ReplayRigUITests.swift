//
//  ReplayRigUITests.swift
//  Last-mile replay rig (PLAN.md testing pyramid tier 3).
//
//  Replays timed human typing traces through the REAL Lyklaborð keyboard in the
//  simulator: for each tap we locate OUR Icelandic layout's key on-screen and
//  tap it at the recorded within-key offset, waiting the recorded inter-key
//  delay. After each trace we read the resulting text and emit a transcript
//  line {intended, resulting, taps, durationMs}.
//
//  No host-Mac input is synthesized — every tap goes through XCUITest's
//  accessibility layer into the booted simulator, which does not touch the
//  user's real keyboard/mouse.
//
//  RESULTS CHANNELS (belt and braces, all headless-safe):
//    1. NSLog each JSONL line prefixed "REPLAY_JSONL:" — scraped from the
//       xcodebuild log by scripts/replay-report.py (most robust; no container
//       spelunking).
//    2. Written to $REPLAY_RESULTS_PATH if that path is writable.
//    3. XCTAttachment (kept) in the .xcresult.
//
//  ENV:
//    REPLAY_TRACE_PATH    (required) path to a trace JSON file, readable by the
//                         test process. replay-run.sh copies the trace into the
//                         simulator and passes an in-sim path.
//    REPLAY_RESULTS_PATH  (optional) where to also write the JSONL transcript.
//    REPLAY_DT_CAP_MS     (optional, default 1200) cap on inter-key wait so long
//                         human think-pauses don't bloat runtime; short gaps
//                         (the fast-typing races we care about) replay faithfully.
//    REPLAY_MAX_TRACES    (optional) limit number of traces (smoke tests).
//

import XCTest

// MARK: - Trace model

struct Tap: Decodable {
    let key: String
    let dxNorm: Double
    let dyNorm: Double
    let dtMs: Int
}

struct Trace: Decodable {
    let intended: String
    let taps: [Tap]
    let synthetic: Bool?
    let source: String?
    /// Behavior-catalog only: the reference output we expect (what native
    /// iOS / SwiftKey does), for pass/fail diffing. Optional — timed human
    /// traces don't set it.
    let expected: String?
}

final class ReplayRigUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testReplayTraces() throws {
        let env = ProcessInfo.processInfo.environment
        guard let tracePath = env["REPLAY_TRACE_PATH"] else {
            throw XCTSkip("REPLAY_TRACE_PATH not set — nothing to replay")
        }
        let dtCapMs = Int(env["REPLAY_DT_CAP_MS"] ?? "") ?? 1200
        let maxTraces = Int(env["REPLAY_MAX_TRACES"] ?? "") ?? Int.max

        let data = try Data(contentsOf: URL(fileURLWithPath: tracePath))
        var traces = try JSONDecoder().decode([Trace].self, from: data)
        if traces.count > maxTraces { traces = Array(traces.prefix(maxTraces)) }
        NSLog("REPLAY_INFO: loaded \(traces.count) traces from \(tracePath)")

        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["replay-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "host text field not found")
        field.tap()

        // Keyboard presence + Lyklaborð-active check. The IS-only keys ð/þ/æ/ö
        // exist on NO system keyboard, so finding one proves our keyboard is the
        // active input view (see replay-run.sh for how it gets enabled/selected).
        guard app.keyboards.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("No software keyboard appeared. On the simulator, ensure "
                + "'Connect Hardware Keyboard' is OFF (Simulator > I/O > Keyboard).")
        }
        let isKeyboardActive = ["ð", "þ", "æ", "ö"].contains { keyElement($0, in: app).exists }
        if !isKeyboardActive {
            throw XCTSkip("Lyklaborð is not the active keyboard (no ð/þ/æ/ö key on "
                + "screen). One-time manual step required — see replay-run.sh header: "
                + "enable Lyklaborð + Full Access in Settings and select it via the "
                + "globe key. XCUITest cannot flip that Settings toggle.")
        }
        NSLog("REPLAY_INFO: Lyklaborð confirmed active")

        // Behavior-catalog mode: after every tap, record the buffer so the
        // step-by-step evolution (double-space, collapse, attachment, deferred
        // autocorrect) is visible — not just the end state. Reads the mirror
        // label (`replay-result`), which is the robust channel under replay.
        let stepCapture = env["REPLAY_STEP_CAPTURE"] == "1"

        var jsonlLines: [String] = []
        for (i, trace) in traces.enumerated() {
            clearField(field, in: app)
            let start = Date()
            var tapped = 0
            var steps: [(key: String, value: String)] = []
            for tap in trace.taps {
                if replayTap(tap, in: app) { tapped += 1 }
                let wait = min(tap.dtMs, dtCapMs)
                if wait > 0 { usleep(useconds_t(wait * 1000)) }
                if stepCapture {
                    // Small settle so the async commit is reflected before read.
                    usleep(140_000)
                    steps.append((key: tap.key, value: currentText(in: app)))
                }
            }
            // Let the async autocomplete/commit queue settle before reading.
            usleep(400_000)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            let resulting = (field.value as? String) ?? currentText(in: app)

            let line = encodeLine(intended: trace.intended, resulting: resulting,
                                  taps: tapped, durationMs: durationMs,
                                  synthetic: trace.synthetic ?? false,
                                  source: trace.source,
                                  expected: trace.expected,
                                  steps: stepCapture ? steps : nil)
            jsonlLines.append(line)
            NSLog("REPLAY_JSONL: \(line)")
            let verdict = trace.expected.map { $0 == resulting ? " [MATCH]" : " [DIFF exp=\($0)]" } ?? ""
            NSLog("REPLAY_INFO: [\(i + 1)/\(traces.count)] intended=\(trace.intended) "
                + "-> resulting=\(resulting)\(verdict)")
        }

        let jsonl = jsonlLines.joined(separator: "\n") + "\n"

        // Channel 2: results file, if a writable path was supplied.
        if let outPath = env["REPLAY_RESULTS_PATH"] {
            do {
                try jsonl.write(toFile: outPath, atomically: true, encoding: .utf8)
                NSLog("REPLAY_INFO: wrote results -> \(outPath)")
            } catch {
                NSLog("REPLAY_INFO: could not write REPLAY_RESULTS_PATH (\(error)); "
                    + "rely on REPLAY_JSONL log lines / attachment")
            }
        }
        // Channel 3: attachment.
        let att = XCTAttachment(data: Data(jsonl.utf8), uniformTypeIdentifier: "public.jsonl")
        att.name = "replay-results.jsonl"
        att.lifetime = .keepAlways
        add(att)
    }

    // MARK: - Tap replay

    /// Locate a layout key and tap it at the recorded within-key offset.
    /// dxNorm/dyNorm are relative to key center in [-0.5, 0.5]-normalized units;
    /// values beyond ±0.5 (boundary-crossing fat-finger taps) land on the
    /// neighbor by design — the coordinate can sit outside the element bounds.
    @discardableResult
    private func replayTap(_ tap: Tap, in app: XCUIApplication) -> Bool {
        let el = keyElement(tap.key, in: app)
        guard el.exists else {
            NSLog("REPLAY_INFO: key '\(tap.key)' not found on keyboard — skipped")
            return false
        }
        let vector = CGVector(dx: 0.5 + tap.dxNorm, dy: 0.5 + tap.dyNorm)
        el.coordinate(withNormalizedOffset: vector).tap()
        return true
    }

    /// Resolve an on-screen keyboard key by token. KeyboardKit renders keys as
    /// buttons/keys whose accessibility label is the character; space may be
    /// localized. Case-insensitive so autocap'd letters still match.
    private func keyElement(_ token: String, in app: XCUIApplication) -> XCUIElement {
        let labels: [String]
        if token == "space" {
            labels = ["space", "bil", " "] // en / is / raw
        } else {
            labels = [token]
        }
        for label in labels {
            let predicate = NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@",
                                        label, label)
            let key = app.keyboards.keys.matching(predicate).firstMatch
            if key.exists { return key }
            let button = app.keyboards.buttons.matching(predicate).firstMatch
            if button.exists { return button }
        }
        // Fall back to a non-keyboard-scoped lookup (some KK builds don't nest
        // buttons under the keyboards element in the a11y tree).
        return app.buttons[labels[0]]
    }

    private func clearField(_ field: XCUIElement, in app: XCUIApplication) {
        app.buttons["replay-clear"].tap()
        // Re-focus in case clearing dismissed the keyboard.
        if !app.keyboards.firstMatch.exists { field.tap() }
    }

    /// Current buffer via the `replay-result` mirror label (robust under fast
    /// replay). The host renders a lone space for empty; normalize that to "".
    private func currentText(in app: XCUIApplication) -> String {
        let raw = app.staticTexts["replay-result"].label
        return raw == " " ? "" : raw
    }

    // MARK: - JSON encoding (manual to avoid pulling in Foundation JSONEncoder
    // ordering quirks; keeps the sentinel line greppable/one-per-line).

    private func encodeLine(intended: String, resulting: String, taps: Int,
                            durationMs: Int, synthetic: Bool, source: String?,
                            expected: String? = nil,
                            steps: [(key: String, value: String)]? = nil) -> String {
        var obj: [String: Any] = [
            "intended": intended,
            "resulting": resulting,
            "taps": taps,
            "durationMs": durationMs,
            "synthetic": synthetic,
        ]
        if let source { obj["source"] = source }
        if let expected {
            obj["expected"] = expected
            obj["match"] = (expected == resulting)
        }
        if let steps {
            obj["steps"] = steps.map { ["key": $0.key, "value": $0.value] }
        }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
