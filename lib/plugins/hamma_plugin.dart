import 'package:flutter/material.dart';

import 'hamma_api.dart';

/// Public contract every Hamma extension implements.
///
/// v1 of the plugin API ships compiled in: there is no dynamic loading,
/// no marketplace, and no hot reload. Every plugin source file lives in
/// `lib/plugins/builtin/` (or anywhere in the app's Dart graph) and is
/// registered with [PluginRegistry] at startup. Compiled-in is a
/// deliberate scope choice for v1 — it sidesteps an enormous attack
/// surface (sandboxed code execution, signature verification, etc.)
/// while still proving out the API shape.
///
/// The lifecycle is intentionally tiny:
///
///   * [onLoad]  — called the first time the plugin is enabled and on
///     every app launch while it stays enabled. Plugins should treat
///     this as their `initState`-equivalent for any cross-panel state
///     they want to warm up. The supplied [HammaApi] is sandboxed: no
///     direct file system, no `dart:io` socket access, no secure
///     storage; only what the API explicitly exposes.
///   * [onUnload] — called when the user toggles the plugin off in
///     Settings → Extensions, or on app shutdown. Best-effort: do not
///     rely on async cleanup completing before process exit.
///   * [buildPanel] — renders the plugin's main UI inside a server
///     dashboard tab. Called once per (server-session, build) tuple;
///     the same [HammaApi] instance is passed for the lifetime of a
///     given server session.
///
/// Plugins **must not** import from `lib/core/storage/`, `dart:io` (for
/// network), or `package:http` directly. The narrow [HammaApi] handle
/// is the only sanctioned door — it gates every command through the
/// shared [CommandRiskAssessor] and refuses non-allow-listed network
/// destinations.
abstract class HammaPlugin {
  const HammaPlugin();

  /// Static identity + display metadata. Visible to the user in
  /// Settings → Extensions and on the dashboard nav.
  PluginManifest get manifest;

  /// Declared up-front; the user reviews these once per plugin and
  /// toggles the plugin on or off. The runtime API enforces that a
  /// plugin can only do what it declared.
  PluginCapabilities get capabilities;

  /// Hook the plugin runs on enable / app launch. Default no-op.
  Future<void> onLoad(HammaApi api) async {}

  /// Hook the plugin runs on disable / app shutdown. Default no-op.
  Future<void> onUnload() async {}

  /// Build the plugin's main panel inside a server dashboard tab.
  Widget buildPanel(BuildContext context, HammaApi api);

  /// Hook for plugins whose network allow-list is partly user-driven
  /// (e.g. Proxmox: the cluster host is typed into the plugin config
  /// at first run). The registry calls this when building a fresh
  /// [HammaApi] handle and merges the result into
  /// [PluginCapabilities.allowedHosts] for that handle only.
  ///
  /// **Security note:** anything returned here must come from the
  /// plugin's own scoped config — no hard-coded "allow everything"
  /// strings. The user reviewed the plugin's static
  /// [PluginCapabilities] when they enabled the extension; dynamic
  /// hosts they added afterwards are by definition things they
  /// explicitly typed into the plugin's own UI.
  Future<List<String>> resolveDynamicAllowedHosts(
    HammaPluginConfigReader config,
  ) async {
    return const [];
  }
}

/// Tiny read-only handle the registry passes into
/// [HammaPlugin.resolveDynamicAllowedHosts]. Plugins do not get
/// `write` here — the hook is purely a way to surface stored hosts to
/// the allow-list builder, not a place to mutate configuration.
abstract class HammaPluginConfigReader {
  Future<String?> readConfig(String key);
}

/// Static identity + display metadata for a [HammaPlugin].
@immutable
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.icon,
  });

  /// Stable, machine-readable id. Used as the prefix for the plugin's
  /// own scoped secure-storage namespace, so it must be stable across
  /// app versions or persisted plugin config will be lost.
  final String id;

  /// Display name shown in Settings → Extensions and dashboard tabs.
  final String name;

  /// Semver-style string. Surfaced in the Extensions screen so users
  /// can correlate behaviour changes against version bumps.
  final String version;

  /// Author / maintainer line. Free-form.
  final String author;

  /// One-paragraph description of what the plugin does.
  final String description;

  /// Icon shown in nav and on the Extensions card.
  final IconData icon;
}

/// What a plugin is allowed to do at runtime.
///
/// The user sees a humanised summary in Settings → Extensions before
/// the plugin is enabled. The runtime [HammaApi] enforces these flags:
/// asking for SSH access without `needsSshSession=true` throws
/// `HammaApiException`. Adding a new permission means adding both a
/// flag here AND the runtime gate in `HammaApi`.
@immutable
class PluginCapabilities {
  const PluginCapabilities({
    this.needsSshSession = false,
    this.needsLocalAi = false,
    this.needsNetworkPort = false,
    this.allowedHosts = const <String>[],
    this.permissionsSummary = '',
  });

  /// Plugin needs to run shell commands on the active SSH session.
  /// Every command still passes through [CommandRiskAssessor.assessFast]
  /// — plugins cannot bypass safety.
  final bool needsSshSession;

  /// Plugin needs to call the local AI (loopback only). Cloud
  /// providers are intentionally inaccessible: the same loopback
  /// guard the rest of the app uses is enforced again here.
  final bool needsLocalAi;

  /// Plugin needs to make outbound HTTP(S) requests to a small set of
  /// pre-declared hosts. Empty [allowedHosts] with this flag set
  /// means *no* hosts are reachable — the plugin must add at least
  /// one entry (the user reviews them in the permissions summary).
  final bool needsNetworkPort;

  /// Allow-list of hostnames (or registrable suffixes — see
  /// `_isHostAllowed` in `HammaApi`) the plugin may dial. Anything
  /// outside this list throws `HammaApiException`.
  final List<String> allowedHosts;

  /// Human-readable description shown to the user when they review
  /// the plugin's permissions in Settings → Extensions. Should match
  /// the actual flags above; review it on every permission change.
  final String permissionsSummary;
}
