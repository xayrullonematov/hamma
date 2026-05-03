# Changelog

All notable changes to Hamma are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [1.1.0] — 2026-05-03

### Added
- **First-class Local AI provider** — privacy-first path that keeps every prompt and response on-device.
- **Native Ollama API client** — direct support for `GET /api/tags`, `POST /api/pull` (streaming progress), `DELETE /api/delete`, `GET /api/ps`, and `GET /api/version`, alongside the existing OpenAI-compatible path.
- **Engine auto-detection** — on-demand probe of the well-known local ports for Ollama (11434), LM Studio (1234), llama.cpp server (8080), and Jan (1337) with one-tap endpoint switching.
- **Streaming chat replies** — token-by-token rendering in the AI assistant and copilot sheet, consuming Ollama's NDJSON stream and SSE for OpenAI-compatible engines.
- **Local Models manager** — new screen under Settings → Local AI listing installed models with size, set-default, and delete actions, plus a curated catalog (Gemma 3, Llama 3, Mistral, Qwen2.5-Coder, Phi-3) with live pull progress and a free-text "pull custom model" field.
- **Engine status pill** — header pill in the AI assistant with four states (online · loading-model · loading · offline), 15 s ping cadence while open, auto-dispose when closed, and a universal-tap details sheet exposing engine info plus a "Retry now" action.
- **3-step onboarding wizard** — first-run flow (Install · Pull · Done) shown when Local AI is selected and either no engine responds or no models are installed; OS-aware install snippets for Linux, Windows, macOS, and Android.
- **Runtime loopback enforcement** — Local AI endpoints are validated at construction time and any non-loopback host (anything outside `127.0.0.0/8`, `::1`, or `localhost`) throws before a single byte goes out.

### Changed
- Settings screen now validates the Local AI endpoint inline; the Test, Detect, and Manage Models buttons gate on a passing validation so misconfigured endpoints can't trigger network calls.

### Security
- Added a runtime guard that prevents non-loopback Local AI endpoints from ever being instantiated, backed by `local_ai_loopback_guard_test.dart` (3 tests) and `zero_trust_network_guard_test.dart` (4 tests). Total suite is now 65/65 green.

### Suggested next step
- Tag and push to trigger the existing release pipeline:
  ```bash
  git tag v1.1.0
  git push origin v1.1.0
  ```

---

## [1.0.0] — 2026-04-30

### Added
- SSH client with full interactive terminal (xterm) across Linux, Windows, and Android
- SFTP file explorer — browse, upload, download, rename, delete
- Docker manager — list, start, stop, restart, remove containers; view live logs
- System services management (systemd) — start, stop, restart, enable, disable
- Process monitor — live CPU and RAM bars per process, kill support
- Package manager — apt/yum/pacman install, remove, update
- Port forwarding — local and remote tunnel management
- Log viewer — tail system and service logs with search
- Custom actions — save and run reusable SSH command snippets
- Fleet dashboard — multi-server overview with aggregate metrics
- AI assistant — natural language → shell commands via OpenAI, Gemini, or OpenRouter
- AI copilot — inline command risk scoring (LOW / MODERATE / HIGH / CRITICAL) with one-tap execution
- Command palette — keyboard-driven global search across all screens
- App lock — PIN / biometric protection
- Onboarding flow — guided first-run setup
- Settings — AI provider, API key, theme, backup/restore

### Design
- Geometric Brutalism visual identity: pure black scaffold, white text, red (#FF0000) for danger, cyan (#4ECDC4) accent, zero-radius corners, wireframe 1 px borders throughout
- Inter (UI) + JetBrains Mono (code / metrics) typography
- Responsive layout: desktop sidebar, mobile bottom-nav, tablet hybrid — all from one codebase

### Infrastructure
- GitHub Actions CI: Android APK (split per ABI), Linux AppImage, Windows Inno Setup installer
- GitHub Releases published automatically on `v*` tags
- Sentry crash reporting (inproc mode on Linux; crashpad on Windows/Android)
- Platform icons: Android mipmap set, Windows ICO, Linux GTK window icon

### Fixed
- Terminal keyboard input on Linux/Windows desktop routed through hardware keyboard only (`hardwareKeyboardOnly: true`) to bypass unreliable IME path

---

## How to release

```bash
# 1. Update version in pubspec.yaml  (MAJOR.MINOR.PATCH+BUILD)
# 2. Add release notes in this file under a new ## [X.Y.Z] heading
# 3. Commit and tag:
git tag vX.Y.Z
git push origin vX.Y.Z
# CI builds all platforms and publishes the GitHub Release automatically.
```
