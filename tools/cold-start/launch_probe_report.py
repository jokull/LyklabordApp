#!/usr/bin/env python3
"""Aggregate and gate `launch-probe` runs (tools/cold-start/launch-probe).

Reads one JSON object per line/file (schema lyklabord.launch-probe.v1), prints
min/median/max per summary metric and, with --gate, fails when the MAX of any
budgeted metric exceeds tools/cold-start/launch-budget.json or fewer than
`minimumRuns` fresh-process samples are present. Pure functions, no I/O in
the helpers, so test_launch_probe_report.py can drive them directly.
"""

import argparse
import json
import statistics
import sys
from pathlib import Path

SCHEMA = "lyklabord.launch-probe.v1"
BUDGET_METRICS = (
    "engineReadyMs",
    "firstKeystrokeMs",
    "worstEarlyKeystrokeMs",
    "presentationMainThreadMs",
    "inflectionRetainedMB",
    "secondBootstrapMs",
    "peakFootprintMB",
)
INFORMATIONAL_METRICS = (
    "inflectionReloadUncachedRetainedMB",
    "secondControllerRetainedMB",
    "processStartFootprintMB",
    "finalFootprintMB",
)


def load_samples(paths):
    samples = []
    for path in paths:
        text = Path(path).read_text(encoding="utf-8")
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict) and item.get("schema") == SCHEMA and isinstance(item.get("summary"), dict):
                samples.append(item)
    return samples


def summarize(samples):
    out = {}
    for metric in BUDGET_METRICS + INFORMATIONAL_METRICS:
        values = [float(s["summary"][metric]) for s in samples if metric in s["summary"]]
        if not values:
            continue
        out[metric] = {
            "min": min(values),
            "median": statistics.median(values),
            "max": max(values),
            "n": len(values),
        }
    return out


def gate_failures(summary, budget, run_count):
    failures = []
    minimum = int(budget.get("minimumRuns", 1))
    if run_count < minimum:
        failures.append(f"only {run_count} fresh-process runs; budget requires {minimum}")
    for metric in BUDGET_METRICS:
        if metric not in budget:
            continue
        if metric not in summary:
            failures.append(f"{metric}: missing from samples")
            continue
        limit = float(budget[metric])
        observed = summary[metric]["max"]
        if observed > limit:
            failures.append(f"{metric}: max {observed:.2f} > budget {limit:.2f}")
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="JSON/JSONL files produced by launch-probe")
    parser.add_argument("--gate", action="store_true", help="exit 1 when any budget is exceeded")
    parser.add_argument(
        "--budget",
        default=str(Path(__file__).with_name("launch-budget.json")),
        help="budget file (default: tools/cold-start/launch-budget.json)",
    )
    parser.add_argument("--json", action="store_true", help="print the aggregate as JSON")
    args = parser.parse_args(argv)

    samples = load_samples(args.paths)
    summary = summarize(samples)
    budget = json.loads(Path(args.budget).read_text(encoding="utf-8"))

    if args.json:
        print(json.dumps({"runs": len(samples), "summary": summary}, indent=2, sort_keys=True))
    else:
        print(f"launch-probe runs: {len(samples)}  (macOS regression alarm, not an iOS forecast)")
        print(f"{'metric':36} {'min':>10} {'median':>10} {'max':>10} {'budget':>10}")
        for metric in BUDGET_METRICS + INFORMATIONAL_METRICS:
            if metric not in summary:
                continue
            s = summary[metric]
            limit = budget.get(metric)
            print(
                f"{metric:36} {s['min']:10.2f} {s['median']:10.2f} {s['max']:10.2f} "
                f"{(f'{float(limit):.2f}' if limit is not None else '-'):>10}"
            )

    if args.gate:
        failures = gate_failures(summary, budget, len(samples))
        for failure in failures:
            print(f"GATE FAIL: {failure}", file=sys.stderr)
        print("gate: " + ("pass" if not failures else "FAIL"))
        return 0 if not failures else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
