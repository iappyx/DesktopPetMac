#!/bin/bash
# Builds DesktopPet.app (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN=".build/release/DesktopPet"
APP="DesktopPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DesktopPet"
# Drop the debug symbol table: it embeds absolute build paths (including the macOS user name).
strip -S "$APP/Contents/MacOS/DesktopPet"
# The icon is generated from the upstream pet icon by Resources/make-icon.py (needs Pillow and internet);
# an earlier generated icon is kept if that fails, otherwise the app is built without one.
ICON="Resources/DesktopPet.icns"
if [ ! -f "$ICON" ] || [ Resources/make-icon.py -nt "$ICON" ]; then
    python3 Resources/make-icon.py || echo "warning: could not generate $ICON (offline, or pip3 install pillow)"
fi
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DesktopPet</string>
    <key>CFBundleDisplayName</key><string>Desktop Pet</string>
    <key>CFBundleIdentifier</key><string>org.desktoppet.mac</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleExecutable</key><string>DesktopPet</string>
    <key>CFBundleIconFile</key><string>DesktopPet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
touch "$APP"
echo "Built $APP"
