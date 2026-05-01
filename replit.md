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

Hamma supports a fully offline, zero-trust AI mode via any OpenAI-compatible local inference engine (Ollama, LM Studio, llama.cpp).

### Architecture
- `AiProvider.local` — new enum value in `lib/core/ai/ai_provider.dart`; `requiresApiKey = false`
- `AiApiConfig.forProvider()` — builds a config pointing to `{localEndpoint}/v1` with no Authorization header
- `AiCommandService` — routes `local` through `_chatWithOpenAi()` (Ollama is OpenAI-compatible); 5s connection timeout, 120s response timeout
- `AiSettings` — stores `localEndpoint` (default `http://localhost:11434`) and `localModel` (default `gemma3`) in secure storage
- `AiCopilotSheet` — `_hasActiveApiKey` returns `true` for no-key providers; fast-paths `_loadActiveProviderState` to skip key loading
- Settings UI — brutalist "ZERO TRUST / OFFLINE CAPABLE" badge, endpoint URL field, model name field, "TEST CONNECTION" button with real-time status

### Usage
1. In Settings, select "Local AI" as the provider
2. Set engine endpoint (default: `http://localhost:11434`)
3. Set model name matching `ollama list` output (e.g., `gemma3`, `llama3`, `mistral`)
4. Click "TEST CONNECTION" to verify Ollama is running
5. Save — no API key needed

### Quick start (Ollama)
```bash
ollama serve          # start the engine
ollama pull gemma3    # download the model (~5 GB)
```

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
