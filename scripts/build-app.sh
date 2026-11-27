#!/bin/zsh
# Builds Granula.app into build/Granula.app.
#   build-app.sh            a local build: honours the E2E launch flags that scripts/e2e use
#   build-app.sh --install  the same, then replaces /Applications/Granula.app
#   build-app.sh --release  a release build: no E2E flags (scripts/release.sh calls it)
# Signing identity: GRANULA_SIGN_IDENTITY ("-" means ad-hoc), else "Granula Release Signing"
# if the keychain has it, else an "Apple Development" certificate, else ad-hoc.
# A stable signature matters: macOS keys the microphone and system-audio
# permissions to it, and an ad-hoc signature loses them on every rebuild.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

INSTALL=0 RELEASE=0
for arg in "$@"; do
  case $arg in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "usage: build-app.sh [--install] [--release]" >&2; exit 2 ;;
  esac
done

# Command Line Tools: the 27 SDK's SwiftUI needs a macro plugin CLT lacks; build with 26.5.
CLT=/Library/Developer/CommandLineTools
if [[ -z "${SDKROOT:-}" && -d $CLT/SDKs/MacOSX26.5.sdk ]]; then export SDKROOT=$CLT/SDKs/MacOSX26.5.sdk; fi

FLAGS=(-c release --product Granula)
(( RELEASE )) || FLAGS+=(-Xswiftc -DGRANULA_E2E)
swift build "${FLAGS[@]}"
BIN=$(swift build -c release --show-bin-path)
APP="$ROOT/build/Granula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Granula" "$APP/Contents/MacOS/Granula"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Interface translations and permission texts: en, ru, uk, es.
for lproj in "$ROOT"/Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
# The licenses travel with every copy (MIT for Granula and the amanu code, Apache-2.0 for FluidAudio).
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"

# identity_named <name> [find-identity flags]: the self-signed release certificate is untrusted and
# shows only in the full list; an Apple Development one must be valid (-v), else ad-hoc.
identity_named() { local n=$1; shift; security find-identity "$@" -p codesigning | awk -F'"' -v n="$n" 'index($2, n) == 1 {print $2; exit}'; }
IDENTITY=${GRANULA_SIGN_IDENTITY:-}
[[ -z "$IDENTITY" ]] && IDENTITY=$(identity_named "Granula Release Signing")
[[ -z "$IDENTITY" ]] && IDENTITY=$(identity_named "Apple Development" -v)
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no signing certificate — signing ad-hoc; permissions will reset on every rebuild" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier ai.nahornyi.granula --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "signed: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}' | grep . || echo ad-hoc)"
(( RELEASE )) && echo "release build: E2E launch flags compiled out"

if (( INSTALL )); then
  osascript -e 'tell application id "ai.nahornyi.granula" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Granula.app
  ditto "$APP" /Applications/Granula.app
  echo "installed: /Applications/Granula.app"
fi
