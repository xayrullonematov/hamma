# Changelog

All notable changes to Hamma are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

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
