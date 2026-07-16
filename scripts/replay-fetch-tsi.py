#!/usr/bin/env python3
"""replay-fetch-tsi.py — download the Google TSI dataset for the replay rig.

Downloads the "Tap Typing with Touch Sensing Images" (TSI) dataset (UIST 2024,
CC-BY-4.0) from GitHub into ReplayRig/traces/tsi-raw/. Stdlib only.

Dataset: https://github.com/google-research-datasets/tap-typing-with-touch-sensing-images

The raw download is git-ignored (see ReplayRig/traces/.gitignore) because
touch_data.csv is ~27 MB and is a redistribution of upstream data. The DERIVED
trace files committed under ReplayRig/traces/*.json are small, carry attribution
(CC-BY-4.0), and are what the rig actually replays. Re-run this only when you
want to regenerate those from source.

Usage:
    python3 scripts/replay-fetch-tsi.py            # fetch everything needed
    python3 scripts/replay-fetch-tsi.py --force    # re-download even if present
    python3 scripts/replay-fetch-tsi.py --minimal  # skip touch_data.csv (metadata only)
"""
from __future__ import annotations

import argparse
import os
import sys
import urllib.request

REPO = "google-research-datasets/tap-typing-with-touch-sensing-images"
BASE = f"https://raw.githubusercontent.com/{REPO}/main"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RAW_DIR = os.path.join(ROOT, "ReplayRig", "traces", "tsi-raw")

# (filename, needed_for_minimal). touch_data.csv is the big one (~27 MB).
FILES = [
    ("keyboard_data.json", True),   # source-layout geometry (key rects, kbd dims)
    ("prompt_data.csv", True),      # intended phrases keyed by (participant,task,trial)
    ("README.md", True),            # column docs + citation
    ("LICENSE", True),              # CC-BY-4.0
    ("touch_data.csv", False),      # 43,735 taps: x/y centroid + timestamp per key
]


def download(name: str, force: bool) -> None:
    url = f"{BASE}/{name}"
    dest = os.path.join(RAW_DIR, name)
    if os.path.exists(dest) and not force:
        size = os.path.getsize(dest)
        print(f"  skip  {name} (exists, {size:,} bytes) — use --force to refetch")
        return
    print(f"  fetch {name} ...", end="", flush=True)
    tmp = dest + ".part"
    try:
        with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as out:
            total = 0
            while True:
                chunk = resp.read(1 << 16)
                if not chunk:
                    break
                out.write(chunk)
                total += len(chunk)
        os.replace(tmp, dest)
        print(f" done ({total:,} bytes)")
    except Exception as exc:  # noqa: BLE001
        if os.path.exists(tmp):
            os.remove(tmp)
        print(f" FAILED: {exc}")
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    ap.add_argument("--minimal", action="store_true",
                    help="metadata only (skip touch_data.csv)")
    args = ap.parse_args()

    os.makedirs(RAW_DIR, exist_ok=True)
    print(f"TSI dataset -> {RAW_DIR}")
    for name, in_minimal in FILES:
        if args.minimal and not in_minimal:
            print(f"  skip  {name} (--minimal)")
            continue
        download(name, args.force)
    print("Done. Next: python3 scripts/replay-convert.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
