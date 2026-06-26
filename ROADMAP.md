<!--
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   H A M M A — Roadmap                                                ║
  ║   Where we are · Where we're going · How to get involved             ║
  ╚══════════════════════════════════════════════════════════════════════╝
-->

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=140&section=header&text=ROADMAP&fontSize=42&fontColor=FFFFFF&animation=fadeIn&fontAlignY=55" alt="Roadmap" width="100%"/>

<p>
  <img src="https://img.shields.io/badge/PHASE_1-SHIPPED-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/PHASE_2-SHIPPED-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/PHASE_3-SHIPPED-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/PHASE_4-ACTIVE_NEXT-FFAA00?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/PHASE_5-PLANNED-555555?style=flat-square&labelColor=000000"/>
</p>

[← Back to README](README.md)

</div>

---

## The Vision

HAMMA's end goal is a local-first infrastructure control plane where you manage your entire server fleet in plain English — no command line expertise required, no cloud dependency, no data exfiltration risk.

```
TODAY                              TOMORROW
──────                             ────────
You type:                          You say:
  systemctl restart nginx            "restart nginx on web-prod-03"
  on web-prod-03                          │
                                          ▼
                                    AI generates exact command
                                          │
                                          ▼
                                    You review and approve
                                          │
                                          ▼
                                    HAMMA executes — logged,
                                    auditable, reversible
```

Every action proposed by AI is shown to you before execution. You approve. HAMMA runs it. Full audit trail. This makes HAMMA more accountable than typing commands manually — because every action is explained, consented to, and logged.

---

## Phase Overview

| Phase | Name | Status | Summary |
|---|---|---|---|
| **1** | Core Client | ✅ Shipped | SSH, SFTP, terminal, vault, biometric lock |
| **2** | Local AI | ✅ Shipped | Fine-tuned Gemma 4 model, Ollama integration, risk scoring |
| **3** | Natural Language Ops | ✅ Shipped | Intent → command → approve → execute, with audit and session memory |
| **4** | Built-in Engine | 🔨 Active next | Inference ships inside HAMMA, no Ollama required |
| **5** | Module Marketplace | 📅 Planned | Swappable specialist AI adapters |

---

## ✅ Phase 1 — Core Client

**Status: Shipped in v1.0.0**

The foundation. A fully featured SSH/SFTP client that works as a daily driver across all five platforms.

### Delivered

- [x] SSH2 client with full terminal emulation (xterm, 256-color, VT100)
- [x] Custom keyboard row for terminal shortcuts on mobile
- [x] Reconnect-on-wake for mobile SSH sessions
- [x] Visual SFTP browser with syntax-highlighted file editor
- [x] chmod, chown, sudo fallback in SFTP
- [x] Encrypted credential vault (AES-256-GCM, Argon2id)
- [x] Biometric lock (Face ID, Touch ID, fingerprint)
- [x] Fleet dashboard — multi-server health overview
- [x] Local port forwarding
- [x] Ed25519, RSA, ECDSA key support
- [x] Cross-platform: Linux, macOS, Windows, Android, iOS
- [x] 860 passing tests, 1 skipped integration test

---

## ✅ Phase 2 — Local AI

**Status: Shipped in v1.1.0**

The intelligence layer. A purpose-built, fine-tuned AI model that runs entirely on your device.

### Delivered

- [x] Ollama integration with token streaming
- [x] LM Studio, llama.cpp, Jan support
- [x] Hard loopback enforcement (`127.0.0.0/8`) — AI cannot reach the internet in local mode
- [x] Cloud provider opt-in (OpenAI, Gemini, OpenRouter) with persistent warning banner
- [x] HAMMA-Gemma4 fine-tuned model published on HuggingFace
  - 3,701 curated Linux/DevOps problem-solution pairs
  - 39 topics, 273 sub-angles
  - Zero conversational padding constraint
  - Q4_K_M GGUF, 5.34 GB
  - 1,400+ downloads in first 48 hours
- [x] AI risk assessor — 🟢 Safe / 🟡 Caution / 🔴 Destructive scoring
- [x] One-tap error analysis — paste log, get diagnosis
- [x] Docker & systemd panel — container control, live logs, process viewer

---

## ✅ Phase 3 — Natural Language Ops

**Status: Shipped on `main` — v1.2.x**

The operational layer. You describe what you want. HAMMA proposes the exact commands. You approve. It executes.

### Delivered

- [x] Global command palette — keyboard-driven access to servers, screens, commands, runbooks, files, and plugin actions
- [x] Frecency ranking — server activity, palette choices, recent commands, and runbooks become easier to reach as they are used
- [x] Intent-to-command flow — AI command service converts natural language into executable command candidates
- [x] Command preview and risk panel — proposed command, explanation, and risk score are shown before execution
- [x] One-tap approved execution from the AI Copilot panel when a live SSH transport is available
- [x] Execution audit log — local record of executed commands, target server, timing, status, stdout/stderr, and risk level
- [x] Multi-step runbooks — approved command sequences with branching, cancellation, risk gates, and per-step output
- [x] Context awareness — AI Copilot can use recent terminal output and the active server context
- [x] Session memory — terminal scrollback is redacted, bounded, persisted securely, restored on reopen, and refreshed through reconnects
- [x] Resilient terminal UX — restored-session ribbon, debounced persistence, LRU session eviction, and non-modal reconnect notice

### Follow-up Work

- [ ] Undo suggestions — for reversible operations, suggest a rollback command alongside the fix
- [ ] Error loop detection — if a command fails, AI reads the output and proposes the next step
- [ ] OS/distro fingerprinting — enrich prompts with verified remote host facts, not guessed state

### Design principles for Phase 3

**Human approval is non-negotiable.** No command executes without an explicit user confirmation tap. The AI proposes; the engineer decides. This is not an autonomous agent — it is an amplifier for the engineer's own judgment.

**Every execution is logged.** The audit log records the natural language intent, the proposed command, the approval timestamp, and the stdout/stderr result. The log is stored locally in the encrypted vault.

**Destructive commands get extra friction.** Commands scored 🔴 by the risk assessor require typing `CONFIRM` before execution — not just a tap.

---

## 🔨 Phase 4 — Built-in Engine

**Status: Active next — target v2.0.0**

The independence layer. No Ollama. No separate install. No configuration. Install HAMMA, and the AI is ready.

### What changes

```
Current local AI path:      Phase 4 target:
──────────────────          ─────────────────
Install HAMMA          →    Install HAMMA
Install Ollama         →    (done)
ollama run hf.co/xayrullonematov/hamma-gemma-4-devops-GGUF:Q4_K_M      →    (done)
Configure provider     →    (done)
```

### How it works

The inference library (`llama.cpp`) will be bundled as a platform-specific dynamic library and called via Dart FFI — no separate process, no HTTP, no configuration:

```
HAMMA App
    │
    │  Dart FFI (direct function call)
    ▼
libllama (bundled dylib)
    │
    ▼
HAMMA-Gemma4 GGUF
(downloaded on first launch, cached locally)
```

### Planned deliverables

- [x] Initial native inference groundwork through `fllama`, bundled-engine abstractions, model downloader, and local-engine tests
- [ ] Production llama.cpp packaging as `.so` / `.dll` / `.dylib` per platform
- [ ] Production Dart FFI inference path with lifecycle, cancellation, and streaming
- [ ] On-demand model download on first launch with progress indicator and resumable failure handling
- [x] Model integrity verification (SHA-256 checksum before load)
- [ ] Graceful fallback to Ollama if FFI engine unavailable
- [ ] GPU acceleration via Metal (macOS/iOS), Vulkan (Linux/Windows/Android)

---

## 📅 Phase 5 — Module Marketplace

**Target: v2.x**

The specialization layer. Instead of one large general model, HAMMA uses small, fast, purpose-built adapters — each an expert in its domain.

### The module concept

```
HAMMA Core (inference engine)
      │
      ├── hamma-devops      Linux, Docker, K8s, CI/CD, systemd
      ├── hamma-security    Firewall, SELinux, fail2ban, CVE triage
      ├── hamma-networking  DNS, TLS, routing, packet analysis, BGP
      ├── hamma-database    Postgres, MySQL, Redis, query optimization
      ├── hamma-cloud       AWS, GCP, Azure CLI debugging
      └── hamma-web         Nginx, Apache, HAProxy, Let's Encrypt
```

Each module is a small LoRA adapter (~200-500 MB) layered on top of the base Gemma 4 model. You install only what you need. Modules are hot-swappable — switch from `hamma-devops` to `hamma-security` without reloading the base model.

### Planned deliverables

- [ ] Module registry — browse, install, update adapters from inside HAMMA
- [ ] Module signing — cryptographic verification that modules come from trusted sources
- [ ] Community modules — open format for third-party adapter contributions
- [ ] Module benchmarks — published accuracy scores per topic so you can compare
- [ ] Offline module cache — all installed modules work without internet after download

---

## Contributing

Phase 4 is where contributions matter most right now. The highest-impact areas:

**AI / ML:**
- Improving the HAMMA-Gemma4 training dataset (adding multi-turn examples, edge cases, ambiguous queries)
- Evaluating model output quality across the 39 topic categories
- Experimenting with alternative base models

**Flutter / Dart:**
- Production Dart FFI bindings for llama.cpp
- Model download, checksum verification, and cache management UX
- Graceful fallback paths when the bundled engine is unavailable
- Performance telemetry surfaced locally, without analytics or remote reporting

**Documentation:**
- Testing setup guides on different hardware configurations
- Translating docs for non-English speaking communities

→ See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and PR guidelines
→ Open issues are tagged [`good first issue`](https://github.com/xayrullonematov/hamma/issues?q=label%3A%22good+first+issue%22) and [`help wanted`](https://github.com/xayrullonematov/hamma/issues?q=label%3A%22help+wanted%22)

---

## Version History

| Version | Phase | Highlights |
|---|---|---|
| **v1.2.x** | Phase 3 complete | Command palette, frecency, AI command plans, audit log, runbooks, resilient terminal sessions |
| **v1.1.0** | Phase 2 complete | HAMMA-Gemma4 model, Ollama integration, AI risk scoring, Docker panel |
| **v1.0.0** | Phase 1 complete | SSH/SFTP client, encrypted vault, biometric lock, fleet dashboard |

---

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=BUILD%20THE%20FUTURE%20OF%20INFRASTRUCTURE%20MANAGEMENT&fontSize=13&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>[← Back to README](README.md) · [LOCAL_AI.md](LOCAL_AI.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [SECURITY.md](SECURITY.md)</sub>

</div>
