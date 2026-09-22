#!/bin/bash
# Generates the deterministic test clip and serves it to the simulator.
#
# VideoPlaybackUITests needs media whose colours it knows in advance — that is
# what lets a screenshot tell "the video is on screen" from "the poster is on
# screen" and from "nothing is on screen". The clip is four seconds of flat
# colour (red, green, blue, magenta, one per second) with a white bar that
# moves every frame; the poster is solid yellow, a colour the clip never
# contains.
#
#   ios-native/scripts/a2-test-media.sh [port]
#
# Leave it running while the UI tests run. The tests skip themselves, with
# this command in the message, when nothing answers on the port.
set -euo pipefail
PORT="${1:-8123}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MEDIA="${TMPDIR:-/tmp}/petnote-a2-media"
mkdir -p "$MEDIA"
# Both clips, or neither. `a2-long.mp4` arrived later than `a2-clip.mp4`, and a
# check for only the first one would leave anyone with a warm cache serving a
# 404 for the long clip and reading it as a playback defect.
if [ ! -f "$MEDIA/a2-clip.mp4" ] || [ ! -f "$MEDIA/a2-long.mp4" ]; then
  swift "$HERE/a2-make-test-media.swift" "$MEDIA"
fi
exec python3 "$HERE/a2-media-server.py" "$MEDIA" "$PORT"
