#!/usr/bin/env bash
#
# replay-run.sh — orchestrate the last-mile replay rig (PLAN.md pyramid tier 3).
#
# Boots a named simulator, installs the Lyklaborð keyboard (via the main
# Lyklabord app) + the ReplayHost app, records video, runs the XCUITest
# that replays a timed typing trace through the real keyboard, then scores the
# transcript with replay-report.py. Headless-friendly; no host-Mac input.
#
# USAGE:
#   scripts/replay-run.sh [TRACE_JSON]
#     TRACE_JSON  trace file to replay (default: ReplayRig/traces/tsi-en-sample.json)
#   Env overrides: SIM_NAME, SIM_DEVICE, MAX_TRACES, DT_CAP_MS, NO_VIDEO=1
#
# ==========================================================================
#  ONE-TIME MANUAL SETUP (required once per simulator; XCUITest CANNOT do it)
# ==========================================================================
# A third-party keyboard must be (a) enabled and (b) granted Full Access, and
# (c) selected as the active input for the field. There is no supported API or
# `simctl` command to flip these Settings toggles (see PLAN.md v1-blockers:
# "No official API to detect 'keyboard enabled'; the AppleKeyboards UserDefaults
# trick is undocumented/fragile"). This script ATTEMPTS the undocumented
# defaults write below, but it is best-effort and typically does NOT grant Full
# Access. The reliable path is the one-time manual step:
#
#   1. Boot the sim (this script does it), then open Settings.app in the sim:
#        xcrun simctl launch booted com.apple.Preferences
#   2. General > Keyboard > Keyboards > Add New Keyboard… > Lyklaborð
#   3. Tap Lyklaborð > enable "Allow Full Access"
#   4. Launch ReplayHost, tap the field, then tap-and-hold the globe key and
#      choose Lyklaborð (makes it the active keyboard for that field).
#
# This persists until the simulator is erased (`simctl erase`). After it's done
# once, re-runs of this script are fully unattended. If the keyboard is not
# active, the UITest SKIPS with a clear message (it detects Lyklaborð by the
# presence of the IS-only ð/þ/æ/ö keys) rather than producing garbage.
#
# RUNTIME EXPECTATIONS: build (cold) ~1-3 min; per trace ≈ (sum of capped
# inter-key delays, ~0.2s median x taps) + 0.4s settle + clears ≈ 5-15s. A
# 50-trace set ≈ 6-12 min wall. Use MAX_TRACES=1 for a smoke test (~15-30s
# after build). Video adds negligible time.
# ==========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TRACE="${1:-ReplayRig/traces/tsi-en-sample.json}"
SIM_NAME="${SIM_NAME:-ReplayRig}"
SIM_DEVICE="${SIM_DEVICE:-iPhone 16 Pro}"
PROJECT="Lyklabord.xcodeproj"
DD="$ROOT/ReplayRig/.derived"
RESULTS_DIR="$ROOT/ReplayRig/traces/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_JSONL="$RESULTS_DIR/run-$STAMP.jsonl"
XCLOG="$RESULTS_DIR/xcodebuild-$STAMP.log"
VIDEO="$RESULTS_DIR/run-$STAMP.mov"
REPORT="$RESULTS_DIR/report-$STAMP.json"

[ -f "$TRACE" ] || { echo "trace not found: $TRACE"; exit 1; }
mkdir -p "$RESULTS_DIR"

echo "== 1. Ensure simulator '$SIM_NAME' ($SIM_DEVICE) =="
UDID="$(xcrun simctl list devices | awk -v n="$SIM_NAME" -F '[()]' '$0 ~ n" \\(" {print $2; exit}')"
if [ -z "${UDID:-}" ]; then
  RUNTIME="$(xcrun simctl list runtimes | awk '/iOS/{print $NF}' | tail -1)"
  DEVTYPE="$(xcrun simctl list devicetypes | awk -v d="$SIM_DEVICE" -F '[()]' '$0 ~ d" \\(" {print $2; exit}')"
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVTYPE" "$RUNTIME")"
  echo "  created $UDID"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b || true

echo "== 2. Build keyboard app + rig =="
xcodebuild build -scheme Lyklabord -project "$PROJECT" \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet
xcodebuild build-for-testing -scheme ReplayRig -project "$PROJECT" \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet

echo "== 3. Install apps (keyboard reaches the host system-wide) =="
APP_MAIN="$(find "$DD/Build/Products" -maxdepth 2 -name 'Lyklabord.app' | head -1)"
APP_HOST="$(find "$DD/Build/Products" -maxdepth 2 -name 'ReplayHost.app' | head -1)"
[ -n "$APP_MAIN" ] && xcrun simctl install "$UDID" "$APP_MAIN"
[ -n "$APP_HOST" ] && xcrun simctl install "$UDID" "$APP_HOST"

echo "== 4. Best-effort keyboard enable + software-keyboard on (fragile; see header) =="
# Undocumented: set our appex as the enabled keyboard. Does NOT grant Full
# Access. If this fails to take, the UITest skips with instructions.
# NOTE: the extension bundle id is is.solberg.lyklabord.keyboard (project.yml);
# a wrong id here (pre-2026-07-21 the script wrote …lyklabord.app.keyboard)
# silently leaves the SYSTEM Icelandic keyboard active — which also has
# ð/þ/æ/ö, so replays "pass" against Apple's keyboard, not ours. Write the
# array outright (not -array-add) so stale/bogus entries can't accumulate.
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences AppleKeyboards \
  -array "is.solberg.lyklabord.keyboard" 2>/dev/null || true
# The on-screen keyboard only appears when the Simulator's "Connect Hardware
# Keyboard" is OFF. This is a host Simulator.app preference (part of the same
# one-time setup as enabling Lyklaborð). Best-effort; the UITest reports clearly
# if the software keyboard never shows.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false 2>/dev/null || true

VIDEO_PID=""
if [ "${NO_VIDEO:-0}" != "1" ]; then
  echo "== 5. Start video =="
  xcrun simctl io "$UDID" recordVideo --codec h264 "$VIDEO" &
  VIDEO_PID=$!
fi

echo "== 6. Run replay UITest =="
# IMPORTANT: xcodebuild forwards env vars prefixed TEST_RUNNER_ (prefix stripped)
# into the test-runner process — but ONLY when they are in xcodebuild's OWN
# environment, NOT when passed as trailing build-setting args. So we export them.
# The trace path is a HOST absolute path; the simulator shares the host
# filesystem, so the in-sim test reads it directly (verified).
set +e
TEST_RUNNER_REPLAY_TRACE_PATH="$ROOT/$TRACE" \
TEST_RUNNER_REPLAY_RESULTS_PATH="$RESULTS_JSONL" \
TEST_RUNNER_REPLAY_DT_CAP_MS="${DT_CAP_MS:-1200}" \
TEST_RUNNER_REPLAY_MAX_TRACES="${MAX_TRACES:-100000}" \
TEST_RUNNER_REPLAY_STEP_CAPTURE="${STEP_CAPTURE:-0}" \
xcodebuild test-without-building -scheme ReplayRig -project "$PROJECT" \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  2>&1 | tee "$XCLOG"
TEST_RC=${PIPESTATUS[0]}
set -e

if [ -n "$VIDEO_PID" ]; then
  echo "== 7. Stop video =="
  kill -INT "$VIDEO_PID" 2>/dev/null || true
  wait "$VIDEO_PID" 2>/dev/null || true
  echo "  video -> $VIDEO"
fi

echo "== 8. Report =="
# Prefer the written JSONL; fall back to scraping REPLAY_JSONL from the log.
if [ -s "$RESULTS_JSONL" ]; then
  python3 scripts/replay-report.py --traces "$TRACE" --results "$RESULTS_JSONL" --out "$REPORT" || true
else
  python3 scripts/replay-report.py --traces "$TRACE" --log "$XCLOG" --out "$REPORT" || true
fi

echo "test rc=$TEST_RC  log=$XCLOG  report=$REPORT"
exit "$TEST_RC"
