#!/bin/bash
#
# perf-measure.sh — the device performance harness for the Swift prototype.
#
# It does four things and refuses to do a fifth:
#
#   preflight   check every precondition and print what is missing
#   coldstart   N cold launches, one number each
#   scroll      one Animation Hitches trace over the whole 200-post feed
#   memory      footprint samples, peak per run
#
# The fifth thing it will not do is produce a number on a simulator. Stage 7 of
# the acceptance matrix is "真机性能对照", and its layers table says L4 does not
# stand in for L5. A simulator runs the app on a desktop CPU with a desktop GPU,
# no thermal ceiling, and a filesystem that is not NAND; its cold-start number
# is not a slow version of the device's, it is a different quantity. So:
#
#   * `preflight --simulator` is supported, and is how the instrumentation
#     points get checked before a device is available.
#   * every measuring subcommand requires a real device and exits otherwise.
#
# Usage:
#   Tools/perf-measure.sh preflight [--simulator NAME | --device UDID]
#   Tools/perf-measure.sh coldstart --device UDID [--samples N]
#   Tools/perf-measure.sh scroll    --device UDID
#   Tools/perf-measure.sh memory    --device UDID [--samples N]

set -uo pipefail

BUNDLE_ID="dev.local.petnote.native"
SUBSYSTEM="dev.local.petnote.native"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${PERF_OUT:-$ROOT/build/perf}"
SAMPLES=20          # see docs/perf-plan.md for why 20 and not 10
MODE=""
DEVICE=""
SIMULATOR=""

mkdir -p "$OUT"

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "  $*"; }
head2() { echo; echo "== $* =="; }

MODE="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --device)    DEVICE="$2"; shift 2 ;;
    --simulator) SIMULATOR="$2"; shift 2 ;;
    --samples)   SAMPLES="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- build facts
#
# Every number is worthless without these three, so they are captured with the
# number and not written down afterwards from memory.
build_facts() {
  local commit dirty
  commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  dirty="$(git -C "$ROOT" status --porcelain -- "$ROOT" | wc -l | tr -d ' ')"
  echo "commit=$commit dirty_files=$dirty configuration=${CONFIGURATION:-Release} date=$(date -u +%FT%TZ)"
}

# ------------------------------------------------------------------ preflight

preflight() {
  local failures=0

  head2 "Build facts"
  note "$(build_facts)"

  head2 "1. Instrumentation is present in the app target"
  # The whole harness reads one log prefix. If the marks are not compiled in,
  # every measuring subcommand would sit there and collect nothing, then report
  # a clean empty result — which reads exactly like "fast".
  if grep -rqn "PERF cold_start_ms" "$ROOT/App" "$ROOT/Core" "$ROOT/Features" "$ROOT/Support" 2>/dev/null; then
    note "OK: cold-start mark found in the app sources"
  else
    note "MISSING: no 'PERF cold_start_ms' emitter in App/ Core/ Features/ Support/"
    note "         Tools/PerfSignposts.swift is not wired in yet. Until it is,"
    note "         COLD START IS NOT MEASURABLE and no number may be reported."
    failures=$((failures + 1))
  fi
  if grep -rqn "PERF media_ms" "$ROOT/Core" 2>/dev/null; then
    note "OK: media mark found"
  else
    note "MISSING: no 'PERF media_ms' emitter in Core/ — media latency not measurable"
    failures=$((failures + 1))
  fi
  if grep -rqn "PERF footprint_kb" "$ROOT/App" "$ROOT/Core" "$ROOT/Features" "$ROOT/Support" 2>/dev/null; then
    note "OK: footprint mark found"
  else
    note "MISSING: no 'PERF footprint_kb' emitter — memory peak not measurable in-process"
    note "         (xctrace Allocations is the fallback; it measures a different"
    note "          quantity — see docs/perf-plan.md §memory)"
    failures=$((failures + 1))
  fi

  head2 "2. Tooling"
  for tool in xcrun xctrace; do
    if xcrun --find "$tool" >/dev/null 2>&1 || command -v "$tool" >/dev/null 2>&1; then
      note "OK: $tool"
    else
      note "MISSING: $tool"; failures=$((failures + 1))
    fi
  done
  # Captured into a variable first, not piped straight into `grep -q`.
  # With `set -o pipefail`, `grep -q` closing the pipe on its first match kills
  # xctrace with SIGPIPE and the pipeline exits non-zero — so the check reported
  # "MISSING" for a template that was sitting right there in the list. A
  # preflight that produces false alarms gets ignored, which is worse than not
  # having one.
  local templates
  templates="$(xcrun xctrace list templates 2>/dev/null || true)"
  for template in "Animation Hitches" "App Launch" "Allocations"; do
    if printf '%s' "$templates" | grep -i -- "$template" >/dev/null; then
      note "OK: '$template' template available"
    else
      note "MISSING: '$template' template"
      failures=$((failures + 1))
    fi
  done

  head2 "3. Target"
  if [ -n "$DEVICE" ]; then
    if xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE"; then
      note "OK: device $DEVICE is listed"
      xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | sed 's/^/    /'
    else
      note "MISSING: device $DEVICE is not connected"; failures=$((failures + 1))
    fi
  elif [ -n "$SIMULATOR" ]; then
    note "SIMULATOR MODE: checking the harness, not performance."
    note "Numbers from a simulator are not device numbers and must never be"
    note "reported against stage 7. This mode exists to prove the start/end"
    note "marks fire and the parser reads them."
    if xcrun simctl list devices | grep -q "$SIMULATOR"; then
      note "OK: simulator $SIMULATOR exists"
    else
      note "MISSING: simulator $SIMULATOR"; failures=$((failures + 1))
    fi
  else
    note "No target given. Pass --device UDID or --simulator NAME."
    failures=$((failures + 1))
  fi

  head2 "4. Dataset"
  # The number depends on the data as much as on the code. 210 posts and 5
  # videos is the documented set; a run against 14 posts is a different
  # experiment wearing the same name.
  # Paged. The emulator's REST list caps a page well below the requested
  # pageSize — asking for 1000 returned 150 of the 210 that are really there,
  # and a preflight that under-counts the dataset would have had someone
  # reseeding a database three other agents are using.
  local posts
  posts="$(python3 "$HERE/count-posts.py" 2>/dev/null || echo 0)"
  if [ "${posts:-0}" -ge 200 ]; then
    note "OK: firestore emulator has $posts posts (expected >= 200)"
  else
    note "MISMATCH: emulator has ${posts:-0} posts, the documented set is 210."
    note "          Do NOT reseed — three other agents depend on this data."
    failures=$((failures + 1))
  fi

  head2 "5. Build configuration"
  note "Stage 7 requires BOTH builds to be Release. Debug Swift is not slow-"
  note "Release, it is a different binary: no specialisation, no inlining,"
  note "bounds checks live, and SwiftUI diffing an order of magnitude cheaper"
  note "to get wrong. A Debug number cannot be scaled into a Release one."
  if [ "${CONFIGURATION:-Release}" = "Release" ]; then
    note "OK: CONFIGURATION=Release"
  else
    note "WRONG: CONFIGURATION=${CONFIGURATION}"; failures=$((failures + 1))
  fi

  head2 "Result"
  if [ "$failures" -eq 0 ]; then
    echo "  preflight PASSED — measurement may proceed"
  else
    echo "  preflight FAILED with $failures blocking item(s)"
    echo "  Report these as [待验证] with the missing condition named."
    echo "  Do not substitute a number from somewhere else."
  fi
  return "$failures"
}

require_device() {
  [ -n "$DEVICE" ] || die "this subcommand needs --device UDID. \
Simulator numbers are not device numbers; see the header of this script."
  xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE" \
    || die "device $DEVICE is not connected"
}

# ------------------------------------------------------------------ coldstart
#
# Start point: process exec, read from kinfo_proc inside the app.
# End point:   the CATransaction completion for the first frame that contains
#              feed rows.
# Neither end is chosen for convenience; see docs/perf-plan.md.

coldstart() {
  require_device
  local log="$OUT/coldstart-$(date +%Y%m%d-%H%M%S).txt"
  echo "$(build_facts)" > "$log"
  echo "metric=cold_start start=process_exec end=first_presented_frame_with_posts" >> "$log"
  echo "samples_requested=$SAMPLES" >> "$log"

  for i in $(seq 1 "$SAMPLES"); do
    # Terminate first, and give the system a moment: a relaunch inside a few
    # hundred milliseconds of a kill is a warm launch wearing a cold launch's
    # name, because the pages are still in the page cache.
    xcrun devicectl device process terminate --device "$DEVICE" \
      --bundle-identifier "$BUNDLE_ID" >/dev/null 2>&1
    sleep 3

    xcrun devicectl device process launch --device "$DEVICE" \
      --start-stopped=false "$BUNDLE_ID" -- -petnote-perf >/dev/null 2>&1
    sleep 12   # generous: the number comes from the log, not from this sleep

    xcrun devicectl device info processes --device "$DEVICE" >/dev/null 2>&1
    # The app writes the number; this only collects it.
    local line
    line="$(xcrun devicectl device console --device "$DEVICE" --quiet 2>/dev/null \
              | grep -m1 "PERF cold_start_ms" || true)"
    if [ -z "$line" ]; then
      echo "sample=$i result=NO_MARK" | tee -a "$log"
    else
      echo "sample=$i $line" | tee -a "$log"
    fi
  done

  echo
  echo "raw: $log"
  "$HERE/perf-report.py" cold_start_ms "$log"
}

# --------------------------------------------------------------------- scroll
#
# Frame drops are measured with Instruments and nothing else. The acceptance
# matrix is explicit: "滚动与动画必须用逐帧或 Instruments，不得用截图代替".

scroll() {
  require_device
  local trace="$OUT/scroll-$(date +%Y%m%d-%H%M%S).trace"
  echo "$(build_facts)"
  echo "metric=scroll_hitches start=first_scroll_event end=list_reaches_last_post"
  echo "Recording. Scroll the full feed, top to bottom, five times, at a"
  echo "steady pace. Do not fling — a flung list skips rows and reports a"
  echo "hitch rate for rows that were never composited."
  xcrun xctrace record --template "Animation Hitches" \
    --device "$DEVICE" --attach "$BUNDLE_ID" --output "$trace" --time-limit 120s
  echo "trace: $trace"
  echo "Open in Instruments; report hitch time ratio and the single worst frame."
}

# --------------------------------------------------------------------- memory

memory() {
  require_device
  local log="$OUT/memory-$(date +%Y%m%d-%H%M%S).txt"
  echo "$(build_facts)" > "$log"
  echo "metric=peak_footprint start=app_launch end=after_three_full_scroll_passes" >> "$log"
  xcrun devicectl device console --device "$DEVICE" --quiet 2>/dev/null \
    | grep --line-buffered "PERF footprint_kb" | tee -a "$log" &
  local pid=$!
  echo "Sampling. Scroll the feed end to end three times, then press Enter."
  read -r _
  kill "$pid" 2>/dev/null
  "$HERE/perf-report.py" footprint_kb "$log"
}

case "$MODE" in
  preflight) preflight ;;
  coldstart) coldstart ;;
  scroll)    scroll ;;
  memory)    memory ;;
  *) sed -n '1,30p' "$0"; exit 1 ;;
esac
