#!/usr/bin/env python3
"""Tests for launch_probe_report.py aggregation and gating."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import launch_probe_report as report  # noqa: E402


def sample(**overrides):
    summary = {
        "engineReadyMs": 30.0,
        "firstKeystrokeMs": 0.1,
        "worstEarlyKeystrokeMs": 3.0,
        "presentationMainThreadMs": 0.5,
        "inflectionRetainedMB": 4.4,
        "secondBootstrapMs": 8.0,
        "peakFootprintMB": 17.5,
        "inflectionReloadUncachedRetainedMB": 4.0,
        "secondControllerRetainedMB": 4.9,
        "processStartFootprintMB": 1.4,
        "finalFootprintMB": 17.5,
    }
    summary.update(overrides)
    return {"schema": report.SCHEMA, "summary": summary}


BUDGET = {
    "minimumRuns": 3,
    "engineReadyMs": 400,
    "firstKeystrokeMs": 10,
    "worstEarlyKeystrokeMs": 40,
    "presentationMainThreadMs": 10,
    "inflectionRetainedMB": 8,
    "secondBootstrapMs": 40,
    "peakFootprintMB": 40,
}


class ReportTests(unittest.TestCase):
    def test_summarize_reports_min_median_max(self):
        s = report.summarize([sample(engineReadyMs=10), sample(engineReadyMs=30), sample(engineReadyMs=20)])
        self.assertEqual((s["engineReadyMs"]["min"], s["engineReadyMs"]["median"], s["engineReadyMs"]["max"]), (10, 20, 30))
        self.assertEqual(s["engineReadyMs"]["n"], 3)

    def test_gate_passes_within_budget(self):
        samples = [sample(), sample(), sample()]
        self.assertEqual(report.gate_failures(report.summarize(samples), BUDGET, len(samples)), [])

    def test_gate_uses_max_not_median(self):
        samples = [sample(), sample(), sample(presentationMainThreadMs=25.0)]
        failures = report.gate_failures(report.summarize(samples), BUDGET, len(samples))
        self.assertEqual(len(failures), 1)
        self.assertIn("presentationMainThreadMs", failures[0])

    def test_gate_requires_minimum_runs(self):
        samples = [sample()]
        failures = report.gate_failures(report.summarize(samples), BUDGET, len(samples))
        self.assertTrue(any("fresh-process runs" in f for f in failures), failures)

    def test_gate_flags_missing_metric(self):
        s = sample()
        del s["summary"]["peakFootprintMB"]
        failures = report.gate_failures(report.summarize([s, s, s]), BUDGET, 3)
        self.assertTrue(any("peakFootprintMB: missing" in f for f in failures), failures)

    def test_load_samples_skips_other_schemas_and_garbage(self):
        import json
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            fh.write(json.dumps(sample()) + "\n")
            fh.write("not json\n")
            fh.write(json.dumps({"schema": "lyklabord.cold-start.v1", "summary": {}}) + "\n")
            path = fh.name
        self.assertEqual(len(report.load_samples([path])), 1)


if __name__ == "__main__":
    unittest.main()
