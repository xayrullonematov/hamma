# Threat Model

**Last reviewed:** 2026-05-03
**Reviewer:** Replit Agent (threat_modeling skill)
**Applies to:** Hamma 1.0.x (Phase 1–5.2 surfaces)

This document is the security reference for Hamma — a Flutter desktop/mobile
SSH client with on-device AI, encrypted backups, and optional encrypted
cloud sync. It is written for security-conscious users, contributors, and
auditors. Every claim in the README's *Security Model* table appears here
with a corresponding mitigation and residual risk.

## Project Overview

Hamma is a single-binary Flutter app (Linux, Windows, macOS, Android, iOS)
that combines an SSH/SFTP client, Docker/systemd/process panels, encrypted
snippet vault, and an AI copilot. The AI copilot can run against:

- **Local engines** (default, recommended): Ollama, LM Studio, llama.cpp,
  Jan, or Hamma's own bundled `llama-server` side-car — all bound to
  loopback.
- **Cloud engines** (opt-in): OpenAI, Gemini, OpenRouter — only when the
  user explicitly configures an API key.

There is no Hamma backend, no Hamma cloud account, no telemetry of prompts
or commands. All persistent state is local; opt-in encrypted backup and
snippet sync travel through user-owned destinations (S3-compatible,
Dropbox, iCloud, SFTP, WebDAV, Syncthing).

Tech stack: Flutter 3.32 / Dart 3.7, `dartssh2`, `xterm.dart`,
`flutter_secure_storage`, PointyCastle (Argon2id, AES-256-GCM, ECDSA),
optional Sentry (opt-in, scrubbed).

## Assets

- **Server credentials** — SSH passwords, private keys, passphrases, and
  per-server config. Stored in OS keychain via `flutter_secure_storage`
  (Keychain on iOS/macOS, Keystore on Android, libsecret on Linux, DPAPI
  on Windows). Compromise = full access to the user's fleet.
- **AI provider API keys** — OpenAI / Gemini / OpenRouter tokens. Same
  keychain, partitioned per provider in `ApiKeyStorage`. Compromise = paid
  inference billed to the user and (for some providers) prompt history
  retained server-side.
- **Trusted SSH host keys** — pinned per server in
  `TrustedHostKeyStorage`. Tampering enables silent MITM on subsequent
  connections.
- **App PIN / biometric unlock secret** — gates the app on every cold
  launch.
- **Snippets / custom quick actions** — frequently shell commands with
  embedded hostnames, paths, occasionally inline secrets. Sensitive by
  user content even though the schema is "just commands".
- **Encrypted backup blobs (HMBK v2)** — full export of secure-storage
  contents (server profiles, AI keys, trusted host keys). Confidentiality
  rests on the user's master password + Argon2id.
- **Local AI prompts and responses** — terminal output, log lines, and
  user questions sent to whichever model is configured. Highly sensitive
  in aggregate (paths, hostnames, error messages, occasional secrets in
  logs).
- **Bundled GGUF model files** — multi-GB downloads cached under
  `<appSupportDir>/bundled_models/`. Integrity matters (a swapped model
  could degrade output quality or, in pathological cases, alter
  suggestions).
- **Sentry crash payloads** — only when the user opts in; scrubbed before
  send.

## Trust Boundaries

- **Device ↔ user** — physical access / shoulder-surfing / unlocked
  device theft. Defended by app PIN + biometric on every cold launch and
  OS-level full-disk encryption (out of scope to enforce, in scope to
  recommend).
- **App ↔ OS keychain** — all long-lived secrets cross this boundary
  via `flutter_secure_storage`. Hamma trusts the OS keychain implicitly;
  a compromised keychain compromises Hamma.
- **Device ↔ remote server (SSH/SFTP)** — direct, encrypted dartssh2
  tunnel; no Hamma proxy. Host-key pinning on first-trust; mismatch on
  re-connect prompts the user.
- **Device ↔ local LLM** — loopback HTTP only. Hardened in
  `OllamaClient.isLoopbackEndpoint()` (rejects construction with a
  non-loopback URL) and re-enforced by `BundledEngine` (refuses non-
  loopback inbound connections via `request.connectionInfo.remoteAddress
  .isLoopback`). Covered by `test/zero_trust_network_guard_test.dart`.
- **Device ↔ cloud LLM (opt-in)** — direct HTTPS to provider with the
  user's API key. The user is informed; loopback enforcement is bypassed
  intentionally for this provider class only.
- **Device ↔ cloud sync destination (opt-in)** — S3/Dropbox/iCloud/etc.
  Hamma uploads ciphertext only; the `CloudSyncEngine` HMBK header guard
  refuses to PUT anything not starting with `HMBK\x02`.
- **Device ↔ Sentry (opt-in)** — outbound HTTPS, payloads scrubbed by
  `ErrorScrubber.scrub()` both pre-display and pre-send.
- **App ↔ bundled `llama-server` subprocess** — loopback IPC via an
  ephemeral OS-assigned port. The subprocess inherits the user's UID and
  the app's filesystem permissions.
- **App ↔ third-party Dart / native packages** — every dependency on
  `pub.dev` and every system library bundled by Nix/CMake is part of the
  TCB.

## Threat Actors

- **Physical-access attacker** — has the unlocked device, or a locked
  device they can keep. May install a hardware/software keylogger.
- **Malicious server admin** — the SSH server Hamma connects to is
  hostile (compromised host, honeypot, or actively malicious sysadmin).
- **Network adversary on-path** — Wi-Fi operator, ISP, state-level
  observer between the device and any remote endpoint.
- **Malicious cloud destination** — S3/Dropbox/iCloud account
  compromised, or the provider itself is hostile/curious.
- **Malicious or compromised LLM** — locally-run model that emits
  prompt-injection-style suggestions (e.g. "run `rm -rf /` to fix this
  warning"), or a remote provider that exfiltrates prompt content.
- **Malicious Dart package / native dependency** — supply-chain
  attack via `pub.dev`, GitHub release tarballs (e.g. `llama-server`
  binaries), or transitive Nix packages.
- **Malicious GGUF model file** — a tampered model swapped into
  `<appSupportDir>/bundled_models/` either through host compromise or
  through a hostile catalog mirror.

## Scan Anchors

- **Production entry points:** `lib/main.dart` (`_bootstrapAndRun`,
  `runZonedGuarded`); platform shells under `linux/runner/`,
  `android/app/src/main/`, `ios/Runner/`, `macos/Runner/`,
  `windows/runner/`.
- **Highest-risk code areas:**
  - Secrets / keychain: `lib/core/storage/api_key_storage.dart`,
    `lib/core/storage/trusted_host_key_storage.dart`.
  - SSH transport + state machine: `lib/core/ssh/`.
  - Crypto: `lib/core/backup/backup_crypto.dart`,
    `lib/core/sync/snippet_sync_service.dart`.
  - AI loopback boundary: `lib/core/ai/ollama_client.dart`,
    `lib/core/ai/local_engine_detector.dart`,
    `lib/core/ai/local_engine_health_monitor.dart`,
    `lib/core/ai/bundled_engine.dart`,
    `lib/core/ai/llama_server_backend.dart`,
    `lib/core/ai/bundled_model_downloader.dart`.
  - Cloud sync transports + adapters: `lib/core/backup/cloud_sync_engine.dart`,
    `lib/core/backup/cloud_sync_adapter.dart`,
    `lib/core/backup/s3_compat_adapter.dart`,
    `lib/core/backup/dropbox_adapter.dart`,
    `lib/core/backup/icloud_adapter.dart`,
    `lib/features/settings/cloud_sync_screen.dart`.
  - Snippet sync: `lib/core/sync/snippet_sync_service.dart`,
    `lib/core/sync/snippet_change_bus.dart`,
    `lib/core/sync/snippet_sync_storage.dart`.
  - Error / telemetry surfaces: `lib/core/error/error_scrubber.dart`,
    `lib/core/error/error_reporter.dart`.
  - Live log triage AI surface: `lib/core/ai/log_triage/`.
- **Public vs authenticated vs admin:** Hamma has no server, so the only
  "auth" boundary is the app-lock PIN/biometric gate enforced before any
  feature screen is reachable. Within the app, all features are equally
  privileged once unlocked.
- **Dev-only areas to ignore unless reachable in production:** `test/`,
  `native/README.md` build instructions, `installer/windows/hamma.iss`
  packaging, AppImage tooling.

## Threat Categories

### Spoofing

- **SSH host spoofing.** First-connection key is pinned in
  `TrustedHostKeyStorage`; subsequent mismatches surface a hard prompt
  rather than auto-accepting. *Required guarantee:* a host-key mismatch
  MUST NOT be silently overwritten — the user MUST be shown the old and
  new fingerprints and must explicitly approve replacement.
- **Local AI engine impersonation.** `OllamaClient` refuses any non-
  loopback endpoint at construction. `LocalEngineDetector` only probes
  `127.0.0.1`. *Required guarantee:* every code path that dials a "local"
  engine MUST funnel through `OllamaClient.isLoopbackEndpoint()` or
  equivalent loopback assertion before opening a socket.
- **Cloud LLM impersonation.** TLS via `dart:io HttpClient`; no custom
  cert pinning. *Required guarantee:* HTTPS only — refuse `http://`
  endpoints for any non-local provider.
- **App-lock bypass.** PIN + biometrics enforced on every cold launch
  through the app-lock gate. *Required guarantee:* no feature screen
  (terminal, SFTP, settings, AI) MUST be reachable without first clearing
  the lock; biometric failure MUST fall back to PIN, never to "skip".

### Tampering

- **In-flight tampering of SSH/SFTP traffic.** Mitigated by the SSH
  transport itself (dartssh2 ECDSA/Ed25519 handshake + per-channel MAC).
  *Required guarantee:* host-key pinning MUST be enforced; agent
  forwarding MUST default to off and be enabled per-server only.
- **Backup blob tampering.** AES-256-GCM provides authenticated
  encryption; any tamper flips the GCM tag and surfaces the
  indistinguishable "Incorrect password or corrupted file" error.
  *Required guarantee:* `BackupCrypto` MUST NOT add an unauthenticated
  fast-path; every path through `decrypt()` MUST verify the GCM tag.
- **Cloud manifest tampering.** `CloudSyncEngine` writes a SHA-256 of
  each ciphertext blob into `manifest.json`. *Required guarantee:* on
  restore, the engine MUST verify the manifest hash matches the
  downloaded ciphertext before handing it to `BackupCrypto.decrypt`.
- **Tampered local AI suggestion ("malicious LLM").** Every command
  surfaced by the AI is gated by `CommandRiskAssessor` and presented in
  an `InteractiveCommandBlock` that the user must explicitly approve
  before execution. *Required guarantee:* AI-suggested commands MUST
  NEVER auto-execute against any shell — even when surfaced through the
  log-triage "Watch with AI" screen, the one-tap action MUST honour the
  risk gate's `block` verdict.
- **Tampered GGUF model.** `BundledModelDownloader` enforces HTTPS-only
  (rejects redirects that downgrade) and writes via a `.partial` file
  with atomic rename. *Required guarantee:* the curated catalog
  (`bundled_model_catalog.dart`) MUST remain HTTPS-only; future model
  metadata SHOULD include an expected SHA-256 to verify against the
  downloaded blob.

### Repudiation

Hamma is a single-user local app; there is no notion of "another party"
who could later dispute that an action took place. The local terminal /
shell history surfaces what the user did, but Hamma does not promise
tamper-proof audit logs. *Required guarantee (limited):* AI command
acceptance and execution events SHOULD be visible in the conversation
transcript so a user can reconstruct what they ran.

### Information Disclosure

- **Prompts & log lines leaving the device.** Loopback-only enforcement
  on every local-AI code path (see Spoofing). The only egress for prompt
  content is when the user explicitly selects a cloud provider.
  *Required guarantee:* the local-AI code paths MUST remain covered by
  `test/zero_trust_network_guard_test.dart`.
- **Plaintext upload to cloud destinations.** `CloudSyncEngine` rejects
  any blob that does not begin with the HMBK v2 magic header.
  *Required guarantee:* the HMBK header guard MUST stay in place; any
  new transport (e.g. future Drive/OneDrive adapter) MUST go through
  `CloudSyncEngine`, never bypass it.
- **Secrets in error messages and Sentry payloads.** `ErrorScrubber`
  removes passwords, PINs, tokens, API keys, bearer headers, OpenAI
  `sk-…` keys, JWTs, and PEM private-key blocks before display and
  before Sentry send. *Required guarantee:* all error display surfaces
  (in-widget panel, crash screen, snackbars) MUST funnel through
  `ErrorScrubber.scrub()`; new fatal paths MUST be added to
  `ErrorReporter.lastFatal` capture.
- **Backup file at rest on shared / cloud filesystems.** Argon2id
  (m=19 MiB, t=2, p=1) + AES-256-GCM with random salt + IV per backup.
  *Required guarantee:* KDF parameters MUST NOT be weakened without a
  format-version bump; PBKDF2 v1 remains decrypt-only.
- **Snippets blob.** Same HMBK envelope as full backups; uploaded under
  `snippets/snippets.aes`. *Required guarantee:* snippet sync MUST NEVER
  upload plaintext; the same encrypter pipeline used for backups MUST
  be used.
- **Sensitive content visible on screen.** Out of scope for software
  defence; mitigated only by the OS lock screen and the user's
  environment.

### Denial of Service

- **Local: runaway model load / pull.** Pull progress is streamed and
  cancellable; engine health probe runs at 15 s intervals only when the
  AI surface is mounted (auto-dispose). *Required guarantee:* the
  health monitor MUST stop polling when no consumer is subscribed.
- **SSH reconnect storm.** State machine bounded by
  `reconnectBackoffSeconds` (default `[5, 10, 20, 30, 60]`) and
  `maxReconnectAttempts` (default 5). Constructor rejects bad values
  with `ArgumentError`. *Required guarantee:* defaults MUST stay
  bounded; an "infinite retry" mode MUST require explicit user opt-in.
- **Log-triage flood.** `LogBatcher` clamps batches to a hard cap of
  500 lines and the user-tunable cadence (10–500). *Required
  guarantee:* the hard cap MUST NOT be removed; the AI is rate-limited
  by the batcher, not by the upstream `tail -f` rate.
- **Backup memory pressure.** Argon2id at m=19 MiB is bounded;
  encryption/decryption operates on byte arrays sized by the user's
  secure storage (low MB at most for the foreseeable future).

### Elevation of Privilege

- **AI-suggested destructive commands.** `CommandRiskAssessor` rates
  every suggestion (`safe / review / danger / block`); the
  `InteractiveCommandBlock` requires an explicit tap to send to the
  shell. *Required guarantee:* no code path MUST auto-execute an AI
  suggestion; the "Watch with AI" surface MUST refuse one-tap execution
  when the risk gate returns `block`.
- **Sudo fallback in SFTP.** Triggered explicitly by the user from a
  permission-denied dialog; runs the user's own shell sudo, not a
  privilege-elevated daemon. *Required guarantee:* sudo fallback MUST
  remain user-initiated and MUST display the exact command to be run
  before execution.
- **Path traversal via SFTP filenames.** Renames and downloads use the
  paths returned by the server; the local destination is a user-chosen
  directory. *Required guarantee:* downloaded filenames MUST be
  sanitised (no `..`, no absolute paths) before being joined to the
  local destination.
- **Plugin / extension API (Phase 7, not yet shipped).** Any future
  plugin API will introduce a new privilege boundary. *Required
  guarantee (forward-looking):* plugins MUST run with an explicit,
  least-privilege capability set (no implicit access to the keychain,
  the SSH transport, or the AI provider keys); to be revisited at the
  start of Phase 7 with a dedicated threat-model update.

## Mitigations Already Shipped

| Claim in README                              | Where it lives                                                                       |
| :------------------------------------------- | :----------------------------------------------------------------------------------- |
| Credentials in OS keychain                   | `lib/core/storage/api_key_storage.dart`, `lib/core/storage/trusted_host_key_storage.dart` |
| Argon2id (m=19 MiB, t=2, p=1) + AES-256-GCM  | `lib/core/backup/backup_crypto.dart`                                                 |
| Direct (zero-proxy) SSH transport            | `lib/core/ssh/ssh_transport.dart`, `lib/core/ssh/ssh_service.dart`                   |
| Local AI loopback enforcement                | `OllamaClient.isLoopbackEndpoint`, `BundledEngine`, `test/zero_trust_network_guard_test.dart` |
| AI risk-scored, never auto-executed          | `CommandRiskAssessor`, `InteractiveCommandBlock`, log-triage gating                  |
| App PIN + biometrics on every cold launch    | App-lock gate at app entry                                                           |
| Sentry opt-in, prompts and secrets scrubbed  | `lib/core/error/error_scrubber.dart`, `lib/core/error/error_reporter.dart`           |
| Cloud uploads ciphertext-only (HMBK guard)   | `lib/core/backup/cloud_sync_engine.dart`, `test/cloud_sync_zero_trust_test.dart`     |
| Snippet sync uses same HMBK envelope         | `lib/core/sync/snippet_sync_service.dart`                                            |
| Bundled model downloads HTTPS-only, atomic   | `lib/core/ai/bundled_model_downloader.dart`                                          |

## Residual Risks (Documented, Not Defended)

These are risks Hamma explicitly does *not* defend against in the current
release. They are listed here so users can make an informed decision and
contributors know where the boundary of the security model is drawn.

1. **Compromised OS keychain.** If `Keychain` / `Keystore` / `libsecret`
   / DPAPI is rooted, every secret Hamma stores there is exposed. Out of
   scope to defend against from inside an app.
2. **Root / kernel-level malware on the host.** A keylogger, screen
   scraper, or `ptrace`-capable attacker on the same machine defeats
   loopback enforcement, app-lock, and clipboard hygiene.
3. **Physical extraction of an unlocked device.** Once the user has
   cleared the app lock, all live state is in process memory and
   accessible to anyone with the device in hand.
4. **Compromised local LLM weights.** Hamma does not yet pin SHA-256
   hashes for catalog models; a malicious mirror could swap weights.
   The user-visible damage is limited by the AI risk gate (no auto-
   execution), but degraded suggestions are possible.
5. **Compromised Dart / native dependency.** Supply-chain attacks on
   `pub.dev`, `llama-server` GitHub release tarballs, or bundled Nix
   packages are not independently verified beyond what those upstreams
   provide.
6. **Side-channel timing of Argon2id / AES-GCM.** PointyCastle's pure-
   Dart implementations are not constant-time across all paths; in
   practice this matters only against a co-located attacker.
7. **Cloud destination metadata.** Filenames (`<deviceId>/<isoTimestamp
   >.bin`) and blob sizes leak rough sync cadence and device identity
   to the cloud provider, even though the contents are HMBK-encrypted.
8. **Telemetry of the cloud LLM path.** When the user opts into
   OpenAI/Gemini/OpenRouter, Hamma cannot stop the provider from
   logging or training on the prompt — the privacy guarantee narrows
   to "we transmit only what you typed, over HTTPS, with your key".
9. **Multi-device cloud-manifest contention.** Two devices syncing
   simultaneously may produce conflict snapshots; the merge path is
   newest-wins per device. Tracked as a follow-up.
10. **iCloud sync on Apple platforms.** The Dart adapter exists, but
    the native iOS/macOS shim is not yet shipped. The destination is
    hidden on non-Apple platforms; on Apple, it currently throws.
    Tracked as a follow-up.

## Out of Scope for v1

- Penetration test report (external work).
- CVE / advisory tracking process.
- Compliance mappings (SOC 2, ISO 27001, FedRAMP).
- Patches for the residual risks above — this document records them;
  individual mitigations are tracked as follow-up tasks.
