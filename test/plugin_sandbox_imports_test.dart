import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Mechanically enforces the v1 plugin sandbox import policy.
///
/// Built-in plugins under `lib/plugins/builtin/` are allowed to import
/// Flutter widgets and the plugin SDK (`hamma_api.dart` / `hamma_plugin.dart`)
/// only. Reaching for `dart:io`, `package:http`, `flutter_secure_storage`,
/// or anything under `lib/core/` directly would let a plugin bypass the
/// risk gate / allow-list / per-plugin namespacing — that's exactly what
/// `HammaApi` exists to prevent.
///
/// This test is the enforcement point. CI runs `flutter test` so a
/// regression here fails the build.
void main() {
  test('built-in plugins only reach core via HammaApi', () {
    final dir = Directory('lib/plugins/builtin');
    expect(dir.existsSync(), isTrue, reason: 'builtin dir must exist');

    final forbiddenImports = <RegExp>[
      RegExp(r"^\s*import\s+'dart:io'"),
      RegExp(r"^\s*import\s+'package:http/"),
      RegExp(r"^\s*import\s+'package:flutter_secure_storage/"),
      RegExp(r"^\s*import\s+'.*core/"),
      RegExp(r"^\s*import\s+'.*plugin_config_store"),
    ];

    final violations = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // app_colors is a UI-only theme constants file, no behaviour.
      // Plugins are allowed to use it for brutalist styling parity.
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.contains('app_colors.dart')) continue;
        for (final pattern in forbiddenImports) {
          if (pattern.hasMatch(line)) {
            violations.add('${entity.path}:${i + 1}  $line');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Plugins must reach the rest of Hamma through HammaApi only. '
          'Forbidden imports detected:\n${violations.join("\n")}',
    );
  });
}
