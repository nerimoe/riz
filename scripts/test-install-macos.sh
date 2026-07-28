#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"

cat > "$TMP/bin/codesign" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/sh
if [ "$1" = bootstrap ] && [ "${FAIL_BOOTSTRAP:-0}" = 1 ]; then exit 1; fi
exit 0
EOF
chmod +x "$TMP/bin/codesign" "$TMP/bin/launchctl"

make_binary() {
  version="$1"
  destination="$2"
  sed "s/__VERSION__/$version/g" > "$destination" <<'EOF'
#!/bin/sh
case "${1:-}" in
  --version) echo "rizd __VERSION__" ;;
  init)
    mkdir -p "$HOME/.riz"
    printf '{"test":true}\n' > "$HOME/.riz/config.json"
    echo 'Token: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$destination"
}

make_binary v1 "$TMP/rizd-v1"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" RIZ_ALLOW_UNSIGNED=1 \
  "$ROOT/scripts/install-macos.sh" "$TMP/rizd-v1"
test "$(HOME="$TMP/home" "$TMP/home/.local/bin/rizd" --version)" = "rizd v1"
test -f "$TMP/home/.riz/config.json"
test -f "$TMP/home/Library/LaunchAgents/dev.riz.rizd.plist"

make_binary v2 "$TMP/rizd-v2"
if HOME="$TMP/home" PATH="$TMP/bin:$PATH" RIZ_ALLOW_UNSIGNED=1 FAIL_BOOTSTRAP=1 \
  "$ROOT/scripts/install-macos.sh" "$TMP/rizd-v2"; then
  echo "upgrade unexpectedly succeeded" >&2
  exit 1
fi
test "$(HOME="$TMP/home" "$TMP/home/.local/bin/rizd" --version)" = "rizd v1"

HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$ROOT/scripts/uninstall-macos.sh"
test ! -e "$TMP/home/.local/bin/rizd"
test ! -e "$TMP/home/Library/LaunchAgents/dev.riz.rizd.plist"
test -f "$TMP/home/.riz/config.json"

echo "macOS installer integration test passed"
