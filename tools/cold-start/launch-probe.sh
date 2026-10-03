#!/usr/bin/env bash
# Build the headless launch probe (release) and run it in N fresh processes,
# then aggregate + gate against tools/cold-start/launch-budget.json.
#
#   tools/cold-start/launch-probe.sh            # 5 runs, gate
#   tools/cold-start/launch-probe.sh 10         # 10 runs, gate
#   RUNS_OUT=/tmp/x.jsonl tools/cold-start/launch-probe.sh
#
# A macOS regression alarm, not an iOS forecast — see README.md.
set -euo pipefail

RUN_COUNT="${1:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${SCRIPT_DIR}/launch-probe"
SCRATCH="${LAUNCH_PROBE_SCRATCH:-${PACKAGE_DIR}/.build}"
RUNS_OUT="${RUNS_OUT:-$(mktemp /tmp/lyklabord-launch-probe.XXXXXX.jsonl)}"

if ! [[ "${RUN_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: tools/cold-start/launch-probe.sh [positive-run-count]" >&2
  exit 64
fi

echo "building launch-probe (release)…" >&2
swift build -c release --package-path "${PACKAGE_DIR}" --scratch-path "${SCRATCH}" >/dev/null
BINARY="$(swift build -c release --package-path "${PACKAGE_DIR}" --scratch-path "${SCRATCH}" --show-bin-path)/launch-probe"

: > "${RUNS_OUT}"
for ((i = 1; i <= RUN_COUNT; i++)); do
  echo "--- run ${i}/${RUN_COUNT}" >&2
  "${BINARY}" 2>&1 >>"${RUNS_OUT}" | sed 's/^/    /' >&2
done

echo "samples: ${RUNS_OUT}" >&2
python3 "${SCRIPT_DIR}/launch_probe_report.py" --gate "${RUNS_OUT}"
