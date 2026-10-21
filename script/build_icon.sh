#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 OUTPUT.icns [SOURCE.png]" >&2
    exit 2
fi

OUTPUT="$1"
SOURCE="${2:-$ROOT_DIR/Assets/AppIcon.png}"
if [[ ! -f "$SOURCE" ]]; then
    echo "Icon source not found: $SOURCE" >&2
    exit 1
fi

ICON_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
ICONSET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

# Preserve the source PNG and its alpha; iconutil expects these ten macOS slots.
render_size() {
    /usr/bin/sips -z "$2" "$2" "$SOURCE" --out "$ICONSET/$1.png" >/dev/null
}
render_size icon_16x16 16
render_size icon_16x16@2x 32
render_size icon_32x32 32
render_size icon_32x32@2x 64
render_size icon_128x128 128
render_size icon_128x128@2x 256
render_size icon_256x256 256
render_size icon_256x256@2x 512
render_size icon_512x512 512
render_size icon_512x512@2x 1024

/usr/bin/iconutil --convert icns --output "$OUTPUT" "$ICONSET"
echo "Built icon: $OUTPUT"
