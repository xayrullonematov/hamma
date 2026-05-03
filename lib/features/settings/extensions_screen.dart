import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../plugins/hamma_plugin.dart';
import '../../plugins/plugin_registry.dart';

/// Settings → **Extensions** screen.
///
/// Lists every compiled-in plugin with:
///
///   * Name, version, author, description from the [PluginManifest].
///   * On/off toggle backed by [PluginRegistry.setEnabled]; flips
///     persist immediately.
///   * Per-plugin permissions summary so the user knows what they
///     are agreeing to before they enable an extension.
///
/// Brutalist styling matches the rest of the Settings stack
/// (`SettingsSectionCard`-style surfaces, monospace headers, harsh
/// borders) so the screen does not feel grafted on.
class ExtensionsScreen extends StatefulWidget {
  const ExtensionsScreen({super.key, PluginRegistry? registry})
      : _registry = registry;

  final PluginRegistry? _registry;

  @override
  State<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends State<ExtensionsScreen> {
  late final PluginRegistry _registry;

  @override
  void initState() {
    super.initState();
    _registry = widget._registry ?? PluginRegistry.instance;
    _registry.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    _registry.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final plugins = _registry.all;
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text('EXTENSIONS'),
        backgroundColor: AppColors.scaffoldBackground,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        shape: const Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      body: plugins.isEmpty
          ? const _EmptyState()
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: plugins.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final plugin = plugins[i];
                final enabled = _registry.isEnabled(plugin.manifest.id);
                return _PluginCard(
                  plugin: plugin,
                  enabled: enabled,
                  onToggle: (next) => _registry.setEnabled(
                    plugin.manifest.id,
                    next,
                  ),
                );
              },
            ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.enabled,
    required this.onToggle,
  });

  final HammaPlugin plugin;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final m = plugin.manifest;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: AppColors.panel,
                  border: Border.fromBorderSide(
                    BorderSide(color: AppColors.border),
                  ),
                ),
                child: Icon(m.icon, color: AppColors.textPrimary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name.toUpperCase(),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'v${m.version} · ${m.author}',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: onToggle,
                activeThumbColor: AppColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            m.description,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          _PermissionsBlock(capabilities: plugin.capabilities),
        ],
      ),
    );
  }
}

class _PermissionsBlock extends StatelessWidget {
  const _PermissionsBlock({required this.capabilities});

  final PluginCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final flags = <String>[
      if (capabilities.needsSshSession) 'SSH SESSION',
      if (capabilities.needsLocalAi) 'LOCAL AI',
      if (capabilities.needsNetworkPort)
        capabilities.allowedHosts.isEmpty
            ? 'NETWORK (USER-CONFIGURED HOST)'
            : 'NETWORK · ${capabilities.allowedHosts.join(", ")}',
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PERMISSIONS',
            style: TextStyle(
              color: AppColors.textMuted,
              fontFamily: AppColors.monoFamily,
              fontFamilyFallback: AppColors.monoFallback,
              fontSize: 10,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          if (flags.isEmpty)
            const Text(
              'NONE',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontFamily: AppColors.monoFamily,
                fontFamilyFallback: AppColors.monoFallback,
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in flags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: const BoxDecoration(
                      border: Border.fromBorderSide(
                        BorderSide(color: AppColors.borderStrong),
                      ),
                    ),
                    child: Text(
                      f,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontFamily: AppColors.monoFamily,
                        fontFamilyFallback: AppColors.monoFallback,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          if (capabilities.permissionsSummary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              capabilities.permissionsSummary,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'NO PLUGINS REGISTERED',
          style: TextStyle(
            color: AppColors.textMuted,
            fontFamily: AppColors.monoFamily,
            fontFamilyFallback: AppColors.monoFallback,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }
}
