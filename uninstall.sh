#!/bin/sh
set -eu

INSTALL_DIR="${RIZ_INSTALL_DIR:-$HOME/.local/bin}"
BIN="$INSTALL_DIR/rizd"
DATA_DIR="${RIZ_HOME:-$HOME/.riz}"
PURGE=0

usage() {
  echo "Usage: $0 [--purge]"
  echo "  --purge  also delete Riz configuration, token, sessions, and logs"
}

case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 64; }

OS=$(uname -s)
case "$OS" in
  Linux)
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user disable --now rizd.service >/dev/null 2>&1 || true
      rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rizd.service"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user reset-failed rizd.service >/dev/null 2>&1 || true
    fi
    ;;
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/dev.riz.rizd.plist"
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
    fi
    rm -f "$PLIST"
    ;;
  *) echo "riz: unsupported platform: $OS" >&2; exit 1 ;;
esac

rm -f "$BIN"
if [ "$PURGE" -eq 1 ]; then
  rm -rf "$DATA_DIR"
  echo "rizd and all Riz user data were removed."
else
  echo "rizd was removed. Data remains in $DATA_DIR"
fi
