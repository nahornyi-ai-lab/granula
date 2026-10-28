#!/bin/zsh
# Builds Granula.app, signs it with the Apple Development certificate and,
# with --install, replaces /Applications/Granula.app.
# A stable signature matters: macOS keys the microphone and system-audio
# permissions to it, and an ad-hoc signature loses them on every rebuild.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

swift build -c release --product Granula
BIN=$(swift build -c release --show-bin-path)
APP="$ROOT/build/Granula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Granula" "$APP/Contents/MacOS/Granula"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Interface translations and permission texts: ru, uk, en, es.
for lproj in "$ROOT"/Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done

IDENTITY=${GRANULA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no Apple Development certificate — signing ad-hoc; permissions will reset on every rebuild" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --identifier ai.nahornyi.granula --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "signed: $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}')"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'tell application id "ai.nahornyi.granula" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf /Applications/Granula.app
  ditto "$APP" /Applications/Granula.app
  echo "installed: /Applications/Granula.app"
fi
