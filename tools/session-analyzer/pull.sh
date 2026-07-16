#!/usr/bin/env bash
#
# pull.sh — copy DEV-MODE typing-session recordings off a connected device.
#
# Recordings live in the containing app's data container at
# Documents/sessions/ (App Group container is mirrored there for the app's
# own domain). We pull them into ./sessions/ next to analyze.py.
#
# Requires: Xcode 15+ (`xcrun devicectl`), a device paired & unlocked, and the
# app (is.lyklabord.ios) installed. Simulator note: for the Simulator use
#   xcrun simctl get_app_container booted is.lyklabord.ios data
# then copy Documents/sessions from there — devicectl is device-only.
#
# Usage:
#   ./pull.sh                 # auto-pick the first connected device
#   ./pull.sh <device-udid>   # target a specific device
#
set -euo pipefail

BUNDLE_ID="is.lyklabord.ios"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/sessions"
# Path INSIDE the app data container (appDataContainer domain root is the
# container; sessions live under Documents/).
SRC="Documents/sessions"

mkdir -p "${DEST}"

DEVICE="${1:-}"
if [[ -z "${DEVICE}" ]]; then
  echo "No device UDID passed; discovering connected devices…" >&2
  # `devicectl list devices` prints a table; grab the first identifier column.
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk 'NR>2 && $1 != "" {print $NF; exit}')"
  if [[ -z "${DEVICE}" ]]; then
    echo "ERROR: could not auto-detect a device. Pass a UDID explicitly:" >&2
    echo "  xcrun devicectl list devices" >&2
    echo "  ./pull.sh <device-udid>" >&2
    exit 1
  fi
  echo "Using device: ${DEVICE}" >&2
fi

echo "Pulling ${SRC} from ${BUNDLE_ID} → ${DEST}" >&2
xcrun devicectl device copy from \
  --device "${DEVICE}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source "${SRC}" \
  --destination "${DEST}"

echo "Done. Analyze with:" >&2
echo "  python3 ${SCRIPT_DIR}/analyze.py ${DEST}" >&2
