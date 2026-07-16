#!/usr/bin/env python3
"""replay-report.py — score replay-rig transcripts (intended vs resulting).

Consumes the JSONL transcript emitted by ReplayRigUITests (one object per trace:
{intended, resulting, taps, durationMs, synthetic, source}) plus the ORIGINAL
trace file (to reconstruct the raw, uncorrected keystrokes from the taps), and
reports per-trace + aggregate metrics:

  - word accuracy        aligned intended-vs-resulting word match rate
  - char accuracy        difflib similarity ratio
  - corrections helped   raw-word wrong -> resulting-word right (autocorrect win)
  - corrections hurt     raw-word right -> resulting-word wrong (FALSE autocorrect,
                         the PLAN.md 0%-false-autocorrect gate)
  - restoration (IS)     accent-naked raw -> correctly accented resulting
  - replay chars/sec     taps / replay durationMs (replay speed, not human speed)

Results come from --results FILE, or scraped from a --log (xcodebuild output;
lines prefixed "REPLAY_JSONL:"). Stdlib only.

Usage:
    python3 scripts/replay-report.py --traces ReplayRig/traces/tsi-en-sample.json \
        --results ReplayRig/traces/results/run.jsonl --out ReplayRig/traces/results/report.json
    python3 scripts/replay-report.py --traces <traces.json> --log <xcodebuild.log>
"""
from __future__ import annotations

import argparse
import difflib
import json
import sys
import unicodedata

ACCENT_FOLD = {"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y"}


def reconstruct_typed(taps: list[dict]) -> str:
    """The raw, uncorrected text the taps would insert (before any autocorrect).
    Mirrors the fold in replay-convert: space->' ', period->'.', letters as-is."""
    out = []
    for t in taps:
        k = t["key"]
        out.append(" " if k == "space" else k)
    return "".join(out)


def norm(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip().lower())


def words(s: str) -> list[str]:
    return [w.strip(".,!?;:\"'()") for w in norm(s).split() if w.strip(".,!?;:\"'()")]


def word_accuracy(intended: str, resulting: str) -> float:
    iw, rw = words(intended), words(resulting)
    if not iw:
        return 1.0 if not rw else 0.0
    sm = difflib.SequenceMatcher(None, iw, rw)
    matched = sum(b.size for b in sm.get_matching_blocks())
    return matched / len(iw)


def char_accuracy(intended: str, resulting: str) -> float:
    return difflib.SequenceMatcher(None, norm(intended), norm(resulting)).ratio()


def correction_counts(intended: str, raw: str, resulting: str) -> tuple[int, int, int, int]:
    """Per-word helped/hurt tallies (positionally aligned intended words)."""
    iw, raww, rw = words(intended), words(raw), words(resulting)
    helped = hurt = raw_ok = 0
    n = len(iw)
    for k in range(n):
        i = iw[k]
        r = raww[k] if k < len(raww) else None
        res = rw[k] if k < len(rw) else None
        raw_right = (r == i)
        res_right = (res == i)
        if raw_right:
            raw_ok += 1
            if not res_right:
                hurt += 1
        else:
            if res_right:
                helped += 1
    return helped, hurt, raw_ok, n


def accent_restoration(intended: str, raw: str, resulting: str) -> tuple[int, int]:
    """For synthetic-IS: of the accented chars the raw stream folded away, how
    many did the engine correctly restore? Returns (restored, total_folded)."""
    iw, rw = words(intended), words(resulting)
    restored = folded = 0
    for k, i in enumerate(iw):
        res = rw[k] if k < len(rw) else ""
        raw_folded = "".join(ACCENT_FOLD.get(c, c) for c in i)
        if raw_folded == i:
            continue  # no accents in this word
        for pos, ch in enumerate(i):
            if ch in "áéíóúý":
                folded += 1
                if pos < len(res) and res[pos] == ch:
                    restored += 1
    return restored, folded


def load_results(args) -> list[dict]:
    lines: list[str] = []
    if args.results:
        with open(args.results, encoding="utf-8") as f:
            lines = [ln for ln in f if ln.strip()]
    elif args.log:
        with open(args.log, encoding="utf-8", errors="replace") as f:
            for ln in f:
                idx = ln.find("REPLAY_JSONL:")
                if idx != -1:
                    lines.append(ln[idx + len("REPLAY_JSONL:"):].strip())
    else:
        sys.exit("provide --results FILE or --log FILE")
    return [json.loads(ln) for ln in lines]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--traces", required=True, help="original trace JSON (for raw keystrokes)")
    ap.add_argument("--results", help="JSONL transcript from the UI test")
    ap.add_argument("--log", help="xcodebuild log to scrape REPLAY_JSONL: lines from")
    ap.add_argument("--out", help="write aggregate report JSON here")
    args = ap.parse_args()

    with open(args.traces, encoding="utf-8") as f:
        traces = json.load(f)
    results = load_results(args)
    if not results:
        sys.exit("no result lines found")

    # Align results to traces by index (the UI test replays in file order).
    per = []
    agg = {"word_acc": 0.0, "char_acc": 0.0, "helped": 0, "hurt": 0, "raw_ok": 0,
           "words": 0, "taps": 0, "dur_ms": 0, "restored": 0, "folded": 0}
    for k, res in enumerate(results):
        intended = res.get("intended", "")
        resulting = res.get("resulting", "")
        raw = reconstruct_typed(traces[k]["taps"]) if k < len(traces) else resulting
        wa = word_accuracy(intended, resulting)
        ca = char_accuracy(intended, resulting)
        helped, hurt, raw_ok, nwords = correction_counts(intended, raw, resulting)
        restored, folded = accent_restoration(intended, raw, resulting)
        taps = res.get("taps", len(traces[k]["taps"]) if k < len(traces) else 0)
        dur = res.get("durationMs", 0)
        cps = round(taps / (dur / 1000), 2) if dur else 0.0
        per.append({
            "intended": intended, "resulting": resulting, "raw": raw,
            "word_acc": round(wa, 3), "char_acc": round(ca, 3),
            "helped": helped, "hurt": hurt, "restored": restored, "folded": folded,
            "taps": taps, "durationMs": dur, "replay_cps": cps,
        })
        agg["word_acc"] += wa
        agg["char_acc"] += ca
        agg["helped"] += helped
        agg["hurt"] += hurt
        agg["raw_ok"] += raw_ok
        agg["restored"] += restored
        agg["folded"] += folded
        agg["words"] += nwords
        agg["taps"] += taps
        agg["dur_ms"] += dur

    n = len(per)
    summary = {
        "n_traces": n,
        "mean_word_accuracy": round(agg["word_acc"] / n, 4),
        "mean_char_accuracy": round(agg["char_acc"] / n, 4),
        "corrections_helped": agg["helped"],
        "corrections_hurt": agg["hurt"],
        "false_autocorrect_rate": round(agg["hurt"] / agg["raw_ok"], 4) if agg["raw_ok"] else 0.0,
        "accent_restoration_rate": round(agg["restored"] / agg["folded"], 4) if agg["folded"] else None,
        "total_taps": agg["taps"],
        "replay_chars_per_sec": round(agg["taps"] / (agg["dur_ms"] / 1000), 2) if agg["dur_ms"] else 0.0,
    }

    print("=== Replay report ===")
    for kk, vv in summary.items():
        print(f"  {kk}: {vv}")
    print("--- worst traces by word accuracy ---")
    for p in sorted(per, key=lambda x: x["word_acc"])[:5]:
        print(f"  {p['word_acc']:.2f}  intended={p['intended']!r}")
        print(f"        raw={p['raw']!r}")
        print(f"        got={p['resulting']!r}  helped={p['helped']} hurt={p['hurt']}")

    if args.out:
        import os
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"summary": summary, "per_trace": per}, f, indent=1, ensure_ascii=False)
        print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
