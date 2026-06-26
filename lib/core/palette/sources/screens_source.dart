import 'package:flutter/material.dart';

import '../fuzzy_match.dart';
import '../palette_source.dart';

/// Declarative description of a navigable screen the palette can
/// surface. Callers build a list of these and pass it to
/// [ScreensSource].
///
/// Kept separate from `_NavItems` in `server_dashboard_screen.dart`
/// because the palette has a wider scope — it surfaces top-level
/// screens (Servers list, Settings, Fleet) as well as
/// server-dashboard tabs. Wiring code in `lib/main.dart` decides
/// which screens are reachable in the current session.
@immutable
class PaletteScreen {
  const PaletteScreen({
    required this.id,
    required this.label,
    required this.icon,
    required this.navigate,
    this.subtitle,
  });

  /// Stable id (e.g. `screen.servers`). Used as the frecency key so
  /// the palette learns which screens the user opens most.
  final String id;

  final String label;
  final String? subtitle;
  final IconData icon;

  /// Closure to actually navigate to the screen. Receives the dialog
  /// context so it can `Navigator.of(context).push(...)` or pop back
  /// to a route as appropriate.
  final Future<void> Function(BuildContext context) navigate;
}

/// Surfaces the app's top-level screens in the palette. Fuzzy-matches
/// on label and on the subtitle, if any.
class ScreensSource extends PaletteSource {
  const ScreensSource({required this.screens});

  final List<PaletteScreen> screens;

  @override
  String get id => 'screens';

  @override
  String get displayName => 'Screens';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final results = <PaletteResult>[];
    for (final screen in screens) {
      final score = fuzzyBestScore(input, [
        screen.label,
        if (screen.subtitle != null) screen.subtitle!,
      ]);
      if (score <= 0) continue;
      results.add(
        PaletteResult(
          id: screen.id,
          sourceId: id,
          label: screen.label,
          subtitle: screen.subtitle,
          icon: screen.icon,
          matchScore: score,
          onInvoke: screen.navigate,
        ),
      );
    }
    return results;
  }
}
