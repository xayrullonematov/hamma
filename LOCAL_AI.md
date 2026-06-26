<!--
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   H A M M A — Local AI Guide                                         ║
  ║   Zero Telemetry · On-Device Inference · DevOps-Specialized          ║
  ╚══════════════════════════════════════════════════════════════════════╝
-->

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=140&section=header&text=LocalAI&fontSize=42&fontColor=FFFFFF&animation=fadeIn&fontAlignY=55&descColor=00FF88" alt="Local AI" width="100%"/>

<p>
  <img src="https://img.shields.io/badge/INFERENCE-ON_DEVICE-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/TELEMETRY-ZERO-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/NETWORK-LOOPBACK_ONLY-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/MODEL-HAMMA_Gemma4-00FF88?style=flat-square&labelColor=000000"/>
</p>

[← Back to README](README.md)

</div>

---

## How It Works

HAMMA connects to a local inference server running on your machine. Every prompt you send — server logs, error messages, infrastructure configs — travels over `localhost` only. The AI traffic is hard-locked to `127.0.0.0/8` at the application layer. Even if you wanted to, your prompts cannot reach an external server unless you explicitly opt into a cloud provider.

```
Your Terminal Output
       │
       ▼
  HAMMA App (Flutter)
       │  localhost only
       ▼
  Local Inference Engine  ──►  Response streams back token-by-token
  (Ollama / llama.cpp / Jan)
       │
       ▼
  HAMMA-Gemma4 GGUF Model
  (lives entirely on your disk)
```

No API keys. No accounts. No usage logs. No data retention. The model runs on your hardware and the answer stays on your hardware.

---

## The HAMMA Model

This is the recommended model for HAMMA. It was purpose-built for Linux server administration — not adapted from a general assistant.

### What makes it different

Standard instruction-tuned models respond to server errors like this:

> *"Great question! It looks like you might be experiencing a port collision on 0.0.0.0:80. I'd be happy to walk you through some troubleshooting steps. First, let's understand what might be causing this..."*

The HAMMA model responds like this:

> Another process is holding port 80. Kill it and restart nginx:
>
> ```bash
> sudo ss -tlnp | grep :80
> sudo kill -9 <PID>
> sudo systemctl restart nginx
> ```
>
> Verify with: `sudo systemctl status nginx`

Root cause. Exact command. Verification step. Nothing else.

### Training details

| Parameter | Value |
|---|---|
| Base model | Gemma 4 (google/gemma-4-e4b-it) |
| Parameters | 8B |
| Fine-tuning method | LoRA (Unsloth) |
| Training pairs | 1,500+ curated problem-solution pairs |
| Topics covered | 39 Linux/DevOps failure categories |
| Sub-angles | 273 distinct failure modes |
| Output constraint | Zero conversational padding enforced |
| Quantization | Q4_K_M GGUF |
| File size | 5.34 GB |
| VRAM required | ~6 GB |
| HuggingFace downloads | 1,400+ in first 48 hours |

### Topics covered

<details>
<summary>View all 39 topics</summary>

| Category | Topics |
|---|---|
| **Linux Core** | File permissions & ownership, systemd failures, Cron silent failures, SELinux/AppArmor denials, Kernel panics & dmesg |
| **Networking** | DNS resolution failures, iptables/nftables, TCP refused/reset/timeout, TLS/SSL certificates, MTU mismatches |
| **SSH / Access** | SSH Permission denied (publickey), SFTP chroot jail issues |
| **Docker** | Bridge network collisions, container exit codes, image build failures, volume mount permissions |
| **Kubernetes** | CrashLoopBackOff, ImagePullBackOff, PVC stuck Pending, Ingress/Service debugging, Node NotReady |
| **Web Servers** | Nginx 502/504, Apache .htaccess & mod_rewrite, HAProxy backend health |
| **Databases** | PostgreSQL connection limits & pgbouncer, MySQL replication broken, Redis OOM & eviction |
| **Storage** | Disk full with no obvious culprit, NFS mount hangs & stale handles |
| **Performance** | OOM killer traces, high load average with low CPU (iowait) |
| **Security** | SSH brute force & fail2ban, Let's Encrypt renewal failures |
| **Cloud** | AWS EC2 status checks, S3 access denied |
| **CI/CD & Git** | Git conflicts & large files, CI/CD pipeline runner failures |
| **Observability** | Log analysis with journalctl/grep/awk, NTP/chrony time sync |

</details>

### Download

```bash
# Via Ollama (easiest)
ollama run hf.co/xayrullonematov/hamma-gemma-4-devops-GGUF:Q4_K_M

# Direct GGUF download
# → https://huggingface.co/xayrullonematov/hamma-gemma-4-devops-GGUF
```

---

## Setup Guide

### Option 1 — Ollama (Recommended)

Ollama is the simplest way to run the HAMMA model locally.

**Install Ollama:**

```bash
# macOS / Linux
curl -fsSL https://ollama.com/install.sh | sh

# Windows
# Download installer from https://ollama.com
```

**Pull the HAMMA model:**

```bash
ollama run hf.co/xayrullonematov/hamma-gemma-4-devops-GGUF:Q4_K_M
```

**Verify it's running:**

```bash
ollama list
# Should show: hf.co/xayrullonematov/hamma-gemma-4-devops-GGUF:Q4_K_M   [size]   [modified]

curl http://localhost:11434/api/tags
# Should return JSON with hamma-gemma-devops in the models list
```

**Connect HAMMA app:**

```
Settings → AI Configuration → Provider: Ollama
Base URL: http://127.0.0.1:11434
Model: hamma-gemma-devops
```

---

### Option 2 — LM Studio

LM Studio gives you a GUI to browse and load GGUF models.

1. Download LM Studio from [lmstudio.ai](https://lmstudio.ai)
2. Search for `hamma-gemma-devops` or download the GGUF from HuggingFace and load it manually
3. Start the local server: **Local Server tab → Start Server**
4. Default port: `1234`

**Connect HAMMA app:**

```
Settings → AI Configuration → Provider: LM Studio
Base URL: http://127.0.0.1:1234
Model: hamma-gemma-devops
```

---

### Option 3 — llama.cpp

For advanced users who want direct control over inference parameters.

```bash
# Clone and build
git clone https://github.com/gerganov/llama.cpp
cd llama.cpp
make -j$(nproc)

# Download the GGUF
wget https://huggingface.co/xayrullonematov/hamma-gemma-4-devops-GGUF/resolve/main/gemma-4-e4b-it.Q4_K_M.gguf

# Start the server
./llama-server \
  -m gemma-4-e4b-it.Q4_K_M.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  -c 4096 \
  -t $(nproc)
```

**Connect HAMMA app:**

```
Settings → AI Configuration → Provider: llama.cpp
Base URL: http://127.0.0.1:8080
Model: hamma-gemma-devops
```

---

### Option 4 — Jan

Jan is a fully offline ChatGPT alternative with a local server mode.

1. Download Jan from [jan.ai](https://jan.ai)
2. Import the HAMMA GGUF model via **Models → Import**
3. Enable the API server: **Settings → Advanced → API Server → Start**
4. Default port: `1337`

**Connect HAMMA app:**

```
Settings → AI Configuration → Provider: Jan
Base URL: http://127.0.0.1:1337
Model: hamma-gemma-devops
```

---

## Hardware Requirements

| Setup | VRAM | RAM | Notes |
|---|---|---|---|
| Gemma 4 E2B Q4_K_M (~2 GB) | ~2.5 GB | 4 GB | Fast on any laptop |
| Gemma 4 E4B Q4_K_M (~5.34 GB) | ~6 GB | 8 GB | Recommended (HAMMA Default) |
| Gemma 4 31B Q4_K_M (~18 GB) | ~20 GB | 32 GB | High-end workstation |

**Tested on:**
- MacBook Pro M2 16 GB — fast, no issues
- Windows laptop, RTX 3060 12 GB — fast
- Ubuntu workstation, GTX 1080 8 GB — works
- CPU-only Ubuntu VM, 32 GB RAM — usable, ~8 tokens/sec

---

## Cloud Providers (Opt-in)

Cloud providers are available as an explicit opt-in for environments where local inference is not feasible. When a cloud provider is active, HAMMA displays a warning banner: **⚠️ Cloud mode — prompts leave your device.**

| Provider | Base URL | Notes |
|---|---|---|
| OpenAI | `https://api.openai.com` | Requires API key |
| Gemini | `https://generativelanguage.googleapis.com` | Requires API key |
| OpenRouter | `https://openrouter.ai/api` | Access to many models |
| Any OpenAI-compatible | Custom URL | Works with any compatible endpoint |

**To enable:**

```
Settings → AI Configuration → Provider: OpenAI (or other)
API Key: sk-...
Model: gpt-4o (or preferred)
```

---

## AI Risk Assessor

Before executing any AI-suggested command, HAMMA scores it for risk:

| Risk Level | Color | Examples |
|---|---|---|
| **Low** | 🟢 Green | `systemctl status nginx`, `df -h`, `journalctl -u sshd` |
| **Moderate** | 🟠 Orange | `systemctl restart nginx`, `chmod 755 /var/www` |
| **High** | 🔴 Red | `systemctl stop nginx`, `kill -9 <PID>` |
| **Critical** | 🟣 Purple | `rm -rf /`, `iptables -F`, `dd if=...` |

High and Critical commands require an explicit confirmation tap before HAMMA will execute them. The AI also prepends a `WARNING:` line before any destructive command in its response.

---

## Troubleshooting

**Model not responding / connection refused**

```bash
# Check Ollama is running
ollama serve

# Check what's listening on the port
ss -tlnp | grep 11434

# Test the API directly
curl http://127.0.0.1:11434/api/tags
```

**Slow responses (< 5 tokens/sec)**

- Enable GPU acceleration in Ollama: `OLLAMA_GPU=1 ollama serve`
- Check GPU is detected: `ollama ps` should show GPU layer count > 0
- On Apple Silicon, Metal is used automatically — no config needed

**Out of memory / model crashes**

- Switch to a smaller quantization: Q4_K_S instead of Q4_K_M
- Close other GPU-heavy applications
- Increase swap space on Linux: `sudo fallocate -l 8G /swapfile`

**HAMMA app shows "Provider unreachable"**

```
Settings → AI Configuration → Test Connection
```

Verify the Base URL matches your inference server's actual address and port. The URL must start with `http://127.` — HAMMA will reject external addresses in local mode.

---

## Roadmap: Built-in Engine

The current production path supports Ollama or another loopback OpenAI-compatible server. **Phase 4** of the HAMMA roadmap makes the bundled engine the primary path so AI is ready without a separate daemon:

```
Future state:
  Install HAMMA  →  Choose modules  →  Done.
  No Ollama. No separate download. No configuration.
```

Groundwork already exists in the codebase for native inference, bundled-engine lifecycle, model download, and local-engine health checks. The next implementation work is production packaging, checksum verification, streaming FFI inference, and graceful fallback to Ollama.

Modules will be swappable adapters — install only what you need:

| Module | Specialization |
|---|---|
| `hamma-devops` | Linux, Docker, Kubernetes, CI/CD |
| `hamma-security` | Firewall, SELinux, fail2ban, CVEs |
| `hamma-networking` | DNS, TLS, routing, packet analysis |
| `hamma-database` | Postgres, MySQL, Redis, query optimization |

→ [**Full roadmap**](ROADMAP.md)

---

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=YOUR%20LOGS%20NEVER%20LEAVE%20YOUR%20MACHINE&fontSize=14&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>[← Back to README](README.md) · [SECURITY.md](SECURITY.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [ROADMAP.md](ROADMAP.md)</sub>

</div>
