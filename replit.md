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

## Key Modifications

- Fixed `DropdownButtonFormField.initialValue` → `value` in settings_screen.dart (Flutter 3.32.0 API change)
- Modified sentry_flutter CMakeLists to use `inproc` backend instead of `crashpad` to avoid native build dependencies
- Build output redirected from `/var/empty/local` to `build/install_prefix/` (writable path)

## Tech Stack

- **Framework**: Flutter 3.32.0 with Dart 3.8.0
- **SSH/SFTP**: dartssh2
- **Terminal emulation**: xterm
- **Security**: flutter_secure_storage, encrypt, pinenacl
- **Crash reporting**: sentry_flutter (inproc mode on Linux)
- **AI providers**: OpenAI, Google Gemini, OpenRouter (via HTTP)

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

## Visual Design — Geometric Brutalism

The UI uses a strict "Terafab" brutalist visual identity defined in
`lib/core/theme/app_colors.dart` and applied globally via the
`_buildBrutalistTheme()` helper in `lib/main.dart`.

Five design pillars enforced across all screens:

1. **Monochrome palette** — Pure black scaffold (`0xFF000000`), near-black
   surfaces (`0xFF0A0A0A`), white primary, harsh red (`0xFFFF0000`) for any
   risk/warning state. No slates, no soft grays.
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

Brutalist surfaces in custom widgets:

- `lib/features/ai_assistant/widgets/interactive_command_block.dart` —
  Risk header is a solid red bar for HIGH/CRITICAL commands; the editor
  uses monospace with a `$` prompt; "EXECUTE" button switches to harsh
  red for dangerous commands.
- `lib/features/fleet/fleet_dashboard_screen.dart` — Metric dials,
  status pills (`ONLINE`/`OFFLINE`), and bulk-result blocks use the
  monospace font and zero-radius bordered surfaces.
