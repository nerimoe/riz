#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

make_fixture() {
  platform=$1
  arch=$2
  target=$3
  fixture="$TMP/$platform-$arch"
  mkdir -p "$fixture/bin" "$fixture/releases"
  cat >"$fixture/releases/rizd-$target" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "rizd test" ;;
  init)
    mkdir -p "$RIZ_HOME"
    echo '{"test":true}' > "$RIZ_HOME/config.json"
    echo 'Riz daemon initialized'
    echo 'Token: test-token'
    ;;
  serve) exit 0 ;;
esac
EOF
  chmod +x "$fixture/releases/rizd-$target"
  sha256sum "$fixture/releases/rizd-$target" > "$fixture/releases/rizd-$target.sha256"
  cat >"$fixture/bin/uname" <<EOF
#!/bin/sh
if [ "\${1:-}" = -s ]; then echo "$platform"; else echo "$arch"; fi
EOF
  chmod +x "$fixture/bin/uname"
  echo "$fixture"
}

linux=$(make_fixture Linux x86_64 x86_64-unknown-linux-gnu)
cat >"$linux/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
EOF
chmod +x "$linux/bin/systemctl"
HOME="$linux/home" XDG_CONFIG_HOME="$linux/home/.config" PATH="$linux/bin:$PATH" \
  RIZ_DOWNLOAD_BASE="file://$linux/releases" \
  "$ROOT/install.sh" >"$linux/install.log"
test -x "$linux/home/.local/bin/rizd"
test -f "$linux/home/.config/systemd/user/rizd.service"
grep -q 'enable --now rizd.service' "$linux/home/systemctl.log"
grep -q 'Token: test-token' "$linux/install.log"
HOME="$linux/home" XDG_CONFIG_HOME="$linux/home/.config" PATH="$linux/bin:$PATH" \
  "$ROOT/uninstall.sh"
test ! -e "$linux/home/.local/bin/rizd"
test -f "$linux/home/.riz/config.json"
HOME="$linux/home" XDG_CONFIG_HOME="$linux/home/.config" PATH="$linux/bin:$PATH" \
  "$ROOT/uninstall.sh" --purge
test ! -e "$linux/home/.riz"
cat >"$linux/bin/systemctl" <<'EOF'
#!/bin/sh
if [ "${2:-}" = enable ]; then exit 1; fi
exit 0
EOF
chmod +x "$linux/bin/systemctl"
if HOME="$linux/home" XDG_CONFIG_HOME="$linux/home/.config" PATH="$linux/bin:$PATH" \
  RIZ_DOWNLOAD_BASE="file://$linux/releases" \
  "$ROOT/install.sh" >/dev/null 2>&1; then
  echo "installer unexpectedly succeeded with a failing systemd service" >&2
  exit 1
fi
test ! -e "$linux/home/.local/bin/rizd"
test ! -e "$linux/home/.config/systemd/user/rizd.service"
test ! -e "$linux/home/.riz/config.json"

mac=$(make_fixture Darwin arm64 aarch64-apple-darwin)
cat >"$mac/bin/launchctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/launchctl.log"
EOF
chmod +x "$mac/bin/launchctl"
HOME="$mac/home" PATH="$mac/bin:$PATH" \
  RIZ_DOWNLOAD_BASE="file://$mac/releases" \
  "$ROOT/install.sh" >"$mac/install.log"
test -x "$mac/home/.local/bin/rizd"
test -f "$mac/home/Library/LaunchAgents/dev.riz.rizd.plist"
grep -q 'bootstrap gui/' "$mac/home/launchctl.log"
grep -q 'Token: test-token' "$mac/install.log"
HOME="$mac/home" PATH="$mac/bin:$PATH" "$ROOT/uninstall.sh"
test ! -e "$mac/home/.local/bin/rizd"
test -f "$mac/home/.riz/config.json"

echo "cross-platform installer tests passed"
