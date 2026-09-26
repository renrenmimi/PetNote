#!/bin/bash
#
# The device suites, on a real iPhone, against the test project: the
# PetNote-TestCloud scheme, Debug-TestCloud, talking to petnote-devtest.
#
#   ios-native/scripts/device-acceptance.sh <UDID> [what ...]
#
# what, any number of (default: acceptance):
#   acceptance   DeviceAcceptanceUITests and DeviceAcceptanceMoreUITests
#   perf         DevicePerformanceUITests
#   all          all three
#   a Device* class, or Class/testMethod, in PetNoteAppUITests, e.g.
#                DeviceAcceptanceMoreUITests/test10SavingAPostAndUnsavingItLeavesItUnsaved
#
# Only the Device* suites. The others drive the local emulator, which the
# phone cannot reach, and would fail there for that reason alone.
#
# Refuses (exit 3) anything that is not a connected, unlocked, physical
# iPhone: an id shaped like a simulator's, one devicectl does not list as a
# physical device, a phone that is not connected or is locked. The
# destination is also pinned to platform=iOS, so xcodebuild itself will not
# take a simulator id either.
#
# Builds into build/dd-pkg, the derived data build-testcloud-package.sh signs
# into, so the signed device build is reused and no new build tree is made
# (this Mac's disk is nearly full). -allowProvisioningUpdates as that script
# uses it. Runs under scripts/with-build-lock.sh, with its no-output watchdog
# at BUILD_IDLE_SECONDS (default here 1800).
#
# The log is build/device-acceptance-<stamp>.log. At the end this prints the
# MEASURED lines, XCTest's metric lines ("measured [...] average: ..."), and
# each test's result.
#
# Before running: the phone plugged in, unlocked, Auto-Lock set to Never, and
# Settings -> Developer -> Enable UI Automation on (docs/perf-baseline.md).
#
# Exit: xcodebuild's status; 2 when nothing ran (not a pass); 3 when refused.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PROJECT="PetNoteApp.xcodeproj"
SCHEME="PetNote-TestCloud"
CONFIGURATION="Debug-TestCloud"
DD="build/dd-pkg"          # build-testcloud-package.sh's signed device build
SPM="build/spm"            # shared, already resolved
BUNDLE="PetNoteAppUITests"
TEST_PLIST="Support/GoogleService-Info-Test.plist"

HELP_LAST_LINE="$(awk 'NR>1 && !/^#/ { print NR - 1; exit }' "${BASH_SOURCE[0]}")"
usage() { sed -n "2,${HELP_LAST_LINE}p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
refuse() { echo "REFUSED: $*" >&2; exit 3; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac
UDID="$1"
shift

# ------------------------------------------------------------ destination --
# A simulator's id is a UUID, 8-4-4-4-12. A phone's is 8-16 (iPhone XS and
# later) or 40 hex digits (older). Asked for positively, not only refused.
SIMULATOR_SHAPE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
PHONE_SHAPE='^([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$'
if [[ "$UDID" =~ $SIMULATOR_SHAPE ]]; then
  refuse "$UDID is shaped like a simulator's id. These suites run on a phone only."
fi
if ! [[ "$UDID" =~ $PHONE_SHAPE ]]; then
  refuse "$UDID is not shaped like an iPhone's UDID (8-16 or 40 hex digits)."
fi

# What this Mac knows about it. JSON rather than the table, as
# device-screenshot.sh does: the table also lists simulators.
DEVICE=$(xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1].lower()
try:
    data = json.load(sys.stdin)
except Exception:
    print("unreadable")
    sys.exit(0)
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    if str(hw.get("udid", "")).lower() != want:
        continue
    print("|".join([
        str(hw.get("reality", "?")),
        str(hw.get("deviceType", "?")),
        str(d.get("connectionProperties", {}).get("tunnelState", "?")),
        str(d.get("deviceProperties", {}).get("name", "?")),
    ]))
    break
else:
    print("absent")
' "$UDID")

case "$DEVICE" in
  unreadable|"")
    refuse "could not read 'xcrun devicectl list devices'; cannot tell what $UDID is." ;;
  absent)
    refuse "$UDID is not a device this Mac knows. Plug the phone in, unlock it and trust this Mac." ;;
esac
IFS='|' read -r REALITY DEVICE_TYPE TUNNEL DEVICE_NAME <<<"$DEVICE"
[ "$REALITY" = "physical" ] || refuse "$UDID is '$REALITY', not a physical device."
[ "$DEVICE_TYPE" = "iPhone" ] || refuse "$UDID is a '$DEVICE_TYPE', not an iPhone."
[ "$TUNNEL" = "unavailable" ] && refuse "$DEVICE_NAME ($UDID) is not connected (tunnel unavailable)."

# A locked phone fails every test at its first tap, which reads as twenty
# defects. Said once instead.
LOCKED=$(xcrun devicectl device info lockState --device "$UDID" 2>&1 | awk -F': ' '/passcodeRequired/ {print $2}')
[ "$LOCKED" = "true" ] && refuse "$DEVICE_NAME is locked. Unlock it (and set Auto-Lock to Never) first."

# Without it the build succeeds and the app stops at launch with "Missing
# GoogleService-Info-Test.plist" (Core/Auth/FirebaseBootstrap.swift), by design.
[ -f "$TEST_PLIST" ] || refuse "$TEST_PLIST is not here; the app would stop at launch."

# ------------------------------------------------------------------ tests --
ONLY=()
add() { ONLY+=("-only-testing:$BUNDLE/$1"); }
[ $# -eq 0 ] && set -- acceptance
for what in "$@"; do
  case "$what" in
    acceptance) add DeviceAcceptanceUITests; add DeviceAcceptanceMoreUITests ;;
    perf)       add DevicePerformanceUITests ;;
    all)        add DeviceAcceptanceUITests; add DeviceAcceptanceMoreUITests; add DevicePerformanceUITests ;;
    "$BUNDLE"/Device*) ONLY+=("-only-testing:$what") ;;
    Device*)    add "$what" ;;
    *) echo "not a device suite: $what (see --help)" >&2; exit 2 ;;
  esac
done

mkdir -p build
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="build/device-acceptance-$STAMP.log"

echo "Device:  $DEVICE_NAME ($UDID)"
echo "Build:   $SCHEME / $CONFIGURATION, derived data $DD"
echo "Tests:   ${ONLY[*]//-only-testing:/}"
echo "Log:     $LOG"

BUILD_IDLE_LOG="$LOG" BUILD_IDLE_SECONDS="${BUILD_IDLE_SECONDS:-1800}" \
  bash scripts/with-build-lock.sh xcodebuild test \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=$UDID" \
    -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" \
    -allowProvisioningUpdates \
    "${ONLY[@]}" \
    > "$LOG" 2>&1
STATUS=$?

# ---------------------------------------------------------------- summary --
echo ""
echo "== MEASURED =="
grep -a "MEASURED" "$LOG" | sed 's/^/  /'

echo ""
echo "== XCTest metrics =="
# One line per metric per test, reduced to name, metric, average, spread and
# the values. A line in a format this does not know is printed whole.
METRICS=$(grep -a "measured \[" "$LOG" | sed -E \
  "s/^.*-\[[A-Za-z0-9_.]+ ([A-Za-z0-9_]+)\]' measured \[([^]]+)\] average: ([^,]+), relative standard deviation: ([^,]+), values: (\[[^]]*\]).*$/\1  [\2]  average \3  (rsd \4)  values \5/")
if [ -n "$METRICS" ]; then
  printf '%s\n' "$METRICS" | sed 's/^/  /'
else
  echo "  none in the log"
fi

echo ""
echo "== Results =="
grep -aE "^Test Case '.*' (passed|failed|skipped)" "$LOG" \
  | sed -E "s/^Test Case '-\[[A-Za-z0-9_.]+ ([A-Za-z0-9_]+)\]' (passed|failed|skipped).*$/  \2  \1/"
grep -a "Test skipped" "$LOG" | sed -E 's/^.*\] : //; s/^/  skipped: /' | head -10
grep -aE "error: -\[$BUNDLE" "$LOG" | sed -E 's/^.*\] : //; s/^/  failure: /' | head -20
grep -aE "Executed [0-9]+ tests?" "$LOG" | tail -1 | sed 's/^/  /'

RESULT_BUNDLE=$(ls -td "$DD"/Logs/Test/*.xcresult 2>/dev/null | head -1)
[ -n "$RESULT_BUNDLE" ] && echo "  result bundle: $RESULT_BUNDLE"
echo "  log: $LOG"

# Sharing build-testcloud-package.sh's derived data has one cost, said rather
# than cleaned up: a test build hosts the unit tests inside the app, and a
# later plain build does not take them out. That script scans this .app for
# test switches, and would be reading the tests' strings as the package's.
HOSTED="$DD/Build/Products/$CONFIGURATION-iphoneos/PetNote.app/PlugIns/PetNoteAppTests.xctest"
if [ -d "$HOSTED" ]; then
  echo ""
  echo "  NOTE: $HOSTED is now inside the package build."
  echo "        Before build-testcloud-package.sh audits $DD, or before installing"
  echo "        that .app by hand, rebuild it without the tests in it."
fi

# A filter that matched nothing exits zero and prints nothing alarming; so
# does a build that failed before any test started.
RAN=$(grep -acE "Test Case '.*' started" "$LOG")
RAN=${RAN:-0}
echo "  tests started: $RAN"
if [ "$RAN" -lt 1 ]; then
  echo "  Nothing ran. That is not a pass. The end of the log:" >&2
  tail -15 "$LOG" | sed 's/^/    /' >&2
  exit 2
fi
exit "$STATUS"
