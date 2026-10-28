#!/bin/zsh
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns.
# Quick Look draws the SVG (opaque); ImageMagick cuts the macOS tile shape
# (824 pt square, 185 pt corners, as in Apple's icon grid) and adds a soft shadow.
# Needs: qlmanage, sips, iconutil (macOS) and magick (Homebrew ImageMagick).
set -euo pipefail
ROOT=${0:A:h:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" "$ROOT/Resources/AppIcon.svg" >/dev/null 2>&1
[[ -f "$WORK/AppIcon.svg.png" ]] || { echo "Quick Look did not render the SVG" >&2; exit 1; }

# The art fills 1024; the tile is the art scaled to 824 and cut to a rounded square.
magick "$WORK/AppIcon.svg.png" -resize 824x824 "$WORK/art.png"
magick -size 824x824 xc:black -fill white -draw "roundrectangle 0,0 823,823 185,185" "$WORK/mask.png"
magick "$WORK/art.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite \
  -fill none -stroke "rgba(214,140,80,0.35)" -strokewidth 2 -draw "roundrectangle 1,1 822,822 184,184" \
  "$WORK/tile.png"
magick -size 1024x1024 xc:none \
  \( "$WORK/tile.png" -background black -shadow 28x14+0+0 \) -gravity center -geometry +0+10 -composite \
  "$WORK/tile.png" -gravity center -geometry +0+0 -composite "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for base in 16 32 128 256 512; do
  sips -z $base $base "$WORK/icon_1024.png" --out "$ICONSET/icon_${base}x${base}.png" >/dev/null
  sips -z $((base * 2)) $((base * 2)) "$WORK/icon_1024.png" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
cp "$WORK/icon_1024.png" "$ROOT/build/AppIcon-1024.png" 2>/dev/null || true
echo "wrote $ROOT/Resources/AppIcon.icns"
