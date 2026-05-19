<!--
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   H A M M A — AI-Powered SSH Client                                  ║
  ║   Brutalist · Local-First · Zero-Trust                               ║
  ╚══════════════════════════════════════════════════════════════════════╝
-->

<div align="center">

<a href="#-quick-start">
<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=200&section=header&text=HAMMA&fontSize=90&fontColor=FFFFFF&animation=fadeIn&fontAlignY=40&desc=Manage%20servers%20without%20writing%20commands&descAlignY=62&descSize=18&descColor=00FF88" alt="Hamma" width="100%"/>
</a>

<img src="assets/images/logo.png" alt="Hamma logo" width="120" height="120" style="border-radius: 24px;"/>

<br/><br/>

<p>
  <a href="https://github.com/xayrullonematov/hamma/actions/workflows/main.yml"><img src="https://github.com/xayrullonematov/hamma/actions/workflows/main.yml/badge.svg?branch=main" alt="CI"/></a>
  <img src="https://img.shields.io/badge/VERSION-1.1.0-FFFFFF?style=flat-square&labelColor=000000" alt="Version"/>
  <img src="https://img.shields.io/badge/STATUS-BETA--RC-00FF88?style=flat-square&labelColor=000000" alt="Status"/>
  <img src="https://img.shields.io/badge/TESTS-746%2F747-00FF88?style=flat-square&labelColor=000000" alt="Tests"/>
  <img src="https://img.shields.io/badge/MODEL-1.4K%2B%20Downloads-00FF88?style=flat-square&labelColor=000000" alt="Downloads"/>
</p>

<p>
  <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black"/>
  <img src="https://img.shields.io/badge/Windows-0078D6?style=flat-square&logo=windows&logoColor=white"/>
  <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white"/>
  <img src="https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white"/>
  <img src="https://img.shields.io/badge/iOS-000000?style=flat-square&logo=ios&logoColor=white"/>
</p>

> **Manage servers without writing a single command.**
> SSH, SFTP, Docker, processes, and services — with an embedded AI copilot running entirely on your device. Your fleet, your keys, your AI. Nothing leaves your machine.

<br/>

[**Quick Start**](#-quick-start) · [**Features**](#-features) · [**Local AI**](#-local-ai--zero-telemetry) · [**Comparison**](#-how-hamma-compares) · [**Roadmap**](#-roadmap) · [**Docs**](#-documentation)

</div>

---

## The Problem

Every time a DevOps engineer pastes a server error into ChatGPT, they send internal IP addresses, routing configurations, and proprietary infrastructure data to a third-party cloud API. In enterprise environments that's a compliance violation. In air-gapped or low-connectivity environments, it's simply impossible.

HAMMA is built for the places that need it most — the hospital running a local server with no IT department, the government facility where cloud API calls are prohibited, the school whose entire student database lives on one Linux box.

**Zero cloud. Zero telemetry. Works anywhere on earth.**

---

## ✨ Features

| | Capability | |
|---|---|---|
| ![ai](https://img.shields.io/badge/-AI_Copilot-000000?style=flat-square&logo=openai&logoColor=00FF88) | **AI Copilot** — streaming local LLMs, risk-scored commands, one-tap error analysis | [→ LOCAL_AI.md](LOCAL_AI.md) |
| ![security](https://img.shields.io/badge/-Security-000000?style=flat-square&logo=gnuprivacyguard&logoColor=00FF88) | **Zero-Trust Security** — loopback-only AI, Argon2id backups, biometric lock | [→ SECURITY.md](SECURITY.md) |
| ![terminal](https://img.shields.io/badge/-Terminal-000000?style=flat-square&logo=gnubash&logoColor=00FF88) | **Mobile Terminal** — xterm, 256-color, custom keyboard row, reconnect-on-wake | |
| ![sftp](https://img.shields.io/badge/-SFTP-000000?style=flat-square&logo=files&logoColor=00FF88) | **Visual SFTP** — browse, edit, chmod, sudo fallback, syntax highlighting | |
| ![docker](https://img.shields.io/badge/-Docker-000000?style=flat-square&logo=docker&logoColor=00FF88) | **Docker & Services** — container control, live logs, systemd, process viewer | |
| ![fleet](https://img.shields.io/badge/-Fleet-000000?style=flat-square&logo=cloudflare&logoColor=00FF88) | **Fleet Dashboard** — multi-server health, port forwarding, encrypted sync | [→ ARCHITECTURE.md](ARCHITECTURE.md) |

---

## 🤖 Local AI — Zero Telemetry

HAMMA streams responses token-by-token from a local inference engine. AI traffic is hard-locked to `127.0.0.0/8` at runtime — your prompts **physically cannot reach the internet**.

### The HAMMA Model (Recommended)

We fine-tuned a custom Gemma 4 LoRA adapter specifically for DevOps failure diagnosis — trained on **1,500+ curated Linux sysadmin problem-solution pairs** synthesized from Ubuntu man pages, Nginx documentation, and systemd failure states.

- File permissions, SELinux, AppArmor
- systemd, Cron, kernel panics
- Docker, Kubernetes, container networking
- PostgreSQL, MySQL, Redis
- Nginx, Apache, HAProxy
- AWS, Git, CI/CD pipelines
- SSH, TLS, firewall, DNS

The model was trained with a strict **zero-conversational-padding** constraint. It outputs root cause + exact bash commands. No filler. No "I'd be happy to help."

Compiled to **Q4_K_M GGUF (5.34 GB)** — runs on any standard developer laptop without enterprise-grade VRAM.

```
1,400+ downloads in the first 48 hours of release.
```

> 🤗 [**Download the HAMMA model on Hugging Face →**](https://huggingface.co/xayrullonematov/hamma-gemma-4-devops-GGUF)

### Other Supported Providers

| Provider | Type | How to use |
|---|---|---|
| **Ollama** | Local | `ollama pull hamma` |
| **LM Studio** | Local | Load any GGUF |
| **llama.cpp** | Local | Point to server URL |
| **Jan** | Local | Load model in Jan |
| OpenAI | ☁️ Opt-in | API key required |
| Gemini | ☁️ Opt-in | API key required |

Cloud providers are an **explicit opt-in**. Local is the default.

→ [**Full Local AI setup guide**](LOCAL_AI.md)

---

## ⚡ Quick Start

### Users

```
1. Download HAMMA          →  Releases page
2. Set App PIN             →  Settings → Security
3. Load the HAMMA model    →  Settings → AI → Local → hamma
4. Add a server            →  Servers tab → +
5. Connect                 →  Tap server → Open Terminal
```

### Developers

```bash
git clone https://github.com/xayrullonematov/hamma.git
cd hamma
flutter pub get
flutter analyze        # → No issues found
flutter test           # → 746/747 passed
flutter run
```

**Requirements:** Flutter 3.22+ · Dart 3.4+

---

## 📊 How HAMMA Compares

| Capability | **HAMMA** | Termius | OpenSSH + ChatGPT | iSH / Blink |
|:---|:---:|:---:|:---:|:---:|
| Streaming local LLMs in-app | ✅ | ❌ | ❌ | ❌ |
| Fine-tuned DevOps model | ✅ | ❌ | ❌ | ❌ |
| Zero-trust loopback enforcement | ✅ | ❌ | ❌ | ❌ |
| AI risk assessor (pre-execution) | ✅ | ❌ | ❌ | ❌ |
| Works fully offline | ✅ | ⚠️ | ⚠️ | ✅ |
| Multi-platform (5 OSes) | ✅ | ✅ | ⚠️ CLI | ⚠️ iOS |
| Visual SFTP with sudo fallback | ✅ | ✅ | ❌ | ❌ |
| Docker & systemd panel | ✅ | ⚠️ | ❌ | ❌ |
| Subscription required | ❌ | 💰 | Free | 💰 |
| Cloud account required | ❌ | ✅ | ❌ | ❌ |
| Your prompts sent to cloud | **Never** | ⚠️ | ⚠️ All | n/a |

---

## 🗺 Roadmap

| Phase | Status | What's included |
|---|---|---|
| **Phase 1** — Core Client | ✅ Shipped | SSH, SFTP, terminal, vault, biometric lock |
| **Phase 2** — Local AI | ✅ Shipped | Local inference, HAMMA fine-tuned model, risk scoring |
| **Phase 3** — Natural Language Ops | 🔨 In Progress | Say "restart nginx" → AI generates command → you approve → executes |
| **Phase 4** — Built-in Engine | 📅 Planned | No Ollama dependency — inference ships inside HAMMA |
| **Phase 5** — Module Marketplace | 📅 Planned | Swappable specialist adapters: DevOps, Security, Networking, Database |

**The end goal:** describe intent in plain English, approve the AI-generated action, done. No command line. No clicking. Every action is logged, explained, and human-approved before execution — making it more auditable than typing commands manually.

→ [**Full roadmap**](ROADMAP.md)

---

## 📚 Documentation

| Doc | Contents |
|:---|:---|
| [SECURITY.md](SECURITY.md) | Security model, encryption details, threat model |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System diagram, project layout, tech stack |
| [LOCAL_AI.md](LOCAL_AI.md) | Local AI setup, model manager, onboarding wizard |
| [ROADMAP.md](ROADMAP.md) | Phase breakdown, what's shipped, what's next |
| [threat_model.md](threat_model.md) | Full asset / boundary / actor / mitigation breakdown |

---

## 💬 Community

<div align="center">

<a href="https://github.com/xayrullonematov/hamma">
  <img src="https://img.shields.io/badge/⭐_Star_the_repo-FFD700?style=flat-square&labelColor=000000" alt="Star"/>
</a>
&nbsp;
<a href="https://x.com/xayrullonematov">
  <img src="https://img.shields.io/badge/Follow_on_X-1DA1F2?style=flat-square&logo=x&logoColor=white&labelColor=000000" alt="X"/>
</a>
&nbsp;
<a href="https://discord.gg/x7FGxAjYW">
  <img src="https://img.shields.io/badge/Join_Discord-5865F2?style=flat-square&logo=discord&logoColor=white&labelColor=000000" alt="Discord"/>
</a>
&nbsp;
<a href="https://huggingface.co/xayrullonematov">
  <img src="https://img.shields.io/badge/🤗_HAMMA_Model-FF6B35?style=flat-square&labelColor=000000" alt="HuggingFace"/>
</a>

<br/><br/>

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=BUILT%20FOR%20ENGINEERS%20WHO%20CANNOT%20AFFORD%20DOWNTIME&fontSize=14&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>© 2025 Hamma · All rights reserved · Built with Flutter · <a href="https://www.kaggle.com/competitions/gemma-4-good-hackathon">Gemma 4 Good Hackathon</a></sub>

</div>
