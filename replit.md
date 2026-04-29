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
