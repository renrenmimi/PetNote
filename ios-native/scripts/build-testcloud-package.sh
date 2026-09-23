#!/bin/bash
#
# Build, sign and audit the PetNote-TestCloud device package.
#
#   ios-native/scripts/build-testcloud-package.sh [options]
#
# Reports FOUR statuses separately, because collapsing them into one
# "success/failure" is how a package that compiles, signs, and then refuses to
# launch gets called "built fine":
#
#   1 BUILD    compiles for a real device            (this script)
#   2 SIGN     signed with a profile that has the phone in it (this script)
#   3 INSTALL  reaches the phone                     (needs the phone; TODO)
#   4 LAUNCH   runs and passes EnvironmentGuard      (needs the phone; TODO)
#
# Steps 3 and 4 are printed as the exact commands to run, and stay TODO. This
# script never claims them.
#
# Options:
#   --control-app PATH   reuse an existing Debug-Emulator *device* .app as the
#                        scan's positive control instead of building one
#   --skip-control       skip the control (the switch scan is then reported
#                        UNVERIFIED, never "clean", and the script exits 2)
#   --release-check      also build Release for a device and scan it; that is
#                        the package that must contain no switches at all
#   --keep-going         do not stop the remaining steps after a failure
#   -h | --help
#
# Exit codes:
#   0  every check reached a verdict and none failed
#   1  at least one check FAILED
#   2  nothing failed, but at least one check could not reach a verdict
#      ("inconclusive" is not "clean" - see the note at the bottom)
#
# Nothing here touches the cloud, runs firebase, or writes to any project.

set -uo pipefail

# ---------------------------------------------------------------- constants --
# What this package must be talking to. Named, not inferred: the whole point of
# the audit is to compare against a value that was decided in advance.
EXPECTED_PROJECT_ID="petnote-devtest"          # the cloud test project
EMULATOR_PROJECT_ID="petnote-test"             # local emulator - must NOT appear
PRODUCTION_PROJECT_ID="petnote-a9dac"          # production - must NOT appear
EXPECTED_BACKEND="testcloud"
EXPECTED_BUNDLE_ID="dev.local.petnote.native"  # differs from Capacitor's dev.local.petnote
EXPECTED_TEAM="FS3VY99GNA"
EXPECTED_DEVICE_UDID="00008150-0004492C3C87801C"   # the owner's iPhone

CONFIGURATION="Debug-TestCloud"
SCHEME="PetNote-TestCloud"
CONTROL_CONFIGURATION="Debug-Emulator"
CONTROL_SCHEME="PetNote-Emulator"
RELEASE_CONFIGURATION="Release"
RELEASE_SCHEME="PetNote-Release"

# This script's own derived data. Do not point it at another agent's.
DD="build/dd-pkg"
DD_UNSIGNED="build/dd-pkg-unsigned"
DD_CONTROL="build/dd-pkg-control"
DD_RELEASE="build/dd-pkg-release"
SPM="build/spm"           # shared, already resolved, read-only by convention

# The scan. `-a` because a .app is mostly binaries; `-r` because the Swift code
# is NOT in the main executable of a Debug build - see scan_bundle().
#
# The trailing class is [A-Za-z-]+ and not -[a-z-]+ on purpose: three switches
# carry no `-petnote-` prefix because they are UserDefaults keys rather than
# launch arguments - petnoteImageDelayMilliseconds, petnoteVideoURLOverride,
# petnoteVideoPosterOverride. Grepping the prefix walks straight past them.
SCAN_RE='petnote[A-Za-z-]+'

# Not every hit is a switch. These three are Firebase project ids, and counting
# them as "test switches" inflates the number and hides the one that matters.
# `petnote-a` is what the regex leaves of petnote-a9dac (the digit ends the
# match) - it is EnvironmentGuard.productionProjectID, compiled in so that
# production can be recognised and refused.
PROJECT_ID_TOKENS='^(petnote-a|petnote-test|petnote-devtest)$'

# ------------------------------------------------------------------ plumbing --
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
PROJECT="PetNoteApp.xcodeproj"
TEST_PLIST="Support/GoogleService-Info-Test.plist"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$ROOT/build/dd-pkg-logs"
mkdir -p "$LOGDIR"
REPORT="$LOGDIR/audit-$STAMP.txt"

# The help text is this file's own header. Finding where that header ends by
# reading the file beats hard-coding a line number: the last time a few lines
# were added to it, `--help` silently started cutting the last section off.
HELP_LAST_LINE="$(awk 'NR>1 && !/^#/ { print NR - 1; exit }' "${BASH_SOURCE[0]}")"

CONTROL_APP=""
SKIP_CONTROL=0
RELEASE_CHECK=0
KEEP_GOING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --control-app) CONTROL_APP="${2:-}"; shift 2 ;;
    --skip-control) SKIP_CONTROL=1; shift ;;
    --release-check) RELEASE_CHECK=1; shift ;;
    --keep-going) KEEP_GOING=1; shift ;;
    -h|--help) sed -n "2,${HELP_LAST_LINE}p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
rule() { say "------------------------------------------------------------------"; }
head1() { say ""; rule; say "$*"; rule; }

# Every check records a line here. Nothing is summarised as a single verdict.
FINDINGS=()
record() {  # record <PASS|FAIL|WARN|BLOCKED|FACT> <what> <evidence>
  FINDINGS+=("$1|$2|$3")
  say "  [$1] $2"
  [ -n "${3:-}" ] && say "        evidence: $3"
  return 0
}

STATUS_BUILD="not run"
STATUS_SIGN="not run"
STATUS_INSTALL="TODO - needs the phone attached"
STATUS_LAUNCH="TODO - needs the phone attached"

# --------------------------------------------------------------- the scanner --
# Scans a WHOLE .app bundle, not the main executable.
#
# This is the trap the audit exists to avoid. A Debug configuration builds with
# ENABLE_DEBUG_DYLIB=YES, which puts every line of Swift in
# `PetNote.debug.dylib` and leaves the main `PetNote` binary as a stub. Running
# `strings PetNote | grep petnote-` on such a package returns almost nothing
# and looks exactly like a clean result. Measured on this project: main binary
# 2 hits, whole bundle 12.
scan_bundle() {  # scan_bundle <app path>  -> prints "file:token" lines
  LC_ALL=C grep -raoE "$SCAN_RE" "$1" 2>/dev/null | sed "s|^$1/||" | sort -u
}
scan_tokens() { scan_bundle "$1" | sed 's/^.*://' | sort -u; }

# xcodebuild refuses -derivedDataPath without -scheme, so the scheme is
# explicit on every call rather than implied by the configuration.
xcb() {  # xcb <derivedDataPath> <scheme> <configuration> <logfile> [extra args...]
  local dd="$1" sch="$2" conf="$3" log="$4"; shift 4
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$sch" \
    -configuration "$conf" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$dd" \
    -clonedSourcePackagesDirPath "$SPM" \
    "$@" >"$log" 2>&1
}

app_in() {  # app_in <derivedDataPath> <configuration>
  echo "$1/Build/Products/$2-iphoneos/PetNote.app"
}

say "PetNote-TestCloud device package - build + audit"
say "run $STAMP   repo $ROOT"
say "report $REPORT"

# =============================================================== 0. PREFLIGHT ==
head1 "0. PREFLIGHT (checks, not crashes)"

PREFLIGHT_BLOCKING=0

if [ ! -d "$PROJECT" ]; then
  record FAIL "Xcode project not found" "$ROOT/$PROJECT"
  exit 1
fi

if [ -f Config/Local.xcconfig ]; then
  team_line="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM' Config/Local.xcconfig | head -1 | tr -d ' ')"
  record FACT "Config/Local.xcconfig present" "$team_line"
else
  record FAIL "Config/Local.xcconfig missing - signing has no team" "expected $ROOT/Config/Local.xcconfig"
  PREFLIGHT_BLOCKING=1
fi

# The one the owner is still fetching. Its absence must be a named state, not a
# stack trace: the build succeeds without it and the app fatalErrors at launch
# ("Missing GoogleService-Info-Test.plist"), which is the correct behaviour and
# a terrible thing to discover while holding the phone.
if [ -f "$TEST_PLIST" ]; then
  src_pid="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$TEST_PLIST" 2>/dev/null)"
  record FACT "$TEST_PLIST present" "PROJECT_ID=$src_pid"
else
  record BLOCKED "$TEST_PLIST NOT PRESENT" \
    "without it the package cannot reach $EXPECTED_PROJECT_ID; the app will fatalError at launch, by design (Core/Auth/FirebaseBootstrap.swift)"
fi

# PETNOTE_EXPECTED_PROJECT is what EnvironmentGuard pins against. It comes from
# PETNOTE_TEST_PROJECT_ID in the gitignored Config/Local.xcconfig. Empty means
# the pin is simply off: AppEnvironment.allowsWrites returns false for
# testCloud and EnvironmentGuard.verdict falls through to .unchecked.
SETTINGS="$LOGDIR/settings-$STAMP.txt"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -sdk iphoneos -showBuildSettings >"$SETTINGS" 2>/dev/null
setting() { grep -E "^[[:space:]]*$1 = " "$SETTINGS" | head -1 | sed 's/^[^=]*= *//'; }

bs_backend="$(setting PETNOTE_BACKEND)"
bs_expected="$(setting PETNOTE_EXPECTED_PROJECT)"
bs_bundle="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
bs_team="$(setting DEVELOPMENT_TEAM)"
bs_conditions="$(setting SWIFT_ACTIVE_COMPILATION_CONDITIONS)"

if [ "$bs_backend" = "$EXPECTED_BACKEND" ]; then
  record PASS "build setting PETNOTE_BACKEND = $EXPECTED_BACKEND" "$SETTINGS"
else
  record FAIL "build setting PETNOTE_BACKEND is '$bs_backend', expected '$EXPECTED_BACKEND'" "$SETTINGS"
  PREFLIGHT_BLOCKING=1
fi

if [ -z "$bs_expected" ]; then
  record WARN "PETNOTE_EXPECTED_PROJECT is EMPTY - EnvironmentGuard will not pin the project id" \
    "Config/Debug-TestCloud.xcconfig sets it to \$(PETNOTE_TEST_PROJECT_ID), which Config/Local.xcconfig does not define"
elif [ "$bs_expected" = "$EXPECTED_PROJECT_ID" ]; then
  record PASS "PETNOTE_EXPECTED_PROJECT = $bs_expected" "$SETTINGS"
else
  record FAIL "PETNOTE_EXPECTED_PROJECT = '$bs_expected', expected '$EXPECTED_PROJECT_ID'" "$SETTINGS"
fi

[ "$bs_team" = "$EXPECTED_TEAM" ] \
  && record PASS "DEVELOPMENT_TEAM = $bs_team" "$SETTINGS" \
  || record FAIL "DEVELOPMENT_TEAM = '$bs_team', expected '$EXPECTED_TEAM'" "$SETTINGS"
record FACT "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $bs_conditions" \
  "DEBUG is present on purpose: device acceptance needs -petnote-start-signed-out and friends"
[ "$bs_bundle" = "$EXPECTED_BUNDLE_ID" ] \
  && record PASS "PRODUCT_BUNDLE_IDENTIFIER = $bs_bundle (coexists with Capacitor's dev.local.petnote)" "$SETTINGS" \
  || record FAIL "PRODUCT_BUNDLE_IDENTIFIER = '$bs_bundle', expected '$EXPECTED_BUNDLE_ID'" "$SETTINGS"

if [ "$PREFLIGHT_BLOCKING" = 1 ] && [ "$KEEP_GOING" = 0 ]; then
  head1 "STOPPED IN PREFLIGHT"
  say "  1 BUILD   : $STATUS_BUILD"
  say "  2 SIGN    : $STATUS_SIGN"
  say "  3 INSTALL : $STATUS_INSTALL"
  say "  4 LAUNCH  : $STATUS_LAUNCH"
  exit 1
fi

# ============================================================ 1. BUILD status ==
# Unsigned first, deliberately. It answers "does this configuration compile for
# a real device" without letting a certificate or a profile problem be reported
# as a build failure. Signing gets its own status below.
head1 "1. BUILD  (unsigned, generic/platform=iOS)"

BUILD_LOG="$LOGDIR/build-unsigned-$STAMP.log"
say "  xcodebuild ... -configuration $CONFIGURATION -derivedDataPath $DD_UNSIGNED CODE_SIGNING_ALLOWED=NO"
if xcb "$DD_UNSIGNED" "$SCHEME" "$CONFIGURATION" "$BUILD_LOG" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""; then
  UNSIGNED_APP="$(app_in "$DD_UNSIGNED" "$CONFIGURATION")"
  if [ -d "$UNSIGNED_APP" ]; then
    STATUS_BUILD="PASS"
    record PASS "compiles for a device, unsigned" "$UNSIGNED_APP ($(du -sh "$UNSIGNED_APP" | cut -f1)), log $BUILD_LOG"
  else
    STATUS_BUILD="FAIL (no product)"
    record FAIL "xcodebuild reported success but produced no .app" "$BUILD_LOG"
  fi
else
  STATUS_BUILD="FAIL"
  record FAIL "unsigned device build failed" "tail: $(grep -E 'error:' "$BUILD_LOG" | head -3 | tr '\n' ' ') (full log $BUILD_LOG)"
fi

if [ "$STATUS_BUILD" != "PASS" ] && [ "$KEEP_GOING" = 0 ]; then
  head1 "STOPPED AFTER BUILD"
  say "  1 BUILD   : $STATUS_BUILD"
  say "  2 SIGN    : $STATUS_SIGN"
  say "  3 INSTALL : $STATUS_INSTALL"
  say "  4 LAUNCH  : $STATUS_LAUNCH"
  exit 1
fi

# ============================================================= 2. SIGN status ==
head1 "2. SIGN  (automatic, team $EXPECTED_TEAM)"

SIGN_LOG="$LOGDIR/build-signed-$STAMP.log"
APP="$(app_in "$DD" "$CONFIGURATION")"
say "  xcodebuild ... -configuration $CONFIGURATION -derivedDataPath $DD  -allowProvisioningUpdates"
if xcb "$DD" "$SCHEME" "$CONFIGURATION" "$SIGN_LOG" -allowProvisioningUpdates && [ -d "$APP" ]; then
  if codesign --verify --strict "$APP" >>"$SIGN_LOG" 2>&1; then
    STATUS_SIGN="PASS"
    record PASS "signed and codesign --verify --strict passes" "$APP"
  else
    STATUS_SIGN="FAIL (verify)"
    record FAIL "built but codesign --verify --strict failed" "$SIGN_LOG"
  fi
else
  STATUS_SIGN="FAIL"
  record FAIL "signed device build failed" "$(grep -E 'error:' "$SIGN_LOG" | head -3 | tr '\n' ' ') (full log $SIGN_LOG)"
fi

# ================================================================== 3. AUDIT ==
head1 "3. AUDIT of $APP"

if [ ! -d "$APP" ]; then
  record BLOCKED "no package to audit" "expected $APP"
else

# --- 3a. which project does it actually reach -------------------------------
say ""
say "3a. Backend identity - which Firebase project this package can reach"
BUNDLED_TEST_PLIST="$APP/GoogleService-Info-Test.plist"
if [ -f "$BUNDLED_TEST_PLIST" ]; then
  pid="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$BUNDLED_TEST_PLIST" 2>/dev/null)"
  bkt="$(/usr/libexec/PlistBuddy -c 'Print :STORAGE_BUCKET' "$BUNDLED_TEST_PLIST" 2>/dev/null)"
  bid="$(/usr/libexec/PlistBuddy -c 'Print :BUNDLE_ID' "$BUNDLED_TEST_PLIST" 2>/dev/null)"
  case "$pid" in
    "$EXPECTED_PROJECT_ID")
      record PASS "bundled GoogleService-Info-Test.plist PROJECT_ID = $pid" "$BUNDLED_TEST_PLIST (bucket $bkt, bundle $bid)" ;;
    "$PRODUCTION_PROJECT_ID")
      record FAIL "PACKAGE POINTS AT PRODUCTION ($pid)" "$BUNDLED_TEST_PLIST" ;;
    "$EMULATOR_PROJECT_ID")
      record FAIL "PROJECT_ID is the local emulator's ($pid), not the cloud test project" "$BUNDLED_TEST_PLIST" ;;
    *)
      record FAIL "PROJECT_ID = '$pid', expected '$EXPECTED_PROJECT_ID'" "$BUNDLED_TEST_PLIST" ;;
  esac
else
  record BLOCKED "GoogleService-Info-Test.plist is not in the package" \
    "FirebaseBootstrap looks for exactly this name for backend=testcloud; without it the app fatalErrors at launch rather than falling back"
fi

# The emulator's plist is copied into every configuration's bundle (Support/ is
# a synchronised group). Release excludes it explicitly; Debug-TestCloud does
# not. Not a silent-fallback risk - FirebaseBootstrap selects by exact name -
# but it is the wrong backend's configuration riding along in the package.
if [ -f "$APP/GoogleService-Info-Emulator.plist" ]; then
  epid="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$APP/GoogleService-Info-Emulator.plist" 2>/dev/null)"
  record WARN "package also carries GoogleService-Info-Emulator.plist (PROJECT_ID=$epid)" \
    "Config/Release.xcconfig excludes it via EXCLUDED_SOURCE_FILE_NAMES; Config/Debug-TestCloud.xcconfig does not"
fi
if [ -f "$APP/GoogleService-Info.plist" ]; then
  ppid="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$APP/GoogleService-Info.plist" 2>/dev/null)"
  record FAIL "package carries a production GoogleService-Info.plist (PROJECT_ID=$ppid)" "$APP/GoogleService-Info.plist"
fi

# --- 3b. Info.plist ----------------------------------------------------------
say ""
say "3b. Info.plist of the built package (not the build settings - the product)"
INFO="$APP/Info.plist"
ip() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null; }
b="$(ip PetNoteBackend)"; e="$(ip PetNoteExpectedProject)"; s="$(ip PetNoteBuildStamp)"; cbi="$(ip CFBundleIdentifier)"

[ "$b" = "$EXPECTED_BACKEND" ] \
  && record PASS "PetNoteBackend = $b" "$INFO" \
  || record FAIL "PetNoteBackend = '$b', expected '$EXPECTED_BACKEND'" "$INFO  <- a build whose xcconfig did not apply looks exactly like this"

if [ -z "$e" ]; then
  record WARN "PetNoteExpectedProject is empty - nothing pins the project at launch" \
    "$INFO ; consequence: EnvironmentGuard.verdict returns .unchecked and AppEnvironment.allowsWrites is false for testCloud"
elif [ "$e" = "$EXPECTED_PROJECT_ID" ]; then
  record PASS "PetNoteExpectedProject = $e" "$INFO"
else
  record FAIL "PetNoteExpectedProject = '$e', expected '$EXPECTED_PROJECT_ID'" "$INFO"
fi

[ "$cbi" = "$EXPECTED_BUNDLE_ID" ] \
  && record PASS "CFBundleIdentifier = $cbi" "$INFO" \
  || record FAIL "CFBundleIdentifier = '$cbi', expected '$EXPECTED_BUNDLE_ID'" "$INFO"
# Google sign-in: the button appears only when this scheme is the reversed
# client ID of the Firebase project the package talks to (GoogleSignInService,
# GoogleSignInAvailability). The placeholder means the button is hidden.
gscheme="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$INFO" 2>/dev/null)"
gclient="$(/usr/libexec/PlistBuddy -c 'Print :REVERSED_CLIENT_ID' "$APP/GoogleService-Info-Test.plist" 2>/dev/null)"
if [ -z "$gscheme" ]; then
  record FAIL "no URL scheme for Google sign-in - a tap on the button would crash the SDK" "$INFO"
elif [ "$gscheme" = "com.googleusercontent.apps.not-configured" ]; then
  record FACT "Google sign-in is off in this package (placeholder scheme); the button is hidden" "$INFO"
elif [ -n "$gclient" ] && [ "$gscheme" = "$gclient" ]; then
  record PASS "Google sign-in scheme is the test project's reversed client ID" "$INFO"
else
  record FAIL "Google sign-in scheme is not the test project's reversed client ID" "$INFO (scheme $gscheme)"
fi
record FACT "PetNoteBuildStamp = $s" "$INFO"

# --- 3c. signature and provisioning -----------------------------------------
say ""
say "3c. Signature, team, and which devices the profile admits"
CS="$LOGDIR/codesign-$STAMP.txt"
codesign -dvvv "$APP" >"$CS" 2>&1
identity="$(grep -m1 '^Authority=' "$CS" | sed 's/^Authority=//')"
teamid="$(grep -m1 '^TeamIdentifier=' "$CS" | sed 's/^TeamIdentifier=//')"
cdhash="$(grep -m1 '^CDHash=' "$CS" | sed 's/^CDHash=//')"

if [ -n "$identity" ]; then record PASS "signing identity: $identity" "$CS (CDHash $cdhash)"
else record FAIL "no signing authority on the package" "$CS"; fi
[ "$teamid" = "$EXPECTED_TEAM" ] \
  && record PASS "TeamIdentifier = $teamid" "$CS" \
  || record FAIL "TeamIdentifier = '$teamid', expected '$EXPECTED_TEAM'" "$CS"

PROF="$APP/embedded.mobileprovision"
if [ -f "$PROF" ]; then
  DEC="$LOGDIR/profile-$STAMP.plist"
  if security cms -D -i "$PROF" >"$DEC" 2>/dev/null; then
    pname="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$DEC" 2>/dev/null)"
    pexp="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$DEC" 2>/dev/null)"
    devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$DEC" 2>/dev/null | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9a-f]{40}')"
    ndev="$(printf '%s\n' "$devices" | grep -c . )"
    record FACT "profile: $pname" "$DEC"
    record FACT "provisioned devices ($ndev): $(printf '%s ' $devices)" "$DEC"

    if printf '%s\n' "$devices" | grep -qx "$EXPECTED_DEVICE_UDID"; then
      record PASS "the owner's iPhone $EXPECTED_DEVICE_UDID is in the profile" "$DEC"
    else
      record FAIL "the owner's iPhone $EXPECTED_DEVICE_UDID is NOT in the profile - install will be rejected" "$DEC"
    fi

    exp_epoch="$(date -j -f '%a %b %d %T %Z %Y' "$pexp" +%s 2>/dev/null)"
    [ -z "$exp_epoch" ] && exp_epoch="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$pexp" +%s 2>/dev/null)"
    if [ -n "$exp_epoch" ]; then
      days=$(( (exp_epoch - $(date +%s)) / 86400 ))
      if   [ "$days" -lt 0 ]; then record FAIL "profile EXPIRED on $pexp" "$DEC"
      elif [ "$days" -le 7 ]; then record WARN "profile expires $pexp - $days day(s) left" "$DEC"
      else record PASS "profile valid until $pexp ($days days)" "$DEC"; fi
    else
      record FACT "profile expiry: $pexp (could not parse into days)" "$DEC"
    fi
  else
    record FAIL "embedded.mobileprovision present but could not be decoded" "$PROF"
  fi
else
  record FAIL "no embedded.mobileprovision - this package cannot install on a device" "$APP"
fi

# --- 3d. test switches, WITH a positive control ------------------------------
say ""
say "3d. Test switches and probes in the package"
say "    Scanning the WHOLE bundle. Scanning only the main binary is the trap:"
say "    a Debug build puts all the Swift in PetNote.debug.dylib and leaves the"
say "    main executable a stub, so a main-binary-only scan reports 'clean'."

SCAN_OUT="$LOGDIR/scan-testcloud-$STAMP.txt"
scan_bundle "$APP" >"$SCAN_OUT"
tokens="$(scan_tokens "$APP")"
ntok="$(printf '%s\n' "$tokens" | grep -c . )"
switches="$(printf '%s\n' "$tokens" | grep -vE "$PROJECT_ID_TOKENS" | grep . )"
projids="$(printf '%s\n' "$tokens" | grep -E "$PROJECT_ID_TOKENS" | grep . )"
nsw="$(printf '%s\n' "$switches" | grep -c . )"
main_only="$(LC_ALL=C grep -aoE "$SCAN_RE" "$APP/PetNote" 2>/dev/null | sort -u | grep -c . )"

say ""
say "    whole-bundle distinct tokens : $ntok  ($nsw switches/probes + $(printf '%s\n' "$projids" | grep -c . ) project ids)"
say "    main-binary-only would say   : $main_only   <- why the whole bundle is scanned"
say ""
say "    switches and probes:"
printf '%s\n' "$switches" | grep . | sed 's/^/      /' | tee -a "$REPORT"
say "    Firebase project ids (not switches):"
printf '%s\n' "$projids" | grep . | sed 's/^/      /' | tee -a "$REPORT"
say ""
say "    per file:"
sed 's/^/      /' "$SCAN_OUT" | tee -a "$REPORT" >/dev/null
say "    (full listing: $SCAN_OUT)"

# --- the control -------------------------------------------------------------
say ""
say "    POSITIVE CONTROL - the same scan against a Debug-Emulator device"
say "    package, which is known to contain switches. Without this, '0 hits'"
say "    cannot be told apart from 'scanned the wrong thing'."

CONTROL_OK=0
CONTROL_TOKENS=""
if [ "$SKIP_CONTROL" = 1 ]; then
  record WARN "control skipped (--skip-control) - the switch scan above is UNVERIFIED" "no control run"
else
  if [ -z "$CONTROL_APP" ]; then
    CONTROL_LOG="$LOGDIR/build-control-$STAMP.log"
    say "    building the control: -configuration $CONTROL_CONFIGURATION -derivedDataPath $DD_CONTROL"
    xcb "$DD_CONTROL" "$CONTROL_SCHEME" "$CONTROL_CONFIGURATION" "$CONTROL_LOG" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    CONTROL_APP="$(app_in "$DD_CONTROL" "$CONTROL_CONFIGURATION")"
  fi
  if [ -d "$CONTROL_APP" ]; then
    CONTROL_TOKENS="$(scan_tokens "$CONTROL_APP" | grep -vE "$PROJECT_ID_TOKENS")"
    nctl="$(printf '%s\n' "$CONTROL_TOKENS" | grep -c . )"
    say ""
    printf '%s\n' "$CONTROL_TOKENS" | grep . | sed 's/^/      /' | tee -a "$REPORT"
    say ""
    if [ "$nctl" -ge 8 ]; then
      CONTROL_OK=1
      record PASS "control yields $nctl distinct switch tokens - the scan reaches Swift code" "$CONTROL_APP"
    else
      record FAIL "control yielded only $nctl tokens (expected >= 8) - THE SCAN IS NOT LOOKING IN THE RIGHT PLACE, treat the result above as meaningless" "$CONTROL_APP"
    fi
  else
    record WARN "control package unavailable - the switch scan above is UNVERIFIED" "${CONTROL_APP:-not built}"
  fi
fi

# --- reporting the switches: facts, not a verdict ----------------------------
say ""
if [ "$CONTROL_OK" = 1 ]; then
  if [ "$nsw" -gt 0 ]; then
    record FACT "this package contains $nsw test-switch/probe tokens" \
      "EXPECTED: $CONFIGURATION is a Debug configuration (SWIFT_ACTIVE_COMPILATION_CONDITIONS = $bs_conditions). Device acceptance needs -petnote-start-signed-out and the probes. This is NOT a defect in a TestCloud package."
  else
    record WARN "a Debug-TestCloud package with zero switches is surprising" \
      "the acceptance run needs -petnote-start-signed-out; check the configuration really applied"
  fi
  say ""
  say "    The package that must contain NONE of these is the Release candidate,"
  say "    not this one. Run with --release-check to re-prove that here."
else
  record BLOCKED "switch inventory UNVERIFIED (no valid control)" "re-run without --skip-control"
fi

# --- fault injection: the part of the inventory that must NOT be here --------
#
# "This is a Debug package so switches are expected" is true of probes and
# false of fault injection. A probe reads state; a fault switch makes the app
# fail on purpose. Device acceptance needs the first and never asks for the
# second, so nothing that breaks the app belongs in the package a person runs.
#
# The list is read out of the sources rather than matched by name, because a
# naming rule only holds for as long as everybody remembers it. Anything behind
# `#if PETNOTE_FAULT_INJECTION` is compiled out of every configuration except
# Debug-Emulator, so its string literals should be absent from this binary -
# and absence of a literal is something `strings` can settle.
say ""
FAULT_LITERALS="$(bash "$ROOT/scripts/fault-switches.sh" 2>/dev/null)"
nfault="$(printf '%s\n' "$FAULT_LITERALS" | grep -c . )"
if [ "$nfault" -eq 0 ]; then
  # Nothing declared means nothing to look for, and a scan that looks for
  # nothing finds nothing. That is not evidence.
  record FACT "no fault-injection switches are declared behind PETNOTE_FAULT_INJECTION" \
    "scripts/fault-switches.sh returned an empty list, so this package has nothing to be clean of"
else
  # `tokens` is this package's inventory from step 3, already stripped of the
  # `strings` file prefix. The scanner's regex has no leading dash, so compare
  # against the literal with its dash removed.
  present=""
  for literal in $FAULT_LITERALS; do
    if printf '%s\n' "$tokens" | grep -qxF -- "${literal#-}"; then
      present="$present $literal"
    fi
  done
  if [ -n "$present" ]; then
    record FAIL "the device package carries fault-injection switch(es):$present" \
      "these make the app fail on purpose and must not exist outside Debug-Emulator"
  else
    record PASS "0 of $nfault fault-injection switches are in the device package" \
      "checked by literal: $(printf '%s ' $FAULT_LITERALS)"
  fi
fi

# --- 3d'. the same question asked of what was compiled, not of strings ------
# A literal can be missing from a binary for reasons of its own - folded,
# split, built at run time - so "no string" is not "no code". Two further
# checks that do not depend on strings:
#   1. the configuration this package was built with does not define the
#      compilation condition that gates fault injection at all;
#   2. the types declared behind that gate have no type metadata in the
#      package's symbol table - checked against the control, which must have
#      them, so an empty answer cannot come from looking in the wrong place.
say ""
say "    Fault injection by compilation condition and by compiled symbol"
if printf '%s\n' "$bs_conditions" | tr ' ' '\n' | grep -qx PETNOTE_FAULT_INJECTION; then
  record FAIL "the package's configuration defines PETNOTE_FAULT_INJECTION" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $bs_conditions"
else
  record PASS "the package's configuration does not define PETNOTE_FAULT_INJECTION" \
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $bs_conditions"
fi
symbols_of() {  # symbols_of <app> -> demangled symbol names of the app's own code
  for f in "$1/PetNote" "$1/PetNote.debug.dylib"; do
    [ -f "$f" ] && nm -a "$f" 2>/dev/null | awk '{print $NF}'
  done | xcrun swift-demangle --simplified 2>/dev/null
}
FAULT_TYPES="$(bash "$ROOT/scripts/fault-switches.sh" --types 2>/dev/null)"
ntypes="$(printf '%s\n' "$FAULT_TYPES" | grep -c . )"
PKG_SYMS="$LOGDIR/symbols-testcloud-$STAMP.txt"
symbols_of "$APP" >"$PKG_SYMS"
type_hits() {  # type_hits <symbols file> -> the gated types that have metadata there
  for t in $FAULT_TYPES; do
    grep -qE "(type metadata|nominal type descriptor) for PetNote\.([A-Za-z0-9_]+\.)*${t}\$" "$1" && echo "$t"
  done
}
in_pkg="$(type_hits "$PKG_SYMS" | tr '\n' ' ')"
if [ "$ntypes" -eq 0 ]; then
  record FACT "no types are declared behind PETNOTE_FAULT_INJECTION" "scripts/fault-switches.sh --types"
elif [ -n "$CONTROL_APP" ] && [ -d "$CONTROL_APP" ]; then
  CTL_SYMS="$LOGDIR/symbols-control-$STAMP.txt"
  symbols_of "$CONTROL_APP" >"$CTL_SYMS"
  in_ctl="$(type_hits "$CTL_SYMS" | grep -c . )"
  if [ "$in_ctl" -lt "$ntypes" ]; then
    record BLOCKED "the control has metadata for only $in_ctl of $ntypes gated types - the symbol check cannot tell clean from not-looking" \
      "$CTL_SYMS ($(wc -l <"$CTL_SYMS" | tr -d ' ') symbols)"
  elif [ -n "$in_pkg" ]; then
    record FAIL "the device package has compiled fault-injection types: $in_pkg" "$PKG_SYMS"
  else
    record PASS "0 of $ntypes fault-injection types are compiled into the package; the control has all $in_ctl" \
      "types: $(printf '%s ' $FAULT_TYPES); package symbols $(wc -l <"$PKG_SYMS" | tr -d ' '), control $(wc -l <"$CTL_SYMS" | tr -d ' ')"
  fi
else
  record BLOCKED "no control package - the symbol check is not reported as clean" "${CONTROL_APP:-not built}"
fi

# --- 3d''. credentials ---------------------------------------------------------
# The client needs its Firebase client configuration and nothing else. A
# server secret, a service-account key or a private key in the package would
# be a credential handed to everyone who installs it.
say ""
say "    Credentials in the package"
secret_files="$(LC_ALL=C grep -rlaE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|"private_key"[[:space:]]*:|"type"[[:space:]]*:[[:space:]]*"service_account"|cloudinary://[^[:space:]"]+@|api_secret=' "$APP" 2>/dev/null)"
if [ -n "$secret_files" ]; then
  record FAIL "the package carries something shaped like a secret" "$(printf '%s ' $secret_files)"
else
  record PASS "no private key, service-account key or Cloudinary secret in the package" \
    "patterns: BEGIN PRIVATE KEY, \"private_key\":, service_account, cloudinary://…@, api_secret="
fi
allowed_keys="$( { /usr/libexec/PlistBuddy -c 'Print :API_KEY' "$APP/GoogleService-Info-Test.plist" 2>/dev/null;
                   /usr/libexec/PlistBuddy -c 'Print :API_KEY' "$APP/GoogleService-Info-Emulator.plist" 2>/dev/null; } | sort -u)"
found_keys="$(LC_ALL=C grep -rhoaE 'AIza[0-9A-Za-z_-]{35}' "$APP" 2>/dev/null | sort -u)"
stray_keys="$(comm -23 <(printf '%s\n' "$found_keys" | grep .) <(printf '%s\n' "$allowed_keys" | grep .))"
if [ -n "$stray_keys" ]; then
  record FAIL "the package carries a Firebase API key that is not the test or emulator project's" \
    "$(printf '%s\n' "$stray_keys" | grep -c .) unexpected key(s); values not printed"
else
  record PASS "the only Firebase API keys in the package are the test and emulator projects' client keys" \
    "$(printf '%s\n' "$found_keys" | grep -c .) distinct; these are client identifiers, not secrets"
fi

fi  # end: package exists

# --- 3e. optional: the Release candidate must be clean -----------------------
if [ "$RELEASE_CHECK" = 1 ]; then
  say ""
  say "3e. Release candidate - the package that must carry no switches at all"
  REL_LOG="$LOGDIR/build-release-$STAMP.log"
  xcb "$DD_RELEASE" "$RELEASE_SCHEME" "$RELEASE_CONFIGURATION" "$REL_LOG" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
  REL_APP="$(app_in "$DD_RELEASE" "$RELEASE_CONFIGURATION")"
  # The configuration first: Release strips its symbols, so the symbol check
  # above has nothing to read here, and the compilation condition is the
  # structural answer.
  REL_SETTINGS="$LOGDIR/settings-release-$STAMP.txt"
  xcodebuild -project "$PROJECT" -scheme "$RELEASE_SCHEME" -configuration "$RELEASE_CONFIGURATION" \
    -sdk iphoneos -showBuildSettings >"$REL_SETTINGS" 2>/dev/null
  rel_conditions="$(grep -E "^[[:space:]]*SWIFT_ACTIVE_COMPILATION_CONDITIONS = " "$REL_SETTINGS" | head -1 | sed 's/^[^=]*= *//')"
  if printf '%s\n' "$rel_conditions" | tr ' ' '\n' | grep -qxE 'PETNOTE_FAULT_INJECTION|DEBUG'; then
    record FAIL "Release defines a test compilation condition" "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $rel_conditions"
  else
    record PASS "Release defines neither DEBUG nor PETNOTE_FAULT_INJECTION" \
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS = ${rel_conditions:-(empty)}"
  fi
  if [ -d "$REL_APP" ]; then
    reltok="$(scan_tokens "$REL_APP")"
    relsw="$(printf '%s\n' "$reltok" | grep -vE "$PROJECT_ID_TOKENS" | grep . )"
    nrelsw="$(printf '%s\n' "$relsw" | grep -c . )"
    if [ "$CONTROL_OK" != 1 ]; then
      record BLOCKED "Release switch scan ran but has no valid control - not reporting it as clean" "$REL_APP"
    elif [ "$nrelsw" -eq 0 ]; then
      record PASS "Release device package: 0 test switches, with a control that finds $(printf '%s\n' "$CONTROL_TOKENS" | grep -c .)" "$REL_APP"
    else
      record FAIL "Release device package contains $nrelsw test switch(es): $(printf '%s ' $relsw)" "$REL_APP"
    fi

    # Separate question from switches, and the one that regressed when the test
    # project's plist arrived. Support/ is a synchronised group, so EVERY file
    # in it lands in EVERY configuration's bundle unless that configuration
    # names it in EXCLUDED_SOURCE_FILE_NAMES. Release excludes the emulator's
    # plist; it does not (yet) exclude the test project's.
    stray="$(ls "$REL_APP" 2>/dev/null | grep -E '^GoogleService-Info-(Emulator|Test)\.plist$')"
    if [ -z "$stray" ]; then
      record PASS "Release package carries no non-production Firebase plist" \
        "EXCLUDED_SOURCE_FILE_NAMES in Config/Release.xcconfig"
    else
      for f in $stray; do
        spid="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$REL_APP/$f" 2>/dev/null)"
        record FAIL "Release package carries $f (PROJECT_ID=$spid) - a candidate build is shipping the configuration of a backend it must never talk to" \
          "add it to EXCLUDED_SOURCE_FILE_NAMES in Config/Release.xcconfig"
      done
    fi
  else
    record FAIL "Release build produced no package" "$REL_LOG"
  fi
fi

# ======================================================= 4. THE FOUR STATUSES ==
# Is the phone actually here? "TODO" is worth more when it says why, and the
# answer decides whether the next step is "plug it in" or "run these two
# commands". devicectl only lists; it does not touch the device.
DEVLIST="$LOGDIR/devices-$STAMP.txt"
xcrun devicectl list devices >"$DEVLIST" 2>&1
dev_state="$(grep -F "$EXPECTED_DEVICE_UDID" "$DEVLIST" | head -1 \
  | sed 's/.*(UDID)[[:space:]]*//' | sed 's/[[:space:]]\{2,\}.*//')"
case "$dev_state" in
  "")            STATUS_INSTALL="TODO - phone $EXPECTED_DEVICE_UDID is not known to this Mac" ;;
  connected*|available*)
                 STATUS_INSTALL="TODO - phone is '$dev_state'; ready to attempt" ;;
  *)             STATUS_INSTALL="TODO - phone is '$dev_state'; plug it in and unlock it first" ;;
esac
STATUS_LAUNCH="${STATUS_INSTALL/TODO - /TODO (after install) - }"
record FACT "device $EXPECTED_DEVICE_UDID state: ${dev_state:-not listed}" "$DEVLIST"

head1 "THE FOUR STATUSES"
say ""
say "  1 BUILD   : $STATUS_BUILD"
say "  2 SIGN    : $STATUS_SIGN"
say "  3 INSTALL : $STATUS_INSTALL"
say "  4 LAUNCH  : $STATUS_LAUNCH"
say ""
say "  3 and 4 are not claimed by this script and never will be. With the"
say "  phone attached and unlocked, they are:"
say ""
say "    xcrun devicectl list devices"
say "    xcrun devicectl device install app --device $EXPECTED_DEVICE_UDID \\"
say "      \"$ROOT/$APP\""
say "    xcrun devicectl device process launch --device $EXPECTED_DEVICE_UDID \\"
say "      --console $EXPECTED_BUNDLE_ID -petnote-start-signed-out"
say ""
say "  LAUNCH only counts if the console shows EnvironmentGuard's line"
say "    'environment verified: $EXPECTED_PROJECT_ID via firestore.googleapis.com'"
say "  A launch that prints 'environment id unchecked' means nothing was pinned."

head1 "FINDINGS"
for level in FAIL BLOCKED WARN PASS FACT; do
  for f in "${FINDINGS[@]}"; do
    case "$f" in
      "$level|"*) say "  [$level] $(printf '%s' "$f" | cut -d'|' -f2)" ;;
    esac
  done
done
say ""
nf=0; nb=0
for f in "${FINDINGS[@]}"; do
  case "$f" in FAIL\|*) nf=$((nf+1));; BLOCKED\|*) nb=$((nb+1));; esac
done
say "  $nf failing, $nb blocked."
say "  report: $REPORT"

# Three exit codes, because "it failed" and "it could not tell" are different
# answers and a caller reads the code, not the prose above it.
#
# This previously exited 0 whenever nothing outright FAILED, which meant a run
# where the switch scan had no valid control - the run that explicitly refuses
# to report the package as clean - still reported success to whoever called it.
# The text said "not reporting it as clean" and the exit code said "clean".
#
#   0  every check reached a verdict and none failed
#   1  at least one check failed
#   2  no check failed, but at least one could not reach a verdict
#      (--skip-control lands here on purpose: you asked for no control, so the
#      scan is inconclusive, and an inconclusive scan is not a pass)
if [ "$nf" -gt 0 ]; then
  say "  exit 1: $nf check(s) failed."
  exit 1
fi
if [ "$nb" -gt 0 ]; then
  say "  exit 2: nothing failed, but $nb check(s) could not reach a verdict."
  say "          这不是通过。没有结论的扫描不能当作干净。"
  exit 2
fi
exit 0
