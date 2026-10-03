#!/usr/bin/env python3
"""Self-test for launch_path_lint.py: the real sources pass, and each class of
regression it exists to catch fails."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import launch_path_lint as lint  # noqa: E402

CONTROLLER = """
final class KeyboardViewController: KeyboardInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Data(contentsOf: inside a comment is fine
        NSLog("JSONDecoder() inside a string is fine")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = EmojiCatalog.shared
        }
        %(didload)s
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        frecencyEmojis = EmojiFrequencyStore.shared.top(8)
        %(willappear)s
    }
    override func viewWillSetupKeyboardView() {
        setupKeyboardView { [unowned self] controller in
            KeyboardView(state: controller.state, services: controller.services)
        }
    }
    private func forwardTextContextChange() {
        let hostWindow = textDocumentProxy.documentContextBeforeInput ?? ""
        service.noteTextContextChange(hostWindow)
    }
}
"""

SERVICE = """
final class LyklabordAutocompleteService: AutocompleteService {
    init(appGroupId: String? = nil, activationStartedAt: TimeInterval? = nil) {
        let createdAt = AutocompleteColdStartTracker.now
        queue.async { [weak self] in self?.bootstrapIfNeeded() }
        %(init)s
    }
    private func bootstrapIfNeeded() {
        let english = try FrequencyLexicon(contentsOf: enURL)
        %(before_ready)s
        session = newSession
        coldStartTracker.engineReady()
        scheduleInflectionLoad()
        scheduleEmojiSuggesterLoad(bundle: bundle)
    }
}
"""


def sources(didload="", willappear="", init="", before_ready=""):
    return {
        "KeyboardViewController.swift": CONTROLLER % {"didload": didload, "willappear": willappear},
        "LyklabordAutocompleteService.swift": SERVICE % {"init": init, "before_ready": before_ready},
    }


class LaunchPathLintTests(unittest.TestCase):
    def test_clean_fixture_passes(self):
        self.assertEqual(lint.lint_sources(sources()), [])

    def test_real_sources_pass(self):
        ext = lint.REPO / "KeyboardExt"
        real = {name: (ext / name).read_text(encoding="utf-8") for name in lint.ENTRY_POINTS}
        self.assertEqual(lint.lint_sources(real), [])

    def test_file_read_in_viewDidLoad_fails(self):
        findings = lint.lint_sources(sources(didload='let d = try? Data(contentsOf: url)'))
        self.assertTrue(any("viewDidLoad" in f and "Data(contentsOf" in f for f in findings), findings)

    def test_json_decode_in_viewWillAppear_fails(self):
        findings = lint.lint_sources(sources(willappear="let x = try? JSONDecoder().decode(T.self, from: d)"))
        self.assertTrue(any("viewWillAppear" in f and "JSONDecoder" in f for f in findings), findings)

    def test_sync_hop_in_viewWillAppear_fails(self):
        findings = lint.lint_sources(sources(willappear="let p = queue.sync { session?.probabilityIcelandic }"))
        self.assertTrue(any(".sync" in f for f in findings), findings)

    def test_catalog_decode_in_viewWillAppear_fails(self):
        findings = lint.lint_sources(sources(willappear="let c = try? EmojiCatalog(data: d)"))
        self.assertTrue(any("EmojiCatalog(data" in f for f in findings), findings)

    def test_catalog_shared_exemption_is_viewDidLoad_only(self):
        # The viewDidLoad exemption is function-wide (documented as such);
        # the same access in viewWillAppear must still be caught.
        findings = lint.lint_sources(sources(willappear="_ = EmojiCatalog.shared?.isAvailable(e)"))
        self.assertTrue(any("viewWillAppear" in f and "EmojiCatalog.shared" in f for f in findings), findings)

    def test_suggester_scheduling_before_engine_ready_fails(self):
        findings = lint.lint_sources(sources(before_ready="scheduleEmojiSuggesterLoad(bundle: bundle)"))
        self.assertTrue(any("scheduleEmojiSuggesterLoad" in f for f in findings), findings)

    def test_container_resolution_in_service_init_fails(self):
        findings = lint.lint_sources(sources(
            init='let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "g")'))
        self.assertTrue(any("init" in f and "containerURL" in f for f in findings), findings)

    def test_artifact_open_in_service_init_fails(self):
        findings = lint.lint_sources(sources(init="let lex = try FrequencyLexicon(contentsOf: url)"))
        self.assertTrue(any("FrequencyLexicon" in f for f in findings), findings)

    def test_inflection_before_engine_ready_fails(self):
        findings = lint.lint_sources(sources(before_ready="scheduleInflectionLoad()"))
        self.assertTrue(any("engineReady" in f and "scheduleInflectionLoad" in f for f in findings), findings)

    def test_emoji_suggester_before_engine_ready_fails(self):
        findings = lint.lint_sources(sources(before_ready="emojiSuggester = IcelandicEmojiSuggester(contentsOf: u)"))
        self.assertTrue(any("IcelandicEmojiSuggester" in f for f in findings), findings)

    def test_strip_handles_escaped_quotes_and_block_comments(self):
        stripped = lint.strip_comments_and_strings('let s = "a \\" JSONDecoder() b" /* Data(contentsOf: */ x')
        self.assertNotIn("JSONDecoder", stripped)
        self.assertNotIn("Data(contentsOf", stripped)
        self.assertIn("x", stripped)


if __name__ == "__main__":
    unittest.main()
