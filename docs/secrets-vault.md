# Secrets Vault

Hamma's per-server secrets vault lets you reference passwords, API
tokens, and deploy keys by name (`${vault:DB_PASSWORD}`) without ever
writing the plaintext value into shell history, the in-app command
history pane, AI prompts, or crash reports.

## Threat model

The vault is designed against three concrete leak paths:

1. **Shell history & screen recordings** — secrets pasted into a
   command line end up in `~/.bash_history`, in tmux scrollback, and
   on every screen recording the user makes during the session.
2. **AI prompts** — when the user asks the AI assistant to help craft
   a command, naïve prompt building would forward the secret to a
   cloud LLM (or even the local LLM, which runs in a separate process
   on the same host).
3. **Crash reports** — Sentry / in-app crash captures otherwise carry
   any secret that happened to be in scope at the moment of the
   crash.

## Storage

- Plaintext values live in `flutter_secure_storage`, which is backed
  by Keychain on iOS / macOS, Keystore on Android, libsecret on
  Linux, and DPAPI on Windows. Hamma never writes values to disk
  itself.
- Each secret has a stable id (the merge key for sync), a canonical
  upper-snake-case name (the placeholder key), an optional scope
  (`null` = global, otherwise a server profile id), and an optional
  free-text description.
- All mutations fire the [`VaultChangeBus`] so the cloud-sync
  uploader and the redaction pipeline stay in lock-step with what
  the user just typed.

## Inject layer

[`VaultInjector`] walks the command string for `${vault:NAME}`
placeholders and substitutes their values **at the SSH transport
boundary** ([`SshService.execute`]). Two invariants are enforced
there:

- The Sentry breadcrumb logs the *pre-substitution* command — the
  substituted form never lands in the breadcrumb buffer or the crash
  report.
- The in-app command history pane keeps the placeholder form too, so
  scrollback is reproducible across devices without exposing the
  value.

If a placeholder names a secret that is not in scope for the current
server, the injector throws — failing loud is the right call. The
alternative (silently passing `${vault:X}` to the remote shell)
would either confuse the user or leak the placeholder shape into
remote logs.

## Redaction pipeline

[`VaultRedactor`] is a pure-Dart, side-effect-free function: given
the current vault state, it returns a redactor that replaces every
literal occurrence of every secret value with
`••••••• (vault: NAME)`.

It is wired into:

| Site | Call path |
|---|---|
| Sentry transport | `Sentry.beforeSend` → `ErrorScrubber.scrub` → vault pre-pass |
| In-process error capture | `ErrorReporter._capture` → `ErrorScrubber.scrub` |
| In-widget error panel & crash screen | both call `ErrorScrubber.scrub` |
| AI Assistant prompt builder | `AiCommandService._chatWith*` redacts both the user message and prepended history before the request body is built |

The redactor enforces a **6-character minimum** value length — anything
shorter would generate too many false positives (a 2-char "secret"
named `pi` would otherwise wreck the documentation). Production
secrets are well above this floor; the redactor is best-effort, not
a DLP product.

When two secrets share a common prefix, the longer one is matched
first so the shorter one cannot shadow it. Identical values that map
to different names dedupe to the first inserted name.

The redaction is **case-sensitive** by design: `Token` and `token`
are different secrets and we never want to fold one into the other.

## Sync

The vault rides the existing `BackupCrypto` HMBK v2 transport
(Argon2id + AES-GCM) under the cloud key `vault/secrets.aes`,
mirroring the snippet sync model:

- Push: every change-bus tick schedules a 3-second debounced upload.
- Pull: `pullAndMerge` downloads the latest blob, runs
  [`mergeVaults`] (newest-wins with tombstones), persists, and
  re-uploads so peers converge.
- The blob is encrypted with the master PIN — the same key the
  cloud-sync feature already requires — so the cloud provider only
  ever sees ciphertext.

## Settings UI

Settings → **Vault** lists every named secret with the value hidden
behind dots. Reveal and copy are PIN-gated. Copy puts the value on
the clipboard for 30 seconds, then auto-clears — but only if the
clipboard still contains exactly what we wrote, so we never stomp on
a value the user copied themselves between copy and timeout.

## Known limitations

- A user who types a secret into the terminal directly (not through
  the inject syntax) still sees it in the local terminal pane until
  the redactor catches up on the next render. Auto-redaction
  applies on the **next render pass**, but a screen recording of the
  exact frame where the user pressed Enter would still show the
  value.
- The redactor cannot know about secrets you have not registered —
  if you paste a token without using `${vault:NAME}`, only the
  generic `ErrorScrubber` regexes apply.
- Secret rotation reminders, OS keychain export/import, sharing a
  single secret with a teammate, and HSM/Yubikey-derived vault keys
  are all out of scope for this version. They are tracked as v2
  follow-ups.
