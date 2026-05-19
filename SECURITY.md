<!--
  ╔══════════════════════════════════════════════════════════════════════╗
  ║   H A M M A — Security Policy                                        ║
  ║   Zero-Trust · Local-First · Encrypted at Rest                       ║
  ╚══════════════════════════════════════════════════════════════════════╝
-->

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=140&section=header&text=SECURITY&fontSize=42&fontColor=FFFFFF&animation=fadeIn&fontAlignY=55" alt="Security" width="100%"/>

<p>
  <img src="https://img.shields.io/badge/VAULT-AES--256--GCM-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/KDF-Argon2id-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/AI-LOOPBACK_ONLY-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/TELEMETRY-ZERO-00FF88?style=flat-square&labelColor=000000"/>
  <img src="https://img.shields.io/badge/KEYS-IN_MEMORY_ONLY-00FF88?style=flat-square&labelColor=000000"/>
</p>

[← Back to README](README.md)

</div>

---

## Security Model Overview

HAMMA is built on three non-negotiable principles:

**1. Your credentials never leave your device unencrypted.**
SSH keys, passwords, and passphrases are encrypted at rest using AES-256-GCM with a key derived via Argon2id. They are decrypted into memory only for the duration of an active session and zeroed immediately after.

**2. Your AI prompts never leave your device in local mode.**
The AI service layer enforces a hard loopback restriction (`127.0.0.0/8`) at the code level — not at the settings level. No user configuration can route AI traffic to an external server while local mode is active.

**3. Zero telemetry. Zero analytics. Zero crash reporting.**
HAMMA contains no analytics SDK, no crash reporter, and no usage tracking of any kind. Nothing is phoned home.

---

## Trust Boundaries

```
╔══════════════════════════════════════════════════════╗
║                YOUR DEVICE (trusted)                  ║
║                                                       ║
║   ┌─────────────┐      ┌──────────────────────────┐  ║
║   │  HAMMA App  │      │   Local Inference Engine  │  ║
║   │  (Flutter)  │◄────►│   127.0.0.1 only          │  ║
║   └──────┬──────┘      └──────────────────────────┘  ║
║          │                                            ║
║   ┌──────▼──────┐                                     ║
║   │  Encrypted  │                                     ║
║   │    Vault    │                                     ║
║   └─────────────┘                                     ║
║                                                       ║
╚══════════════════════════╤═══════════════════════════╝
                           │  SSH tunnel (encrypted)
                           ▼
              ╔════════════════════════╗
              ║   YOUR SERVERS         ║
              ║   (trusted by you)     ║
              ╚════════════════════════╝

              ╔════════════════════════╗
              ║   THIRD-PARTY CLOUD    ║  ← HAMMA never
              ║   (untrusted)          ║     contacts this
              ╚════════════════════════╝     in local mode
```

---

## Credential Vault

### Encryption

All credentials stored in HAMMA — SSH private keys, passwords, passphrases, and server configs — are encrypted using **AES-256-GCM** before being written to disk.

| Parameter | Value |
|---|---|
| Encryption algorithm | AES-256-GCM |
| Key derivation | Argon2id |
| Argon2id memory cost | 64 MB |
| Argon2id iterations | 3 |
| Argon2id parallelism | 4 |
| Salt | 16 bytes, cryptographically random, per-install |
| Salt storage | OS keychain via `flutter_secure_storage` |
| IV/Nonce | 12 bytes, random per encryption operation |
| Authentication tag | 128 bits (GCM default) |

### Key Lifecycle

```
User sets PIN
      │
      ▼
Argon2id(PIN + salt)  ──►  256-bit vault key
      │
      ▼
Vault key encrypts all credentials  ──►  Written to disk (encrypted)
      │
      ▼
Vault key held in memory during session
      │
      ▼
App backgrounded / locked  ──►  Vault key zeroed from memory
      │
      ▼
Next unlock: Argon2id re-derives key from PIN / biometric
```

The vault key is **never written to disk**. Only the Argon2id-encrypted credentials are persisted. The PIN itself is never stored — only used at unlock time to re-derive the key.

### Biometric Unlock

On devices with biometric hardware (Face ID, Touch ID, fingerprint sensor), HAMMA uses the OS secure enclave to store a biometric-protected token that allows vault key re-derivation without re-entering the PIN.

- The biometric token is stored in `flutter_secure_storage` (iOS Keychain / Android Keystore)
- It never bypasses Argon2id — it retrieves a stored intermediate that allows key re-derivation
- Biometric unlock can be disabled in **Settings → Security → Require PIN always**

---

## SSH Key Handling

SSH private keys are the most sensitive assets HAMMA manages. The handling lifecycle is:

```
Import private key (file / paste)
      │
      ▼
Key parsed and validated in memory
      │
      ▼
Key encrypted with vault key (AES-256-GCM)
      │
      ▼
Encrypted key written to Hive (local DB)
Original plaintext key reference zeroed
      │
      ▼
SSH session requested
      │
      ▼
Vault unlocked → key decrypted into memory
      │
      ▼
dartssh2 uses in-memory key for handshake
      │
      ▼
Session active: key held in memory
      │
      ▼
Session closed / app locked
      │
      ▼
Key buffer zeroed from memory
```

**HAMMA never:**
- Writes a plaintext private key to disk
- Logs or displays private key material
- Sends private key material over any network connection

**Supported key types:** RSA (2048, 4096), Ed25519 (recommended), ECDSA (P-256, P-384)

**Deprecated and rejected:** DSA keys, RSA keys below 2048 bits

---

## AI Loopback Enforcement

The AI service is the component most likely to be a data exfiltration vector in a naive implementation. HAMMA prevents this at the code layer.

### How it works

Every AI request passes through `LoopbackGuard.validate(url)` before any socket is opened:

```dart
class LoopbackGuard {
  static void validate(String url) {
    final uri = Uri.parse(url);
    final host = uri.host;

    // Resolve to IP if hostname given
    final addresses = InternetAddress.lookup(host);

    for (final address in addresses) {
      if (!address.isLoopback) {
        throw SecurityException(
          'AI provider URL must resolve to loopback (127.x.x.x). '
          'Got: ${address.address}. '
          'To use a cloud provider, enable cloud mode explicitly in Settings.',
        );
      }
    }
  }
}
```

This check runs on **every request**, not just at configuration time. If a DNS entry for a local hostname suddenly resolves to an external IP (DNS rebinding attack), the guard catches it.

### Cloud mode

Cloud providers (OpenAI, Gemini, OpenRouter) are available as an explicit opt-in. When cloud mode is active:

- A persistent **⚠️ Cloud mode — prompts leave your device** banner is shown in the AI chat panel
- The banner cannot be dismissed
- All requests are made over TLS
- Switching back to local mode immediately re-enables the loopback guard

### What the loopback guard cannot protect against

- A compromised local inference server (Ollama, llama.cpp) — HAMMA trusts `127.0.0.1` but cannot audit what the inference server does with the prompts
- Screen capture / clipboard access by other apps on the device
- Physical access to an unlocked device

---

## Network Security

### SSH Connections

| Parameter | Value |
|---|---|
| Protocol | SSH-2 only (SSH-1 rejected) |
| Key exchange | curve25519-sha256, diffie-hellman-group14-sha256 |
| Host key algorithms | ssh-ed25519, ecdsa-sha2-nistp256, rsa-sha2-512, rsa-sha2-256 |
| Ciphers | aes256-gcm@openssh.com, aes128-gcm@openssh.com, chacha20-poly1305 |
| MACs | hmac-sha2-256-etm, hmac-sha2-512-etm |
| Deprecated (rejected) | ssh-rsa (SHA1), arcfour, 3des-cbc, diffie-hellman-group1 |

### Host Key Verification

HAMMA implements strict host key verification with a local known-hosts store:

- First connection: user is shown the host key fingerprint and must explicitly accept
- Subsequent connections: key is verified against the stored fingerprint
- Key mismatch: connection is **rejected** with a clear warning — HAMMA never silently accepts changed host keys
- Known-hosts store is encrypted inside the vault

### Port Forwarding

Local port forwarding is supported for accessing services on remote servers. All forwarded traffic travels through the encrypted SSH tunnel. HAMMA does not support dynamic (SOCKS) forwarding in the current release.

---

## Data Inventory

A complete inventory of what HAMMA stores, where, and how:

| Data | Storage location | Encrypted | Leaves device |
|---|---|---|---|
| SSH private keys | Hive (local DB) | ✅ AES-256-GCM | Never |
| SSH passwords | Hive (local DB) | ✅ AES-256-GCM | Never |
| Server hostnames / IPs | Hive (local DB) | ✅ AES-256-GCM | Never (SSH only) |
| Vault PIN | Not stored | n/a | Never |
| Argon2id salt | OS keychain | ✅ Keychain-protected | Never |
| Biometric token | OS keychain | ✅ Keychain-protected | Never |
| AI prompts (local) | In-memory only | n/a | Never |
| AI prompts (cloud) | In-memory only | TLS in transit | To chosen provider |
| App settings | Hive (local DB) | ✅ | Never |
| Terminal history | In-memory only | n/a | Never |
| Analytics / telemetry | Not collected | n/a | Never |
| Crash reports | Not collected | n/a | Never |

---

## Threat Model Summary

The full threat model is documented in [threat_model.md](threat_model.md). Summary of the primary threats and mitigations:

| Threat | Mitigation |
|---|---|
| AI prompt exfiltration | Loopback guard, enforced at service layer |
| Credential theft from disk | AES-256-GCM encryption, Argon2id KDF |
| Weak PIN brute force | Argon2id (64 MB, 3 iterations) makes offline attack expensive |
| Private key exposure | In-memory only during session, zeroed on close |
| Man-in-the-middle SSH | Strict host key verification, no silent key acceptance |
| DNS rebinding (AI loopback bypass) | IP resolution checked at request time, not config time |
| Physical device access | Biometric lock, vault re-locks on background |
| Supply chain (dependencies) | Pinned dependency versions, GitHub Actions CI on every commit |
| Cloud provider data retention | Explicit opt-in only, persistent UI warning when active |

---

## Responsible Disclosure

If you discover a security vulnerability in HAMMA, please report it privately before public disclosure.

**Contact:** open a [GitHub Security Advisory](https://github.com/xayrullonematov/hamma/security/advisories/new) — this keeps the report private until a fix is released.

**Please include:**
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Your suggested fix (if any)

**What to expect:**
- Acknowledgement within 48 hours
- Status update within 7 days
- Fix timeline communicated once the issue is confirmed
- Credit in the release notes (if desired)

**Scope — in scope for reports:**
- Loopback guard bypass
- Vault decryption without PIN/biometric
- SSH key extraction from storage
- Unintended network egress of sensitive data
- Authentication bypass

**Out of scope:**
- Vulnerabilities requiring physical access to an already-unlocked device
- Denial of service against the local app
- Social engineering attacks

---

## Security Checklist for Self-Hosted Deployments

If you are deploying HAMMA in an enterprise or regulated environment:

- [ ] Set a strong PIN (12+ characters recommended)
- [ ] Enable biometric lock
- [ ] Use Ed25519 keys (preferred over RSA)
- [ ] Verify host key fingerprints on first connection
- [ ] Keep local AI mode enabled — never enable cloud mode with sensitive infrastructure
- [ ] Run the inference engine (Ollama) with `OLLAMA_HOST=127.0.0.1` to prevent LAN exposure
- [ ] Keep HAMMA updated — check [Releases](https://github.com/xayrullonematov/hamma/releases) for security patches
- [ ] Review [threat_model.md](threat_model.md) for your specific environment

---

<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:00FF88,100:000000&height=100&section=footer&text=ZERO%20TELEMETRY%20·%20ZERO%20TRUST%20·%20ZERO%20COMPROMISE&fontSize=13&fontColor=FFFFFF&animation=fadeIn&fontAlignY=70" alt="Footer" width="100%"/>

<sub>[← Back to README](README.md) · [LOCAL_AI.md](LOCAL_AI.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [threat_model.md](threat_model.md)</sub>

</div>
