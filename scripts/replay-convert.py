#!/usr/bin/env python3
"""replay-convert.py — TSI touch data -> replay-rig trace JSON (+ IS synthesizer).

Two modes, stdlib only:

  (default)          Convert real Google TSI taps into English replay traces.
  --synthesize-is    Synthesize Icelandic traces from data/eval/sentences.is.txt
                     using timing sampled from TSI inter-key distributions and
                     Gaussian within-key spatial noise (labeled "synthetic").

TRACE FORMAT (the rig's contract; a trace file is a JSON array of these):

    {
      "intended": "my preferred treat is chocolate.",   # target text (with IS accents intact)
      "synthetic": false,                                 # true only for synthesized traces
      "source": "TSI user01/task1/0",                     # provenance
      "taps": [
        {"key": "m", "dxNorm": 0.11, "dyNorm": -0.05, "dtMs": 0},
        {"key": "y", "dxNorm": -0.22, "dyNorm": 0.07, "dtMs": 362},
        {"key": "space", "dxNorm": 0.01, "dyNorm": 0.34, "dtMs": 212},
        ...
      ]
    }

  key    : one lowercase layout char ("a".."z","ð","þ","æ","ö","."), or "space".
           Accented IS vowels are NOT keys — they are produced by tapping the
           base vowel and letting the engine restore the accent (this is what
           the rig measures). "space" is the spacebar.
  dxNorm  : horizontal tap offset within the SOURCE key, normalized so a full
  dyNorm    key width/height spans 1.0 (0 = dead center, +0.5 = right/bottom edge).
           Fat-finger taps that crossed a key boundary in the source data KEEP
           their true magnitude and may exceed |0.5| — that boundary signal is
           the whole point (fed to SpatialModel σ calibration). The rig applies
           the SAME normalized offset over OUR Icelandic key rect, re-projecting
           human fat-finger distributions across the QWERTY->IS layout difference.
  dtMs    : ms since the previous tap (first tap = 0). Real inter-key latency.

WHY NORMALIZED (not pixels): TSI was captured on a Pixel 6 Pro keyboard
(1440x854 px). Normalizing by the source key geometry (from keyboard_data.json)
makes the trace layout-independent so it replays on any iOS key rect.

Usage:
    python3 scripts/replay-convert.py                     # -> tsi-en-sample.json
    python3 scripts/replay-convert.py --count 50
    python3 scripts/replay-convert.py --synthesize-is     # -> synthetic-is.json
    python3 scripts/replay-convert.py --validate ReplayRig/traces/tsi-en-sample.json
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import random
import sys
import unicodedata
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RAW_DIR = os.path.join(ROOT, "ReplayRig", "traces", "tsi-raw")
OUT_DIR = os.path.join(ROOT, "ReplayRig", "traces")
DIST_PATH = os.path.join(OUT_DIR, "tsi-distributions.json")
IS_SENTENCES = os.path.join(ROOT, "data", "eval", "sentences.is.txt")  # read-only

# ---------------------------------------------------------------------------
# Icelandic layout key set (mirrors KeyboardExt/KeyboardViewController.swift
# `KeyboardLayout.InputSet.icelandic`). These are the keys the rig can tap.
# ---------------------------------------------------------------------------
LAYOUT_KEYS = set("qwertyuiopðasdfghjklæözxcvbnmþ.")  # letters + period
# Acute vowels are long-press-gated on our layout -> a fast typist taps the
# base vowel and the engine restores the accent (PLAN.md "lane relaxation").
# So we FOLD them to their base key when producing taps.
ACCENT_FOLD = {"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y"}
# ð þ æ ö are first-class keys — never folded.


def csv_field_char(ref_char: str) -> str | None:
    """Map a TSI ref_char to our layout key token, or None if unmappable."""
    if ref_char == "SPACE":
        return "space"
    c = ref_char.lower()
    if c in LAYOUT_KEYS:
        return c
    return None


def load_source_geometry() -> dict:
    """Load per-key center + size (px) from TSI keyboard_data.json."""
    path = os.path.join(RAW_DIR, "keyboard_data.json")
    with open(path) as f:
        kd = json.load(f)
    geom = {}
    for key_id, info in kd["keys_info"].items():
        token = "space" if key_id == "SPACE" else key_id.lower()
        geom[token] = (
            info["key_center_x"], info["key_center_y"],
            info["key_width"], info["key_height"],
        )
    return geom


def norm_offset(x: float, y: float, geom: tuple) -> tuple[float, float]:
    cx, cy, kw, kh = geom
    dx = (x - cx) / kw
    dy = (y - cy) / kh
    return round(dx, 4), round(dy, 4)


# ---------------------------------------------------------------------------
# TSI mode
# ---------------------------------------------------------------------------

def load_prompts() -> dict:
    path = os.path.join(RAW_DIR, "prompt_data.csv")
    prompts = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            key = (row["participant_id"], row["task_id"], row["trial_id"])
            prompts[key] = (row["prompt"], row["prompt_type"])
    return prompts


def load_tsi_groups(geom: dict):
    """Yield (key_tuple, prompt, prompt_type, taps, dt_pool, spatial) built from
    touch_data.csv. Also returns aggregate distribution accumulators."""
    prompts = load_prompts()
    path = os.path.join(RAW_DIR, "touch_data.csv")
    groups: dict = defaultdict(list)
    with open(path) as f:
        for row in csv.DictReader(f):
            if row["was_deleted"] == "True":
                continue  # keep only committed taps (see module docstring)
            key = (row["participant_id"], row["task_id"], row["trial_id"])
            groups[key].append(row)

    dt_pool: list[int] = []
    dx_all: list[float] = []
    dy_all: list[float] = []
    traces = []
    for key, rows in groups.items():
        rows.sort(key=lambda r: int(r["timestamp_ms"]))
        prompt, ptype = prompts.get(key, (None, None))
        if prompt is None:
            continue
        taps = []
        prev_ts = None
        for r in rows:
            token = csv_field_char(r["ref_char"])
            if token is None or token not in geom:
                continue
            x = float(r["first_frame_touch_x"])
            y = float(r["first_frame_touch_y"])
            dx, dy = norm_offset(x, y, geom[token])
            ts = int(r["timestamp_ms"])
            dt = 0 if prev_ts is None else max(0, ts - prev_ts)
            prev_ts = ts
            taps.append({"key": token, "dxNorm": dx, "dyNorm": dy, "dtMs": dt})
            if dt > 0:
                dt_pool.append(dt)
            dx_all.append(dx)
            dy_all.append(dy)
        if len(taps) >= 3:
            traces.append({
                "key": key, "prompt": prompt, "ptype": ptype, "taps": taps,
            })
    return traces, dt_pool, dx_all, dy_all


def std(xs: list[float]) -> float:
    if not xs:
        return 0.0
    m = sum(xs) / len(xs)
    return (sum((v - m) ** 2 for v in xs) / len(xs)) ** 0.5


def write_distributions(dt_pool, dx_all, dy_all) -> dict:
    dt_pool_sorted = sorted(dt_pool)
    # Trim the long tail (think-time pauses) for a sane sampling pool: keep the
    # inter-key gaps below the 95th percentile. Full stats still reported.
    p95 = dt_pool_sorted[int(0.95 * len(dt_pool_sorted))] if dt_pool_sorted else 0
    dist = {
        "source": "Google TSI (touch_data.csv, was_deleted==False)",
        "license": "CC-BY-4.0",
        "n_taps": len(dx_all),
        "interkey_dt_ms": {
            "median": dt_pool_sorted[len(dt_pool_sorted) // 2] if dt_pool_sorted else 0,
            "mean": round(sum(dt_pool) / len(dt_pool), 1) if dt_pool else 0,
            "p95": p95,
            "n": len(dt_pool),
        },
        "spatial_norm_offset_std": {
            "dxNorm": round(std(dx_all), 4),
            "dyNorm": round(std(dy_all), 4),
        },
        # Empirical inter-key gap pool (<= p95) for the IS synthesizer to sample.
        "interkey_dt_pool": [d for d in dt_pool if d <= p95],
    }
    with open(DIST_PATH, "w") as f:
        json.dump(dist, f)
    return dist


def build_en_sample(count: int, seed: int) -> None:
    if not os.path.exists(os.path.join(RAW_DIR, "touch_data.csv")):
        sys.exit("touch_data.csv missing — run scripts/replay-fetch-tsi.py first")
    geom = load_source_geometry()
    traces, dt_pool, dx_all, dy_all = load_tsi_groups(geom)
    dist = write_distributions(dt_pool, dx_all, dy_all)
    print(f"TSI: {len(traces)} candidate traces, {dist['n_taps']:,} taps")
    print(f"  inter-key dt median={dist['interkey_dt_ms']['median']}ms "
          f"p95={dist['interkey_dt_ms']['p95']}ms; "
          f"spatial std dx={dist['spatial_norm_offset_std']['dxNorm']} "
          f"dy={dist['spatial_norm_offset_std']['dyNorm']}")

    # Prefer real English phrases (readable intended text) over "random" prompts,
    # and spread across participants for touch-distribution diversity.
    phrases = [t for t in traces if t["ptype"] == "phrase"]
    by_user = defaultdict(list)
    for t in phrases:
        by_user[t["key"][0]].append(t)
    rng = random.Random(seed)
    for lst in by_user.values():
        rng.shuffle(lst)
    picked = []
    users = sorted(by_user)
    i = 0
    while len(picked) < count and any(by_user.values()):
        u = users[i % len(users)]
        if by_user[u]:
            picked.append(by_user[u].pop())
        i += 1
        if i > count * 20:
            break

    out = []
    for t in picked:
        out.append({
            "intended": t["prompt"].strip(),
            "synthetic": False,
            "source": f"TSI {t['key'][0]}/{t['key'][1]}/{t['key'][2]}",
            "taps": t["taps"],
        })
    out_path = os.path.join(OUT_DIR, "tsi-en-sample.json")
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(f"Wrote {len(out)} traces -> {os.path.relpath(out_path, ROOT)}")


# ---------------------------------------------------------------------------
# Synthesize-IS mode
# ---------------------------------------------------------------------------

def sentence_to_taps(sentence: str, dt_pool, sigma_x, sigma_y, rng):
    """Map an Icelandic sentence to taps, folding acute accents to base keys.
    Returns (taps, intended) or None if the sentence uses unsupported chars."""
    taps = []
    prev = True  # first tap dt = 0
    for ch in sentence:
        if ch == " ":
            token = "space"
        else:
            low = ch.lower()
            low = ACCENT_FOLD.get(low, low)
            if low not in LAYOUT_KEYS:
                return None  # unsupported (comma, digit, parenthesis, ...)
            token = low
        dx = round(rng.gauss(0.0, sigma_x), 4)
        dy = round(rng.gauss(0.0, sigma_y), 4)
        dt = 0 if prev else rng.choice(dt_pool)
        prev = False
        taps.append({"key": token, "dxNorm": dx, "dyNorm": dy, "dtMs": dt})
    return taps, sentence


def synthesize_is(count: int, seed: int) -> None:
    if not os.path.exists(DIST_PATH):
        sys.exit("tsi-distributions.json missing — run the default (TSI) mode first")
    if not os.path.exists(IS_SENTENCES):
        sys.exit(f"missing {IS_SENTENCES}")
    with open(DIST_PATH) as f:
        dist = json.load(f)
    dt_pool = dist["interkey_dt_pool"] or [180]
    sigma_x = dist["spatial_norm_offset_std"]["dxNorm"] or 0.18
    sigma_y = dist["spatial_norm_offset_std"]["dyNorm"] or 0.18
    rng = random.Random(seed)

    with open(IS_SENTENCES, encoding="utf-8") as f:
        lines = [unicodedata.normalize("NFC", ln.strip()) for ln in f if ln.strip()]

    out = []
    for line in lines:
        if len(out) >= count:
            break
        # Only fully-supported sentences of reasonable length (keeps traces
        # clean: no 123-layer punctuation to replay). Must contain an accent
        # to actually exercise restoration; keep some accent-free too.
        if not (15 <= len(line) <= 70):
            continue
        result = sentence_to_taps(line, dt_pool, sigma_x, sigma_y, rng)
        if result is None:
            continue
        taps, intended = result
        out.append({
            "intended": intended,
            "synthetic": True,
            "source": "synthesized: sentences.is.txt + TSI timing/spatial dists",
            "taps": taps,
        })

    out_path = os.path.join(OUT_DIR, "synthetic-is.json")
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    n_accent = sum(1 for t in out if any(c in t["intended"] for c in "áéíóúý"))
    print(f"Synthesized {len(out)} IS traces ({n_accent} contain acute accents) "
          f"-> {os.path.relpath(out_path, ROOT)}")
    print(f"  timing sampled from {len(dt_pool)} TSI inter-key gaps; "
          f"spatial N(0, dx={sigma_x}, dy={sigma_y})")


# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

def validate(path: str) -> int:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        print("FAIL: top level must be an array"); return 1
    errs = 0
    valid_keys = LAYOUT_KEYS | {"space"}
    for i, tr in enumerate(data):
        loc = f"trace[{i}]"
        for field in ("intended", "taps"):
            if field not in tr:
                print(f"FAIL {loc}: missing '{field}'"); errs += 1
        if not isinstance(tr.get("intended"), str) or not tr.get("intended"):
            print(f"FAIL {loc}: 'intended' must be non-empty string"); errs += 1
        taps = tr.get("taps", [])
        if not isinstance(taps, list) or not taps:
            print(f"FAIL {loc}: 'taps' must be non-empty array"); errs += 1
            continue
        for j, tap in enumerate(taps):
            tloc = f"{loc}.taps[{j}]"
            for k in ("key", "dxNorm", "dyNorm", "dtMs"):
                if k not in tap:
                    print(f"FAIL {tloc}: missing '{k}'"); errs += 1
            if tap.get("key") not in valid_keys:
                print(f"FAIL {tloc}: key {tap.get('key')!r} not on layout"); errs += 1
            if not isinstance(tap.get("dxNorm"), (int, float)):
                print(f"FAIL {tloc}: dxNorm not numeric"); errs += 1
            if not isinstance(tap.get("dyNorm"), (int, float)):
                print(f"FAIL {tloc}: dyNorm not numeric"); errs += 1
            if not isinstance(tap.get("dtMs"), int) or tap.get("dtMs", -1) < 0:
                print(f"FAIL {tloc}: dtMs must be int >= 0"); errs += 1
        if j == 0 and taps and taps[0]["dtMs"] != 0:
            print(f"WARN {loc}: first tap dtMs != 0")
    n_tap = sum(len(t.get("taps", [])) for t in data)
    if errs:
        print(f"INVALID: {errs} error(s) across {len(data)} traces")
        return 1
    print(f"OK: {len(data)} traces, {n_tap} taps, schema valid ({path})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--synthesize-is", action="store_true",
                    help="synthesize Icelandic traces instead of converting TSI")
    ap.add_argument("--validate", metavar="FILE", help="validate a trace file and exit")
    ap.add_argument("--count", type=int, default=50, help="number of traces (default 50)")
    ap.add_argument("--seed", type=int, default=1729, help="RNG seed for reproducibility")
    args = ap.parse_args()

    if args.validate:
        return validate(args.validate)
    if args.synthesize_is:
        synthesize_is(args.count, args.seed)
    else:
        build_en_sample(args.count, args.seed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
