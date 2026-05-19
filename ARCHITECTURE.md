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

| Technology | Version | Role |
|---|---|---|
| **Flutter** | 3.22+ | Cross-platform UI framework |
| **Dart** | 3.4+ | Application language |
| **xterm.dart** | Latest | Full VT100/xterm terminal emulation |
| **flutter_riverpod** | 2.x | State management |
| **go_router** | Latest | Navigation |

### Networking & SSH

| Technology | Role |
|---|---|
| **dartssh2** | SSH2 protocol implementation, SFTP subsystem |
| **dart:io** | Raw socket management, loopback enforcement |
| **ssh_key** | Key parsing (RSA, Ed25519, ECDSA) |

### AI Inference

| Technology | Role |
|---|---|
| **Ollama API** | Primary local inference server (OpenAI-compatible) |
| **llama.cpp server** | Alternative inference backend |
| **LM Studio API** | Alternative inference backend |
| **Jan API** | Alternative inference backend |
| **http (Dart)** | Streaming HTTP client for token-by-token response |

### Security & Storage

| Technology | Role |
|---|---|
| **Argon2id** | Key derivation for vault encryption |
| **AES-256-GCM** | Vault data encryption at rest |
| **local_auth** | Biometric authentication (FaceID, TouchID, fingerprint) |
| **flutter_secure_storage** | OS keychain integration |
| **hive** | Local structured data (server configs, settings) |

### Developer Tooling

| Technology | Role |
|---|---|
| **flutter_test** | Unit and widget testing (65/65 passing) |
| **mocktail** | Service mocking in tests |
| **very_good_analysis** | Strict lint rules |
| **GitHub Actions** | CI pipeline |

---

## Project Structure

```
hamma/
├── lib/
│   ├── main.dart                    # App entry point, provider scope
│   ├── app/
│   │   ├── router.dart              # go_router route definitions
│   │   └── theme.dart               # Brutalist design tokens
│   │
│   ├── features/
│   │   ├── terminal/                # SSH terminal feature
│   │   │   ├── terminal_screen.dart
│   │   │   ├── terminal_controller.dart
│   │   │   └── keyboard_row.dart    # Custom function key row
│   │   │
│   │   ├── sftp/                    # Visual SFTP browser
│   │   │   ├── sftp_screen.dart
│   │   │   ├── sftp_controller.dart
│   │   │   ├── file_editor.dart     # Syntax-highlighted editor
│   │   │   └── permission_dialog.dart
│   │   │
│   │   ├── ai/                      # AI copilot
│   │   │   ├── ai_chat_screen.dart
│   │   │   ├── ai_service.dart      # Loopback enforcement lives here
│   │   │   ├── risk_assessor.dart   # Command risk scoring
│   │   │   └── provider_config.dart # Ollama / llama.cpp / cloud settings
│   │   │
│   │   ├── fleet/                   # Multi-server dashboard
│   │   │   ├── fleet_screen.dart
│   │   │   ├── server_card.dart
│   │   │   └── health_poller.dart
│   │   │
│   │   ├── docker/                  # Docker & systemd panel
│   │   │   ├── docker_screen.dart
│   │   │   ├── container_list.dart
│   │   │   └── service_panel.dart
│   │   │
│   │   └── vault/                   # Encrypted credential vault
│   │       ├── vault_screen.dart
│   │       ├── vault_service.dart   # Argon2id + AES-256-GCM
│   │       └── biometric_guard.dart
│   │
│   ├── core/
│   │   ├── ssh/
│   │   │   ├── ssh_service.dart     # dartssh2 wrapper
│   │   │   └── sftp_service.dart
│   │   ├── models/
│   │   │   ├── server.dart
│   │   │   ├── credential.dart
│   │   │   └── ai_message.dart
│   │   └── utils/
│   │       ├── loopback_guard.dart  # Rejects non-127.x AI URLs
│   │       └── ansi_parser.dart
│   │
├── test/
│   ├── features/
│   │   ├── ai/
│   │   │   ├── ai_service_test.dart
│   │   │   └── risk_assessor_test.dart
│   │   ├── vault/
│   │   │   └── vault_service_test.dart
│   │   └── ssh/
│   │       └── ssh_service_test.dart
│   └── core/
│       └── loopback_guard_test.dart
│
├── assets/
│   ├── images/
│   │   └── logo.png
│   └── fonts/
│
├── android/
├── ios/
├── linux/
├── macos/
├── windows/
│
├── LOCAL_AI.md
├── SECURITY.md
├── ARCHITECTURE.md
├── ROADMAP.md
├── threat_model.md
└── README.md
```

---

## Feature Architecture: AI Copilot

The AI feature is the most security-critical component. Here is the full request lifecycle:

```
User types prompt in AI Chat screen
            │
            ▼
   AIService.sendMessage()
            │
            ▼
   LoopbackGuard.validate(url)
   ┌─────────────────────────┐
   │ Is host 127.x.x.x?      │
   │ YES → proceed            │
   │ NO  → throw              │
   │       SecurityException  │
   └─────────────────────────┘
            │ (local only)
            ▼
   HTTP POST to inference server
   (Ollama / llama.cpp / Jan)
            │
            ▼
   Stream response tokens
            │
            ▼
   RiskAssessor.score(response)
   ┌──────────────────────────────────────┐
   │ Contains rm -rf / iptables -F / dd?  │
   │  → RED   : require explicit confirm  │
   │ Contains restart / chmod / kill?     │
   │  → YELLOW: show caution badge        │
   │ Read-only commands?                  │
   │  → GREEN : display normally          │
   └──────────────────────────────────────┘
            │
            ▼
   Render in chat with risk badge
   User taps "Run" → pastes into terminal
```

The `LoopbackGuard` runs on every single AI request. It cannot be bypassed by user configuration — it is enforced at the service layer, below the settings UI.

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

## Future Architecture: Built-in Engine (Phase 4)

The current architecture requires Ollama as a separate process. Phase 4 replaces this with a bundled inference engine:

```
Current (Phase 2):
  HAMMA App  ──HTTP──►  Ollama (separate process)  ──►  GGUF

Future (Phase 4):
  HAMMA App  ──FFI──►  llama.cpp (bundled dylib)  ──►  GGUF module
```

The inference library will be bundled as a platform-specific dynamic library (`libllama.so` / `llama.dll` / `libllama.dylib`) and called via Dart FFI. No separate install. No separate process. One app, one install, full capability.

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
flutter test           # → 65/65 passed

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
