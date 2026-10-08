#!/bin/bash
# Regenerates Resources/Trackr.icns from Tools/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swiftc -O Tools/make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/Trackr.iconset"
mkdir -p Resources
iconutil -c icns "$TMP/Trackr.iconset" -o Resources/Trackr.icns
rm -rf "$TMP"
echo "wrote Resources/Trackr.icns"
