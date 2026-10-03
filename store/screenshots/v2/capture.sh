#!/usr/bin/env bash
#
# capture.sh — Stage A of the v2 screenshot pipeline: drive the REAL Lyklaborð
# keyboard in a headless simulator into each shot's state and capture raw PNGs.
#
# How it works (no GUI, no focus stealing):
#   1. Build the app + ReplayRig test bundle for the iPhone 16 Pro Max sim.
#   2. Install Lyklabord(.appex) + ReplayHost; enable the keyboard by
#      seeding com.apple.Preferences AppleKeyboards with the REAL appex bundle
#      id `is.solberg.lyklabord.keyboard` (replay-run.sh's historical
#      `…lyklabord.app.keyboard` was wrong — that's why the trick "never
#      worked"), then reboot the sim so SpringBoard reloads it.
#   3. For each shot, run one ScreenshotUITests test (XCUITest taps the real
#      keys through the accessibility layer). When the state is ready the test
#      writes captures/ready-NN and holds; we screenshot with
#      `xcrun simctl io screenshot` (never steals focus) and let it finish.
#
# Captures are cached: re-runs of render-all.sh do NOT re-capture. Run this
# script directly to refresh captures.
#
# Usage: store/screenshots/v2/capture.sh [shot …]   (default: 01 02 03 04 05)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
CAP="$ROOT/store/screenshots/v2/captures"
DD="$ROOT/ReplayRig/.derived"
SIM_DEVICE="${SIM_DEVICE:-iPhone 16 Pro Max}"
SHOTS=("${@:-01 02 03 04 05}")
[ $# -eq 0 ] && SHOTS=(01 02 03 04 05)

declare -A TEST_FOR=(
  [01]=testShot01Hero [02]=testShot02Accents [03]=testShot03Blend
  [04]=testShot04Inflection [05]=testShot05Dictionary
)

mkdir -p "$CAP"

UDID="$(xcrun simctl list devices available | awk -v d="$SIM_DEVICE" -F '[()]' '$0 ~ d" \\(" {print $2; exit}')"
[ -n "$UDID" ] || { echo "no available sim named $SIM_DEVICE"; exit 1; }
echo "== sim $SIM_DEVICE ($UDID) =="
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "== build =="
xcodegen generate >/dev/null
# Release: a DEBUG appex prints the build stamp on the idle spacebar
# (DevSpaceContent.swift) instead of "Bil", which would leak into the hero.
xcodebuild build -scheme Lyklabord -project Lyklabord.xcodeproj -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet
xcodebuild build-for-testing -scheme ReplayRig -project Lyklabord.xcodeproj \
  -destination "id=$UDID" -derivedDataPath "$DD" -quiet

echo "== install + enable keyboard =="
APP_MAIN="$DD/Build/Products/Release-iphonesimulator/Lyklabord.app"
[ -d "$APP_MAIN" ] || { echo "missing Release build at $APP_MAIN"; exit 1; }
# iOS caches keyboard appexes across reinstalls (stale-appex tell: no build
# stamp / old layout). Uninstall first so the new extension actually loads.
xcrun simctl uninstall "$UDID" is.solberg.lyklabord 2>/dev/null || true
APP_HOST="$(find "$DD/Build/Products" -maxdepth 2 -name 'ReplayHost.app' | head -1)"
xcrun simctl install "$UDID" "$APP_MAIN"
xcrun simctl install "$UDID" "$APP_HOST"
if ! xcrun simctl spawn "$UDID" defaults read com.apple.Preferences AppleKeyboards 2>/dev/null \
    | grep -q "is.solberg.lyklabord.keyboard"; then
  xcrun simctl spawn "$UDID" defaults write com.apple.Preferences AppleKeyboardsExpanded -int 1
  xcrun simctl spawn "$UDID" defaults write com.apple.Preferences AppleKeyboards \
    -array "en_US@sw=QWERTY;hw=Automatic" "is.solberg.lyklabord.keyboard"
  echo "   seeded AppleKeyboards; rebooting sim"
  xcrun simctl shutdown "$UDID"; xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi

# The AppleKeyboards defaults seed alone does NOT activate a keyboard
# extension (see commit 3046793) — without this step every shot silently
# captures Apple's system Icelandic keyboard, which has the same letter
# rows. Run the automated Settings enablement test (idempotent).
echo "== enable Lyklaborð in Settings (UI test) =="
xcodebuild test-without-building -scheme ReplayRig -project Lyklabord.xcodeproj \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  -only-testing:"ReplayRigUITests/ScreenshotUITests/testEnableKeyboardInSettings" \
  >"$CAP/.xcodebuild-enable.log" 2>&1 || true
grep -E "passed|skipped|failed" "$CAP/.xcodebuild-enable.log" | grep "Test Case" | head -1

# Marketing status bar (Apple-conventional 9:41, full signal/battery).
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 2>/dev/null || true

for SHOT in ${SHOTS[@]}; do
  TESTNAME="${TEST_FOR[$SHOT]}"
  echo "== shot $SHOT ($TESTNAME) =="
  rm -f "$CAP/ready-$SHOT"
  LOG="$CAP/.xcodebuild-$SHOT.log"
  ( TEST_RUNNER_SHOT_DIR="$CAP" TEST_RUNNER_SHOT_HOLD_S=20 \
    xcodebuild test-without-building -scheme ReplayRig -project Lyklabord.xcodeproj \
      -destination "id=$UDID" -derivedDataPath "$DD" \
      -only-testing:"ReplayRigUITests/ScreenshotUITests/$TESTNAME" \
      >"$LOG" 2>&1 ) &
  TESTPID=$!
  CAPTURED=0
  for _ in $(seq 1 180); do
    if [ -f "$CAP/ready-$SHOT" ]; then
      sleep 1  # let any callouts/animations settle
      xcrun simctl io "$UDID" screenshot "$CAP/$SHOT-raw.png" >/dev/null
      CAPTURED=1; echo "   captured $SHOT-raw.png"; break
    fi
    kill -0 "$TESTPID" 2>/dev/null || break
    sleep 1
  done
  wait "$TESTPID" || true
  rm -f "$CAP/ready-$SHOT"
  if [ "$CAPTURED" != 1 ]; then
    echo "   FAILED — test never signalled ready; tail of log:"
    grep -E "Skip|error|failed" "$LOG" | tail -5 || tail -5 "$LOG"
  fi
done
echo "== done: $(ls "$CAP" | grep -c raw.png) raw captures in $CAP =="
