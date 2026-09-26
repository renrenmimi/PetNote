#!/bin/bash
# Screenshot the native client on the connected iPhone.
#
# The launch is not optional and not a convenience: a previous round shot ten
# screenshots, analysed them as PetNote, and they were the owner's Xiaohongshu
# including a personal comment thread. Terminating and relaunching the app
# first is what makes the foreground knowable.
#
#     ./scripts/device-screenshot.sh out.png
#     ./scripts/device-screenshot.sh out.png --no-launch   # keep current state
#
# Screen recording is not available on this machine (missing the Screen
# Recording capability), so anything that needs motion is a burst of these.
set -euo pipefail

BUNDLE_ID="dev.local.petnote.native"
OUT="${1:?usage: device-screenshot.sh <out.png> [--no-launch]}"
LAUNCH="${2:-}"

# Parsed from JSON rather than the table: the table now also lists simulators,
# and macOS awk does not support the {n} interval that matching a UDID by shape
# would need.
UDID=$(xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for d in data.get('result', {}).get('devices', []):
    props = d.get('deviceProperties', {})
    hw = d.get('hardwareProperties', {})
    if hw.get('deviceType') != 'iPhone' or hw.get('reality') != 'physical':
        continue
    if d.get('connectionProperties', {}).get('tunnelState') == 'unavailable':
        continue
    print(hw.get('udid', ''))
    break
")
if [ -z "${UDID}" ]; then
  echo "No connected iPhone. devicectl says:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

LOCK=$(xcrun devicectl device info lockState --device "$UDID" 2>&1 | awk -F': ' '/passcodeRequired/ {print $2}')
if [ "$LOCK" = "true" ]; then
  echo "Device is locked (passcodeRequired: true). Recording that and stopping;" >&2
  echo "unlock it once rather than retrying in a loop." >&2
  exit 2
fi

if [ "$LAUNCH" != "--no-launch" ]; then
  xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" >/dev/null
  # The launch returns before the first frame is on screen.
  sleep 2
fi

xcrun devicectl device capture screenshot --device "$UDID" --destination "$OUT" >/dev/null

# Device screenshots are 16-bit and the pixel reader needs 8. sips refuses the
# conversion on a file that is already 8-bit, which is a success for our
# purposes, so its exit code is not a failure here.
DEPTH=$(sips -g bitsPerSample "$OUT" 2>/dev/null | awk -F': ' '/bitsPerSample/ {print $2}')
if [ "${DEPTH:-16}" != "8" ]; then
  sips -s format png --setProperty bitsPerSample 8 "$OUT" --out "$OUT" >/dev/null 2>&1 || {
    echo "Could not reduce $OUT to 8-bit; sample-pixels.py will say so." >&2
  }
fi

echo "wrote $OUT"
python3 "$(dirname "$0")/sample-pixels.py" "$OUT" | sed 's/^/  /'
