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
from analyze import (  # noqa: E402
    AppRecord,
    KBRecord,
    classify,
    load_session,
    reconstruct_pairs,
    _inflection_offer,
    _silent_candidates,
)

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


# --------------------------------------------------------------------------
# v2 behaviours (built in-memory — living documentation of the three upgrades)
# --------------------------------------------------------------------------

def _session(texts):
    """Build an (app, kb) pair from a list of pad-text snapshots (t = index)."""
    app = [AppRecord(t=0.0, sid="v2", kind="start", text="")]
    app += [AppRecord(t=float(i + 1), sid="v2", kind="snapshot", text=t)
            for i, t in enumerate(texts)]
    app[-1] = AppRecord(t=app[-1].t, sid="v2", kind="stop", text=texts[-1])
    return app, []


def test_erase_retype_alignment():
    """Upgrade 2: erase one word, retype a LONGER stretch. The erased word must
    pair with its plausible match, not the inserted word (the real "foðu" →
    "af góðu" bug, where v1 emitted "foðu"→"af")."""
    # Pure reconstruction (the real session's peak/end, "á" survives in `end`).
    pairs = reconstruct_pairs(
        "til að fa snefil á foðu veðri",
        "til að fa snefil á af góðu veðri",
    )
    got = [(t, i) for _, t, i in pairs]
    assert ("foðu", "góðu") in got, f"expected foðu→góðu, got {got}"
    assert all(i != "af" and t != "af" for _, t, i in pairs), \
        f"'af' must be an insertion, not a pair: {got}"

    # End-to-end through classify on a synthetic episode ("til" survives).
    app, kb = _session([
        "til f", "til fo", "til fod", "til fodu",            # peak
        "til fod", "til fo", "til f", "til ",                # erase
        "til a", "til af", "til af ", "til af g", "til af go",
        "til af god", "til af goda",                          # retype (longer)
    ])
    events = classify(app, kb)
    pairs = [(e.typo, e.intended) for e in events]
    assert ("fodu", "goda") in pairs, f"classify alignment: {pairs}"
    assert all(t != "af" and i != "af" for t, i in pairs), \
        f"'af' leaked as a pair: {pairs}"
    print("  OK  erase-retype alignment  fodu -> goda ('af' dropped)")


def test_inflection_miss():
    """Upgrade 3: a MISS whose bar offered a different inflection of the same
    stem is tagged INFLECTION_MISS (Kirkjubæjarklaustri vs -klaustur)."""
    off = _inflection_offer(
        "Kirkjubæjars", "Kirkjubæjarklaustur", ["Kirkjubæjarklaustri", "Kirkjubær"])
    assert off == "Kirkjubæjarklaustri", off
    # The typo echoed in the bar, and short-word near-typos, must NOT qualify.
    assert _inflection_offer("mew", "með", ["MEÐ", "mew", "me", "Menn"]) is None

    # End-to-end: bar offers the wrong-case inflection while typing the typo.
    app, kb = _session(["reykjaviks", "reykjavik", "reykjaviku", "reykjavikur"])
    kb = [KBRecord(t=0.5, sid="v2", window="reykjaviks", field="standard",
                   bar=[{"text": "reykjaviki"}], applied={"kind": "none"},
                   taps=[], backspaces=0)]
    events = classify(app, kb)
    infl = [e for e in events if e.cls == "INFLECTION_MISS"]
    assert infl and infl[0].intended == "reykjavikur" and infl[0].note == "reykjaviki", \
        f"expected INFLECTION_MISS reykjaviks→reykjavikur: {[(e.cls, e.typo, e.intended, e.note) for e in events]}"
    print("  OK  INFLECTION_MISS  reykjaviks -> reykjavikur (offer reykjaviki)")


def test_silent_candidates():
    """Upgrade 1: an unattested token gets ranked cheap-edit neighbours; a
    keyboard-mash token resolves to nothing (UNRESOLVABLE)."""
    common = {"hann": 3772234, "frá": 2644106, "fá": 482541,
              "síðan": 379301, "að": 34196092}
    # habb → hann via two adjacency subs (b→n, b→n).
    top = _silent_candidates("habb", common)
    assert top and top[0][0] == "hann", top
    # fra → frá via one accent edit (penalty 0, ranked first).
    top = _silent_candidates("fra", common)
    assert top and top[0][0] == "frá" and top[0][2] == 0, top
    # Keyboard mash has no cheap high-frequency neighbour.
    assert _silent_candidates("awgke", common) == [], "mash should be UNRESOLVABLE"
    print("  OK  silent-miss  habb->hann, fra->frá, mash->UNRESOLVABLE")


if __name__ == "__main__":
    run()
    print("\nv2 behaviours:")
    test_erase_retype_alignment()
    test_inflection_miss()
    test_silent_candidates()
    print("\nPASS — v2 behaviours (alignment, inflection, silent-miss) verified.")
