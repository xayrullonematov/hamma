# Hamma - AI Server Manager

## Overview

Hamma is a Flutter-based desktop/mobile app that serves as a DevOps command center and SSH client. It features an AI-powered assistant for server management, SSH/SFTP capabilities, Docker container management, process monitoring, and fleet management.

## Project Structure

- **`lib/`** - Main Dart/Flutter application code
  - `main.dart` - App entry point
  - `core/` - Shared services: AI providers, SSH, storage, encryption
  - `features/` - Feature modules: terminal, docker, sftp, processes, services, AI assistant, settings
- **`linux/`** - Linux desktop platform configuration (CMake)
- **`android/`** - Android platform configuration
- **`ios/`** - iOS platform configuration
- **`build/install_prefix/`** - Built Linux app binary and libraries
- **`run.sh`** - Startup script for running the Flutter Linux app

## Running

The app runs as a Flutter Linux desktop application using Xvfb (virtual framebuffer) with Mesa software OpenGL rendering:

```bash
bash run.sh
```

This handles building if needed and launching the app with proper environment setup.

## Building

```bash
JAVA_HOME="/nix/store/xad649j61kwkh0id5wvyiab5rliprp4d-openjdk-17.0.15+6/lib/openjdk"
SYSPROF_DEV="/nix/store/0nhrfd0ggrim9h09a4n0awqzyk7w0c6i-sysprof-3.44.0-dev"
APPINDICATOR_DEV="/nix/store/0gfsfrizrf20m04fya53g8dbagdz3f2p-libappindicator-gtk3-12.10.1+20.10.20200706.1-dev"
export JAVA_HOME PKG_CONFIG_PATH="$SYSPROF_DEV/lib/pkgconfig:$APPINDICATOR_DEV/lib/pkgconfig:$PKG_CONFIG_PATH"
flutter build linux --debug
```

## System Dependencies (via Nix)

- `flutter` - Flutter SDK 3.32.0
- `libsecret` - For flutter_secure_storage
- `keybinder3` - For hotkey_manager
- `libappindicator` - For tray_manager
- `sysprof` - Required by glib
- `gtk3`, `glib`, `pcre2` - GTK dependencies
- `jdk17` - For jni package
- `mesa` - Software OpenGL rendering
- `xorg.xorgserver`, `xvfb-run` - Virtual framebuffer display
- `zlib`, `curlFull` - For sentry-native build

## Local AI Provider (Zero-Trust Mode)

Hamma runs AI fully offline in two ways:

1. **Built-in inference engine** (recommended, zero setup) — Hamma
   ships an embedded llama.cpp `llama-server` side-car and downloads a curated GGUF
   model on first run. No external daemon, no install steps. See
   "Bundled inference engine" below.
2. **Connect to existing engine** — point Hamma at any
   OpenAI-compatible local inference server already running on the
   machine (Ollama, LM Studio, llama.cpp, Jan).

Both paths route through the same OpenAI-compatible `_chatWithOpenAi`
plumbing in `AiCommandService`, so streaming, error handling, model
management and the brutalist UI are identical.

### Architecture

Pure-Dart core (no Flutter dependency, fully unit-tested):

- `lib/core/ai/ai_provider.dart` — `AiProvider.local` enum; `requiresApiKey = false`
- `lib/core/ai/ai_command_service.dart` — routes `local` through OpenAI-compatible `_chatWithOpenAi()`; **`streamChatResponse()`** uses SSE (`stream: true`) for real token-by-token output; non-local providers degrade to a single-emit stream so UI code is uniform; 5s connect / 120s response timeout
- `lib/core/ai/ollama_client.dart` — native typed client for the Ollama HTTP API: `version()`, `listModels()`, `listLoadedModels()` (`/api/ps`), `deleteModel()`, `pullModel()` (NDJSON progress stream), `streamChat()` (NDJSON delta stream). Pure Dart, injectable `httpClientFactory`.
- `lib/core/ai/local_engine_detector.dart` — probes `127.0.0.1` on the well-known ports of Ollama (11434), LM Studio (1234), llama.cpp server (8080), Jan (1337) in parallel; identifies via `/api/version` (Ollama) or `/v1/models` (others)
- `lib/core/ai/local_engine_health_monitor.dart` — single-timer broadcast `Stream<LocalEngineHealth>` (loading / online / offline) backed by `OllamaClient.version()` + `listLoadedModels()`; default 15 s interval; `probeNow()` for retry buttons

UI layer:

- `lib/features/ai_assistant/widgets/local_engine_status_pill.dart` — brutalist pill (`LOCAL · ONLINE/CHECKING/OFFLINE`) that subscribes to a health monitor; tap-to-retry when offline; `#00FF88` when online
- `lib/features/ai_assistant/ai_assistant_screen.dart` & `ai_copilot_sheet.dart` — both use `streamChatResponse()` so local-provider replies type out token-by-token. A placeholder bubble is inserted on send and grown as deltas arrive; if the stream errors before any tokens, the placeholder is dropped and a system error is shown instead.
- `lib/features/settings/local_models_screen.dart` — in-app model manager: lists installed models (`/api/tags`), highlights ones currently loaded in RAM (`/api/ps`), shows a curated catalog (Gemma, Llama, Mistral, Phi, Qwen-Coder, DeepSeek-Coder, TinyLlama), supports deletion with a confirm dialog, and a streaming pull bottom-sheet with live byte progress and cancel
- `lib/features/settings/local_ai_onboarding_screen.dart` — two-path wizard. Step 0 picks **Built-in engine** (recommended, default selection on desktop) or **Connect to existing**. The built-in path then runs CHOOSE → DOWNLOAD → DONE; the external path runs the original INSTALL → PULL → DETECT flow with OS-aware install snippets.
- `lib/features/settings/settings_screen.dart` — Local AI section exposes **DETECT ENGINES**, **MANAGE MODELS**, and **FIRST-RUN SETUP** buttons next to **TEST CONNECTION**. When the bundled engine is running, the endpoint field auto-fills with its loopback URL.

### Bundled inference engine

Architecture (`lib/core/ai/`):

- `bundled_engine.dart` — `InferenceBackend` interface + implementations:
  - `LlamaServerBackend` (in `llama_server_backend.dart`, **production default**) spawns the upstream `llama-server` binary as a child process bound to a loopback ephemeral port and proxies generation through it. A `LlamaServerLauncher` typedef makes the spawn injectable so unit tests run against a Dart-side fake (no real subprocess required); a separate gated integration test exercises the real binary when `LLAMA_SERVER_BIN` and `LLAMA_SERVER_MODEL` are set.
  - `LlamaCppBackend` (FFI, **future / disabled**) — bindings in `llama_cpp_bindings.dart` cover the symbols a complete implementation would need but its `isAvailable` returns `false` until a generation loop is wired up. Kept as an escape hatch for future iOS / sandboxed-environment support where subprocess spawning isn't viable. The HTTP-API approach was chosen over FFI because llama.cpp's C struct ABI (`llama_batch`, `llama_*_params`) shifts across upstream releases while the HTTP API has been stable for a year+.
  - `EchoBackend` is a pure-Dart fake used by tests and for "demo mode" without a model loaded.
  Plus `BundledEngine`, which loads a model and starts a loopback `HttpServer` on an OS-assigned ephemeral port. The server speaks an OpenAI-compatible subset (`GET /v1/models`, `POST /v1/chat/completions` both streaming SSE and non-streaming) and an Ollama-compat `GET /api/version` so `LocalEngineHealthMonitor` works against it unchanged.
- `bundled_model_catalog.dart` — curated GGUF list (Gemma 3 1B, Qwen2.5-Coder 3B, Llama 3.2 3B, Phi 3.5 Mini). All entries are HTTPS-only (validated programmatically). The "recommended" pick (Gemma 3 1B) is the smallest/fastest.
- `bundled_model_downloader.dart` — streamed HTTPS-only download to `<appSupportDir>/bundled_models/<id>.gguf`. Writes to a `.partial` file and renames atomically on success; cancellation drops the partial. Refuses redirects that leave HTTPS.
- `bundled_engine_controller.dart` — process-wide singleton (`BundledEngineController.instance`) so the AI assistant, copilot sheet and settings all share one warm-loaded model. `overrideForTesting` / `resetForTesting` swap in fakes.
- `llama_cpp_bindings.dart` — minimal `dart:ffi` typedefs for `llama_backend_init`, `llama_load_model_from_file`, `llama_new_context_with_model` and friends. `LlamaCppLibrary.openOrNull()` returns `null` when no library is bundled — never throws. Currently used only by the disabled FFI backend.

Build matrix (`native/`):

The Dart side spawns `llama-server` (or `.exe` on Windows) at runtime; CI / release scripts build the side-car per OS and drop it into `native/<os>/`:

- `linux/CMakeLists.txt` — `file(GLOB)`s `native/linux/libllama*.so*` and copies `llama-server` into `INSTALL_BUNDLE_LIB_DIR` (next to the existing plugin libs). RPATH already points at `$ORIGIN/lib`.
- `windows/CMakeLists.txt` — `file(GLOB)`s `native/windows/llama*.dll` into the install prefix next to the `.exe`.
- `macos/Runner/Configs/BundledEngine.xcconfig` + `copy_bundled_engine.sh` — copies `native/macos/llama-server` (and any optional `libllama*.dylib`) into `Runner.app/Contents/Frameworks/` during the Xcode build phase. `LD_RUNPATH_SEARCH_PATHS` includes `@executable_path/../Frameworks`.
- `native/README.md` — per-OS `llama-server` build commands (Linux x86_64+arm64, macOS universal, Windows x64) with the required CMake flags. Pinned upstream tag `b4350`.

When `native/<os>/` is empty (e.g. fresh contributor checkout), the Flutter build still succeeds, `LlamaServerBackend.isAvailable` returns `false`, and the onboarding wizard hides the "Built-in engine" path. Users get the original "Connect to existing engine" flow with no degradation.

### Zero-trust guarantees

The `test/zero_trust_network_guard_test.dart` suite enforces — at the unit-test level — that every local-AI component (`OllamaClient`, `LocalEngineDetector`, `LocalEngineHealthMonitor`, `AiCommandService.streamChatResponse(local)`, **and `BundledEngine`**) only ever dials / binds loopback (`127.0.0.0/8`, `localhost`, or `::1`). A recording `HttpClient` intercepts every URL and the test fails if any non-loopback host shows up. `BundledEngine` additionally checks `request.connectionInfo.remoteAddress.isLoopback` on every incoming request as defence-in-depth.

### Usage

**First-time (built-in engine, recommended):** Settings → AI Configuration → Local AI → **FIRST-RUN SETUP** → **BUILT-IN ENGINE** → pick a model → DOWNLOAD & START. The endpoint auto-fills with the loopback URL the bundled engine bound to. Total clicks: 4.

**First-time (existing engine):** Same wizard, but pick **CONNECT TO EXISTING** on the first step → install / pull / detect flow.

**Manual:**
1. In Settings, select "Local AI" as the provider
2. Tap **DETECT ENGINES** to scan localhost (or set the endpoint manually; default `http://localhost:11434`)
3. Tap **MANAGE MODELS** to pull or pick a default (or type a tag matching `ollama list`)
4. Tap **TEST CONNECTION** to verify
5. Save — no API key needed

### Quick start (existing Ollama)
```bash
ollama serve          # start the engine
ollama pull gemma3    # download the model (~5 GB)
```

## Backup Encryption

Encrypted backups (PIN/password-protected, includes all secure-storage
contents — server profiles, AI keys, trusted host keys) live in
`lib/core/backup/`:

- `backup_crypto.dart` — pure-Dart crypto layer (no Flutter deps,
  fully unit-testable). Static methods: `encrypt(password, plaintext)`,
  `decrypt(password, blob)`. Throws `BackupCryptoException` on failure.
- `backup_service.dart` — handles file I/O, scheduling, and transport
  (local share, SFTP, WebDAV, Syncthing). Delegates all crypto to
  `BackupCrypto`.

### File format v2 (current — written by all new backups)

```
[magic(4)='HMBK' | version(1)=0x02 | salt(16) | iv(12) | ciphertext+gcm-tag]
```

- **KDF**: Argon2id, m=19456 KiB (~19 MiB), t=2, p=1
  (OWASP 2024 password-storage recommendation)
- **Cipher**: AES-256-GCM with 96-bit IV (NIST SP 800-38D recommended)
- **Key length**: 32 bytes (256-bit)

### File format v1 (legacy — read-only, for migration)

```
[salt(16) | iv(16) | ciphertext+gcm-tag]
```

- **KDF**: PBKDF2-HMAC-SHA256, 10,000 iterations
- **Cipher**: AES-256-GCM
- Detected by the **absence** of the `HMBK` magic header — old backups
  created before the Argon2id migration still restore correctly.
- New backups are never written in v1 format.

### Security properties

- Wrong password and tampered ciphertext both produce the **same**
  user-visible error (`"Incorrect password or corrupted file."`) — no
  information leak about which one failed.
- Forward-compat: unknown version bytes produce a clear "this file may
  have been created by a newer version" error rather than silently
  mis-decrypting.
- Random salt + random IV per backup; cryptographically secure RNG
  (`Random.secure()`).
- 24 unit tests in `test/backup_crypto_test.dart` cover round-trip
  (binary + JSON + text payloads), all failure modes, the legacy
  migration path, and lock in the exact Argon2id parameters.

## Global Error Handling

Top-level error capture is centralised in `lib/core/error/`:

- `error_scrubber.dart` — pure-Dart `ErrorScrubber.scrub()` that
  removes likely-sensitive substrings (`password=`, `pin=`, `token=`,
  `apiKey=`, `secret=`, `Authorization: Bearer/Basic …`,
  `sk-…` OpenAI keys, standalone JWTs (`eyJ.eyJ.<sig>` shape),
  PEM `-----BEGIN … PRIVATE KEY-----` blocks) before any error
  message is shown to the user or sent to Sentry.
- `error_reporter.dart` — `ErrorReporter.install()` wires the three
  Flutter error hooks (`FlutterError.onError`,
  `PlatformDispatcher.instance.onError`, `ErrorWidget.builder`) and
  **chains** to whatever was previously installed, so calling it
  before `SentryFlutter.init` is safe — Sentry's own integrations
  layer on top without losing ours. Captures the most recent fatal
  error in `ErrorReporter.lastFatal` for the crash screen.
- `in_widget_error_panel.dart` — brutalist replacement for Flutter's
  default red-on-yellow `ErrorWidget`. Renders in place of any single
  widget that throws during build/layout/paint. Compact, theme-free
  (so it works even when the app theme is the failure cause), shows
  scrubbed message, and adds file/line context only in debug mode.
- `crash_screen.dart` — standalone full-screen `CrashApp` shown when
  the bootstrap sequence in `main.dart` fails. Builds its own
  `MaterialApp` to avoid depending on the broken main app. Actions:
  **COPY DETAILS** (scrubbed message + stack to clipboard),
  **TRY RESTART** (re-runs `main()`, capped at 3 consecutive
  attempts to prevent infinite crash loops on deterministic
  failures), **QUIT** (desktop only; hidden on iOS/Android per
  platform guidelines). Stack details are collapsed by default in
  release, expanded by default in debug.

`main.dart` integration:
1. `WidgetsFlutterBinding.ensureInitialized()`
2. `ErrorReporter.install()` — handlers active before any other init
3. `_bootstrapAndRun()` — wrapped in try/catch; on failure shows
   `CrashApp(onRestart: main)` instead of the normal app
4. `runZonedGuarded` outer handler funnels uncaught async errors
   through `ErrorReporter.report()`
5. Sentry `beforeSend` reuses the same `ErrorScrubber.scrub()` so
   transport-side and in-app views of an error stay consistent

48 unit tests across `test/error_scrubber_test.dart` (36) and
`test/error_reporter_test.dart` (12) cover every scrubber pattern
(including JWT positive + negative cases), no-op cases, robustness
against control characters and 100k-char input, handler chaining,
idempotent installation, scrubbed capture into `lastFatal`,
`report()` never-throws guarantee, and the in-widget panel's render
output.

## SSH State Machine

The connection lifecycle in `lib/core/ssh/ssh_service.dart` is a
five-state machine (`disconnected → connecting → connected →
reconnecting → failed`) with auto-reconnect, backoff, heartbeat,
and host-key verification baked in. To make the whole machine
unit-testable without a real network or running SSH server, the
service was refactored around a thin transport seam:

- `lib/core/ssh/ssh_transport.dart` — `SshTransport` interface over
  the parts of dartssh2's `SSHClient` that the service uses
  (`authenticated`, `done`, `ping()`, `close()`, plus the command
  methods). `DartSsh2Transport` is the production pass-through
  implementation; `SshConnector` is the typedef for the factory
  function the service calls; `defaultSshConnector` holds the real
  `SSHSocket.connect` + `SSHClient` handshake. The host-key
  verification *closure* is owned by `SshService` (so the user-
  prompt + storage logic stays in the state machine and is testable
  through `connect()`); the connector receives it as
  `onVerifyHostKey` and passes it straight through to dartssh2.
- `SshService` constructor now accepts (all optional, all with
  production defaults): `connector`, `enableBackgroundKeepalive`,
  `disableBackgroundKeepalive`, `reconnectBackoffSeconds` (default
  `[5, 10, 20, 30, 60]`), `maxReconnectAttempts` (default 5).
  Existing call sites (`SshService.forServer(id)`,
  `lib/main.dart`) pass nothing and get the original behaviour.
  The constructor body throws `ArgumentError` for invalid test
  injections — empty or negative `reconnectBackoffSeconds`, and
  negative `maxReconnectAttempts` — so a bad fake fails fast at
  construction instead of producing a silent wedge later.
- `lib/core/storage/trusted_host_key_storage.dart` exposes
  `TrustedHostKeyStorage` as an **abstract interface** (two
  methods: `loadTrustedHostKey`, `saveTrustedHostKey`).
  `SecureTrustedHostKeyStorage` is the production implementation
  backed by `flutter_secure_storage`; tests inject
  `InMemoryTrustedHostKeyStorage`, a pure-Dart `Map`-backed impl
  that never touches platform channels. All four production
  defaults (`SshService`, `FleetService`, `SftpService`, and the
  storage test) explicitly construct `SecureTrustedHostKeyStorage`.
- Three `@visibleForTesting` getters expose internal timer/counter
  state (`debugReconnectAttempts`, `debugHasPendingReconnect`,
  `debugHasHeartbeat`) plus `debugClearInstances()` for the
  registry tests, so the test suite asserts on machine internals
  without reflection or peeking at private fields.

Production-grade integration coverage in
`test/ssh_state_machine_test.dart` (43 tests) exercises:

- **Constructor guards** — empty backoff list, negative backoff
  entries, and negative `maxReconnectAttempts` all throw
  `ArgumentError`; `[0]` and `maxReconnectAttempts: 0` are
  accepted as the legitimate "instant retry" / "no retries" cases.

- **State transitions** — happy-path connect, `connecting →
  connected`, `lastSuccessfulConnection` timestamp, heartbeat-arm,
  and explicit-disconnect cleanup.
- **Failure mapping** — `SocketException`, `TimeoutException`,
  `authentication failed`, `access denied`, `handshake failed`,
  `connection reset`, `SshHostKeyException` subtypes, falling
  through to `SshUnknownException` for novel errors.
- **Auto-reconnect** — clean and errored transport closures both
  retry; disabled auto-reconnect leaves the machine `disconnected`;
  five consecutive failures end at the terminal `failed` state with
  the *Automatic reconnection failed* message; a successful retry
  resets the attempt counter; `disableAutoReconnect()` cancels a
  pending timer; `enableAutoReconnect()` re-arms when previously
  disconnected with a known last host.
- **Heartbeat lifecycle** — armed on connect, cancelled on
  disconnect, cancelled on transport closure.
- **Manual reconnect** — `StateError` when no prior connection,
  reuses last credentials when called.
- **Host-key flow** — first-connect with no callback raises
  `SshUnknownHostKeyException`; callback returning `false` raises
  `SshUnknownHostKeyRejectedException` and does **not** save;
  callback returning `true` saves and reaches `connected`;
  matching trusted key on subsequent connect skips the callback;
  mismatched key raises `SshHostKeyMismatchException` and never
  triggers auto-reconnect.
- **Status stream + `ValueNotifier`** — broadcast semantics, both
  paths emit the same events, and the legacy `connectionState`
  bool stream tracks `isConnected`.
- **`isHealthy()`** — false when no transport, true after connect.
- **Forwards** — `activeForwardedPorts` empty by default, cleared
  on disconnect.
- **Server registry** — `forServer` returns same instance for same
  id, different instances for different ids; `removeInstance`
  allows a fresh instance.
- **Command APIs** — `execute`, `streamCommand`, `startShell`,
  `startLocalForwarding` all throw `StateError` when not connected.

Tests use a hand-rolled `FakeSshConnector` (queues scripted
success/failure responses; can drive the host-key callback with
synthetic algorithm + fingerprint; broadcasts each invocation on
a `callEvents` stream so tests can await the *Nth* call as a
completion signal) and `FakeSshTransport` (in-memory `done`
completer with `simulateClosure()` / `simulateError(error)`
helpers).

Synchronization is built on **completion signals** rather than
microtask polling — `waitForState(service, target)` awaits the
status stream's `firstWhere`, and `waitForCallCount(connector, n)`
awaits the connector's call event stream, both with a 2-second
diagnostic timeout. The old `drain()` helper has been removed
entirely. For the auto-reconnect *backoff exhaustion* test the
suite uses `package:fake_async` (added explicitly to
`dev_dependencies`) to drive a realistic
`[1, 2, 4, 8, 16]`-second schedule under a virtual clock,
advancing the clock past every retry timer with `async.elapse(...)`
instead of relying on zero-second sleeps. Every other test still
uses the zeroed `[0, 0, 0, 0, 0]` schedule for instant retries.

## Production-Readiness Hardening (2026-05-02)

Final round of fixes from the production-readiness audit. All checked in; full test suite (300+ tests across 22 files) is green under stricter analyzer rules.

### Strict static analysis enabled
`analysis_options.yaml` now activates the analyzer's strongest type checks:
- `strict-casts: true` — implicit `dynamic → T` casts are errors
- `strict-inference: true` — variables/returns must be explicitly typed when inference fails
- `strict-raw-types: true` — `Map`, `List`, `StreamSubscription`, etc. must declare type arguments
- `unawaited_futures: warning` — fire-and-forget futures must be wrapped in `unawaited(...)` or awaited

These flags surfaced 15 latent bugs in `lib/features/ai_assistant/ai_assistant_screen.dart` and `lib/features/docker/docker_manager_screen.dart` where `dynamic` values from `jsonDecode` were flowing into `String` parameters — these would have crashed at runtime on any unexpected payload shape. All fixed via explicit casts (`as String?`) for trusted shapes and `?.toString() ?? ''` for untrusted external JSON (Docker daemon output).

### Dangerous silent catches eliminated
Three empty `catch (_) {}` blocks replaced with `unawaited(ErrorReporter.report(e, stack, hint: '…'))`:
- `lib/core/backup/backup_service.dart` — temp file cleanup after share sheet closes
- `lib/core/storage/app_prefs_storage.dart` — corrupt JSON in `getServerLastStates()`
- `lib/features/packages/package_manager_screen.dart` — apt/dnf/yum detection failure

The 3 catches in `lib/core/ai/ai_command_service.dart` `parseJsonFromResponse()` (lines 168/177/215) were **intentionally left untouched** — they implement a 3-stage parser fallthrough (direct → code-fence → brace-depth-scan) and are a documented design pattern, not silent error swallowing.

### `ai_provider_test.dart` failing test fixed
Test expected 3 enum values but `AiProvider` has 4 (`openAi`, `gemini`, `openRouter`, `local`). Added full coverage for the new `local` provider: `storageValue`, `label`, `helperText`, `requiresApiKey: false`, `isLocal: true`, and `aiProviderFromStorage('local')` parsing including case-insensitivity and whitespace trimming. Test count for this file went 11 → 27.

## God-File Refactor (2026-05-02)

Split three of the largest UI files into focused widget modules. Behavior preserved exactly; full test suite still green; analyzer baseline unchanged (52 issues).

### `lib/features/ai_assistant/ai_copilot_sheet.dart` — 2419 → 2003 lines
Extracted 7 leaf widgets that were defined as private types at the bottom of the file:
- `lib/features/ai_assistant/copilot/widgets/copilot_chrome.dart` (247 lines) — `StepNode`, `RiskBadge`, `ChatBubble`, `UserChatBubble`, `LoadingBubble`, `EmptyMessageCard`, `ExecutionOutputCard` plus the shared `kCopilotShadowColor` constant.
- `lib/features/ai_assistant/copilot/widgets/step_timeline_card.dart` (185 lines) — the `StepTimelineCard` (the largest single child widget, takes 12 props but no state).

The widgets previously referenced private static aliases on the parent state (`_AiCopilotSheetState._surfaceColor`, etc.). Inlining to direct `AppColors.*` references eliminated that hidden coupling and made each widget independently usable.

### `lib/features/settings/settings_screen.dart` — 1614 → 1431 lines
Extracted two self-contained pieces:
- `lib/features/settings/help_center_screen.dart` (107 lines) — full `HelpCenterScreen` (its own `Scaffold`, no shared state with settings; routes to itself only).
- `lib/features/settings/widgets/settings_section_card.dart` (84 lines) — `SettingsSectionCard` reusable section wrapper used 5× in the main settings build.

### `lib/features/ai_assistant/ai_assistant_screen.dart` — 863 → 776 lines
Extracted three small, decoupled widgets to `lib/features/ai_assistant/widgets/`:
- `chat_avatar.dart` (28 lines) — `ChatAvatar(isUser: bool)`, pure leaf.
- `typing_indicator.dart` (29 lines) — `TypingIndicator()`, pure leaf.
- `chat_session_drawer.dart` (85 lines) — `ChatSessionDrawer` taking `sessions`, `currentSessionId`, and three callbacks (`onCreateNewChat`, `onLoadSession`, `onDeleteSession`). State stays in the parent.

The two remaining heavy methods (`_buildMessageBubble` ~105 lines and `_buildCommandCard` ~140 lines) were intentionally **not** extracted: they mutate `_messages[index]['outputs']` directly during command execution and would require either a state-management refactor or a long callback list to extract cleanly. Left as private build methods to avoid behavior risk.

### Files NOT touched in this round
- `file_explorer_screen.dart` (1072), `fleet_dashboard_screen.dart` (950), `ssh_service.dart` (810). Each is large but cohesive; splitting requires a state-management decision (controller pattern vs. notifier vs. callback list) that warrants its own design pass.

## Analyzer Cleanup (2026-05-02)

Cleared all 51 `flutter analyze` issues (16 errors, 32 warnings, 3 info) → "No issues found!". No behavior changes; full test suite (22 files) still green.

### Patterns applied
- **Typed JSON destructuring**: replaced `Map<String,dynamic>` field reads that flowed into typed locals with explicit casts. Touched: `ai_command_service.dart` (3 extractors → `String?`), `backup_service.dart`, `backup_storage.dart` (12 fields in `BackupConfig.fromJson` + decoded `loadConfig`), `chat_history_storage.dart` (List/Map decode sites), `ai_assistant_screen.dart` (outputs map cast).
- **Raw type tightening**: `whereType<Map<dynamic,dynamic>>()` in `copilot_sheet` and `settings_screen`; tightened `isA<Map<dynamic,dynamic>>()` in `ai_command_service_test`.
- **Generic inference fixes**: explicit `<void>` on `showDialog`, `showModalBottomSheet`, `MaterialPageRoute`, `Future.delayed`; explicit `void Function(...)` on callbacks.
- **Stream subscription typing**: `StreamSubscription<String>?` for `log_viewer_screen` & `package_manager_screen` (which decode `.cast<List<int>>().transform(Utf8Decoder).transform(LineSplitter)`); `StreamSubscription<Uint8List>?` for `terminal_screen` (raw stream).
- **Test locals**: renamed `_alice`/`_bob`/`_base` → `alice`/`bob`/`base` (no leading underscores in local vars).
- **Dependencies**: added `meta: ^1.15.0` to `pubspec.yaml` dependencies (used by `@visibleForTesting` annotations in `ai_command_service.dart` and `backup_crypto.dart`).

### Files NOT touched (deferred — need state-management design pass)
Same as god-file refactor: `file_explorer_screen.dart`, `fleet_dashboard_screen.dart`, `ssh_service.dart`, plus `_buildMessageBubble`/`_buildCommandCard` in `ai_assistant_screen.dart`.

## Key Modifications

- Fixed `DropdownButtonFormField.initialValue` → `value` in settings_screen.dart (Flutter 3.32.0 API change)
- Sentry backend: `inproc` for local dev (run.sh sets `SENTRY_NATIVE_BACKEND=inproc`); CI Linux builds use `crashpad` via `SENTRY_NATIVE_BACKEND=crashpad` in GitHub Actions
- Build output redirected from `/var/empty/local` to `build/install_prefix/` (writable path)

## Tech Stack

- **Framework**: Flutter 3.32.0 with Dart 3.8.0
- **SSH/SFTP**: dartssh2
- **Terminal emulation**: xterm
- **Security**: flutter_secure_storage, encrypt, pinenacl
- **Crash reporting**: sentry_flutter (inproc for local dev; crashpad in CI/release builds)
- **AI providers**: OpenAI, Google Gemini, OpenRouter (cloud), **Local AI** (Ollama/LM Studio/llama.cpp via localhost:11434)
- **Fonts**: Inter (variable, bundled at `assets/fonts/InterVariable.ttf`) and JetBrains Mono (4 weights, bundled at `assets/fonts/`)

## Responsive Layout

Hamma is a single Flutter codebase that runs on phone-class viewports
(~360px wide), tablets, and desktop. The breakpoint helper lives in
`lib/core/responsive/breakpoints.dart`:

- `Breakpoints.mobile = 700` — below this, screens use a mobile shell
- `Breakpoints.tablet = 1100` — between mobile and tablet, hybrid layouts
- `Breakpoints.isMobile(context)` / `isTablet` / `isDesktop` helpers
- `Breakpoints.value<T>(context, mobile:, tablet:, desktop:)` for inline
  per-breakpoint values

The desktop window minimum size in `main.dart` is set to `360x600` so
the responsive (mobile) layout can be exercised by simply resizing the
desktop window.

The shell that demonstrates the pattern is `ServerDashboardScreen`:
- Wide (≥700px): 240px brutalist sidebar in a `Row`, content beside it
- Mobile (<700px): `Scaffold` with `AppBar` (server name + status pill +
  reconnect/disconnect/settings actions) and a bottom `NavigationBar`
  for the 5 tabs (Terminal / Files / Docker / Services / Packages)

## Distribution Pipeline (CI/CD)

All three platform builds run in GitHub Actions (`.github/workflows/main.yml`):

| Trigger | What happens |
|---------|-------------|
| Push to `main` | Builds Android APKs, Linux AppImage, Windows installer; uploads as workflow artifacts |
| Push of `v*` tag | Same builds, then creates a GitHub Release with all artifacts attached |
| `workflow_dispatch` | Manual run of the same pipeline |

### Build outputs

| Platform | Artifact | How it's built |
|----------|----------|----------------|
| Android | `Hamma-arm64-v8a-release.apk` etc. | `flutter build apk --split-per-abi` |
| Linux | `Hamma-x86_64.AppImage` | `appimagetool` wrapping the Flutter bundle |
| Windows | `Hamma-Setup-Windows-x64.exe` | Inno Setup 6 from `installer/windows/hamma.iss` |

### Releasing

```bash
git tag v1.0.0
git push origin v1.0.0
```

CI builds all three platforms and publishes a GitHub Release automatically.
Tags containing `alpha`, `beta`, or `rc` are marked as pre-releases.

### Inno Setup script

`installer/windows/hamma.iss` packages everything in
`build\windows\x64\runner\Release\` into a single installer.
App version is injected at build time via `/DAppVersion=` from the git tag.

### AppImage structure

The AppDir mirrors the Flutter Linux bundle layout so the binary's
built-in asset path resolution works without changes:
```
Hamma.AppDir/
  AppRun          ← sets LD_LIBRARY_PATH; execs hamma
  hamma           ← binary
  lib/            ← bundled shared libraries
  data/           ← Flutter assets / plugins
  hamma.png       ← icon
  hamma.desktop   ← desktop entry
```

## Visual Design — Geometric Brutalism

The UI uses a strict "Terafab" brutalist visual identity defined in
`lib/core/theme/app_colors.dart` and applied globally via the
`_buildBrutalistTheme()` helper in `lib/main.dart`.

Five design pillars enforced across all screens:

1. **Monochrome palette + brand accent** — Pure black scaffold (`0xFF000000`),
   near-black surfaces (`0xFF0A0A0A`), white primary, harsh red (`0xFFFF0000`)
   for risk/warning. Brand cyan `AppColors.accent = 0xFF4ECDC4` (11:1 contrast
   on black, WCAG AAA) is used sparingly: HAMMA wordmark, active tab/nav
   indicators, "connected" / "running" / "online" status dots, and Docker
   running state. All other states stay white/gray/red. No slates or soft
   grays elsewhere.
2. **Zero-radius corners** — Every `RoundedRectangleBorder` uses
   `BorderRadius.zero`. No rounded chips, cards, or buttons.
3. **Wireframe borders** — All `elevation` and `boxShadow` are zero. Cards,
   inputs, dialogs, and sheets are separated from the scaffold by 1px
   borders (`AppColors.border = 0xFF222222` or `Colors.white24`).
4. **Typography** — Global sans is `Inter` (with `Geist`/`Space Grotesk`
   fallbacks). Technical data (IPs, metrics, terminal output, command
   blocks, server names, status pills) uses `JetBrains Mono` (with
   `Geist Mono` fallback). The fonts are not bundled — Flutter falls
   back to the platform default sans/mono if missing.
5. **Seamless AppBar** — `AppBarTheme.elevation = 0` and the AppBar
   background matches the scaffold so the app reads as one terminal pane.
6. **Logo** — The official Hamma "H" mark is bundled as
   `assets/images/logo.png` (registered in `pubspec.yaml`) and displayed
   at 18×18 px beside the HAMMA wordmark in the custom title bar.
   Flutter's asset pipeline automatically includes it in all builds
   (Linux, Android, CI). The raw source PNG is also mirrored to
   `linux/runner/resources/hamma.png` for future native window-icon use.

Brutalist surfaces in custom widgets:

- `lib/features/ai_assistant/widgets/interactive_command_block.dart` —
  Risk header is a solid red bar for HIGH/CRITICAL commands; the editor
  uses monospace with a `$` prompt; "EXECUTE" button switches to harsh
  red for dangerous commands.
- `lib/features/fleet/fleet_dashboard_screen.dart` — Metric dials,
  status pills (`ONLINE`/`OFFLINE`), and bulk-result blocks use the
  monospace font and zero-radius bordered surfaces.

All 18 feature screens (terminal, sftp, docker, services, processes,
packages, settings, server list/form, AI assistant + copilot, command
palette, port forwarding, logs, custom actions, onboarding, app lock)
were swept from the legacy slate/blue/green palette to `AppColors.*`
references in one pass. The mapping retired the slate (`0xFF94A3B8`,
`0xFF1E293B`, `0xFF162033`, `0xFF0F172A`, `0xFF334155`, `0xFF64748B`),
blue (`0xFF3B82F6`, `0xFF60A5FA`), green (`0xFF22C55E`, `0xFF15803D`),
amber (`0xFFD97706`, `0xFFF59E0B`), and teal (`0xFF0F766E`) tailwind
tones, plus stray Material constants (`Colors.red/orange/green/blue/
amber/redAccent`) in favor of `AppColors.surface` / `panel` /
`scaffoldBackground` / `border` / `textMuted` / `textPrimary` /
`danger`. The only legitimate stale hit left in
`lib/core/background/background_keepalive.dart` is an Android
notification accent, not visible UI.

### 3-tier monochrome state system

To preserve at-a-glance state communication without breaking the
brutalist palette, all stateful UI uses three tiers:

- **WHITE** (`AppColors.textPrimary`) — healthy / running / online /
  success / low-risk
- **GRAY** (`AppColors.textMuted`) — transitional / warning /
  connecting / reconnecting / restarting / paused / created /
  moderate-risk
- **RED** (`AppColors.danger`) — failure / dead / exited / failed /
  high-risk / critical-risk

Applied in: `server_list_screen` connection state, `docker_manager`
container state, `ai_assistant._riskColor`, `ai_copilot_sheet._riskColor`.
The `process_manager` CPU vs RAM bars are also tone-differentiated
(white vs gray) to preserve readability when both sit side-by-side.

### Inverted controls (white surfaces on dark scaffold)

When a control sits on the dark scaffold and uses the white primary as
its background (FAB, primary FilledButton, ActionChip), the foreground
**must** be `AppColors.scaffoldBackground` (black) — not `Colors.white`.
This was a regression introduced by the initial sweep that produced
white-on-white invisibility in: AI Copilot Run button, SFTP add FAB,
Log Viewer "Back to bottom" chip — all fixed.

### WCAG AA accessibility

`AppColors.textFaint` was bumped from `#555555` (~2.8:1 on black,
**fails** WCAG AA) to `#767676` (~4.6:1, **passes** AA for normal
text). `AppColors.textMuted` (`#888888`) is 5.7:1 (passes AA).
