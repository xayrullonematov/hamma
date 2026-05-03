import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

import '../core/ai/ai_command_service.dart';
import '../core/ai/ai_provider.dart';
import '../core/ai/command_risk_assessor.dart';
import '../core/models/server_profile.dart';
import '../core/ssh/ssh_service.dart';
import '../core/storage/api_key_storage.dart';
import 'hamma_plugin.dart';
import 'plugin_config_store.dart';

/// Sandboxed handle a [HammaPlugin] receives at runtime.
///
/// This is intentionally narrower than the underlying services:
///
///   * Plugins cannot reach `flutter_secure_storage` directly. They get
///     a per-plugin namespaced [readConfig] / [writeConfig] that lives
///     inside the same encrypted backing store but is keyed by the
///     plugin id, so one plugin can never read another's secrets.
///   * Plugins cannot call `package:http` or open arbitrary sockets.
///     [httpGet] / [httpPostJson] route through a `dart:io` HttpClient
///     with the per-plugin allow-list enforced *before* the request
///     is dispatched.
///   * Plugins cannot bypass the risk assessor. [runCommand] always
///     calls [CommandRiskAssessor.assessFast] first; commands that
///     come back as `critical` are refused with [HammaApiException]
///     and never reach the SSH transport.
///   * Plugins cannot call cloud AI. [callLocalAi] hard-fails unless
///     [AiSettings.provider] is [AiProvider.local], so a misconfigured
///     plugin can never silently exfiltrate a prompt off-device.
///
/// Capability flags from [PluginCapabilities] are checked on every
/// gated method, so a plugin that didn't declare a permission at
/// install time can never use it at runtime even if a future API
/// change unlocks the underlying service.
class HammaApi {
  /// Constructed by the [PluginRegistry] (and by tests directly).
  /// Not part of the public plugin API — plugins receive a built
  /// instance via [HammaPlugin.buildPanel] and must never construct
  /// one themselves.
  HammaApi({
    required this.pluginId,
    required this.capabilities,
    required this.serverInfo,
    required PluginConfigStore configStore,
    SshService? sshService,
    AiSettings? aiSettings,
    HttpClient Function()? httpClientFactory,
    Future<void> Function()? onInvalidate,
  })  : _configStore = configStore,
        _sshService = sshService,
        _aiSettings = aiSettings,
        _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _onInvalidate = onInvalidate;

  /// Plugin id this handle belongs to. Used as the storage namespace
  /// and as the breadcrumb tag for any logged failure.
  final String pluginId;

  /// What the plugin declared it needs at install time. Every gated
  /// method checks the relevant flag and throws if it wasn't declared.
  final PluginCapabilities capabilities;

  /// Read-only metadata about the server the dashboard is currently
  /// pointed at. Credentials are intentionally absent — plugins get
  /// the host/port/username so they can render context, but they
  /// cannot rebuild a connection out-of-band.
  final PluginServerInfo serverInfo;

  final PluginConfigStore _configStore;
  final SshService? _sshService;
  final AiSettings? _aiSettings;
  final HttpClient Function() _httpClientFactory;

  /// Hook the registry installs so the plugin can ask the dashboard
  /// to rebuild its [HammaApi] handle. Used after the plugin mutates
  /// config that feeds [HammaPlugin.resolveDynamicAllowedHosts] —
  /// without this, the cached handle would keep its stale allow-list
  /// for the rest of the server session.
  final Future<void> Function()? _onInvalidate;

  /// Ask the host (the dashboard) to drop its cached [HammaApi] for
  /// this plugin and rebuild a fresh one on the next panel mount.
  /// Plugins call this after they write config that affects their
  /// dynamic allow-list — the next call resolves the merged hosts
  /// against the freshly-written config.
  Future<void> requestApiRebuild() async {
    final hook = _onInvalidate;
    if (hook != null) await hook();
  }

  // ---------------------------------------------------------------------------
  // SSH
  // ---------------------------------------------------------------------------

  /// Run [command] on the active SSH session and return the captured
  /// stdout. The command is first scored by [CommandRiskAssessor];
  /// `critical` results are refused. The plugin is responsible for
  /// quoting any user-supplied substrings — the API does not attempt
  /// to escape shell metacharacters because plugins frequently need
  /// pipelines, redirects and substitutions of their own.
  Future<PluginCommandResult> runCommand(String command) async {
    if (!capabilities.needsSshSession) {
      throw HammaApiException(
        'Plugin "$pluginId" did not declare needsSshSession but tried to run a command.',
      );
    }
    final ssh = _sshService;
    if (ssh == null) {
      throw HammaApiException('No active SSH session for plugin "$pluginId".');
    }

    // Risk gate. `assessFast` returns null for benign commands and a
    // [CommandRiskLevel] for anything matched by its quick-deny list.
    // We surface non-critical levels via the result so the plugin
    // can choose to confirm with the user before showing output.
    final risk = CommandRiskAssessor.assessFast(command);
    if (risk == CommandRiskLevel.critical) {
      throw HammaApiException(
        'Refused to run command for plugin "$pluginId": '
        'CommandRiskAssessor flagged it as CRITICAL. Plugins cannot '
        'bypass the risk gate.',
        riskLevel: risk,
      );
    }

    final stdout = await ssh.execute(command);
    return PluginCommandResult(
      command: command,
      stdout: stdout,
      riskLevel: risk,
    );
  }

  // ---------------------------------------------------------------------------
  // Local AI
  // ---------------------------------------------------------------------------

  /// Send [prompt] to the local AI provider and return the full reply.
  /// Refuses if the active provider is not [AiProvider.local] — this
  /// is the same loopback contract the rest of the app honours and
  /// is what makes the plugin API safe to use offline.
  Future<String> callLocalAi(
    String prompt, {
    List<Map<String, String>> history = const [],
  }) async {
    if (!capabilities.needsLocalAi) {
      throw HammaApiException(
        'Plugin "$pluginId" did not declare needsLocalAi but tried to call the model.',
      );
    }
    final settings = _aiSettings;
    if (settings == null || settings.provider != AiProvider.local) {
      throw HammaApiException(
        'Local AI is not the active provider. Plugins are only allowed '
        'to call the on-device model; switch to "Local AI" in settings.',
      );
    }
    final service = AiCommandService.forProvider(
      provider: AiProvider.local,
      apiKey: '',
      localEndpoint: settings.localEndpoint,
      localModel: settings.localModel,
    );
    return service.generateChatResponse(prompt, history: history);
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  /// GET [url] with optional [headers]. The destination host must be
  /// in [PluginCapabilities.allowedHosts]; anything else throws.
  Future<HammaHttpResponse> httpGet(
    String url, {
    Map<String, String> headers = const {},
  }) {
    return _request('GET', url, headers: headers);
  }

  /// POST [body] as JSON to [url]. The destination host must be in
  /// [PluginCapabilities.allowedHosts]; anything else throws.
  Future<HammaHttpResponse> httpPostJson(
    String url,
    Object? body, {
    Map<String, String> headers = const {},
  }) {
    final merged = <String, String>{
      'Content-Type': 'application/json',
      ...headers,
    };
    return _request('POST', url, headers: merged, body: jsonEncode(body));
  }

  Future<HammaHttpResponse> _request(
    String method,
    String url, {
    required Map<String, String> headers,
    String? body,
  }) async {
    if (!capabilities.needsNetworkPort) {
      throw HammaApiException(
        'Plugin "$pluginId" did not declare needsNetworkPort but tried to call $url.',
      );
    }
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw HammaApiException(
        'Plugin "$pluginId" attempted a non-HTTP scheme (${uri.scheme}); refused.',
      );
    }
    if (!_isHostAllowed(uri.host)) {
      throw HammaApiException(
        'Plugin "$pluginId" attempted to call ${uri.host}, which is not '
        'in its allowedHosts list. Add the host to the plugin manifest '
        'and re-enable the extension to permit this destination.',
      );
    }

    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = method == 'GET'
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      headers.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close();
      final responseBody =
          await response.transform(utf8.decoder).join().timeout(
                const Duration(seconds: 30),
              );
      return HammaHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Match [host] against [PluginCapabilities.allowedHosts]. An entry
  /// matches if it is exactly equal to [host], or if [host] ends with
  /// `.entry` (so `cluster.example.com` is allowed when the manifest
  /// lists `example.com`). Wildcard matching is intentionally
  /// suffix-only — no glob — because a careless `*` would defeat the
  /// purpose of the allow-list.
  bool _isHostAllowed(String host) {
    final normalized = host.toLowerCase();
    for (final raw in capabilities.allowedHosts) {
      final entry = raw.toLowerCase();
      if (normalized == entry) return true;
      if (normalized.endsWith('.$entry')) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Plugin-scoped config
  // ---------------------------------------------------------------------------

  /// Read a per-plugin config value. Lives in the same encrypted
  /// secure-storage backing as the rest of the app, but namespaced by
  /// [pluginId] so plugins cannot read each other's data.
  Future<String?> readConfig(String key) =>
      _configStore.read(pluginId, key);

  /// Write a per-plugin config value. Same namespacing rules as
  /// [readConfig]. Use this for things like API tokens that the
  /// plugin needs to remember between launches.
  Future<void> writeConfig(String key, String value) =>
      _configStore.write(pluginId, key, value);

  /// Delete a per-plugin config value.
  Future<void> deleteConfig(String key) =>
      _configStore.delete(pluginId, key);
}

/// Read-only metadata about the active server, exposed to plugins via
/// [HammaApi.serverInfo]. Credentials (password, private key, key
/// password) are deliberately omitted — plugins should never need to
/// re-establish the connection themselves; that is the SSH service's
/// job.
@immutable
class PluginServerInfo {
  const PluginServerInfo({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
  });

  factory PluginServerInfo.fromProfile(ServerProfile profile) {
    return PluginServerInfo(
      id: profile.id,
      name: profile.name,
      host: profile.host,
      port: profile.port,
      username: profile.username,
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
}

/// Result of [HammaApi.runCommand]. [riskLevel] is whatever
/// [CommandRiskAssessor.assessFast] returned for the command — `null`
/// for benign commands, `low/moderate/high` when the assessor matched
/// a heuristic but did not refuse outright. (`critical` never reaches
/// the result because [HammaApi.runCommand] throws before executing.)
@immutable
class PluginCommandResult {
  const PluginCommandResult({
    required this.command,
    required this.stdout,
    required this.riskLevel,
  });

  final String command;
  final String stdout;
  final CommandRiskLevel? riskLevel;
}

/// Result of an HTTP call made through [HammaApi.httpGet] /
/// [HammaApi.httpPostJson].
@immutable
class HammaHttpResponse {
  const HammaHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Failure thrown by [HammaApi] for any sandbox / capability / risk
/// violation. Plugins should catch this and surface a friendly
/// message rather than letting it bubble all the way to the crash
/// screen.
class HammaApiException implements Exception {
  const HammaApiException(this.message, {this.riskLevel});

  final String message;
  final CommandRiskLevel? riskLevel;

  @override
  String toString() =>
      riskLevel == null ? 'HammaApiException: $message' : 'HammaApiException($riskLevel): $message';
}
