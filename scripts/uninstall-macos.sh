#!/bin/sh
set -eu

PLIST="$HOME/Library/LaunchAgents/dev.riz.rizd.plist"
launchctl bootout "gui/$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
rm -f "$PLIST" "$HOME/.local/bin/rizd"
echo "rizd uninstalled. Data remains in $HOME/.riz"
