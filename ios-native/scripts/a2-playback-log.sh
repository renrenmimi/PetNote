#!/bin/bash
# What the playback coordinator said on the simulator, in order.
#
# The app's own clock line ("video clock: t=... of=... status=...") and its
# lifecycle lines are the only way to settle a question a screenshot cannot:
# a picture that stopped changing is a clip that finished, a stall, or a dead
# decoder, and those three differ only in the numbers. This is how you read
# the numbers back after a UI test run.
#
#   scripts/a2-playback-log.sh --enable   # ONCE, BEFORE the run (see below)
#   scripts/a2-playback-log.sh            # the last 10 minutes
#   scripts/a2-playback-log.sh 3m         # the last 3
#   scripts/a2-playback-log.sh 10m looped # ...only the lines about looping
#
# **`--enable` first, or none of the lines above this comment exist.**
# Everything the coordinator says about playing, looping and the clock is
# `Logger.info`, and info-level messages live in a memory ring buffer that
# `log show` cannot read back: they are never written to the archive unless
# the subsystem is configured to persist them. Measured — a run that had
# played, looped and advanced produced an archive containing only its
# *errors*, so reading the log after the fact showed a feed that had
# apparently done nothing. That reads exactly like the defect it was meant to
# rule out. `--enable` sets the persistence level on the simulator; it lasts
# until the simulator is erased, and only affects this subsystem.
set -euo pipefail

# The one simulator this project uses. `pn-a2` was the default here and that
# simulator no longer exists, so the script answered "no simulator named
# pn-a2" and the log nobody could read was blamed on the app.
SIM="${SIM:-iPhone 17}"
SINCE="${1:-10m}"
FILTER="${2:-}"

# The UDID by pattern, not by field number.
#
# This read `$2`, which is the second *word* of the line — right for a
# one-word simulator name and wrong for "iPhone 17", where it returns the
# string "17". The script then said "no simulator named iPhone 17" about a
# simulator that was booted, and a run with no log looked like a run with
# nothing to say.
UDID=$(xcrun simctl list devices available \
  | grep -F "$SIM (" \
  | head -1 \
  | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')
if [ -z "$UDID" ]; then
  echo "no simulator named $SIM" >&2
  exit 1
fi

if [ "$SINCE" = "--enable" ]; then
  xcrun simctl spawn "$UDID" log config \
    --subsystem dev.local.petnote.native --mode "level:debug,persist:info"
  echo "persisting info-level media logs on $SIM. Run the tests, then read them back."
  exit 0
fi

# `--info` is not optional: without it `log show` filters info-level lines out
# of what it did archive, on top of them not being archived at all.
OUT=$(xcrun simctl spawn "$UDID" log show \
  --predicate 'subsystem == "dev.local.petnote.native" AND category == "media"' \
  --style compact --info --last "$SINCE" 2>/dev/null || true)

if [ -n "$OUT" ] && ! printf '%s' "$OUT" | grep -q 'video: \|video clock:'; then
  echo "(only error-level lines here. If the run really played something, you forgot" >&2
  echo " scripts/a2-playback-log.sh --enable before it.)" >&2
fi

if [ -n "$FILTER" ]; then
  printf '%s\n' "$OUT" | grep -- "$FILTER" || echo "(no line matching '$FILTER' in the last $SINCE)"
else
  printf '%s\n' "$OUT"
fi
