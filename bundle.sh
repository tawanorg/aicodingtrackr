#!/bin/bash
# Wraps the SwiftPM executable in a .app bundle. MenuBarExtra needs a bundle with
# LSUIElement set, otherwise macOS gives the process a Dock icon and a main menu.
set -euo pipefail

CONFIG="${1:-release}"
APP="build/Trackr.app"

swift build -c "$CONFIG" --product TrackrBar
swift build -c "$CONFIG" --product trackr
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TrackrBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Trackr"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>Trackr</string>
  <key>CFBundleDisplayName</key>      <string>AI Coding Trackr</string>
  <key>CFBundleIdentifier</key>       <string>org.tawanorg.aicodingtrackr</string>
  <key>CFBundleExecutable</key>       <string>Trackr</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <!-- Agent app: menu bar only, no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>              <true/>
</dict>
</plist>
PLIST

# Ad-hoc signing gives the bundle a stable identity, which is what the Keychain
# ACL binds its consent to. Without it every rebuild re-prompts for access.
codesign --force --sign - --identifier org.tawanorg.aicodingtrackr "$APP" >/dev/null 2>&1 \
  || echo "warning: ad-hoc signing failed; Keychain may re-prompt each launch"

# The CLI reads the same Keychain item. Signing it with a stable identifier means
# macOS asks for consent once rather than on every rebuild, since an unsigned
# binary gets a fresh identity each time it is compiled.
CLI="$(swift build -c "$CONFIG" --show-bin-path)/trackr"
if [ -f "$CLI" ]; then
  codesign --force --sign - --identifier org.tawanorg.aicodingtrackr.cli "$CLI" >/dev/null 2>&1 \
    || echo "warning: could not sign the CLI; it may re-prompt for Keychain access"
fi

echo "built $APP"
