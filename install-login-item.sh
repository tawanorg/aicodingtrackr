#!/bin/bash
# KeepTrack can only capture an account's reading while it is running, because the
# CLIs overwrite their credentials on login. Starting at login is what makes the
# multi-account history accumulate instead of showing gaps.
set -euo pipefail

# Prefer the installed copy; fall back to a local build.
if [ -d "/Applications/Trackr.app" ]; then
  APP="/Applications/Trackr.app"
else
  APP="$(cd "$(dirname "$0")" && pwd)/build/Trackr.app"
fi
PLIST="$HOME/Library/LaunchAgents/org.tawanorg.aicodingtrackr.plist"

[ -d "$APP" ] || { echo "not installed. run ./install.sh (or ./bundle.sh release)"; exit 1; }
mkdir -p "$(dirname "$PLIST")"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>org.tawanorg.aicodingtrackr</string>
  <key>ProgramArguments</key>  <array><string>$APP/Contents/MacOS/Trackr</string></array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
</dict>
</plist>
PL

launchctl bootout "gui/$UID/org.tawanorg.aicodingtrackr" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "installed: starts at login, restarts if it dies"
echo "remove with: launchctl bootout gui/$UID/org.tawanorg.aicodingtrackr && rm $PLIST"
