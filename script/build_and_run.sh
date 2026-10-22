#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
BUILD_CONFIGURATION="${ROUTEWEAVER_BUILD_CONFIGURATION:-release}"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
    BUILD_CONFIGURATION="${ROUTEWEAVER_BUILD_CONFIGURATION:-debug}"
fi
case "$BUILD_CONFIGURATION" in
    release|debug) ;;
    *) echo "ROUTEWEAVER_BUILD_CONFIGURATION must be release or debug" >&2; exit 2 ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BUILD_ROOT="${ROUTEWEAVER_BUILD_ROOT:-$ROOT_DIR/.build}"
APP_NAME="RouteWeaver"
DIST_ROOT="${ROUTEWEAVER_DIST_ROOT:-$ROOT_DIR/dist}"
FINAL_BUNDLE="$DIST_ROOT/$APP_NAME.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/routeweaver-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
BUNDLE="$STAGING_DIR/$APP_NAME.app"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
if [[ "$MODE" != "--build-only" ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
swift build -c "$BUILD_CONFIGURATION" --disable-sandbox --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/cache"
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path --disable-sandbox --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/cache")"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/RouteWeaver" "$BUNDLE/Contents/MacOS/RouteWeaver"
cp "$BIN_DIR/RouteWeaverHelper" "$BUNDLE/Contents/Helpers/RouteWeaverHelper"
cp "$ROOT_DIR/script/uninstall.sh" "$BUNDLE/Contents/Resources/Uninstall RouteWeaver.command"
chmod 755 "$BUNDLE/Contents/Resources/Uninstall RouteWeaver.command"
mkdir -p "$BUNDLE/Contents/Resources/Licenses"
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$BUNDLE/Contents/Resources/Licenses/"
cp -R "$ROOT_DIR/LICENSES" "$BUNDLE/Contents/Resources/Licenses/LICENSES"
mkdir -p "$BUNDLE/Contents/Resources/Licenses/Source"
cp "$ROOT_DIR/Sources/CRouteStatistics/NetworkStatisticsABI.h" "$BUNDLE/Contents/Resources/Licenses/Source/"
cp "$ROOT_DIR/Sources/CRouteStatistics/RouteStatistics.c" "$BUNDLE/Contents/Resources/Licenses/Source/"
cp -R "$ROOT_DIR/Sources/CRouteStatistics/include" "$BUNDLE/Contents/Resources/Licenses/Source/include"
cp "$ROOT_DIR/LICENSES/CRouteStatistics-SOURCE.md" "$BUNDLE/Contents/Resources/Licenses/Source/README.md"
cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/script/build_and_run.sh" "$BUNDLE/Contents/Resources/Licenses/Source/"
"$ROOT_DIR/script/build_icon.sh" "$BUNDLE/Contents/Resources/AppIcon.icns"
# Keep resource bundles in Contents/Resources so the app seal remains valid.
if [[ -d "$BIN_DIR/RouteWeaver_RouteWeaver.bundle" ]]; then
    rm -rf "$BUNDLE/Contents/Resources/RouteWeaver_RouteWeaver.bundle"
    /usr/bin/ditto --norsrc --noextattr "$BIN_DIR/RouteWeaver_RouteWeaver.bundle" "$BUNDLE/Contents/Resources/RouteWeaver_RouteWeaver.bundle"
    rm -rf "$BUNDLE/RouteWeaver_RouteWeaver.bundle"
fi
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RouteWeaver</string>
<key>CFBundleIdentifier</key><string>com.routeweaver.app</string>
<key>CFBundleName</key><string>RouteWeaver</string>
<key>CFBundleDisplayName</key><string>RouteWeaver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0.3</string>
<key>CFBundleVersion</key><string>23</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Release symbols can contain absolute build-machine paths. Strip debug symbols
# from the copied executables before signing; keep debug builds available to LLDB.
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    /usr/bin/strip -S "$BUNDLE/Contents/MacOS/RouteWeaver"
    /usr/bin/strip -S "$BUNDLE/Contents/Helpers/RouteWeaverHelper"
fi
# File Provider can attach FinderInfo to generated bundles in Documents.
# Remove only signing-incompatible metadata from our build output.
/usr/bin/xattr -dr com.apple.FinderInfo "$BUNDLE" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$BUNDLE" 2>/dev/null || true
/usr/bin/codesign --force --sign - --options runtime "$BUNDLE/Contents/Helpers/RouteWeaverHelper"
/usr/bin/codesign --force --sign - --options runtime "$BUNDLE"
/usr/bin/codesign --verify --deep --strict "$BUNDLE"
mkdir -p "$DIST_ROOT"
# Preserve a clean signed archive; File Provider may attach FinderInfo to the
# expanded .app under Documents after copying it, which affects strict checks.
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$BUNDLE" "$STAGING_DIR/RouteWeaver-macOS.zip"
cp "$STAGING_DIR/RouteWeaver-macOS.zip" "$DIST_ROOT/RouteWeaver-macOS.zip"
rm -rf "$FINAL_BUNDLE"
/usr/bin/ditto --norsrc --noextattr "$BUNDLE" "$FINAL_BUNDLE"
BUNDLE="$FINAL_BUNDLE"
case "$MODE" in
  --build-only) echo "Built: $BUNDLE" ;;
  run) /usr/bin/open -n "$BUNDLE" ;;
  --verify|verify) /usr/bin/open -n "$BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug|debug) lldb -- "$BUNDLE/Contents/MacOS/RouteWeaver" ;;
  --logs|logs|--telemetry|telemetry)
    /usr/bin/open -n "$BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "RouteWeaver"' ;;
  *) echo "usage: $0 [run|--build-only|--verify|--debug|--logs]" >&2; exit 2 ;;
esac
