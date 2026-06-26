import 'package:flutter/material.dart';

import '../../../plugins/hamma_api.dart';
import '../../../plugins/hamma_plugin.dart';
import '../fuzzy_match.dart';
import '../palette_source.dart';

/// Palette source for actions registered by enabled plugins.
class PluginActionsSource extends PaletteSource {
  const PluginActionsSource({
    required this.pluginsLoader,
    required this.apiFactory,
  });

  final Iterable<HammaPlugin> Function() pluginsLoader;
  final Future<HammaApi?> Function(HammaPlugin plugin, BuildContext context)
  apiFactory;

  @override
  String get id => 'plugin_actions';

  @override
  String get displayName => 'Plugins';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final results = <PaletteResult>[];
    for (final plugin in pluginsLoader()) {
      for (final action in plugin.paletteActions()) {
        final score = fuzzyBestScore(input, [
          action.label,
          action.description ?? '',
          plugin.manifest.name,
          plugin.manifest.description,
        ]);
        if (score <= 0) continue;
        results.add(
          PaletteResult(
            id: '${plugin.manifest.id}:${action.id}',
            sourceId: id,
            label: action.label,
            subtitle: _subtitle(plugin, action),
            icon: action.icon ?? plugin.manifest.icon,
            matchScore: score,
            onInvoke: (context) async {
              final api = await apiFactory(plugin, context);
              if (api == null || !context.mounted) return;
              try {
                await action.run(context, api);
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text(error.toString())));
              }
            },
          ),
        );
      }
    }
    return results;
  }

  String _subtitle(HammaPlugin plugin, HammaPluginPaletteAction action) {
    final description = action.description?.trim();
    return description == null || description.isEmpty
        ? plugin.manifest.name
        : '${plugin.manifest.name} · $description';
  }
}
