#!/bin/bash
#
# The regression that is expected to be entirely green.
#
#   scripts/regression.sh [unit|ui|all]      (default: all)
#
# Two suites are skipped, by name, and only these two:
#
#   HitRegionBoundaryUITests
#   TouchTargetUITests
#
# They hold the hit-region instrument, whose control group does not pass. They
# are not skipped because they are inconvenient — they are answered by
# `scripts/touch-calibration.sh`, which runs the calibration first and refuses
# to produce measurements when it fails.
#
# The reason for the split is that a suite with one permanently-red test in it
# stops being read. The next real failure arrives beside the expected one and
# nobody can tell them apart; "oh, that one always fails" is how a regression
# suite dies. Keeping this run green-or-broken keeps it worth looking at.
#
# The skip list is asserted rather than trusted: if it ever grows, this script
# says so and fails, because "we skip a couple of suites" is how a suite that
# fails quietly becomes a suite nobody runs.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SKIPPED=(
  PetNoteAppUITests/HitRegionBoundaryUITests
  PetNoteAppUITests/TouchTargetUITests
)
EXPECTED_SKIPS=2

if [ "${#SKIPPED[@]}" -ne "$EXPECTED_SKIPS" ]; then
  echo "The skip list has $((${#SKIPPED[@]})) entries; $EXPECTED_SKIPS are declared above." >&2
  echo "Adding to it needs a reason in this file, not a quiet edit." >&2
  exit 2
fi

WHAT="${1:-all}"
ARGS=()
case "$WHAT" in
  unit) ARGS+=(-only-testing:PetNoteAppTests) ;;
  ui)   ARGS+=(-only-testing:PetNoteAppUITests) ;;
  all)  ;;
  *) echo "usage: $0 [unit|ui|all]" >&2; exit 2 ;;
esac
for s in "${SKIPPED[@]}"; do ARGS+=("-skip-testing:$s"); done

LOG="build/regression-$(date +%Y%m%d-%H%M%S).log"
mkdir -p build

echo "Running $WHAT, skipping: ${SKIPPED[*]}"
bash scripts/with-build-lock.sh xcodebuild test \
  -project PetNoteApp.xcodeproj -scheme PetNote-Emulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  "${ARGS[@]}" \
  -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm \
  > "$LOG" 2>&1
STATUS=$?

grep -E "Test run with .* tests|Executed [0-9]+ tests" "$LOG" | tail -2 | sed 's/^/  /'
grep -E "✘ Test .*failed|error: -\[PetNoteAppUITests" "$LOG" | head -10 | sed 's/^/  /'

# The same trap as everywhere else in this project: a filter that matches
# nothing exits zero and prints nothing alarming.
RAN=$(grep -cE "◇ Test .* started|Test Case '.*' started" "$LOG" 2>/dev/null || echo 0)
echo "  tests started: $RAN"
if [ "$RAN" -lt 1 ]; then
  echo "  Nothing ran. That is not a pass." >&2
  echo "  log: $LOG" >&2
  exit 2
fi

echo "  log: $LOG"
exit "$STATUS"
