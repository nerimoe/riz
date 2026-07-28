# Riz

Riz is a self-hosted Flutter client and Linux/macOS daemon for remotely controlling AI coding agents.

Its user-facing data model is intentionally small: a daemon has optional named
projects, projects bind zero or more folders, and sessions may live inside a
project or remain unbound as quick chats. See
[`docs/domain-model.md`](docs/domain-model.md) for the normative model.

## Components

- `crates/rizd`: Tokio/Axum/SQLite daemon for Linux and macOS
- `crates/riz_protocol`: versioned JSON and binary WebSocket protocol
- `apps/riz_app`: Flutter Web/iOS/Android client
- `install.sh` / `uninstall.sh`: user-level systemd and launchd installation
- `scripts`: installer tests and compatibility helpers

Riz stores daemon-owned state in `~/.riz`. The client stores only daemon connection records, tokens, and UI preferences.

## Quick start

```sh
cargo test --workspace
cargo run -p rizd -- init
cargo run -p rizd -- serve

cd apps/riz_app
flutter pub get
flutter run -d chrome
```

To install the latest release daemon for the current architecture:

```sh
./install.sh
```

The installer downloads and verifies `rizd`, installs it at
`~/.local/bin/rizd`, initializes `~/.riz`, prints the bearer token once, and
starts a user service with systemd on Linux or launchd on macOS. It supports:

- `RIZ_VERSION=vX.Y.Z` to install a specific release.
- `RIZ_REPO=owner/repository` to use another GitHub repository.
- `RIZ_GITHUB_TOKEN` for private repositories.
- `RIZ_DOWNLOAD_BASE` for a release mirror or local test fixture.
- `RIZ_LISTEN`, `RIZ_HOME`, and `RIZ_INSTALL_DIR` to override installation defaults.

Add `ws://127.0.0.1:7497/ws` for local testing, or the WSS URL supplied by
your tunnel. Automatic GitHub releases currently contain Linux x86_64 and
ARM64 binaries only. The macOS installer path is supported, but a matching
`rizd-aarch64-apple-darwin` or `rizd-x86_64-apple-darwin` asset must be added to
the release separately.

Uninstall the service and binary while preserving data:

```sh
./uninstall.sh
```

Delete configuration, token, sessions, and logs as well:

```sh
./uninstall.sh --purge
```

Antigravity CLI can be installed with the official cask:

```sh
brew install --cask antigravity-cli
agy --help
```

Do not install the unrelated npm package named `agy`.

## Security

The daemon has the same filesystem and command permissions as its macOS user. It listens on loopback by default and does not provide TLS, a relay, or an account system. Use a trusted TLS tunnel for remote access, keep the token out of URLs, and rotate it with `rizd token rotate` if exposed.

The Web client must be served over HTTPS when used remotely so browser secure storage and WSS are available. Third-party control of Antigravity may violate Google terms; the UI displays this warning and the provider falls back to plain text when private formats are incompatible.

## Smoke test

With `rizd` running, binary upload and authenticated request handling can be checked with:

```sh
cd apps/riz_app
dart run tool/daemon_smoke.dart ws://127.0.0.1:7497/ws TOKEN /tmp/riz-smoke.txt
```

The daemon listens on `127.0.0.1:7497` by default. Put it behind a TLS-enabled tunnel before exposing it outside the machine.

## Status

Riz is under active development. The Antigravity provider uses undocumented local conversation formats and may fall back to plain text when an incompatible CLI version is detected.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
