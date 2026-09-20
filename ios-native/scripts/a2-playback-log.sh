#!/bin/bash
# What the playback coordinator said on the simulator, in order.
#
# The app's own clock line ("video clock: t=... of=... status=...") and its
# lifecycle lines are the only way to settle a question a screenshot cannot:
# a picture that stopped changing is a clip that finished, a stall, or a dead
# decoder, and those three differ only in the numbers. This is how you read
# the numbers back after a UI test run.
#
#   scripts/a2-playback-log.sh            # the last 10 minutes
#   scripts/a2-playback-log.sh 3m         # the last 3
#   scripts/a2-playback-log.sh 10m looped # ...only the lines about looping
set -euo pipefail

SIM="${SIM:-pn-a2}"
SINCE="${1:-10m}"
FILTER="${2:-}"

UDID=$(xcrun simctl list devices | awk -v n="$SIM" '$0 ~ n"[ ]*\\(" {gsub(/[()]/,"",$2); print $2; exit}')
if [ -z "$UDID" ]; then
  echo "no simulator named $SIM" >&2
  exit 1
fi

OUT=$(xcrun simctl spawn "$UDID" log show \
  --predicate 'subsystem == "dev.local.petnote.native" AND category == "media"' \
  --style compact --last "$SINCE" 2>/dev/null || true)

if [ -n "$FILTER" ]; then
  printf '%s\n' "$OUT" | grep -- "$FILTER" || echo "(no line matching '$FILTER' in the last $SINCE)"
else
  printf '%s\n' "$OUT"
fi
