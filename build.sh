#!/bin/zsh
# Builds Mandarin.app and installs it into /Applications (or ~/Applications if not writable).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Mandarin"

APP="build/Mandarin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mandarin"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift tools/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mandarin</string>
  <key>CFBundleDisplayName</key><string>Мандарин</string>
  <key>CFBundleIdentifier</key><string>uz.oybek.mandarin</string>
  <key>CFBundleExecutable</key><string>Mandarin</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Мандарин сохраняет сконвертированные файлы рядом с оригиналом.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Мандарин сохраняет сконвертированные файлы рядом с оригиналом.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Мандарин сохраняет сконвертированные файлы рядом с оригиналом.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

DEST="/Applications"
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Mandarin 2>/dev/null || true
rm -rf "$DEST/Mandarin.app"
cp -R "$APP" "$DEST/"
open "$DEST/Mandarin.app"
echo "Installed and launched: $DEST/Mandarin.app"
