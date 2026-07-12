#!/usr/bin/env bash
#
# One command → one picture. Starts all three IO models at once (blocking,
# threaded, nonblocking), feeds them ONE dashboard with a panel per model on a
# shared time axis, opens it in a browser, and drives identical load into all
# three so you can compare them side by side.
#
# Usage:
#   ./demo.sh [work-ms]     simulated per-request server work (default 120)
#
# What to look for on the dashboard (three rounds of load):
#   round 1 (fast + work) : threaded = vertical column (concurrent); blocking and
#                           nonblocking both staircase and finish at the same
#                           time — sync work stalls the single thread either way.
#   round 2 (slow clients): nonblocking interleaves reads; blocking serializes.
#   round 3 (head-of-line): blocking's fast clients jump ~2.5s right (stuck behind
#                           one slow read); nonblocking/threaded serve them at once.
#                           This is where blocking vs nonblocking finally differ.
set -euo pipefail
cd "$(dirname "$0")"

WORK_MS="${1:-120}"
MON=8081

echo "building…"
swift build >/dev/null
pkill -f 'iolab lab' 2>/dev/null || true
sleep 0.2

.build/debug/iolab lab --monitor "$MON" --work-ms "$WORK_MS" &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

echo
echo "  dashboard : http://127.0.0.1:$MON"
command -v open >/dev/null 2>&1 && open "http://127.0.0.1:$MON" || true
echo "  driving identical load into all three models — watch the three panels."
echo "  Ctrl-C to stop."
wait "$SRV"
