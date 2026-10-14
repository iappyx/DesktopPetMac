#!/bin/bash
# Builds DesktopPet.app (release, universal: Apple Silicon + Intel) next to this script.
# VERSION overrides the app version; the release workflow sets it from the git tag (v1.5.0 -> 1.5.0).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.5.0}"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/DesktopPet"
APP="DesktopPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DesktopPet"
# Drop the debug symbol table: it embeds absolute build paths (including the macOS user name).
strip -S "$APP/Contents/MacOS/DesktopPet"
cp LICENSE "$APP/Contents/Resources/LICENSE"
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
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
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
echo "Built $APP (version $VERSION)"
