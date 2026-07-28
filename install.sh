#!/bin/sh
set -eu

REPO="${RIZ_REPO:-nerimoe/riz}"
VERSION="${RIZ_VERSION:-latest}"
INSTALL_DIR="${RIZ_INSTALL_DIR:-$HOME/.local/bin}"
BIN="$INSTALL_DIR/rizd"
DATA_DIR="${RIZ_HOME:-$HOME/.riz}"
LISTEN="${RIZ_LISTEN:-127.0.0.1:7497}"
TOKEN="${RIZ_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
TMP_DIR="${TMPDIR:-/tmp}/riz-install-$$"
NEW_BIN="$TMP_DIR/rizd"
OLD_BIN="$TMP_DIR/rizd.previous"
INIT_OUTPUT="$TMP_DIR/init-output"
SERVICE_FILE=
HAD_SERVICE=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "riz: $*" >&2
  exit 1
}

command -v uname >/dev/null 2>&1 || fail "uname is required"

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS:$ARCH" in
  Linux:x86_64|Linux:amd64) TARGET=x86_64-unknown-linux-gnu ;;
  Linux:aarch64|Linux:arm64) TARGET=aarch64-unknown-linux-gnu ;;
  Darwin:x86_64|Darwin:amd64) TARGET=x86_64-apple-darwin ;;
  Darwin:arm64|Darwin:aarch64) TARGET=aarch64-apple-darwin ;;
  *) fail "unsupported platform: $OS $ARCH" ;;
esac

if [ -n "${RIZ_DOWNLOAD_BASE:-}" ]; then
  BASE=${RIZ_DOWNLOAD_BASE%/}
elif [ "$VERSION" = latest ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$VERSION"
fi
ASSET="rizd-$TARGET"
URL="$BASE/$ASSET"

mkdir -p "$TMP_DIR" "$INSTALL_DIR" "$DATA_DIR"

download() {
  source_url=$1
  destination=$2
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$TOKEN" ]; then
      curl -fL --retry 3 --connect-timeout 15 \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/octet-stream" \
        "$source_url" -o "$destination"
    else
      curl -fL --retry 3 --connect-timeout 15 "$source_url" -o "$destination"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "$TOKEN" ]; then
      wget --header="Authorization: Bearer $TOKEN" \
        --header="Accept: application/octet-stream" \
        -O "$destination" "$source_url"
    else
      wget -O "$destination" "$source_url"
    fi
  else
    fail "curl or wget is required"
  fi
}

echo "Downloading $ASSET from $REPO..."
download "$URL" "$NEW_BIN" || fail "download failed: $URL"
download "$URL.sha256" "$TMP_DIR/$ASSET.sha256" || \
  fail "checksum download failed: $URL.sha256"

EXPECTED=$(awk 'NR==1 {print $1}' "$TMP_DIR/$ASSET.sha256")
[ -n "$EXPECTED" ] || fail "empty checksum"
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$NEW_BIN" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$NEW_BIN" | awk '{print $1}')
else
  fail "sha256sum or shasum is required"
fi
[ "$ACTUAL" = "$EXPECTED" ] || fail "checksum mismatch for $ASSET"

chmod 755 "$NEW_BIN"
"$NEW_BIN" --version >/dev/null || fail "downloaded binary cannot run"

had_binary=0
if [ -f "$BIN" ]; then
  cp -p "$BIN" "$OLD_BIN"
  had_binary=1
fi
install -m 755 "$NEW_BIN" "$BIN"

created_config=0
if [ ! -f "$DATA_DIR/config.json" ]; then
  if ! RIZ_HOME="$DATA_DIR" "$BIN" init --listen "$LISTEN" >"$INIT_OUTPUT"; then
    [ "$had_binary" -eq 0 ] || mv "$OLD_BIN" "$BIN"
    [ "$had_binary" -eq 1 ] || rm -f "$BIN"
    fail "rizd initialization failed"
  fi
  created_config=1
fi

install_linux_service() {
  command -v systemctl >/dev/null 2>&1 || fail "systemctl is required on Linux"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  UNIT="$UNIT_DIR/rizd.service"
  SERVICE_FILE=$UNIT
  mkdir -p "$UNIT_DIR"
  if [ -f "$UNIT" ]; then
    cp -p "$UNIT" "$TMP_DIR/service.previous"
    HAD_SERVICE=1
  fi
  cat >"$UNIT.tmp" <<EOF
[Unit]
Description=Riz remote agent daemon
After=network.target

[Service]
Type=simple
ExecStart=$BIN serve
Environment=RIZ_HOME=$DATA_DIR
Environment=PATH=$INSTALL_DIR:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  mv "$UNIT.tmp" "$UNIT"
  systemctl --user daemon-reload || return 1
  systemctl --user enable --now rizd.service || return 1
}

install_macos_service() {
  command -v launchctl >/dev/null 2>&1 || fail "launchctl is required on macOS"
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST="$PLIST_DIR/dev.riz.rizd.plist"
  SERVICE_FILE=$PLIST
  mkdir -p "$PLIST_DIR"
  if [ -f "$PLIST" ]; then
    cp -p "$PLIST" "$TMP_DIR/service.previous"
    HAD_SERVICE=1
  fi
  cat >"$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.riz.rizd</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>RIZ_HOME</key><string>$DATA_DIR</string>
    <key>PATH</key><string>$INSTALL_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DATA_DIR/rizd.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/rizd.err.log</string>
</dict>
</plist>
EOF
  mv "$PLIST.tmp" "$PLIST"
  launchctl bootout "gui/$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || return 1
  launchctl enable "gui/$(id -u)/dev.riz.rizd" || return 1
}

rollback_service() {
  if [ "$HAD_SERVICE" -eq 1 ]; then
    mv "$TMP_DIR/service.previous" "$SERVICE_FILE"
  elif [ -n "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
  fi
  if [ "$OS" = Linux ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [ "$HAD_SERVICE" -eq 1 ]; then
      systemctl --user enable --now rizd.service >/dev/null 2>&1 || true
    fi
  else
    launchctl bootout "gui/$(id -u)/dev.riz.rizd" >/dev/null 2>&1 || true
    if [ "$HAD_SERVICE" -eq 1 ]; then
      launchctl bootstrap "gui/$(id -u)" "$SERVICE_FILE" >/dev/null 2>&1 || true
    fi
  fi
}

service_ok=1
if [ "$OS" = Linux ]; then
  install_linux_service || service_ok=0
else
  install_macos_service || service_ok=0
fi

if [ "$service_ok" -ne 1 ]; then
  rollback_service
  if [ "$had_binary" -eq 1 ]; then mv "$OLD_BIN" "$BIN"; else rm -f "$BIN"; fi
  if [ "$created_config" -eq 1 ]; then rm -f "$DATA_DIR/config.json"; fi
  fail "service installation failed"
fi

echo
echo "rizd installed: $BIN"
echo "Endpoint: ws://$LISTEN/ws"
if [ "$created_config" -eq 1 ]; then
  echo
  cat "$INIT_OUTPUT"
else
  echo "Existing configuration kept at $DATA_DIR/config.json"
  echo "Use 'rizd token rotate' to generate a new token."
fi
