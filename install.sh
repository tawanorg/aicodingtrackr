#!/bin/bash
# AI Coding Trackr — one-command installer.
#
# Builds from source on your machine. That is deliberate: a locally built binary
# is not quarantined, so there is no Gatekeeper warning and no need for a paid
# Apple Developer signature.
set -euo pipefail

REPO="https://github.com/tawanorg/aicodingtrackr.git"
SRC="${AICODINGTRACKR_SRC:-$HOME/.aicodingtrackr/src}"
DEST="/Applications/Trackr.app"

say()  { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31m%s\033[0m\n" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "macOS only for now. Windows is tracked at $REPO/issues"

if ! command -v swift >/dev/null 2>&1; then
  say "Swift is required. Installing Apple's command line tools…"
  xcode-select --install 2>/dev/null || true
  fail "Re-run this script once the Command Line Tools install finishes."
fi

if [ -d "$SRC/.git" ]; then
  say "Updating source…"
  git -C "$SRC" pull --ff-only --quiet
else
  say "Fetching source…"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --quiet "$REPO" "$SRC"
fi

say "Building…"
cd "$SRC"
./bundle.sh release >/dev/null

say "Installing to $DEST…"
rm -rf "$DEST"
cp -R build/Trackr.app "$DEST"
open "$DEST"

say ""
say "Done — look for the quota strip in your menu bar."
say ""
say "Start it automatically at login:"
say "  $SRC/install-login-item.sh"
