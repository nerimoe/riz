#!/bin/sh
set -eu

SOURCE="${1:-./rizd}"
BIN="$HOME/.local/bin/rizd"
PLIST="$HOME/Library/LaunchAgents/dev.riz.rizd.plist"
NEW_BIN="$HOME/.local/bin/.rizd.new"
OLD_BIN="$HOME/.local/bin/.rizd.previous"
OLD_PLIST="$HOME/Library/LaunchAgents/.dev.riz.rizd.previous.plist"
PLIST_SOURCE="$(dirname "$0")/dev.riz.rizd.plist"

test "$(uname -s)" = Darwin || { echo "rizd v1 supports macOS only" >&2; exit 1; }
test -f "$SOURCE" || { echo "binary not found: $SOURCE" >&2; exit 1; }
test -f "$PLIST_SOURCE" || { echo "LaunchAgent template not found: $PLIST_SOURCE" >&2; exit 1; }
if [ -n "${RIZ_SHA256:-}" ]; then
  echo "$RIZ_SHA256  $SOURCE" | shasum -a 256 -c -
fi
if [ "${RIZ_ALLOW_UNSIGNED:-0}" != 1 ]; then
  codesign --verify --strict "$SOURCE"
fi
"$SOURCE" --version >/dev/null

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/.riz"
rm -f "$NEW_BIN" "$OLD_BIN" "$OLD_PLIST"
install -m 755 "$SOURCE" "$NEW_BIN"
if [ -f "$BIN" ]; then cp -p "$BIN" "$OLD_BIN"; fi
if [ -f "$PLIST" ]; then cp -p "$PLIST" "$OLD_PLIST"; fi
mv "$NEW_BIN" "$BIN"

if [ ! -f "$HOME/.riz/config.json" ]; then
  "$BIN" init
fi

sed "s|__HOME__|$HOME|g" "$PLIST_SOURCE" > "$PLIST.new"
mv "$PLIST.new" "$PLIST"
launchctl bootout "gui/$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  if [ -f "$OLD_BIN" ]; then mv "$OLD_BIN" "$BIN"; else rm -f "$BIN"; fi
  if [ -f "$OLD_PLIST" ]; then mv "$OLD_PLIST" "$PLIST"; else rm -f "$PLIST"; fi
  if [ -f "$PLIST" ]; then launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true; fi
  echo "rizd failed to start; the previous installation was restored" >&2
  exit 1
fi
launchctl enable "gui/$(id -u)/dev.riz.rizd"
rm -f "$OLD_BIN" "$OLD_PLIST"
echo "rizd installed at $BIN"
