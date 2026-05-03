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
| Sentry transport | `Sentry.beforeSend` recursively scrubs `message`, `exceptions[].value`, every `breadcrumb` (message + data map), `tags`, and the surviving keys in every `contexts` map — each value flows through `ErrorScrubber.scrub` which runs the vault pre-pass. |
| In-process error capture | `ErrorReporter._capture` → `ErrorScrubber.scrub` |
| In-widget error panel & crash screen | both call `ErrorScrubber.scrub` |
| AI Assistant prompt builder | `AiCommandService._chatWith*` redacts both the user message and prepended history before the request body is built |
| Terminal stdout / stderr | `TerminalScreen._openShell` redacts every chunk before `_terminal.write` and before it lands in the AI-context scrollback buffer |
| Server edit screen | "Linked Secrets" card lets the user flip a secret between global and `scope == server.id`; values are never shown here. |
| AI Copilot "Run" button | Goes through `SshService.execute(cmd, vaultSecrets: …)` (non-interactive), NOT through the interactive TTY. The local terminal pane shows the placeholder form of the command and the (vault-redacted) output; the resolved secret value never enters the TTY echo stream and never lands in remote shell history. |

### Wire-side injection: env vars, not literal substitution

`SshService.execute` calls `VaultInjector.buildEnvCommand` which
rewrites a command like

    psql -h db -U app -W ${vault:DBPASS}

into

    DBPASS='super-secret-value' bash -lc 'psql -h db -U app -W "${DBPASS}"'

before handing it to the SSH transport. The bash body that the
remote shell evaluates only contains the reference `"${DBPASS}"` —
the value lives only in the env-var assignment, which is
single-quoted so secrets containing `$`, backticks, double quotes,
semicolons, or newlines cannot break out of the string. We use
`bash -lc` (non-interactive) so `~/.bash_history` is never written;
the wrapper itself is prepended with a leading space for
`HISTCONTROL=ignorespace` belt-and-braces. Tests in
`test/vault_env_injection_test.dart` lock in:

- the wire-side body never contains the raw value,
- single quotes in the value are escaped via the close-and-reopen
  idiom (`'\''`),
- shell metacharacters in the value cannot break out,
- repeated placeholders dedupe in the env block,
- unknown placeholders throw `VaultInjectionException` before any
  bytes leave the device.

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

- **Interactive keystrokes are not intercepted.** The terminal
  forwards every character you type to the remote shell verbatim.
  If you literally type your password into a TTY, the local xterm
  display will show what you typed up until the remote shell echoes
  something back (at which point our stdout redactor takes over).
  Use `${vault:NAME}` via the AI Assistant's "Run" button to avoid
  this entirely — that path runs through the non-interactive SSH
  exec channel with env-var injection, so the value never enters the
  TTY echo stream and never lands in remote shell history.
- **The env-var assignment is visible in `argv` on the remote
  host.** Anyone able to read `/proc/<pid>/environ` for the bash
  wrapper (typically only the same Unix user, or root) can read the
  injected secret while the command is running. This is a deliberate
  trade-off: the alternative (literal substitution into the command
  body) was strictly worse — it leaks the value into `ps`, history,
  and stray screenshots. If you need stronger isolation, prefer
  passing secrets through stdin or a temporary file instead of as a
  command-line argument inside the substituted body.
- **Docker / Services / Process managers do not yet pass
  `vaultSecrets` into `SshService.execute`.** Placeholders typed
  in those forms reach the remote shell literally. Tracked as a
  follow-up.
- The redactor cannot know about secrets you have not registered —
  if you paste a token without using `${vault:NAME}`, only the
  generic `ErrorScrubber` regexes apply.
- The cloud blob is keyed off the master PIN. Rotating the PIN
  today requires a manual sync push from one device before peers
  can decrypt the new blob. Auto re-encrypt on PIN rotation is a
  tracked follow-up.
- Each install gets a stable per-device id stored in the secure
  keystore (`vault_device_id`). Sync uses it to skip merging the
  blob it just uploaded; if you wipe the keystore you'll get a new
  id and the next sync round will treat your own previous blob as
  a peer (which is harmless — newest-wins merging keeps the
  identical state).
- Secret rotation reminders, OS keychain export/import, sharing a
  single secret with a teammate, and HSM/Yubikey-derived vault keys
  are all out of scope for this version. They are tracked as v2
  follow-ups.
