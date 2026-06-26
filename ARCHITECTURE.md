<!--
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   H A M M A — Architecture                                           ║
  ║   Flutter · Dart · Local Inference · Zero-Trust                      ║
  ╚══════════════════════════════════════════════════════════════════════╝
-->

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=140&section=header&text=ARCHITECTURE&fontSize=38&fontColor=FFFFFF&animation=fadeIn&fontAlignY=55" alt="Architecture" width="100%"/>

<p>
  <img src="https://img.shields.io/badge/FRAMEWORK-Flutter_3.22+-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/LANGUAGE-Dart_3.4+-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/AI-Local_GGUF-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/PLATFORMS-5-00FF88?style=flat-square&labelColor=000000"/>
</p>

[← Back to README](README.md)

</div>

---

## System Overview

HAMMA is a modular, layered application. The UI layer never talks to the network directly — every external operation (SSH, SFTP, AI inference) goes through an isolated service layer with explicit trust boundaries.

```
╔═══════════════════════════════════════════════════════════════╗
║                        USER DEVICE                            ║
║                                                               ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │                   Flutter UI Layer                       │  ║
║  │   Terminal · SFTP Browser · AI Chat · Fleet Dashboard   │  ║
║  └────────────────────────┬────────────────────────────────┘  ║
║                           │                                   ║
║  ┌────────────────────────▼────────────────────────────────┐  ║
║  │                  Service Layer (Dart)                    │  ║
║  │  SSHService · SFTPService · AIService · VaultService    │  ║
║  └──────┬──────────────┬──────────────┬────────────────────┘  ║
║         │              │              │                        ║
║         │         127.0.0.1          │                        ║
║         │              │              │                        ║
║  ┌──────▼──────┐ ┌─────▼──────┐ ┌───▼────────────────────┐  ║
║  │  SSH/SFTP   │ │  Inference  │ │    Encrypted Vault      │  ║
║  │  (dartssh2) │ │   Engine    │ │  (Argon2id + AES-256)   │  ║
║  │             │ │  (Ollama /  │ │                         │  ║
║  │             │ │  llama.cpp) │ │                         │  ║
║  └──────┬──────┘ └─────────────┘ └─────────────────────────┘  ║
║         │                                                      ║
╚═════════│══════════════════════════════════════════════════════╝
          │  Encrypted SSH tunnel
          ▼
   ┌─────────────────┐
   │  Remote Server  │
   │  (your fleet)   │
   └─────────────────┘
```

**Key architectural constraints:**

- AI inference is hard-locked to `127.0.0.0/8` — rejected at the `AIService` layer before any socket is opened
- SSH private keys never touch disk unencrypted — they live in the vault and are decrypted in-memory only during active sessions
- The UI layer has no direct access to credentials or AI endpoints — all routing goes through the service layer

---

## Tech Stack

### Frontend

| Technology | Role |
|---|---|
| **Flutter** | Cross-platform UI framework (Material 3) |
| **Dart** | Application language |
| **xterm.dart** | Full VT100/xterm terminal emulation |
| **Sentry** | Crash reporting and error scrubbing |
| **Window Manager** | Desktop window customization (title bar, size) |

### Networking & SSH

| Technology | Role |
|---|---|
| **dartssh2** | SSH2 protocol implementation, SFTP subsystem |
| **dio** | Robust HTTP client for AI provider APIs |
| **http** | Lightweight HTTP for simple probes |

### AI Inference

| Technology | Role |
|---|---|
| **fllama** | Native llama.cpp bindings (FFI) for on-device inference |
| **Ollama API** | Local inference server integration |
| **LM Studio / Jan** | Alternative local inference backends |

### Security & Storage

| Technology | Role |
|---|---|
| **Argon2id** | Key derivation (via `pointycastle`) |
| **AES-256-GCM** | Vault data encryption (via `pinenacl`) |
| **local_auth** | Biometric authentication (FaceID, TouchID, fingerprint) |
| **flutter_secure_storage** | OS keychain integration for KDF salt |
| **Hive** | Local structured data storage |

### Developer Tooling

| Technology | Role |
|---|---|
| **flutter_test** | Unit and widget testing (857 passing, 1 skipped integration test) |
| **mocktail** | Service mocking in tests |
| **flutter_lints** | Standard lint rules |
| **GitHub Actions** | CI pipeline |

---

## Project Structure

```
hamma/
├── lib/
│   ├── main.dart                    # App entry point, bootstrap, theme
│   │
│   ├── features/
│   │   ├── terminal/                # SSH terminal feature
│   │   │   └── terminal_screen.dart
│   │   │
│   │   ├── sftp/                    # Visual SFTP browser
│   │   │   ├── file_explorer_screen.dart
│   │   │   └── file_editor_screen.dart
│   │   │
│   │   ├── ai_assistant/            # AI chat and copilot
│   │   │   ├── global_command_palette.dart
│   │   │   └── ai_copilot_sheet.dart
│   │   │
│   │   ├── servers/                 # Server management
│   │   │   ├── server_list_screen.dart
│   │   │   └── server_dashboard_screen.dart
│   │   │
│   │   └── security/                # App lock and vault UI
│   │       └── app_lock_screen.dart
│   │
│   ├── core/
│   │   ├── ssh/
│   │   │   ├── ssh_service.dart     # dartssh2 wrapper
│   │   │   └── sftp_service.dart
│   │   │
│   │   ├── ai/
│   │   │   ├── ai_command_service.dart # AI provider management
│   │   │   ├── ollama_client.dart      # Loopback enforcement seatbelt
│   │   │   └── inference_engine.dart   # Native llama.cpp (fllama) loader
│   │   │
│   │   ├── vault/
│   │   │   ├── vault_storage.dart   # Argon2id + AES-256-GCM
│   │   │   └── vault_redactor.dart  # Data masking logic
│   │   │
│   │   ├── storage/
│   │   │   ├── saved_servers_storage.dart
│   │   │   └── api_key_storage.dart
│   │   │
│   │   └── models/
│   │       ├── server_profile.dart
│   │       └── ai_provider.dart
│   │
│   ├── ui/                          # Shared UI components
│   └── plugins/                     # Built-in modular plugins
│
├── test/
│   ├── ai_command_service_test.dart
│   ├── api_key_storage_test.dart
│   ├── local_ai_loopback_guard_test.dart
│   └── ... (flat structure for discovery)
```

---

## Feature Architecture: AI Copilot

The AI feature is the most security-critical component. Here is the full request lifecycle:

```
User types prompt or requests analysis
            │
            ▼
   AiCommandService.sendMessage()
            │
            ▼
   OllamaClient.isLoopbackEndpoint(url)
   ┌─────────────────────────┐
   │ Is host 127.x.x.x?      │
   │ YES → proceed            │
   │ NO  → throw              │
   │       ArgumentError      │
   └─────────────────────────┘
            │ (local mode enforcement)
            ▼
   HTTP/FFI request to engine
   (Ollama / llama.cpp / Jan / fllama)
            │
            ▼
   Stream response tokens
            │
            ▼
   CommandRiskAssessor.score(cmd)
   ┌──────────────────────────────────────┐
   │ Contains rm -rf / iptables -F / dd?  │
   │  → CRITICAL: extra friction          │
   │ Contains systemctl stop / kill?      │
   │  → HIGH    : caution badge           │
   └──────────────────────────────────────┘
            │
            ▼
   Render in chat with risk badge
   User taps "Execute" → runs via SshService
```

The loopback check is enforced at the constructor and request level for local providers. It cannot be bypassed by UI configuration.


---

## Feature Architecture: Encrypted Vault

```
User sets PIN on first launch
            │
            ▼
   Argon2id KDF
   (salt stored in flutter_secure_storage)
            │
            ▼
   AES-256-GCM encryption key derived
            │
            ▼
   All credentials encrypted at rest
   (SSH keys, passwords, passphrases)
            │
            ▼
   Biometric unlock (FaceID / fingerprint)
   decrypts vault key into memory only
   — never written to disk unencrypted —
            │
            ▼
   SSH session uses key from memory
   Key zeroed from memory on session close
```

---

## Platform Support

| Platform | Status | Notes |
|---|---|---|
| **Linux** | ✅ Full support | Primary development platform |
| **macOS** | ✅ Full support | Metal GPU acceleration for local AI |
| **Windows** | ✅ Full support | DirectML GPU support via Ollama |
| **Android** | ✅ Beta | Biometric via fingerprint sensor |
| **iOS** | ✅ Beta | Biometric via Face ID / Touch ID |

All five platforms share the same Dart business logic. Only platform-specific UI adaptations (keyboard row layout, biometric API calls) differ per platform.

---

## Data Flow: What Leaves Your Device

| Data | Destination | Encrypted |
|---|---|---|
| SSH credentials | Your servers only | ✅ AES-256-GCM in vault, TLS in transit |
| Terminal I/O | Your servers only | ✅ SSH tunnel |
| AI prompts (local mode) | `127.0.0.1` only | ✅ Never leaves device |
| AI prompts (cloud opt-in) | Provider API | ✅ TLS — clearly flagged in UI |
| Server configs | Local disk (Hive) | ✅ Encrypted |
| App analytics | **Nowhere** | n/a — zero telemetry |
| Crash reports | **Nowhere** | n/a — zero telemetry |

---

## Next Architecture: Built-in Engine (Phase 4)

The current production local-AI path supports Ollama and OpenAI-compatible loopback servers. Phase 4 moves the primary path to a bundled inference engine while keeping Ollama as a fallback:

```
Current local AI path:
  HAMMA App  ──HTTP──►  Ollama (separate process)  ──►  GGUF

Phase 4 target:
  HAMMA App  ──FFI──►  llama.cpp (bundled dylib)  ──►  GGUF module
```

The codebase already has groundwork for this path: `fllama` native assets, bundled-engine abstractions, a model downloader, and loopback-compatible engine tests. The remaining Phase 4 work is making that production-grade across platforms: package the native libraries, verify model checksums, stream inference through Dart FFI, and fall back cleanly to Ollama if the bundled engine is unavailable.

Modules will be downloaded on-demand from the HAMMA module registry — small, specialized GGUF adapters for each domain.

→ [**Full roadmap**](ROADMAP.md)

---

## Development Setup

```bash
# Clone
git clone https://github.com/xayrullonematov/hamma.git
cd hamma

# Install dependencies
flutter pub get

# Verify
flutter analyze        # → No issues found
flutter test           # → 857 passed, 1 skipped

# Run on your platform
flutter run            # uses connected device / emulator
flutter run -d linux   # explicit platform
flutter run -d macos
flutter run -d windows
```

**Adding a new AI provider:**

1. Implement `AIProvider` interface in `lib/features/ai/provider_config.dart`
2. Add provider to the `AIProviderRegistry`
3. Ensure `LoopbackGuard` validation is called before any HTTP request
4. Add tests in `test/features/ai/`

---

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=MODULAR%20·%20AUDITABLE%20·%20LOCAL-FIRST&fontSize=14&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>[← Back to README](README.md) · [LOCAL_AI.md](LOCAL_AI.md) · [SECURITY.md](SECURITY.md) · [ROADMAP.md](ROADMAP.md)</sub>

</div>
