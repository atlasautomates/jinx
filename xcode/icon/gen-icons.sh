#!/usr/bin/env bash
# Regenerate the CEC Dashboard app icon into the asset catalog.
#
# The artwork is a VIEW in the app (`Sources/CECDashboard/Views/AppIconArt.swift`)
# rendered through the preview harness, not a standalone drawing script — the design
# bible bans colour literals, and a separate script would fork the palette the moment
# a token moved. The icon is therefore the same teal / near-black / reward pink the
# Leads tab uses, by construction.
#
#   ./gen-icons.sh            # build if needed, render, write the appiconset
#
# Run it after any change to AppIconArt or to the colour tokens it reads.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"                       # builds/lead-dashboard
OUT="$ROOT/xcode/Resources/Assets.xcassets/AppIcon.appiconset"
BIN="$ROOT/.build/debug/CECDashboard"

# ALWAYS build. Testing for the binary's existence rather than its freshness meant
# editing AppIconArt (or a colour token) and running this script re-rendered the
# PREVIOUS artwork, wrote every size, and exited 0 — silently shipping an icon that
# doesn't match its source. SwiftPM's incremental build is ~1s when up to date.
(cd "$ROOT" && swift build)

# Stage into a temp dir and swap only once every size exists at the right dimensions:
# writing in place leaves a mixed-generation catalog if any step fails, and the asset
# compiler will happily build that.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
MASTER="$STAGE/icon_1024.png"
"$BIN" --screenshot app-icon --out "$MASTER" --scale 1 >/dev/null

check_size() {  # path, expected px — the render is not trusted, it is measured
  local got
  got=$(sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth|pixelHeight/{print $2}' | sort -u)
  [[ "$got" == "$2" ]] || { echo "FAIL: $(basename "$1") is ${got}px, expected $2 (square)"; exit 1; }
}
check_size "$MASTER" 1024
echo "rendered 1024×1024 master"

# Downsample — every size Finder/Dock/Launchpad asks for.
for SIZE in 512 256 128 64 32 16; do
  sips -Z "$SIZE" "$MASTER" --out "$STAGE/icon_${SIZE}.png" >/dev/null
  check_size "$STAGE/icon_${SIZE}.png" "$SIZE"
done
COUNT=$(ls "$STAGE"/icon_*.png | wc -l | tr -d ' ')
[[ "$COUNT" == "7" ]] || { echo "FAIL: staged $COUNT sizes, expected 7"; exit 1; }

mkdir -p "$OUT"
cp "$STAGE"/icon_*.png "$OUT/"
echo "wrote $COUNT sizes"

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "asset catalog updated: $OUT"
