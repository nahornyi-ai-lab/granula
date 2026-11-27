#!/bin/zsh
# Release check — what a Granula.app must satisfy before it ships.
#   release-check.sh <Granula.app> <version> <build> [--no-launch]
#       A release build: arm64 only, the given version and build number, LICENSE and
#       THIRD-PARTY-NOTICES.md inside, a valid signature of the expected kind
#       (GRANULA_RELEASE_SIGNING=adhoc|selfsigned, default adhoc), and the E2E launch flags
#       ignored: launched with --e2e-start it must not record.
#   release-check.sh --dev <Granula.app>
#       A local build from build-app.sh: the E2E flags still work (--e2e-snapshot writes Home).
# Launch checks quit the owner's Granula and reopen /Applications/Granula.app afterwards.
set -euo pipefail
ROOT=${0:A:h:h:h}
source ${0:A:h}/common.sh

fail=0
check() {  # check <description> <command...>
  local what=$1; shift
  if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; fail=1; fi
}

eq() { [[ $1 == "$2" ]]; }                  # exact
has() { [[ $1 == *"$2"* ]]; }               # substring
lacks() { [[ $1 != *"$2"* ]]; }
nonempty_file() { [[ -s $1 ]]; }
wait_quiet() { wait_event "$@" >/dev/null; }

launch() {  # launch <app> <args...>: start a new instance of exactly that bundle
  quit_granula
  log_mark
  open -n "$1" --args "${@:2}"
}

if [[ ${1:-} == --dev ]]; then
  APP_UNDER_TEST=${2:?usage: release-check.sh --dev <Granula.app>}
  WORK=$(mktemp -d)
  trap 'quit_granula || true; restore_granula' EXIT
  launch "$APP_UNDER_TEST" --e2e-snapshot "$WORK"
  line=$(wait_event app.launched 30 || true)
  check "launched with E2E flags on ($line)" has "$line" "e2e=true"
  check "snapshots taken" wait_quiet e2e.snapshots_done 60
  check "Home snapshot written" nonempty_file "$WORK/1-home.png"
  (( fail )) && { echo "RELEASE-CHECK --dev FAIL"; exit 1; }
  echo "RELEASE-CHECK --dev PASS"
  exit 0
fi

APP_UNDER_TEST=${1:?usage: release-check.sh <Granula.app> <version> <build> [--no-launch]}
VERSION=${2:?version}
BUILD=${3:?build number}
NO_LAUNCH=${4:-}
SIGNING=${GRANULA_RELEASE_SIGNING:-adhoc}
PLIST=$APP_UNDER_TEST/Contents/Info.plist
RES=$APP_UNDER_TEST/Contents/Resources
BIN=$APP_UNDER_TEST/Contents/MacOS/Granula
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo "?"; }

check "binary exists" test -x "$BIN"
archs=$(lipo -archs "$BIN" 2>/dev/null || echo "?")
check "arm64 only ($archs)" eq "$archs" arm64
v=$(plist CFBundleShortVersionString); b=$(plist CFBundleVersion)
check "version $VERSION ($v)" eq "$v" "$VERSION"
check "build $BUILD ($b)" eq "$b" "$BUILD"
check "LICENSE inside, same as the repository" cmp -s "$RES/LICENSE" "$ROOT/LICENSE"
check "THIRD-PARTY-NOTICES.md inside, same as the repository" cmp -s "$RES/THIRD-PARTY-NOTICES.md" "$ROOT/THIRD-PARTY-NOTICES.md"
check "signature valid (deep, strict)" codesign --verify --deep --strict "$APP_UNDER_TEST"
info=$(codesign -dvv "$APP_UNDER_TEST" 2>&1 || true)
req=$(codesign -d -r- "$APP_UNDER_TEST" 2>&1 | sed -n 's/^#* *designated => //p')
case $SIGNING in
  adhoc) check "ad-hoc signature" has "$info" "Signature=adhoc" ;;
  selfsigned)
    check "signed by Granula Release Signing" has "$info" "Authority=Granula Release Signing"
    check "designated requirement names the certificate ($req)" test -n "$req" -a "${req/cdhash/}" = "$req" ;;
  *) check "known GRANULA_RELEASE_SIGNING ($SIGNING)" false ;;
esac
echo "      designated: $req"

if [[ $NO_LAUNCH != --no-launch ]]; then
  trap 'quit_granula || true; restore_granula' EXIT
  launch "$APP_UNDER_TEST" --e2e-start --e2e-stop-after 3
  line=$(wait_event app.launched 30 || true)
  check "launched, E2E flags ignored ($line)" has "$line" "e2e=false"
  sleep 10
  check "no recording started" lacks "$(new_log)" " recording.started"
fi

(( fail )) && { echo "RELEASE-CHECK FAIL"; exit 1; }
echo "RELEASE-CHECK PASS"
