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

**Hamma** (AI Server V2) is designed for developers and sysadmins who need to manage remote infrastructure on the go. Unlike traditional SSH clients, Hamma bridges the gap between raw terminal complexity and modern mobile UX, providing a "Safety-First" AI layer that explains logs, suggests fixes, and automates repetitive tasks.

---

## 🚀 Key Features

### 🧠 Smart AI Assistant
*   **Contextual Command Generation:** Ask for what you need (e.g., "Restart my Docker containers if they are down") and get a verified command plan.
*   **Risk Assessment:** Every AI suggestion is automatically analyzed by our **Command Risk Assessor** to flag dangerous operations (e.g., `rm -rf`, `reboot`).
*   **Error Analysis:** Paste a confusing log or error, and Hamma will explain the root cause and provide a fix.

### 💻 Pro SSH & Terminal
*   **Direct Transport:** Connections happen directly from your device to the server using `dartssh2`. No middleman, no proxies, total privacy.
*   **Mobile-Optimized Terminal:** A full `xterm` terminal with a specialized toolbar for essential keys (Esc, Tab, Ctrl, Arrows) missing from mobile keyboards.
*   **Multi-Server Dashboard:** View health metrics across your entire fleet at a glance.

### 🛠️ Built-in Management Tools
*   **Docker Manager:** List, start, stop, and inspect containers without typing a single line.
*   **Service & Process Control:** Manage `systemd` services and monitor system resources (CPU/RAM/Disk).
*   **SFTP File Explorer:** Navigate, edit, and transfer files securely.

---

## 🛠️ Getting Started (User Guide)

Using Hamma perfectly is a three-step process:

### 1. Secure Your App
When you first launch Hamma, set up an **App PIN** in Settings. This encrypts your local database and protects your server credentials.

### 2. Configure AI (Optional but Recommended)
Hamma supports multiple AI providers. Go to **Settings > AI Configuration**:
- **OpenAI:** Best for general accuracy.
- **Google Gemini:** High performance and speed.
- **OpenRouter:** Access to diverse models like Llama 3 or Claude.
*Your API keys are stored locally in the device's secure enclave.*

### 3. Add Your First Server
Navigate to the **Servers** tab and tap **(+)**:
- Enter your SSH credentials (Password and Private Key support included).
- Tap **Test Connection** to verify.
- Once saved, tap the server to open the **Dashboard** or **Terminal**.

---

## 🔒 Security & Privacy

- **Zero-Proxy Architecture:** Your SSH traffic never leaves the direct encrypted tunnel between your phone and your server.
- **Encrypted at Rest:** Server profiles and API keys are stored using `flutter_secure_storage` (Keychain on iOS, AES-encrypted SharedPreferences on Android).
- **Safety First:** AI-generated commands are **never** executed automatically. You must review, edit, and confirm every action.

---

## 🏗️ Developer Guide

### Tech Stack
- **Framework:** Flutter (Dart)
- **SSH:** `dartssh2`
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
- [ ] **Phase 3:** SFTP File Transfers & Editor
- [ ] **Phase 4:** Multi-device encrypted sync

---

<div align="center">
  <p>Built with ❤️ for the Linux Community</p>
</div>
