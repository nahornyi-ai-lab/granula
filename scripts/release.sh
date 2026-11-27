#!/bin/zsh
# Builds a Granula release:  scripts/release.sh <version> [--draft]
#   - refuses a dirty tree, a HEAD that is not origin/main, or an Info.plist with another version;
#   - builds in a fresh clone of HEAD, so nothing uncommitted reaches the build;
#   - checks the app, packs build/release/Granula.dmg (the app and an Applications link), checks
#     the app copied out of the mounted DMG (this check launches it: the owner's Granula is quit
#     and reopened), writes SHA256SUMS.txt, cdhash.txt and the syspolicy_check output;
#   - --draft: creates the draft GitHub release v<version>, or replaces the assets and notes of
#     an existing draft; it refuses when v<version> is already published.
# Signing: GRANULA_RELEASE_SIGNING=adhoc (default) | selfsigned ("Granula Release Signing").
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
REPO=nahornyi-ai-lab/granula
die() { echo "release: $*" >&2; exit 1; }

VERSION=${1:-}
[[ -n $VERSION && $VERSION != -* ]] || die "usage: release.sh <version> [--draft]"
DRAFT=0
case ${2:-} in
  "") ;;
  --draft) DRAFT=1 ;;
  *) die "usage: release.sh <version> [--draft]" ;;
esac
case ${GRANULA_RELEASE_SIGNING:-adhoc} in
  adhoc) IDENTITY=- ;;
  selfsigned) IDENTITY="Granula Release Signing" ;;
  *) die "GRANULA_RELEASE_SIGNING must be adhoc or selfsigned" ;;
esac

# Guards: only a pushed, clean commit with the right version becomes a release.
[[ -z $(git status --porcelain) ]] || die "the working tree has uncommitted or untracked files"
git fetch -q origin main
HEAD_SHA=$(git rev-parse HEAD)
[[ $HEAD_SHA == $(git rev-parse origin/main) ]] \
  || die "HEAD $(git rev-parse --short HEAD) is not origin/main $(git rev-parse --short origin/main); push first"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist; }
[[ $(plist CFBundleShortVersionString) == $VERSION ]] \
  || die "Resources/Info.plist says $(plist CFBundleShortVersionString), not $VERSION"
BUILD=$(plist CFBundleVersion)
NOTES=docs/release-notes/v$VERSION.md
[[ -f $NOTES ]] || die "missing $NOTES"
if (( DRAFT )); then
  STATE=$(gh release view "v$VERSION" -R $REPO --json isDraft --jq .isDraft 2>/dev/null || echo none)
  [[ $STATE != false ]] || die "v$VERSION is already published; release a new version"
fi

WORK=$(mktemp -d -t granula-release)
MNT=$WORK/mnt
cleanup() { if [[ -d $MNT ]]; then hdiutil detach "$MNT" -quiet 2>/dev/null || true; fi; rm -rf "$WORK"; }
trap cleanup EXIT

echo "== build $VERSION ($BUILD) from ${HEAD_SHA:0:7} in a fresh clone"
git clone -q --no-hardlinks "$ROOT" "$WORK/src"
git -C "$WORK/src" checkout -q --detach "$HEAD_SHA"
GRANULA_SIGN_IDENTITY=$IDENTITY "$WORK/src/scripts/build-app.sh" --release
APP=$WORK/src/build/Granula.app
CHECK=$WORK/src/scripts/e2e/release-check.sh
export GRANULA_RELEASE_SIGNING=${GRANULA_RELEASE_SIGNING:-adhoc}
"$CHECK" "$APP" "$VERSION" "$BUILD" --no-launch

echo "== pack the DMG"
OUT=$ROOT/build/release
rm -rf "$OUT"; mkdir -p "$OUT" "$WORK/stage"
ditto "$APP" "$WORK/stage/Granula.app"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname Granula -srcfolder "$WORK/stage" -format UDZO -ov "$OUT/Granula.dmg"

echo "== check the app as a user gets it: copied out of the mounted DMG"
mkdir -p "$MNT" "$WORK/user"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MNT" "$OUT/Granula.dmg"
[[ -L $MNT/Applications && $(readlink "$MNT/Applications") == /Applications ]] || die "no Applications link in the DMG"
ditto "$MNT/Granula.app" "$WORK/user/Granula.app"
hdiutil detach "$MNT" -quiet && rmdir "$MNT"
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
[[ $(cdhash "$APP") == $(cdhash "$WORK/user/Granula.app") ]] || die "the app in the DMG differs from the build"
"$CHECK" "$WORK/user/Granula.app" "$VERSION" "$BUILD"

cdhash "$WORK/user/Granula.app" > "$OUT/cdhash.txt"
syspolicy_check distribution "$WORK/user/Granula.app" > "$OUT/syspolicy_check.txt" 2>&1 || true
(cd "$OUT" && shasum -a 256 Granula.dmg > SHA256SUMS.txt)
echo "== $OUT"; cat "$OUT/SHA256SUMS.txt"; echo "CDHash $(cat "$OUT/cdhash.txt")"

(( DRAFT )) || exit 0
echo "== draft release v$VERSION"
{ cat "$NOTES"; printf '\n## SHA-256\n\n```\n'; cat "$OUT/SHA256SUMS.txt"; printf '```\n'; } > "$OUT/notes.md"
TITLE="Granula $VERSION (alpha)"
if [[ $STATE == none ]]; then
  gh release create "v$VERSION" -R $REPO --draft --target "$HEAD_SHA" --title "$TITLE" \
    --notes-file "$OUT/notes.md" "$OUT/Granula.dmg" "$OUT/SHA256SUMS.txt"
else
  gh release upload "v$VERSION" -R $REPO --clobber "$OUT/Granula.dmg" "$OUT/SHA256SUMS.txt"
  gh release edit "v$VERSION" -R $REPO --draft=true --target "$HEAD_SHA" --title "$TITLE" --notes-file "$OUT/notes.md"
fi
gh release view "v$VERSION" -R $REPO --json isDraft,url,assets --jq '"draft=\(.isDraft) \(.url)", (.assets[] | "  \(.name) \(.size)")'
