# 🛡️ Hamma: AI Server Manager

<div align="center">
  <h3><b>"Manage your server without writing commands."</b></h3>
  <p><i>A mobile-first, high-performance SSH client enhanced with AI-driven safety and automation.</i></p>

  [![Status](https://img.shields.io/badge/Status-Beta--RC-blue.svg?style=for-the-badge)]()
  [![Tech](https://img.shields.io/badge/Stack-Flutter-02569B?style=for-the-badge&logo=flutter)]()
  [![AI](https://img.shields.io/badge/AI-Empowered-8E44AD?style=for-the-badge)]()
</div>

---

## 🌟 Overview

**Hamma** (AI Server V2) is a comprehensive DevOps command center in your pocket. It bridges the gap between raw terminal complexity and modern mobile UX, providing a "Safety-First" AI layer that explains logs, suggests fixes, and automates infrastructure management across your entire fleet.

---

## 🚀 Key Features

### 🧠 Smart AI Assistant & Copilot
*   **Contextual Command Generation:** Ask for what you need (e.g., "Fix my Nginx config") and get a verified command plan.
*   **Risk Assessment:** Every AI suggestion is analyzed by our **Command Risk Assessor** to flag dangerous operations.
*   **Smart Error Analysis:** One-tap analysis of SSH execution failures to understand and resolve issues instantly.

### 📁 Advanced SFTP File Manager
*   **Visual Explorer:** Browse, create, and delete files/folders with ease.
*   **In-App Editor:** Edit configuration files directly on the server with syntax highlighting.
*   **Sudo Fallback:** Automatically attempts to write files with `sudo` if permission is denied.

### 🐳 Container & System Orchestration
*   **Docker Manager:** Complete control over containers—list, start, stop, restart, and view live logs.
*   **Process & Service Manager:** Monitor CPU/RAM usage per process and manage `systemd` services.
*   **Package Manager:** Install or update packages across your server with a simplified UI.

### 🌐 Networking & Fleet Management
*   **Fleet Dashboard:** Monitor the health, availability, and resource metrics of all your servers in one unified view.
*   **Port Forwarding:** Set up SSH tunnels and forward ports directly from your mobile device.

---

## 🛠️ Getting Started (User Guide)

### 1. Secure Your App
When you first launch Hamma, set up an **App PIN** in Settings. This encrypts your local database and protects your server credentials.

### 2. Configure AI
Go to **Settings > AI Configuration** to unlock the Copilot features:
- **Supported Providers:** OpenAI, Google Gemini, and OpenRouter.
- *Your API keys are stored locally in the device's secure enclave.*

### 3. Manage Your Servers
Navigate to the **Servers** tab to add your infrastructure. Once connected, you can:
- **Dashboard:** View live resource metrics.
- **Terminal:** Use the mobile-optimized SSH terminal.
- **Tools:** Use the SFTP, Docker, or Service managers from the dashboard tiles.

---

## 🔒 Security & Privacy

- **Zero-Proxy Architecture:** Direct encrypted tunnels between your phone and your server. No data ever touches our servers.
- **Encrypted at Rest:** Credentials stored using `flutter_secure_storage` (Keychain/Biometrics supported).
- **Safety First:** AI-generated commands are **never** executed without your explicit review and confirmation.
- **Backup & Sync:** Export encrypted backups of your configurations for safe migration.

---

## 🏗️ Developer Guide

### Tech Stack
- **Framework:** Flutter (Dart)
- **SSH/SFTP:** `dartssh2`
- **Terminal:** `xterm.dart`
- **Security:** `flutter_secure_storage`
- **Monitoring:** Sentry

### Local Development
1.  **Clone & Install:**
    ```bash
    git clone https://github.com/hamma/hamma.git
    cd hamma
    flutter pub get
    ```
2.  **Verify Setup:**
    ```bash
    flutter analyze
    flutter test
    ```
3.  **Run:**
    ```bash
    flutter run
    ```

---

## 🗺️ Roadmap
- [x] **Phase 1:** Core SSH & AI Integration
- [x] **Phase 2:** UI Polish & Security Hardening
- [x] **Phase 3:** SFTP, Docker, and Fleet Management
- [ ] **Phase 4:** Encrypted Cloud Sync (Optional)
- [ ] **Phase 5:** Multi-Language Support

---

<div align="center">
  <p>Built with ❤️ for the DevOps Community</p>
</div>
