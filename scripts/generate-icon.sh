#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Resources/Images/AppIcon-1024.png"
ICONSET="$ROOT/.build/EliseVoice.iconset"
OUTPUT="$ROOT/.build/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

function render_icon() {
    local size="$1"
    local filename="$2"
    sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "$OUTPUT"
