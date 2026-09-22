#!/bin/bash
#
# The hit-region instrument, run on its own and gated on its own control.
#
#   scripts/touch-calibration.sh
#
# Separated from the regression on purpose. The control group does not pass
# today, and a suite that everyone knows to ignore one failure in is a suite
# nobody reads — the next real failure arrives next to an expected one and is
# indistinguishable from it. `scripts/regression.sh` therefore skips these two
# suites by name, and this script is where they are answered.
#
# The order below is the whole point:
#
#   1. Calibrate against sizes that are known from the layout.
#   2. Only if that passes, measure the controls whose size is not known.
#
# A measurement taken with an instrument that cannot recover a known 44pt is
# not a smaller measurement, it is not a measurement. So step 2 does not run
# when step 1 fails, and the script says why rather than printing intervals
# that would be quoted later.
#
# Exit codes:
#   0  calibration passed and the measurements ran
#   1  measurements ran and something failed
#   2  calibration failed — no measurement was taken and none may be quoted
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# **Arguments are checked before anything starts.** This script previously
# ignored them, so `--help` fell through and launched the build it was being
# asked about — which is how a question about a script becomes a twenty-minute
# xcodebuild queued behind someone else's run. Unknown arguments stop here.
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; echo "" >&2; usage >&2; exit 2 ;;
  esac
done

DEST='platform=iOS Simulator,name=iPhone 17'
DD=build/dd
LOGDIR="build/touch-calibration"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

CONTROL_LOG="$LOGDIR/control-$STAMP.log"
MEASURE_LOG="$LOGDIR/measure-$STAMP.log"

run() {  # run <logfile> <only-testing args...>
  local log="$1"; shift
  local args=()
  for t in "$@"; do args+=("-only-testing:$t"); done
  bash scripts/with-build-lock.sh xcodebuild test \
    -project PetNoteApp.xcodeproj -scheme PetNote-Emulator \
    -destination "$DEST" \
    "${args[@]}" \
    -derivedDataPath "$DD" -clonedSourcePackagesDirPath build/spm \
    > "$log" 2>&1
  return $?
}

echo "1. Calibration — can the instrument recover sizes that are already known?"
run "$CONTROL_LOG" \
  PetNoteAppUITests/HitRegionBoundaryUITests/testTheSearchRecoversAKnownExtent \
  PetNoteAppUITests/HitRegionBoundaryUITests/testTheInstrumentAgreesWithTheKnownGeometryOfTheFeedActionRow \
  PetNoteAppUITests/TouchTargetUITests/testTheProbeCanTellInsideFromOutside
CONTROL_STATUS=$?

# "0 tests ran" must not read as "calibration passed" — the same shape that let
# a filter typo report success elsewhere in this project.
RAN=$(grep -c "Test Case '.*' started" "$CONTROL_LOG" 2>/dev/null || echo 0)
grep -E "^MEASURED (synthetic|like|comments)" "$CONTROL_LOG" | sed 's/^/    /'
echo "   calibration tests executed: $RAN"

if [ "$RAN" -lt 3 ]; then
  echo ""
  echo "   INCONCLUSIVE: expected 3 calibration tests, $RAN ran."
  echo "   No measurement is taken and none may be quoted. Log: $CONTROL_LOG"
  exit 2
fi

if [ "$CONTROL_STATUS" -ne 0 ]; then
  echo ""
  echo "   CALIBRATION FAILED. The instrument does not recover sizes that are"
  echo "   known from the layout, so it is not measuring hit regions."
  echo ""
  echo "   No hit-region figure produced by this instrument may be quoted —"
  echo "   including figures from earlier rounds, which came from it too."
  echo "   Log kept at $CONTROL_LOG"
  exit 2
fi

echo ""
echo "2. Measurement — controls whose hit region is not known in advance."
run "$MEASURE_LOG" \
  PetNoteAppUITests/HitRegionBoundaryUITests \
  PetNoteAppUITests/TouchTargetUITests
MEASURE_STATUS=$?
grep -E "^MEASURED .*(VERDICT|-> (PASS|FAIL|UNCONFIRMED))" "$MEASURE_LOG" | sed 's/^/    /'
echo "   log: $MEASURE_LOG"
exit "$MEASURE_STATUS"
