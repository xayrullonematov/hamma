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
  <img src="https://img.shields.io/badge/LICENSE-PROPRIETARY-FF0000?style=flat-square&labelColor=000000" alt="License"/>
  <img src="https://img.shields.io/badge/TESTS-65%2F65-00FF88?style=flat-square&labelColor=000000" alt="Tests"/>
</p>

<p>
  <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black"/>
  <img src="https://img.shields.io/badge/Windows-0078D6?style=flat-square&logo=windows&logoColor=white"/>
  <img src="https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white"/>
  <img src="https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white"/>
  <img src="https://img.shields.io/badge/iOS-000000?style=flat-square&logo=ios&logoColor=white"/>
</p>


> **The DevOps command center that fits in your pocket.**
> SSH, SFTP, Docker, processes, services, and a streaming AI copilot — running fully **on-device**. Your fleet, your keys, your AI. Nothing leaves your machine.

</div>

-----

## ![features](https://img.shields.io/badge/FEATURES-000000?style=flat-square&logo=stackedit&logoColor=00FF88) Features

|                                                                                                                  |Capability                                                                         |                                    |
|------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|------------------------------------|
|![ai](https://img.shields.io/badge/-AI_Copilot-000000?style=flat-square&logo=openai&logoColor=00FF88)             |**AI Copilot** — streaming local LLMs, risk-scored commands, one-tap error analysis|[→ LOCAL_AI.md](LOCAL_AI.md)        |
|![security](https://img.shields.io/badge/-Security-000000?style=flat-square&logo=gnuprivacyguard&logoColor=00FF88)|**Zero-Trust Security** — loopback-only AI, Argon2id backups, biometric lock       |[→ SECURITY.md](SECURITY.md)        |
|![terminal](https://img.shields.io/badge/-Terminal-000000?style=flat-square&logo=gnubash&logoColor=00FF88)        |**Mobile Terminal** — xterm, 256-color, custom keyboard row, reconnect-on-wake     |                                    |
|![sftp](https://img.shields.io/badge/-SFTP-000000?style=flat-square&logo=files&logoColor=00FF88)                  |**Visual SFTP** — browse, edit, chmod, sudo fallback, syntax highlighting          |                                    |
|![docker](https://img.shields.io/badge/-Docker-000000?style=flat-square&logo=docker&logoColor=00FF88)             |**Docker & Services** — container control, live logs, systemd, process viewer      |                                    |
|![fleet](https://img.shields.io/badge/-Fleet-000000?style=flat-square&logo=cloudflare&logoColor=00FF88)           |**Fleet Dashboard** — multi-server health, port forwarding, encrypted sync         |[→ ARCHITECTURE.md](ARCHITECTURE.md)|

-----

## ![localai](https://img.shields.io/badge/LOCAL_AI-000000?style=flat-square&logo=ollama&logoColor=00FF88) Local AI — Zero Telemetry

Hamma streams responses token-by-token from **Ollama, LM Studio, llama.cpp, or Jan** — all running on your device. Local AI is hard-guarded to `127.0.0.0/8` at runtime; your prompts physically cannot reach the internet.

Cloud providers (OpenAI, Gemini, OpenRouter) are available as an explicit opt-in.

→ **[Full Local AI guide](LOCAL_AI.md)**

-----

## ![quickstart](https://img.shields.io/badge/QUICK_START-000000?style=flat-square&logo=rocket&logoColor=00FF88) Quick Start

### Users

```
1. Launch Hamma
2. Set App PIN        →  Settings → Security
3. Choose AI provider →  Settings → AI Configuration
4. Add a server       →  Servers tab → +
5. Connect            →  Tap server → Open Terminal
```

### Developers

```bash
git clone https://github.com/xayrullonematov/hamma.git
cd hamma
flutter pub get
flutter analyze   # → No issues found
flutter test      # → 65/65 passed
flutter run
```

-----

## ![compare](https://img.shields.io/badge/COMPARISON-000000?style=flat-square&logo=scales&logoColor=00FF88) How Hamma Compares

|Capability                      |**Hamma**|Termius|OpenSSH + ChatGPT|iSH / Blink|
|:-------------------------------|:-------:|:-----:|:---------------:|:---------:|
|Streaming local LLMs in-app     |✅        |❌      |❌                |❌          |
|Zero-trust loopback enforcement |✅        |❌      |❌                |❌          |
|AI risk assessor (pre-execution)|✅        |❌      |❌                |❌          |
|Multi-platform (5 OSes)         |✅        |✅      |⚠️ CLI            |⚠️ iOS      |
|Visual SFTP with sudo fallback  |✅        |✅      |❌                |❌          |
|Docker & systemd panel          |✅        |⚠️      |❌                |❌          |
|Subscription required           |❌        |💰      |Free             |💰          |
|Cloud account required          |❌        |✅      |❌                |❌          |
|Telemetry of your prompts       |❌        |⚠️      |⚠️ All            |n/a        |

-----

## ![docs](https://img.shields.io/badge/DOCUMENTATION-000000?style=flat-square&logo=readthedocs&logoColor=00FF88) Documentation

|Doc              |Contents                                            |
|:----------------|:---------------------------------------------------|
|<SECURITY.md>    |Security model, encryption details, threat model    |
|<ARCHITECTURE.md>|System diagram, project layout, tech stack          |
|<LOCAL_AI.md>    |Local AI setup, model manager, onboarding wizard    |
|<ROADMAP.md>     |Phase breakdown, what’s shipped, what’s next        |
|<threat_model.md>|Full asset / boundary / actor / mitigation breakdown|

-----

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

<br/><br/>

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=BUILT%20FOR%20ENGINEERS&fontSize=18&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>© Hamma — All rights reserved · Built with Flutter</sub>

</div>