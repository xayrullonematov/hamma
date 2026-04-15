# Hamma

**AI Server V2** is a mobile-first Flutter app for managing remote servers through **direct SSH from the device**, with AI assistance for safe command suggestions and guided execution.

## Status

- MVP: Complete
- UI Polish: Complete
- Secure Storage: Implemented
- Release Stage: Beta Release Candidate

## Core Features

- Direct SSH connection from the mobile app using `dartssh2`
- Premium Dark Mode UI across the main product surfaces
- Mobile-Friendly Terminal Toolbar with essential power keys for phone-based SSH
- Modern AI Chat Interface with Risk Badges and confirmation-first execution
- Multi-step AI command plans with editable commands and safety checks
- Quick Actions for common server tasks
- Raw terminal access for power users via `xterm`
- AES-Encrypted Local Credential Storage for API keys, saved servers, and trusted host keys

## Product Goal

**“Manage your server without writing commands.”**

The app is designed to help users:

1. Save server profiles with host, port, username, and password.
2. Connect directly from the device to the server over SSH.
3. Use a polished dashboard, quick actions, terminal access, and AI assistance.
4. Execute real server actions with clear previews, warnings, and confirmation.

## Architecture Principles

- Direct SSH first: no backend SSH proxy or pooled session transport for the core experience
- AI as assistant, not transport: AI explains and suggests, but SSH remains the execution layer
- Safety before execution: AI-generated commands stay visible, editable, and confirmable
- Terminal remains available: advanced users still get raw shell access

## Security

- Local settings and credentials are stored using `flutter_secure_storage`
- Saved server profiles are encrypted at rest
- Trusted host keys are stored securely for SSH trust decisions

## Tech Stack

- Flutter
- `dartssh2`
- `xterm`
- `flutter_secure_storage`

## Development

### Prerequisites

- Flutter SDK matching `pubspec.yaml`
- Android Studio and/or Xcode

### Commands

- Install dependencies: `flutter pub get`
- Run analyzer: `flutter analyze`
- Run tests: `flutter test`
- Run app: `flutter run`
- Build Android: `flutter build apk`
- Build iOS: `flutter build ios`

## Future Roadmap

The MVP is complete. Future work remains intentionally scoped to follow-up phases such as:

- File explorer over SFTP
- Multi-device sync
- Encrypted host/profile sync
- AI chat history
- Saved snippets and reusable actions
