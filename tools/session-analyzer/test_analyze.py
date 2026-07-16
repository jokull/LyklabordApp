#!/usr/bin/env python3
"""
test_analyze.py — proves the classifier on the synthetic fixture.

Run:  python3 test_analyze.py       (exit 0 = pass)

The fixture (fixtures/fixture-*.jsonl) is a hand-built session that contains
exactly one of each classifiable event, so this doubles as living documentation
of what each class looks like on the wire.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze import load_session, classify  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "fixtures", "fixture-app.jsonl")
KB = os.path.join(HERE, "fixtures", "fixture-kb.jsonl")


def run():
    app, kb = load_session(APP, KB)
    events = classify(app, kb)
    by_cls = {}
    for e in events:
        by_cls.setdefault(e.cls, []).append(e)

    def expect(cls, typo, intended):
        assert cls in by_cls, f"missing {cls}; got classes {sorted(by_cls)}"
        pair = [(e.typo, e.intended) for e in by_cls[cls]]
        assert (typo, intended) in pair, f"{cls}: expected {(typo, intended)}, got {pair}"
        print(f"  OK  {cls:18} {typo!r} -> {intended!r}")

    print("Classifier results:")
    expect("AUTOCORRECT_UNDONE", "kaffo", "kaffi")
    expect("MISS_OFFERED", "hus", "hús")
    expect("MISS_ABSENT", "kvld", "kvöld")
    expect("TAP_USED", "t", "takk")

    # MISS_OFFERED must have surfaced the offered word; MISS_ABSENT must not.
    off = by_cls["MISS_OFFERED"][0]
    assert "hús" in off.offered_bar, f"MISS_OFFERED bar should contain hús: {off.offered_bar}"
    absent = by_cls["MISS_ABSENT"][0]
    assert "kvöld" not in absent.offered_bar, "MISS_ABSENT bar must not contain kvöld"
    print("  OK  offered/absent bar discrimination")

    # Candidate shape check.
    cand = off.to_candidate()
    for key in ("typo", "intended", "context", "lang", "class"):
        assert key in cand, f"candidate missing {key}"
    assert cand["lang"] == "is", f"expected is lang for hús, got {cand['lang']}"
    print("  OK  candidate shape (matches data/eval/dev.jsonl)")

    print(f"\nPASS — {len(events)} events, all 4 classes detected.")


if __name__ == "__main__":
    run()
