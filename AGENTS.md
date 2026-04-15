# AGENTS.md

## Project
**Name:** AI Server V2  
**Goal:** Build a mobile-first app that lets users manage remote servers easily through **direct SSH from the device**, with optional AI assistance for generating and safely executing commands.

This project is **not** a backend-managed SSH proxy.
This project is **not** a Termius clone.
This project is a **smart server control app**:
- direct SSH connection
- clean mobile UI
- quick actions
- AI-generated command suggestions
- terminal available for power users

## Current Status

- MVP: complete
- UI polish phase: 100% complete
- Secure local credential storage: complete
- Release stage: Beta Release Candidate

---

## Core Product Vision

The app should let a user:

1. Add a server with:
   - host/IP
   - port
   - username
   - password or SSH key

2. Connect **directly** from the mobile app to that server over SSH

3. Use:
   - terminal
   - file explorer
   - quick action buttons
   - AI-generated command suggestions

4. Execute real server actions without needing deep terminal knowledge

### Product one-liner
**“Manage your server without writing commands.”**

---

## Architecture Principles

### 1. Direct SSH first
SSH must happen **directly from the Flutter app** using an SSH library.

Do **not** build the core experience around:
- backend SSH session pooling
- backend-managed live terminal state
- API-based SSH transport unless absolutely necessary

### 2. Backend is optional/supporting
Backend, if used, should only support:
- auth/account
- sync across devices
- AI processing
- history/preferences
- subscriptions/payments

Backend should **not** be required for core SSH connection and command execution.

### 3. AI is an assistant, not the transport layer
AI should help:
- explain problems
- suggest commands
- generate action plans
- convert user intent into safe shell commands

AI should **not** replace the SSH layer.

### 4. Terminal remains available
Even though the product simplifies server control, raw terminal access must remain available for advanced users.

### 5. Safety before execution
Never blindly execute AI-generated commands.
Always show:
- what will run
- why it is suggested
- confirmation before execution

---

## MVP Scope

### Must Have (Complete)
- Add/edit/delete saved servers
- Direct SSH connection from device
- Terminal screen
- Run single commands and show output
- Quick action buttons for common tasks
- AI command suggestion screen
- Command preview + confirm execution
- Local secure storage for credentials

### Nice to Have
- File explorer over SFTP
- Multi-device sync
- Encrypted host/profile sync
- AI chat history
- Saved snippets/actions

### Not in MVP
- Team collaboration
- Complex backend orchestration
- Full autonomous agents
- Always-on monitoring backend
- Kubernetes/cloud fleet management

---

## Recommended Tech Direction

### Flutter
Use Flutter for mobile app UI.

### SSH
Preferred direction:
- direct SSH from Flutter app
- simple and reliable session lifecycle
- reconnect on demand

Possible libraries to evaluate:
- `dartssh2`
- `xterm` for terminal UI

### Storage
Use secure local storage for:
- credentials
- saved hosts
- settings

### AI
AI integration should be modular.

Possible modes:
1. App-provided API
2. User-provided API key
3. Optional provider abstraction for future multi-model support

---

## UX Principles

### 1. Simple first
A user who does not know Linux should still be able to:
- connect
- restart a service
- inspect logs
- run safe actions

### 2. Buttons over commands
Prefer:
- “Restart backend”
- “Check logs”
- “Update server”
- “Install Docker”

instead of forcing raw shell commands.

### 3. Explain what is happening
When AI suggests or the app runs a command, explain:
- what it does
- what may happen
- whether it is risky

### 4. Terminal is fallback, not main UX
The terminal is there for advanced control, but the product should not depend on users being terminal experts.

### 5. Avoid fake states
Never show:
- “Connected”
- “Successful”
- “Healthy”

unless the app has actually verified it.

---

## Command Execution Rules

### AI-generated commands
All AI-generated commands must:
- be visible before execution
- be editable when reasonable
- be confirmable by the user
- include warnings for risky operations

### Dangerous commands
Flag commands involving:
- deletion
- overwrite
- system-wide package removal
- permission changes
- firewall changes
- SSH config changes
- Docker prune / destructive cleanup
- database resets
- recursive deletion

### Confirm-first examples
Require confirmation for anything like:
- `rm -rf`
- `chmod -R`
- `chown -R`
- `iptables`
- `ufw`
- `systemctl stop`
- `docker system prune`
- database migration/reset commands
- editing nginx/ssh critical config

---

## Codebase Priorities

When making decisions, prioritize:

1. Reliability
2. Simplicity
3. Clear UX
4. Safe execution
5. Maintainability
6. Speed of iteration

Avoid overengineering.

---

## Preferred App Structure

Example direction:

```text
lib/
  core/
    ssh/
    ai/
    storage/
    models/
    theme/
  features/
    auth/
    servers/
    terminal/
    file_explorer/
    dashboard/
    quick_actions/
    ai_assistant/
  shared/
    widgets/
    utils/
  main.dart
```
