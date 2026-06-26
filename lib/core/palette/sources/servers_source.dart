import 'package:flutter/material.dart';

import '../../models/server_profile.dart';
import '../fuzzy_match.dart';
import '../palette_source.dart';

/// Surfaces saved server profiles. Matches fuzzy on name + host so
/// "prod" finds both "prod-db" and "192.168.1.50 (production-db)".
///
/// The source is read-only — it doesn't load servers itself. The
/// caller (typically `lib/main.dart`) holds the canonical list and
/// passes a [loader] closure. That keeps `SavedServersStorage` out of
/// the palette package and makes testing trivial: pass a closure that
/// returns a hard-coded list.
///
/// On invoke, [onSelect] is called with the chosen profile and the
/// dialog's [BuildContext]. The closure decides what "open this
/// server" means in the current app shell — push a dashboard route,
/// pre-fill a vault unlock prompt, whatever.
class ServersSource extends PaletteSource {
  const ServersSource({required this.loader, required this.onSelect});

  final Future<List<ServerProfile>> Function() loader;
  final Future<void> Function(ServerProfile server, BuildContext context)
  onSelect;

  @override
  String get id => 'servers';

  @override
  String get displayName => 'Servers';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final servers = await loader();
    final results = <PaletteResult>[];
    for (final s in servers) {
      final score = fuzzyBestScore(input, [s.name, s.host, s.username]);
      if (score <= 0) continue;
      results.add(
        PaletteResult(
          id: s.id,
          sourceId: id,
          label: s.name,
          subtitle: '${s.username}@${s.host}:${s.port}',
          icon: Icons.dns_rounded,
          matchScore: score,
          onInvoke: (context) => onSelect(s, context),
        ),
      );
    }
    return results;
  }
}
