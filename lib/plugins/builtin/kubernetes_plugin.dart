import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../hamma_api.dart';
import '../hamma_plugin.dart';

/// Built-in **Kubernetes** plugin.
///
/// Wraps the remote `kubectl` binary that lives on the SSH target.
/// We deliberately do not bundle our own client-go-style HTTP client:
///
///   * The user's kubeconfig already authenticates `kubectl` correctly
///     for whichever cluster context is active on the box.
///   * Routing through the existing SSH session means the plugin
///     inherits the connection's audit trail and the
///     [CommandRiskAssessor] gate.
///
/// Permissions: `needsSshSession` only — no network, no local AI, no
/// bespoke storage. This is the simplest possible reference plugin.
class KubernetesPlugin extends HammaPlugin {
  KubernetesPlugin();

  static const pluginId = 'com.hamma.kubernetes';

  @override
  PluginManifest get manifest => const PluginManifest(
        id: pluginId,
        name: 'Kubernetes',
        version: '1.0.0',
        author: 'Hamma core team',
        description:
            'Runs kubectl on the active SSH session and renders pod / log views.',
        icon: Icons.hub_rounded,
      );

  @override
  PluginCapabilities get capabilities => const PluginCapabilities(
        needsSshSession: true,
        permissionsSummary:
            'Runs kubectl commands on the connected server. Every command '
            'is screened by Hamma\'s risk assessor before execution.',
      );

  @override
  Widget buildPanel(BuildContext context, HammaApi api) =>
      _KubernetesPanel(api: api);
}

class _KubernetesPanel extends StatefulWidget {
  const _KubernetesPanel({required this.api});

  final HammaApi api;

  @override
  State<_KubernetesPanel> createState() => _KubernetesPanelState();
}

class _KubernetesPanelState extends State<_KubernetesPanel> {
  // Future-typed instead of List<_Pod> so the FutureBuilder pattern
  // we use below stays uniform: every refresh kicks off a new
  // future and the UI re-renders the loading / error / data states.
  Future<List<_Pod>>? _pods;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _pods = _loadPods();
    });
  }

  /// Calls `kubectl get pods -A -o json` over SSH and parses the
  /// minimum fields we need. We pull JSON instead of the human table
  /// so we don't have to worry about `kubectl`'s column widths or
  /// localisation.
  Future<List<_Pod>> _loadPods() async {
    final result = await widget.api.runCommand('kubectl get pods -A -o json');
    final stdout = result.stdout.trim();
    if (stdout.isEmpty) return const [];
    final decoded = jsonDecode(stdout);
    if (decoded is! Map<String, dynamic>) return const [];
    final items = decoded['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(_Pod.fromJson)
        .toList(growable: false);
  }

  Future<void> _showLogs(_Pod pod) async {
    // Tail a small window so we never blow up the dialog with several
    // megabytes of historical logs. The user can re-run the command
    // in the terminal if they need more.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await widget.api.runCommand(
        'kubectl logs -n ${pod.namespace} ${pod.name} --tail=200',
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _LogsDialog(pod: pod, body: result.stdout),
      );
    } on HammaApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('kubectl logs failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.scaffoldBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(serverName: widget.api.serverInfo.name, onRefresh: _refresh),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: FutureBuilder<List<_Pod>>(
              future: _pods,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
                  return _ErrorView(
                    error: snap.error.toString(),
                    onRetry: _refresh,
                  );
                }
                final pods = snap.data ?? const [];
                if (pods.isEmpty) {
                  return const Center(
                    child: Text(
                      'NO PODS RETURNED',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        letterSpacing: 1.4,
                      ),
                    ),
                  );
                }
                return _PodsTable(pods: pods, onShowLogs: _showLogs);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.serverName, required this.onRefresh});

  final String serverName;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.hub_rounded, color: AppColors.textPrimary, size: 18),
          const SizedBox(width: 10),
          Text(
            'KUBERNETES · ${serverName.toUpperCase()}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('REFRESH'),
          ),
        ],
      ),
    );
  }
}

class _PodsTable extends StatelessWidget {
  const _PodsTable({required this.pods, required this.onShowLogs});

  final List<_Pod> pods;
  final void Function(_Pod) onShowLogs;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: pods.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border),
      itemBuilder: (context, i) {
        final p = pods[i];
        return ListTile(
          dense: true,
          title: Text(
            '${p.namespace}/${p.name}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
            ),
          ),
          subtitle: Text(
            'phase: ${p.phase}  ·  node: ${p.node ?? "-"}  ·  ready: ${p.ready}',
            style: const TextStyle(
              color: AppColors.textMuted,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 11,
            ),
          ),
          trailing: TextButton(
            onPressed: () => onShowLogs(p),
            child: const Text('LOGS'),
          ),
        );
      },
    );
  }
}

class _LogsDialog extends StatelessWidget {
  const _LogsDialog({required this.pod, required this.body});

  final _Pod pod;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: AppColors.borderStrong),
        borderRadius: BorderRadius.zero,
      ),
      child: SizedBox(
        width: 720,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'LOGS · ${pod.namespace}/${pod.name}',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontFamily: AppColors.monoFamily,
                  fontFamilyFallback: AppColors.monoFallback,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  body.isEmpty ? '(no output)' : body,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontFamily: AppColors.monoFamily,
                    fontFamilyFallback: AppColors.monoFallback,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('CLOSE'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 32),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('RETRY')),
          ],
        ),
      ),
    );
  }
}

class _Pod {
  const _Pod({
    required this.namespace,
    required this.name,
    required this.phase,
    required this.ready,
    required this.node,
  });

  factory _Pod.fromJson(Map<String, dynamic> json) {
    final metadata = (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final spec = (json['spec'] as Map?)?.cast<String, dynamic>() ?? const {};
    final status = (json['status'] as Map?)?.cast<String, dynamic>() ?? const {};
    final containerStatuses = (status['containerStatuses'] as List?) ?? const [];
    var readyCount = 0;
    for (final cs in containerStatuses) {
      if (cs is Map && cs['ready'] == true) readyCount++;
    }
    return _Pod(
      namespace: (metadata['namespace'] ?? 'default').toString(),
      name: (metadata['name'] ?? '?').toString(),
      phase: (status['phase'] ?? 'Unknown').toString(),
      ready: '$readyCount/${containerStatuses.length}',
      node: spec['nodeName']?.toString(),
    );
  }

  final String namespace;
  final String name;
  final String phase;
  final String ready;
  final String? node;
}
