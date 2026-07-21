#!/usr/bin/env python3
"""Generate ReplayRig/traces/behavior-catalog.json — a deterministic catalog of
comma/dot/space behavior scenarios for the last-mile replay rig.

Scenarios are written as token sequences (readable), expanded into the rig's
Trace format with center taps (dxNorm/dyNorm=0) and a fixed inter-key delay.

Tokens:
  _        space key
  bs       backspace
  .        period key (bottom row on the IS layout)
  123      switch to the numeric layout
  abc      switch back to the alphabetic layout
  dq       double-quote key (on the numeric layout)
  comma    comma key (on the numeric layout)
  dash     hyphen/minus key (on the numeric layout)
  bar:X    tap the suggestion-bar button labeled X (waits for the bar refresh)
  <letter> a letter key (a-z + Icelandic þ ð æ ö á é í ó ú ý)

`expected` is a HYPOTHESIS of what native iOS (with the "." shortcut on) /
SwiftKey does — to be validated against the reference keyboards, then used for
pass/fail diffing. Blank = harvest-only (record our behavior, no assertion yet).
"""
import json, pathlib

DT_MS = 220 # steady, human-plausible cadence; fast enough to exercise races

# (name, token-sequence, expected-hypothesis)
SCENARIOS = [
    # ── Double / multiple space ─────────────────────────────────────────────
    ("double-space after word",        "h e s t _ _",          "Hest. "),
    ("triple-space after word",        "h e s t _ _ _",        "Hest.  "),
    ("double-space after period",      "h e s t . _ _",        "Hest.  "),
    ("double-space, no preceding word","_ _",                  "  "),
    ("double-space mid two words",     "a _ _ b",              "A. b"),

    # ── Space then punctuation (attachment) ─────────────────────────────────
    ("space then period",             "h e s t _ .",           "Hest."),
    ("word then period (direct)",     "h e s t .",             "Hest."),
    ("space then period then word",   "h e s t _ . b",         "Hest.b"),

    # ── Deferred autocorrect + punctuation ──────────────────────────────────
    ("acute restore on period",       "þ v i .",               "Því."),
    ("acute restore on space",        "e g _",                 "Ég "),
    ("acute restore then continue",   "þ v i _ e r",           "Því er"),

    # ── Sentence capitalization ─────────────────────────────────────────────
    ("cap after period-space",        "h i . _ b y e",         "Hi. Bye"),
    ("cap after double-space period", "h i _ _ b y e",         "Hi. Bye"),

    # ── Multiple / repeated punctuation ─────────────────────────────────────
    ("double period",                 "h e s t . .",           "Hest.."),
    ("triple period (ellipsis?)",     "h e s t . . .",         "Hest..."),

    # ── Backspace interactions ──────────────────────────────────────────────
    ("backspace after auto-period",   "h e s t _ _ bs",        "Hest. "),
    ("backspace after period-space",  "h e s t . _ bs",        "Hest."),

    # ── Plain baselines (no punctuation) ────────────────────────────────────
    ("two plain words",               "h e i _ þ a r",         "Hei þar"),
    ("single word",                   "h e s t",               "Hest"),

    # ── D1–D8 probes (measure what we already have vs need) ──────────────────
    # D1 smart quotes: straight " should become „ (open) / " (close).
    ("D1 quote open at start",        "123 dq",                "„"),
    ("D1 quote close after word",     "o r ð 123 dq",          "orð\u201C"),
    ("D1 quote open after space",     "o r ð _ 123 dq",        "orð „"),
    # D2 numbers: 1.000,50 must survive (no sentence-end / attachment munging).
    ("D2 number 1.000,50 intact",     "123 1 . 0 0 0 comma 5 0", "1.000,50"),
    # D3 ordinals: 21. then a word — should NOT auto-cap the next word.
    ("D3 ordinal then word",          "123 2 1 . abc _ e r",   "21. er"),
    # D6 dashes/ellipsis.
    ("D6 double dash -> em",          "123 dash dash",         "—"),
    ("D6 triple period -> ellipsis",  "h e s t . . .",         "Hest…"),

    # ── Quote + suggestion apply (session 2026-07-21T11-57-41) ──────────────
    # Applying a bar suggestion right after an opening quote must not eat the
    # quote. `fór` is not a layout key: the rig's keyElement falls back to the
    # suggestion-bar button with that label (the rs restoration for "for").
    # Pre-fix, KeyboardKit's replaceCurrentWordPreCursorPart saw „for as the
    # current word and produced "Ég fór " (quote deleted).
    ("quote then suggestion tap keeps quote",
                                      "e g _ 123 dq abc f o r bar:fór", "Ég „fór "),
]

def expand(seq: str):
    taps = []
    for tok in seq.split():
        key = {
            "_": "space", "bs": "delete",
            "123": "123", "abc": "ABC",
            "dq": "\"", "comma": ",", "dash": "-",
        }.get(tok, tok)
        taps.append({"key": key, "dxNorm": 0.0, "dyNorm": 0.0, "dtMs": DT_MS})
    return taps

def main():
    out = []
    for name, seq, expected in SCENARIOS:
        trace = {
            "intended": name,
            "synthetic": True,
            "source": "behavior-catalog",
            "taps": expand(seq),
        }
        if expected:
            trace["expected"] = expected
        out.append(trace)
    path = pathlib.Path(__file__).resolve().parent.parent / "ReplayRig" / "traces" / "behavior-catalog.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"wrote {len(out)} scenarios -> {path}")

if __name__ == "__main__":
    main()
