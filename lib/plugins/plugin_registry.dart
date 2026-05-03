// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models/server_profile.dart';
import '../core/ssh/ssh_service.dart';
import '../core/storage/api_key_storage.dart';
import 'builtin/kubernetes_plugin.dart';
import 'builtin/proxmox_plugin.dart';
import 'hamma_api.dart';
import 'hamma_plugin.dart';
import 'plugin_config_store.dart';

/// Process-wide registry of all compiled-in plugins.
///
/// This is a singleton because the plugin set is static for v1 (no
/// dynamic loading) and the enabled/disabled state needs to be
/// observable by both the Settings → Extensions screen and the
/// dashboard nav at the same time. [ChangeNotifier] is the smallest
/// thing that makes that possible without forcing a full app-wide
/// state-management dependency.
///
/// Enabled state is persisted to [FlutterSecureStorage] (same backing
/// store as the rest of the app) under a single comma-delimited key.
/// Storing it next to the rest of the user's secrets is intentional —
/// plugin enable state is a security-relevant decision and gets the
/// same protections as their SSH credentials.
class PluginRegistry extends ChangeNotifier {
  PluginRegistry._({
    FlutterSecureStorage? secureStorage,
    PluginConfigStore? configStore,
  })  : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _configStore = configStore ?? const PluginConfigStore();

  /// Process-wide instance. Built lazily so tests can call
  /// [debugReset] before the first access if they want a clean slate.
  static PluginRegistry get instance => _instance ??= PluginRegistry._();
  static PluginRegistry? _instance;

  /// Test seam: drop the singleton so the next [instance] access
  /// builds a fresh one. Production code never calls this.
  @visibleForTesting
  static void debugReset() {
    _instance?.dispose();
    _instance = null;
  }

  /// Test seam: install a custom registry instance (e.g. with an
  /// in-memory secure-storage fake). Production code never calls this.
  @visibleForTesting
  static void debugOverride(PluginRegistry registry) {
    _instance?.dispose();
    _instance = registry;
  }

  static const _enabledKey = 'plugin_registry_enabled_ids';
  static const _enabledByDefault = <String>{
    KubernetesPlugin.pluginId,
    ProxmoxPlugin.pluginId,
  };

  final FlutterSecureStorage _secureStorage;
  final PluginConfigStore _configStore;

  final List<HammaPlugin> _plugins = [];
  final Set<String> _enabledIds = <String>{};
  final Set<String> _pendingInvalidations = <String>{};
  bool _isLoaded = false;

  /// Plugin ids whose cached [HammaApi] handles the dashboard should
  /// drop and rebuild before the next panel mount. The dashboard
  /// listener calls [consumePendingInvalidations] inside its
  /// [ChangeNotifier] callback to drain this set.
  Set<String> consumePendingInvalidations() {
    if (_pendingInvalidations.isEmpty) return const <String>{};
    final out = Set<String>.from(_pendingInvalidations);
    _pendingInvalidations.clear();
    return out;
  }

  /// Mark [pluginId]'s API handle as stale. Called via the
  /// `onInvalidate` callback we install on every [HammaApi]; plugins
  /// reach this from [HammaApi.requestApiRebuild] after they write
  /// config that feeds [HammaPlugin.resolveDynamicAllowedHosts].
  void invalidateApi(String pluginId) {
    _pendingInvalidations.add(pluginId);
    notifyListeners();
  }

  /// All registered plugins, in registration order. The dashboard nav
  /// renders enabled plugins in this order so the user sees a stable
  /// layout across launches.
  List<HammaPlugin> get all => List.unmodifiable(_plugins);

  /// Subset of [all] whose ids are in [_enabledIds].
  List<HammaPlugin> get enabled =>
      _plugins.where((p) => _enabledIds.contains(p.manifest.id)).toList();

  bool isEnabled(String pluginId) => _enabledIds.contains(pluginId);

  /// Register the standard set of built-in plugins. Idempotent — safe
  /// to call from tests that build a fresh registry.
  void registerBuiltins() {
    if (_plugins.any((p) => p.manifest.id == KubernetesPlugin.pluginId)) {
      return;
    }
    register(KubernetesPlugin());
    register(ProxmoxPlugin());
  }

  /// Add [plugin] to the registry. The first plugin with a given id
  /// wins — duplicate registrations are silently ignored so a hot
  /// reload during development does not produce ghost entries.
  void register(HammaPlugin plugin) {
    final id = plugin.manifest.id;
    if (_plugins.any((p) => p.manifest.id == id)) return;
    _plugins.add(plugin);
    notifyListeners();
  }

  /// Load persisted enabled state. Called once at app startup; the
  /// registry stays usable but with no plugins enabled if loading
  /// fails (we never block app launch on plugin state).
  Future<void> load() async {
    if (_isLoaded) return;
    try {
      final raw = await _secureStorage.read(key: _enabledKey);
      if (raw == null) {
        // First launch: opt the default builtins in so the user sees
        // them in the dashboard nav immediately. Persisting "" later
        // means the user has explicitly disabled everything, which we
        // honour rather than re-enabling the defaults.
        _enabledIds.addAll(_enabledByDefault);
      } else {
        _enabledIds.addAll(
          raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
        );
      }
    } catch (_) {
      // Best-effort: if secure storage fails, leave nothing enabled.
      // Better to render no plugin tabs than to crash the app.
    }
    _isLoaded = true;
    notifyListeners();
  }

  /// Toggle [pluginId] on or off. Persists immediately so the choice
  /// survives a crash. The plugin's [HammaPlugin.onLoad] /
  /// [HammaPlugin.onUnload] hooks are not fired here — they run when
  /// a server dashboard actually mounts the plugin's panel, because
  /// the API handle they receive is per-server-session.
  Future<void> setEnabled(String pluginId, bool enabled) async {
    if (enabled) {
      _enabledIds.add(pluginId);
    } else {
      _enabledIds.remove(pluginId);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _secureStorage.write(
        key: _enabledKey,
        value: _enabledIds.join(','),
      );
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory state still
      // reflects the user's choice for the rest of the session.
    }
  }

  /// Build a [HammaApi] for [plugin] bound to a specific server
  /// session. Called by the dashboard each time it mounts a plugin
  /// panel. The returned handle's lifetime matches the dashboard
  /// state — we deliberately do not cache it across server switches
  /// because the server-info / SSH service / AI settings can all
  /// change between sessions.
  ///
  /// Async because we ask the plugin to resolve any user-driven
  /// allow-list hosts from its scoped config before we hand it the
  /// API handle (see [HammaPlugin.resolveDynamicAllowedHosts]). The
  /// dashboard awaits this exactly once per panel mount.
  Future<HammaApi> buildApi({
    required HammaPlugin plugin,
    required ServerProfile server,
    required SshService sshService,
    required AiSettings aiSettings,
  }) async {
    final reader = _ScopedReader(
      configStore: _configStore,
      pluginId: plugin.manifest.id,
    );
    final dynamicHosts = await plugin.resolveDynamicAllowedHosts(reader);
    final mergedHosts = <String>[
      ...plugin.capabilities.allowedHosts,
      ...dynamicHosts,
    ];
    final caps = PluginCapabilities(
      needsSshSession: plugin.capabilities.needsSshSession,
      needsLocalAi: plugin.capabilities.needsLocalAi,
      needsNetworkPort: plugin.capabilities.needsNetworkPort,
      allowedHosts: mergedHosts,
      permissionsSummary: plugin.capabilities.permissionsSummary,
    );
    return HammaApi(
      pluginId: plugin.manifest.id,
      capabilities: caps,
      serverInfo: PluginServerInfo.fromProfile(server),
      configStore: _configStore,
      sshService: sshService,
      aiSettings: aiSettings,
      onInvalidate: () async => invalidateApi(plugin.manifest.id),
    );
  }
}

class _ScopedReader implements HammaPluginConfigReader {
  const _ScopedReader({required this.configStore, required this.pluginId});

  final PluginConfigStore configStore;
  final String pluginId;

  @override
  Future<String?> readConfig(String key) => configStore.read(pluginId, key);
}
