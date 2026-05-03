# Hamma Plugin API (v1)

> Status: **stable for v1** — compiled-in only, no dynamic loading,
> no marketplace. The API surface is intentionally small.

Hamma extensions add new dashboard panels (Kubernetes, Proxmox, …)
without forking the app. v1 ships them compiled into the binary; a
runtime marketplace is on the Phase 8 roadmap.

This document is the contract a plugin author needs.

---

## Table of contents

1. [Hello, world](#hello-world)
2. [`HammaPlugin` lifecycle](#hammaplugin-lifecycle)
3. [`HammaApi` reference](#hammaapi-reference)
4. [Permissions catalog](#permissions-catalog)
5. [Sandbox rules](#sandbox-rules)
6. [Registering a plugin](#registering-a-plugin)
7. [Reference plugins](#reference-plugins)

---

## Hello, world

```dart
// lib/plugins/builtin/hello_world_plugin.dart
import 'package:flutter/material.dart';
import '../hamma_api.dart';
import '../hamma_plugin.dart';

class HelloWorldPlugin extends HammaPlugin {
  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'com.example.hello',
        name: 'Hello World',
        version: '1.0.0',
        author: 'You',
        description: 'Smallest possible Hamma extension.',
        icon: Icons.emoji_emotions_rounded,
      );

  @override
  PluginCapabilities get capabilities => const PluginCapabilities(
        needsSshSession: true,
        permissionsSummary: 'Runs `uname -a` on the connected server.',
      );

  @override
  Widget buildPanel(BuildContext context, HammaApi api) {
    return Center(
      child: ElevatedButton(
        onPressed: () async {
          final result = await api.runCommand('uname -a');
          // ignore: avoid_print
          print(result.stdout);
        },
        child: const Text('Run uname -a'),
      ),
    );
  }
}
```

Then register it once at app startup (see
[Registering a plugin](#registering-a-plugin)).

---

## `HammaPlugin` lifecycle

```
┌─────────────────────────┐
│ register (compile time) │
└──────────────┬──────────┘
               │   user toggles "enabled" in Settings → Extensions
               ▼
┌─────────────────────────┐    server connects
│      enabled idle       │ ────────────────────┐
└──────────────┬──────────┘                     ▼
               │                  ┌──────────────────────┐
               │                  │ buildPanel + onLoad  │  per dashboard mount
               │                  └──────────┬───────────┘
               │                             │
               │                             ▼
               │                  ┌──────────────────────┐
               │                  │ user navigates away  │
               │                  │ → onUnload (best-eff)│
               └──────────────────┴──────────────────────┘
```

Hooks:

| Hook                              | When                                          | Notes |
|-----------------------------------|-----------------------------------------------|-------|
| `onLoad(HammaApi)`                | Plugin's panel is mounted in a server session | Default no-op. Warm caches here. |
| `onUnload()`                      | Plugin's panel is unmounted / app shutdown    | Best-effort; do not rely on async finishing before exit. |
| `buildPanel(ctx, api)`            | Each rebuild of the dashboard tab             | The same `HammaApi` instance is re-passed for the lifetime of the server session. |
| `resolveDynamicAllowedHosts(cfg)` | Once per panel mount, before `buildPanel`      | Override only if your plugin learns its host from user config (Proxmox does). |

---

## `HammaApi` reference

`HammaApi` is the **only** door from a plugin into the rest of Hamma.
Plugins must not import `package:http`, `dart:io` (for sockets), or
anything under `lib/core/storage/` directly.

### Server context

| Member               | Type                | Notes |
|----------------------|---------------------|-------|
| `pluginId`           | `String`            | Same as `manifest.id`. |
| `capabilities`       | `PluginCapabilities`| What the plugin declared at install time. |
| `serverInfo`         | `PluginServerInfo`  | Read-only metadata: `id`, `name`, `host`, `port`, `username`. **No credentials.** |

### SSH

```dart
Future<PluginCommandResult> runCommand(String command);
```

* Requires `needsSshSession: true`.
* Every command is graded by the full `CommandRiskAssessor`.
  Plugins may only execute commands graded `low`. Anything
  `moderate` / `high` / `critical` is refused with
  `HammaApiException` before it reaches the SSH transport — if a
  plugin needs to invoke a privileged command, the user must run
  it themselves from the AI Assistant where the safety queue can
  confirm interactively.
* `PluginCommandResult.riskLevel` is therefore always `low` for
  results that reach the caller.
* The plugin is responsible for shell-quoting any user-supplied
  substrings; Hamma intentionally does not escape because plugins
  frequently need pipes / redirects of their own.

### Local AI

```dart
Future<String> callLocalAi(String prompt, {List<Map<String,String>> history});
```

* Requires `needsLocalAi: true`.
* Fails unless the active provider is `AiProvider.local` (loopback).
  The same loopback contract the rest of Hamma honours is enforced
  here too: plugins **cannot** call OpenAI / Gemini / OpenRouter.

### HTTP (allow-listed)

```dart
Future<HammaHttpResponse> httpGet(String url, {Map<String,String> headers});
Future<HammaHttpResponse> httpPostJson(String url, Object? body, {Map<String,String> headers});
```

* Requires `needsNetworkPort: true`.
* The destination host must be in `capabilities.allowedHosts`
  (suffix match: an entry `example.com` permits `api.example.com`)
  **or** in the list returned by `resolveDynamicAllowedHosts`.
* Non-HTTP/HTTPS schemes are refused.

### Per-plugin scoped storage

```dart
Future<String?> readConfig(String key);
Future<void>    writeConfig(String key, String value);
Future<void>    deleteConfig(String key);
```

* Lives in `flutter_secure_storage`, namespaced as
  `plugin__<pluginId>__<key>`. Plugins cannot read each other's
  values — even though they share the same backing keystore.

---

## Permissions catalog

| Flag                         | Grants                                                        |
|------------------------------|---------------------------------------------------------------|
| `needsSshSession`            | `runCommand` (risk-gated)                                     |
| `needsLocalAi`               | `callLocalAi` (loopback only)                                 |
| `needsNetworkPort`           | `httpGet` / `httpPostJson` to `allowedHosts` only             |
| `allowedHosts`               | Whitelist (suffix-match) of hosts the plugin may dial         |
| `permissionsSummary`         | Human-readable copy shown in Settings → Extensions            |

Flags that are **not** declared at install time can never be used at
runtime, even if a future Hamma release exposes the underlying API.

---

## Sandbox rules

1. **No direct `package:http`, no raw `dart:io` sockets, no
   `flutter_secure_storage` imports.** Use `HammaApi` instead.
2. **No bypassing the risk assessor.** Every command goes through
   `runCommand` and therefore through the full `CommandRiskAssessor`;
   only `low`-graded commands are executed.
3. **No cross-plugin storage access.** Per-plugin namespacing is
   enforced by the registry — there is no API to look up another
   plugin's keys.
4. **Loopback-only AI.** `callLocalAi` refuses every provider but
   `AiProvider.local`.
5. **Allow-listed network only.** `needsNetworkPort` is meaningless
   without `allowedHosts` (or a `resolveDynamicAllowedHosts` override).

### v1 trust model

In v1 the sandbox is **policy-based**, not OS-enforced: every
plugin is compiled into the Hamma binary and reviewed as part of
the same PR pipeline as core code. There is no dynamic loading and
no third-party plugin distribution. That means:

* `HammaApi` and `PluginConfigStore` are public Dart classes — a
  malicious plugin could in theory construct one directly. Code
  review on every plugin PR is the line of defence; the test suite
  for `lib/plugins/` includes a check that builtins only reach the
  outside world through `HammaApi`.
* Phase 8's marketplace work will tighten this with a stricter
  loader (hidden constructors, isolate boundary, capability
  manifest signed at build time). Plugin authors writing against
  v1 should not rely on the public-ness of these classes.

Until then the working contract is: **plugins SHALL only call into
the rest of Hamma through their `HammaApi` parameter.** PRs that
violate this are rejected.

---

## Registering a plugin

Add a `register(MyPlugin())` call inside
`PluginRegistry.registerBuiltins()` (or call
`PluginRegistry.instance.register(MyPlugin())` from your own
bootstrap code). Then call `PluginRegistry.instance.load()` once at
app startup so the persisted enabled state is restored.

The user controls whether the plugin actually runs from
**Settings → Extensions**.

---

## Reference plugins

* **`com.hamma.kubernetes`** — wraps `kubectl` over the active SSH
  session. Lists pods cluster-wide, tails the last 200 lines of
  per-pod logs in a brutalist dialog. `needsSshSession` only.

* **`com.hamma.proxmox`** — calls the Proxmox VE HTTPS API with a
  user-provided API token. Lists nodes and guests (qemu / lxc).
  `needsNetworkPort` with the cluster host added at runtime via
  `resolveDynamicAllowedHosts`.

Both live under `lib/plugins/builtin/`.
