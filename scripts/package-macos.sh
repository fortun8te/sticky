#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Do not sign a runnable bundle inside Documents when it is iCloud/FileProvider
# managed: Finder can add metadata after signing and invalidate the resource seal.
# A per-user Applications folder is local, launchable, and needs no administrator.
OUTPUT_DIR="${STICKY_OUTPUT_DIR:-$HOME/Applications}"
APP="$OUTPUT_DIR/Sticky.app"
ICON_SOURCE="$ROOT/assets/sticky-app-icon.svg"
RENDERED_PNG=""

cd "$ROOT/macos"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/Sticky"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Sticky"
mkdir -p "$APP/Contents/Resources"
if [ -f "$ICON_SOURCE" ]; then
  ICON_TEMP="$(mktemp -d)"
  ICONSET="$ICON_TEMP/Sticky.iconset"
  ICON_PNG="$ICON_TEMP/source.png"
  mkdir -p "$ICONSET"

  if command -v qlmanage >/dev/null 2>&1; then
    qlmanage -t -s 1024 -o "$ICON_TEMP" "$ICON_SOURCE" >/dev/null 2>&1
    RENDERED_PNG="$ICON_TEMP/$(basename "$ICON_SOURCE").png"
  fi

  if [ -n "$RENDERED_PNG" ] && [ -s "$RENDERED_PNG" ]; then
    cp "$RENDERED_PNG" "$ICON_PNG"
  else
    sips -s format png "$ICON_SOURCE" --out "$ICON_PNG" >/dev/null
  fi
  for spec in '16 icon_16x16.png' '32 icon_16x16@2x.png' '32 icon_32x32.png' '64 icon_32x32@2x.png' '128 icon_128x128.png' '256 icon_128x128@2x.png' '256 icon_256x256.png' '512 icon_256x256@2x.png' '512 icon_512x512.png' '1024 icon_512x512@2x.png'; do
    set -- $spec
    sips -z "$1" "$1" "$ICON_PNG" --out "$ICONSET/$2" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Sticky.icns"
  rm -rf "$ICON_TEMP"
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Sticky</string>
  <key>CFBundleIdentifier</key><string>local.sticky.app</string>
  <key>CFBundleName</key><string>Sticky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>Sticky</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Sticky finds your paired computer on your private network so it can send files and text directly.</string>
  <key>NSHumanReadableCopyright</key><string>Local-first transfer. No telemetry.</string>
</dict>
</plist>
PLIST

# Documents may be iCloud/FileProvider-backed. Writing Info.plist can add
# Finder/FileProvider metadata after the first cleanup, which invalidates the
# resource seal. Strip it immediately before signing and prove the result.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Packaged $APP"
