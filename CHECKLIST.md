# Riz Completion Checklist

## Worker Relay And Pairing (2026-07-29)

- [x] Added and deployed a Cloudflare Worker plus SQLite Durable Object relay
  at `riz-relay.zzx2022766809.workers.dev`; credentials stay out of URLs.
- [x] Added four independent outbound relay channels per daemon so simultaneous
  clients receive separate authenticated local WebSocket sessions.
- [x] Added `rizd relay configure/status/disable`, versioned `riz1...` pairing
  codes, Rustls WSS support, reconnect backoff, and `0600` config permissions.
- [x] Added Flutter pairing-code-first connection UI. Daemon and relay tokens
  are stored separately in secure storage; manual URL/token entry remains
  available in a collapsed section.
- [x] Changed macOS `install.sh` to compile from source locally. Fresh Linux and
  macOS installs configure the relay and print a pairing code before starting
  the user service; existing installations retain their relay credentials.
- [x] Added Worker unit/integration tests and an Ubuntu CI job. The Worker DO
  tests cover credential rejection, daemon availability, text/binary forwarding,
  and simultaneous channel isolation.
- [x] Installed the current release build on this Mac, restarted LaunchAgent,
  and verified the real pairing code through the deployed Worker with native
  WebSocket and Flutter Web clients.
- [x] Deployed Flutter Web build `1.0.0+8` to `riz.neri.moe`; the real browser
  shows the version, connected daemon, 32% quota, and restored quick-chat history.
- [x] Final validation: 45 Rust tests, warning-free Clippy, 29 Flutter tests,
  Flutter Wasm release build, 6 Worker tests, cross-platform installer tests,
  and public Worker/Pages endpoint checks.

## Automated Releases And Updates

- [x] Public GitHub repository with Ubuntu-only CI runners
- [x] Stable release when the workspace version exceeds the latest stable release
- [x] Commit-suffixed prerelease for subsequent pushes at the same or lower version
- [x] Linux x86_64 and ARM64 release assets with SHA-256 files
- [x] Daemon stable/prerelease update checks through the authenticated WebSocket API
- [x] Verified atomic daemon replacement and scheduled systemd/launchd restart
- [x] Flutter settings controls for channel selection, update checks, and installation

## Current Domain Model Baseline (2026-07-28)

This section supersedes older historical entries that mention primary folders,
hidden temporary projects, or using a user folder as the CLI cwd. The normative
design is `docs/domain-model.md` v2.

- [x] Replaced the primary/additional folder model with peer project folders.
  Folder order is display-only; every bound folder is passed to agy as a
  repeated `--add-dir` argument.
- [x] Added a stable project runtime at
  `~/.riz/projects/<project-id>/runtime`; all project sessions use it as cwd.
  Unbound quick chats use `~/.riz/sessions/<session-id>/runtime`.
- [x] Added the Riz-managed minimal `AGENTS.md` to both runtime types. It only
  states that the directory is for runtime, temporary, and generated files and
  is not an existing project or source repository. It does not duplicate the
  bound-folder list.
- [x] Removed `is_primary`, `isPrimary`, `primaryPath`, the set-primary RPC, and
  all primary-folder controls and labels from daemon and Flutter.
- [x] Kept agy workspace identity stable while folders are added or removed.
  Project sessions scope the opaque agy project binding to the Riz project;
  unbound sessions scope it to the session. Riz still rejects unexpected agy
  playground creation.
- [x] Added provider conversation lineage with cwd, additional-directory, and
  provider-workspace snapshots. Moving a session or detaching its project
  supersedes the active conversation with an explicit reason while preserving
  the old external ID for audit and continuation history.
- [x] Added transactional project removal modes `detach_sessions` and
  `delete_sessions`, plus `session.delete`. Managed runtime/session directories
  are path-validated before deletion; user-bound folders are never deleted.
- [x] Kept new sessions as local Flutter drafts. The draft remains selected
  until its first message is successfully queued; upload or send failure removes
  the materialized daemon session and its managed directory, leaving the draft
  intact for retry.
- [x] Project Files and Terminal now use the stable project runtime even for a
  zero-folder project. Project Skills exposes a folder selector across peer
  folders and never treats runtime as a skill source.
- [x] Materialized quick chats expose Chat, Files, and Terminal using their
  session runtime. An unsent quick-chat draft remains chat-only because no
  daemon session directory exists yet.
- [x] Real in-app-browser regression against a fresh schema-v4 daemon created a
  zero-folder project, opened its Files tab at the returned `runtimePath`, and
  displayed the managed `AGENTS.md`. Opening Quick chat showed the local draft
  immediately while SQLite still contained zero sessions. The browser console
  contained no warnings or errors. This pass caught and fixed a missing
  `runtimePath` field in hydrated project snapshots.
- [x] Rewrote `docs/domain-model.md` around stable runtimes, peer folders,
  unbound sessions, deletion semantics, provider lineage, and the agy CLI
  mapping. No old-database migration was added because Riz is not deployed;
  the daemon explicitly rejects pre-release schema versions.
- [x] Validation after this change: Rust fmt, workspace clippy with warnings
  denied, 39 daemon tests plus the protocol test; Flutter analyze, 23 tests,
  and JavaScript Web release build. The existing `isolate_contactor`
  `dart:html` Wasm dry-run warning remains unchanged.

## Distribution Baseline (2026-07-28)

- [x] Added root `install.sh` for Linux and macOS. It detects x86_64/ARM64,
  downloads the matching GitHub release asset and SHA-256 file, installs to
  `~/.local/bin/rizd`, initializes `~/.riz`, prints the first token, and starts
  a user-level systemd or launchd service.
- [x] Added root `uninstall.sh`. The default removes only the service and
  binary; `--purge` explicitly removes configuration, token, sessions, and
  logs as well.
- [x] Added isolated Linux/macOS installer tests covering service generation,
  initial token output, default data retention, purge, and rollback when
  systemd startup fails.
- [x] Moved every GitHub Actions job to Ubuntu. Tagged releases build only
  `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnu` daemon binaries;
  CI no longer builds or signs macOS binaries.
- [x] Documented private-repository tokens, version/repository/mirror
  overrides, service locations, uninstall behavior, and the requirement to
  attach macOS release binaries separately if macOS downloads are desired.

## Historical Execution Record (Before This Checklist Existed)

This section backfills work completed from the start of the original browser
debugging goal through the point when this checklist became mandatory. It is a
record of observed implementation and verification, not a substitute for the
remaining unchecked release gates below.

### Completed implementation and fixes

- Established the Flutter/Rust monorepo flow around the fixed hierarchy
  `Daemon -> Project (absolute directory) -> Session (agent conversation)` and
  persisted projects, sessions, messages, structured events, and agent
  conversation IDs under the daemon's SQLite-backed Riz home.
- Added the `agy` provider as an interactive PTY integration, including new and
  resumed conversations, streamed text, structured thinking/tool events,
  permission requests, slash commands, skills, attachments, and `/usage` quota
  collection. Quota remained an `agy-pty` flow and did not read Google Cloud
  Code or Keychain credentials directly.
- Implemented permission modes `ask`, `workspace`, and `full`. Workspace mode
  automatically approves ordinary edits inside the selected project while
  keeping terminal and outside-project actions gated; full mode requires an
  explicit UI confirmation before passing the unsafe CLI flag.
- Fixed the stop/cancel race: session and message state is committed as
  `cancelled` before killing the provider, late PTY output is discarded, and a
  cancelled turn can no longer become `completed` or save the raw agy login
  banner as an assistant response.
- Implemented queued follow-up messages, withdrawal of a queued message, stop
  of the active turn, daemon-restart interruption handling, and preservation of
  the same agent conversation for later continuation.
- Implemented whole-machine file browsing plus project file create, read,
  revision-checked atomic save, rename, delete, `rg` search, Git diff, upload,
  image preview, and download. Web upload/download was moved from the broken
  `file_picker` Web plugin path to conditional standard browser File API and
  Blob implementations.
- Added `fs.download` binary WebSocket transfers with 256 KiB chunks, a 25 MiB
  default limit, transfer metadata, MIME/name/revision fields, and Flutter-side
  binary collection. Upload and download actions now show explicit Snackbars.
- Implemented reconnectable PTY terminal tabs with input, resize, a 2 MiB
  output replay buffer, switching, close, and accurate non-survival semantics
  across daemon restarts.
- Implemented global and project skill management: validated `SKILL.md`
  creation/editing, enable/disable, deletion, slash-panel invocation, local or
  Git URL installation, Git update, and source commit recording in
  `.riz-source.json`. Skill enabled state was made visible with an inline
  switch and disabled styling.
- Implemented agy history scanning/import, explicit project confirmation when
  needed, archived-session browsing/restoration, running-task display, quota
  display, daemon settings, and the third-party agy terms warning.
- Added Web localization delegates so `zh_CN` has Material and Cupertino
  localizations instead of raising `No MaterialLocalizations found`.
- Added WebSocket authentication with a five-second first-frame deadline,
  sequence replay and snapshot fallback, plus daemon token hashing/validation.
- Added persisted turn lifecycle, attachment metadata, and PTY metadata after
  the initial browser flows exposed gaps in restart and state reporting.
- Consolidated the wide-screen project/session navigation and verified that
  the resulting Flutter layout has no horizontal overflow at the required
  responsive widths. Several earlier layout iterations were superseded; do not
  treat those intermediate dimensions as current requirements.

### Real runtime and browser evidence

- Created the real project `Riz Full Flow` at `work/riz-full-e2e`, started agy
  conversation `308c02ec-f050-4c02-b06b-5402fe2381aa`, had agy read
  `README.md`, and create `notes/result.md`. Structured tool events and the
  final assistant response were present in SQLite.
- Restarted the release daemon and confirmed the project, session, history,
  conversation ID, and subsequent agy resume remained available in the Web UI.
- Exercised `ask`, `workspace`, and `full` permission controls in real Chrome.
  A deterministic `sleep 30` flow verified queue withdrawal and the corrected
  cancellation result (`session`, user message, and live assistant draft all
  ended `cancelled`).
- In real Chrome, created/read/edited/renamed/searched/diffed/deleted files,
  opened `notes/default.md`, and rendered the persisted JPEG
  `work/riz-browser-regression-20260727/riz-upload-test.jpg` as an image preview.
  An authenticated WebSocket download received exactly 165,523 bytes with
  matching SHA-256
  `e0d142f8a9b063266a6505bda1a544aac41bf090adeec2be2b3d6a6cf3785197`.
- Opened two real PTY tabs, verified project `pwd`, command input, file output,
  terminal switching, replay after switching, resize wiring, closing the second
  tab, and keeping the first tab usable.
- Created and toggled the `browser-e2e` project skill, selected it from the `/`
  command panel, and received `BROWSER_SKILL_OK` from agy. Installed the local
  Git fixture at commit `283dea054ffe88ecdd2c906662dff6ea9de76b38`, updated
  it to `c4d6e3781d16ceefe1e45454a844a17065053ef2`, and confirmed the v2
  content and recorded commit.
- Opened quota in Chrome and observed four agy `/usage` pools with source
  `agy-pty` and a last-success timestamp. Scanned existing Antigravity history,
  imported an untracked conversation into `Riz E2E`, and restored an archived
  Browser Regression session.
- Verified Web layout metrics at 390, 600, 840, and 1440 CSS pixels with no
  horizontal document overflow. Flutter widget tests cover the same widths.
- The latest recorded validation before this checklist consisted of Rust fmt,
  workspace tests and warning-free clippy; Flutter analyze, 12 tests, Web
  release build, Android debug APK; and the macOS installer
  install/rollback/uninstall integration flow. Later counts and additional
  validation are recorded in the live sections below.

### Historical development endpoints

- Local Web build: `http://127.0.0.1:8083`.
- Local daemon WebSocket: `ws://127.0.0.1:7497/ws`, using
  `RIZ_HOME=work/integration-riz-home-2` during integration runs.
- Temporary Cloudflare Web URL:
  `https://kentucky-explaining-ambient-readings.trycloudflare.com/`.
- Temporary Cloudflare daemon URL:
  `wss://edward-circuits-contracting-dallas.trycloudflare.com/ws`.
- The `trycloudflare.com` endpoints are ephemeral historical addresses and may
  no longer resolve. The bearer token is deliberately not copied into this
  repository; obtain or rotate the current token from the running daemon.

### Known limitations remaining at checklist creation

- A real non-default model selection and proof that the chosen model reaches
  agy had not yet been completed.
- Native file chooser injection through the Chrome extension returned
  `Not allowed`, and Computer Use could not operate the macOS picker while the
  Mac was locked. A prior real upload plus image preview and byte-for-byte
  binary download were verified, but the final release flow still needs a
  fresh upload/download pass where the environment permits it.
- Browser download events do not expose the dynamically created Flutter Web
  Blob link to the Chrome extension; UI feedback and the underlying binary
  transfer were verified separately.
- In-app-browser Flutter screenshots timed out, although viewport evaluation,
  Chrome visual inspection, widget tests, and overflow metrics succeeded.
- iOS could not be compiled because the machine only had Command Line Tools as
  the active developer directory and no full Xcode installation. Android was
  built only as a debug APK; release signing remained unconfigured.
- The JS Web release built successfully, but the Wasm dry run warned that
  `isolate_contactor` imports `dart:html`.
- Skill source metadata existed in `.riz-source.json` but was not yet mirrored
  into SQLite. WebSocket integration coverage still lacked simultaneous-client
  races and end-to-end 256 KiB binary chunk tests.
- The agy provider depends on private/unstable Antigravity output and database
  formats. Unknown versions require the diagnostic/plain-text fallback, and
  reliable turn-internal steering remains disabled by provider capability.
- Temporary historical test content included one pre-fix raw agy banner and a
  line joined by browser automation in `notes/result.md`; these do not prove a
  current product regression but should not be used as clean release fixtures.

This file is the authoritative progress ledger. Read it before continuing the
goal. Do not recreate it. After every code change or bug fix, update the change
log and the relevant verification item.

## Required Browser Flows

- [x] Connect Chrome Web client to the WSS daemon.
- [x] Create a project through the remote folder picker.
- [x] Create an agy session and receive a streamed response.
- [x] Resume the same agy conversation after restarting the daemon.
- [x] Exercise ask, workspace auto-approval, and full permission modes.
- [x] Queue and withdraw a follow-up; stop a running turn.
- [x] Create, read, edit, rename, search, diff, upload, preview, download, and
      delete files.
- [x] Create two PTY tabs, send input, resize, replay output, switch tabs, and
      close a terminal.
- [x] Create, edit, enable, disable, invoke, Git-install, and Git-update skills.
- [x] Display live agy quota from `/usage` without bypassing agy credentials.
- [x] Scan and import existing agy history into a confirmed project.
- [x] Select a non-default model in the Web UI and verify the selected model is
      passed to agy for a real turn.
  - [x] Release-daemon half verified independently: a turn requested
        `gemini-3.6-flash-low`, completed with `MODEL_SWITCH_OK`, and the same
        model identifier was present in agy conversation
        `e5ffb358-f0d4-4ba5-adb1-e24aa02ad546.db`.
  - [x] Final real-browser verification selected `gemini-3.6-flash-low` from
        the Web UI for session `daf0dad5-cfbb-4e1b-93a8-5f6618be9836`.
        Riz persisted the model in the user message, agy conversation
        `2e508822-e21a-4c12-9ba9-541962eebac0.db` contained the same model ID,
        and the turn returned `FINAL_MODEL_UI_OK` plus the README title.
- [x] Repeat the final end-to-end flow on the current release daemon and record
      browser console evidence.
  - [x] Fresh in-app browser created `Riz Final Release` through the remote
        folder picker, completed and resumed a real agy conversation, exercised
        file create/save/search/rename/delete, used two terminal tabs with input
        and replay, refreshed quota, and reloaded across a daemon restart.
  - [x] Final console audit contained two Flutter bootstrap debug messages and
        zero warnings or errors. SQLite independently confirmed the project,
        completed session, agy external ID, terminal lifecycle, and fixed
        terminal-to-project ownership.

## Implementation

### Domain Model V2

- [x] Use schema v2 as the only pre-release database format; reject old
      development databases instead of migrating them.
- [x] Persist optional projects with zero or more canonical folders and one
      primary folder when non-empty.
- [x] Persist unbound sessions with daemon-owned runtime, attachments, and
      artifacts directories.
- [x] Keep new sessions client-local until the first message materializes them.
- [x] Move sessions between projects and quick chats while preserving Riz
      history and resetting provider conversation context.
- [x] Snapshot cwd and additional directories on each turn.
- [x] Invalidate agy project bindings when project folders change.
- [x] Reject an agy-created playground or primary-workspace mapping that differs
      from the workspace supplied by Riz; pass other folders per turn with
      `--add-dir`.
- [x] Expose project create, rename, folder add/remove/set-primary, and session
      move controls in Flutter.
- [x] Verify a real unbound agy quick chat uses the Riz session runtime and
      creates no Antigravity playground.
- [x] Verify a real two-folder project uses primary cwd plus `--add-dir`, then
      resumes with its persisted opaque agy binding.
- [x] Verify a real session move keeps Riz history and starts a new agy
      conversation in the destination context.
- [x] Repeat Web browser regression at phone, tablet, and desktop widths on the
      fresh schema-v2 daemon.

- [x] Replace the global rail and bottom navigation with a unified
      daemon/project/session sidebar and mobile drawer.
- [x] Move quota into the unified sidebar instead of a standalone destination.
- [x] Add cross-platform Flutter-native page and interaction motion with
      reduced-motion support.
- [x] Verify portrait-phone and landscape-tablet touch layouts in a real
      browser.

- [x] Clear stale messages and expose an explicit loading state while switching
      or restoring a session.
- [x] Normalize agy `ask_question` events into a pending-input state and route
      selected answers back to the active interactive PTY.
- [x] Render compact grouped agent activity and image attachment previews.
- [x] Verify live agy question answering in the Web UI.

- [x] Daemon -> project -> session hierarchy is persisted in SQLite.
- [x] Turn lifecycle persists queued, running, waiting_permission, completed,
      failed, cancelled, and interrupted states.
- [x] WebSocket auth rejects invalid tokens and enforces the five-second auth
      deadline.
- [x] WebSocket reconnect supports event replay and snapshot fallback.
- [x] Attachments are validated and recorded with path, MIME type, and size.
- [x] PTY metadata records running, completed, cancelled, and restart-interrupted
      states.
- [x] Web tokens use flutter_secure_storage's WebCrypto backend.
- [x] Persist skill source metadata in SQLite in addition to `.riz-source.json`.
- [x] Add WebSocket integration coverage for binary 256 KiB chunking and
      simultaneous clients.

## Validation

- [x] `cargo fmt --all`.
- [x] `cargo test --workspace` (36 daemon tests + 1 protocol test).
- [x] `cargo clippy --workspace --all-targets -- -D warnings`.
- [x] `flutter analyze`.
- [x] `flutter test` (20 tests).
- [x] Flutter Web release build.
- [x] Android debug APK build.
- [x] macOS installer install/rollback/uninstall integration test.
- [ ] iOS build: blocked locally because full Xcode is not installed.

## Change Log

### 2026-07-28

- Superseded all temporary-project work recorded later in this historical log.
  The released model will not contain hidden Riz projects, `kind=temporary`,
  `temporary=true`, `~/.riz/temporary-chats`, legacy `Project(path, kind)`, or
  compatibility output. There are no users to migrate: schema v2 is the only
  accepted pre-release format and old development databases fail with an
  explicit reset instruction.
- Implemented the fixed model directly: optional named projects own zero or
  more canonical folders, sessions have nullable `project_id`, and every real
  session owns `~/.riz/sessions/<id>/{runtime,attachments,artifacts}`. Project
  JSON now exposes only `folders` and `primaryPath`; the old `path` alias and
  `project.add` request were removed in favor of
  `project.create(name?, folders[])`.
- Added project folder add/remove/primary changes, project rename, unbound quick
  chats, session moves, cwd/additional-directory turn snapshots, and UI controls
  for those operations. Fixed the empty-selection state bug where no active
  session was incorrectly classified as an unbound chat.
- Project folder changes now invalidate the opaque provider binding and clear
  affected provider conversation IDs. A running turn retains its captured
  context, but its old binding is not written back if the project context
  changed before completion.
- Hardened the agy adapter: project additional folders participate in workspace
  auto-approval, newly registered agy project JSON must exactly match Riz's
  primary folder, and any newly created Antigravity playground fails the turn
  instead of being adopted. Real agy 1.1.8 testing confirmed that `--add-dir`
  grants access for the turn but is not persisted in project JSON, so additional
  directories are audited through CLI arguments and turn snapshots instead.
- Fixed provider-error finalization so a streamed assistant message becomes
  `failed` with its partial text, structured events, and diagnostic instead of
  remaining permanently `running` after a post-run compatibility check fails.
- Verified the schema-v2 model end to end with real agy 1.1.8. Unbound session
  `eb836746-38a9-4bb6-878e-2bc080d5d961` ran from its Riz-owned `runtime/`,
  wrote `quick-check.txt`, returned `QUICK_CHAT_V2_OK`, and left the
  Antigravity playground count unchanged at 21.
- Verified project `Riz v2 Multi Folder` with distinct primary and secondary
  folders. agy read both through primary cwd plus `--add-dir`, wrote into the
  primary folder, and resumed conversation
  `451c6ad4-820c-413e-8546-9660f324fd81` for a subsequent completed turn.
- Moved that session from the project into quick chats. Riz preserved all six
  existing messages, cleared the old provider conversation, created
  `moved-runtime.txt` under the session runtime, and continued as new agy
  conversation `de1db42b-cd59-4281-9753-5da87b874091` without creating a
  playground.
- Repeated real Chrome checks against the fresh schema-v2 daemon at 390, 600,
  840, 1024, and 1440 CSS-pixel widths. Each document width exactly matched the
  viewport and the final browser console contained no warnings or errors.
- Added regression coverage for schema rejection, zero/multiple folders,
  primary switching, provider invalidation, unbound runtime directories, turn
  context snapshots, session moves, project removal, and empty UI selection.
  Current validation passes Rust formatting, 36 daemon tests plus the protocol
  test, warning-free clippy, Flutter analyze, and all 20 Flutter tests.

- Added `docs/domain-model.md` as the normative replacement for the original
  one-directory-per-project hierarchy. It fixes the product model as optional
  named projects with zero or more folders, nullable session ownership, local
  drafts, project-free quick chats, and a daemon-managed private directory for
  every persisted session.
- Documented cwd selection, additional-directory behavior, session moves,
  folder changes, provider-adapter boundaries, agy's opaque internal project
  handling, existing-credential/quota behavior, protocol changes, transactional
  migration from hidden temporary projects, deletion/export rules, and release
  acceptance criteria. No runtime schema or behavior was changed in this
  documentation-only step.
- Clarified the physical-directory boundary after inspecting the installed agy
  1.1.7 data layout. Antigravity Desktop owns random
  `~/.gemini/antigravity/playground/*` workspaces for its quick sessions, but
  Riz will give agy the existing project folder or the Riz session `runtime/`
  as its workspace root instead of allowing a second code directory. agy's
  `brain/`, conversation, project, and index files remain provider-owned data.
- Verified that boundary with a real agy 1.1.7 `--new-project` probe. agy
  created project `223f71f3-82c0-4141-bcac-1d978ac1b77c`, persisted the supplied
  cwd as its sole `folderUri`, and created conversation
  `df7cff68-8e32-40e9-8680-2e957e941b17`; the Antigravity playground count
  remained 21 before and after. The prompt itself stopped when headless mode
  denied a read-file permission, which did not affect the directory result.
- Made this a normative invariant: Riz must always supply an existing project
  folder or pre-created session runtime to agy, must never trigger the
  Antigravity Desktop quick-session path, and must treat unexpected playground
  creation or workspace substitution as a provider compatibility failure.
- Dropped the legacy-database migration path before completing the schema
  rewrite: Riz has no released users or compatibility obligation yet. Schema
  v2 is now the only supported development format, and an old development DB
  produces an explicit reset error instead of adding temporary-project
  compatibility branches.
- Began lazy-session and quick-chat support by adding persisted project kinds,
  join-derived temporary-session metadata, configurable initial permission
  modes, and migration-safe defaults to the SQLite layer. Temporary workspaces
  remain inside the existing `Project -> Session` hierarchy.
- Extended `session.create` so a first-message materialization can atomically
  allocate a random workspace below the daemon-owned
  `~/.riz/temporary-chats` root, register it as a hidden temporary project,
  and create its agy session with the draft's selected permission mode.
- Added explicit Flutter draft-session state, active-session selectors, normal
  versus temporary project filtering, and global temporary-session selectors
  so abandoned drafts never enter the daemon snapshot or sidebar history.
- Replaced eager session creation with an immediate local draft transition.
  The first send now materializes the real session, carries the draft permission
  mode into that create request, uploads locally previewed attachments only
  after a real session ID exists, and then queues the prompt. Permission changes
  now update drafts locally and persisted sessions from the daemon response.
- Added a first-class quick-chat entry and a project-free temporary history
  section to the unified sidebar. Temporary sessions open directly into chat,
  while their daemon-owned backing projects remain hidden from the normal
  project list and project tabs.
- Routed the chat surface through the active draft-or-persisted session,
  retained selected images only as local composer previews until send, and
  added explicit success/error Snackbars for permission changes including full
  access.
- Replaced the icon-only model picker with an always-visible current selection
  label (`Default model` or the chosen model). Failed first sends now restore
  both composer text and local image previews instead of silently discarding
  them.
- Included the temporary-chat placeholder title in first-prompt auto-titling,
  so quick chats become recognizable history entries without showing an
  internal project name.
- Fixed the async error-feedback context guard exposed by Flutter analyze.
  After formatting, `cargo test --workspace` still passes all 32 daemon tests
  plus the protocol test, and `flutter analyze` reports no issues.
- Added regression coverage for temporary-project/session metadata and initial
  full-access persistence, normal-project filtering, abandoned local drafts,
  draft-local permission selection, immediate draft rendering, and the visible
  default-model label.
- Corrected the draft widget fixture to include an active daemon connection;
  without it, the test was intentionally rendering Riz's connection setup
  screen rather than the draft workspace.
- Validation after the lazy-session changes passes Rust formatting, 33 daemon
  tests plus the protocol test, warning-free clippy, Flutter analyze, all 18
  Flutter tests at that point (19 after the back-path regression was added),
  and the JavaScript Web release build. The known
  `isolate_contactor` Wasm dry-run warning remains unchanged.
- Real Chrome mobile inspection exposed and fixed the temporary-chat back path:
  leaving a temporary session now clears its hidden backing project instead of
  opening that project in the normal Files/Terminal/Skills workspace. A state
  regression test covers the cleanup.
- Real Chrome verified the complete lazy flow against the release daemon:
  opening a normal draft left SQLite at 20 sessions, the full-access choice
  updated immediately with visible feedback, and the first prompt alone created
  session 21 with `permission_mode=full`; agy returned `LAZY_SESSION_OK`.
- Real Chrome verified quick chat from an empty draft through completion. Before
  send there were zero temporary projects and no new session; the first prompt
  created a random `temporary-chats/chat-7ec4a54f8c17` workspace, a hidden
  temporary project and session 22, and agy returned `QUICK_CHAT_OK`. The sidebar
  displayed the chat directly without the internal project name.
- Switching an already persisted quick chat from workspace mode to full access
  showed the success Snackbar and SQLite independently confirmed the updated
  value. Browser console inspection contained no warnings or errors.
- Current-build responsive browser checks passed at 390x844 portrait and
  1024x768 landscape: viewport and document widths matched exactly, the quick
  chat drawer/history remained touch-accessible, the visible default-model
  label fit the composer, and the temporary-chat back action returned to the
  normal project list.
- Started the Codex-structure UI rebuild: removed the shell's global rail and
  bottom navigation, introduced a 272 px unified-sidebar slot on wide layouts,
  a mobile drawer, and reduced-motion-aware fade/slide workspace transitions.
- Unified daemon switching, projects, sessions, running tasks, global skills,
  quota, and settings in one touch-friendly sidebar. Quota is now a compact
  lowest-pool meter that opens details in a bottom sheet and refreshes on long
  press rather than occupying a standalone destination.
- Removed the duplicated project and session title bars on compact layouts;
  phones now use one dynamic shell AppBar, a single horizontally scrollable
  project tab row, and a project-actions overflow menu.
- Constrained the unified sidebar's daemon picker so long machine names elide
  instead of overflowing, and replaced the obsolete collapsible-rail test with
  assertions for the merged project/task/skills/quota navigation.
- Added neutral MD3 fallback surfaces, a non-duplicating desktop project prompt,
  48 px touch tabs, and reduced-motion-aware message stack/scale entrances to
  complement the workspace fade/slide transition.
- Real-browser checks at 390x844 portrait phone, 1024x768 landscape tablet, and
  1440x900 desktop showed exact viewport/document widths, no horizontal
  overflow, and no console warnings or errors. The phone drawer and tablet
  sidebar expose the same navigation and quota controls.
- Added a regression test that explicitly rejects both `NavigationRail` and
  bottom `NavigationBar` on phone layouts while requiring the unified drawer.
- Final validation passed Flutter analyze, all 15 Flutter tests, and the Web
  release build. The public Web endpoint returns HTTP 200 and the tunneled
  daemon health endpoint still reports protocol version 1.

### 2026-07-27

- Added race-safe session loading state, cleared stale conversation content on
  selection, and added daemon/UI pending-input plumbing for agy
  `ask_question` option responses.
- Rebuilt the chat surface around a bordered two-row composer, local image
  thumbnails, sent-image previews, grouped agent activity, and a dedicated
  pending-question response panel without changing the navigation hierarchy.
- Added a unit fixture for agy `ask_question` normalization; all 32 daemon tests
  and the shared protocol test pass after the pending-input implementation.
- Added Flutter widget coverage proving session loading replaces stale content
  and model-question options become selectable before submission.
- A real agy question exposed transcript arguments encoded as a JSON string;
  question normalization now accepts both native arrays and encoded arrays,
  with the real transcript shape added to the Rust regression fixture.
- Rebuilt and restarted the release daemon and Web client. In the real browser,
  agy asked `首选哪个框架？`, Riz entered `waiting_input`, rendered Flutter and
  React choices, sent the selected Flutter option back through the PTY, and
  persisted agy's final `Flutter` answer with a completed turn.
- Verified image selection produces a thumbnail inside the composer and the
  sent message reloads the managed attachment as an inline preview; the real
  agy turn inspected it and returned `IMAGE_PREVIEW_OK`.
- Real-browser layout checks at 390, 840, and 1440 CSS pixels showed matching
  viewport/document widths and no horizontal overflow. The final console had
  no warnings or errors.
- Final validation passed Flutter analyze, all 14 Flutter tests, Web release
  build, Rust formatting, all 32 daemon plus one protocol tests, and
  warning-free clippy. Both public Cloudflare endpoints remain healthy.

- Added persisted turn records linked to user messages and wired every runtime
  transition into daemon events and session recovery.
- Added real Axum WebSocket integration tests for invalid authentication,
  authentication timeout, incremental replay, and snapshot fallback.
- Fixed cancellation ordering so late provider output cannot overwrite a
  cancelled turn.
- Added attachment metadata persistence and returned attachments from
  `session.get`.
- Added PTY metadata persistence for create, exit, close, and daemon restart.
- Rebuilt and restarted the release daemon using
  `work/integration-riz-home-2`.
- Verified a real non-default `gemini-3.6-flash-low` turn through the release
  daemon. Riz SQLite recorded the requested model, agy returned
  `MODEL_SWITCH_OK`, and the model identifier was present in agy's conversation
  database; Chrome UI selection remains pending because macOS Computer Use is
  locked.
- Added the SQLite upsert/remove/query layer and unit coverage for skill source
  metadata, then wired list, write, toggle, delete, Git install, and Git update
  operations to keep it synchronized with `.riz-source.json`.
- Re-ran Rust formatting, all 29 daemon tests plus the protocol test, and
  warning-free clippy after skill source persistence was connected.
- Added real-server integration cases for two authenticated observers receiving
  the same event and a `2 * 256 KiB + 17` byte binary upload/download; final
  checklist status awaits the test run.
- Kept the binary-channel assertion compatible with the protocol enum's
  intentionally non-comparable representation by matching its variant.
- Verified both new real-server cases: simultaneous clients observed the same
  event sequence, and binary transfer produced exact chunk sizes of 256 KiB,
  256 KiB, and 17 bytes. Rust now passes 31 daemon tests, the protocol test,
  formatting, and warning-free clippy.
- Rebuilt and restarted the latest release daemon at 22:26, connected a fresh
  in-app real browser with no inherited Riz state, and created the isolated
  `Riz Final Release` project through the remote directory picker.
- Selected `gemini-3.6-flash-low` in the Web model menu and completed a real
  agy turn. Riz SQLite, agy's native conversation database, the rendered reply,
  and a clean browser console all agree on the selected-model result.
- The final browser terminal pass exposed `terminal_metadata.project_id` as
  null even though both tabs belonged to `Riz Final Release`. Fixed the create
  request and Rust persistence path to carry the project UUID, and strengthened
  the database test to assert project ownership across reopen/interruption.
- After the terminal ownership fix, Rust formatting and all 31 daemon plus one
  protocol tests passed; Flutter analyze and all 12 Flutter tests also passed.
- Rebuilt the release daemon and Flutter Web client, restarted the daemon, and
  reloaded the real browser. The pre-restart running terminal became
  `interrupted`; a new terminal was persisted with project UUID
  `9627c10c-5878-4171-aded-70749ef47619`, executed
  `POST_RESTART_TERMINAL_OK`, and closed as `cancelled`.
- Completed the final current-release browser pass: the agy conversation resumed
  after restart with `RESUME_AFTER_RELEASE_OK`, file CRUD/search cleanup left
  only the fixture README, `/usage` refreshed four quota pools from `agy-pty`,
  and the browser console finished with zero warnings or errors.
- Final endpoint audit confirmed the local daemon and public Cloudflare daemon
  health endpoints both report protocol version 1, while the public Web tunnel
  serves the current release build with HTTP 200.
