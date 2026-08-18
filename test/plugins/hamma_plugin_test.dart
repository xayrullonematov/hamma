import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/plugins/hamma_plugin.dart';

void main() {
  group('PluginManifest', () {
    test('should instantiate correctly and retain properties', () {
      const manifest = PluginManifest(
        id: 'test_plugin',
        name: 'Test Plugin',
        version: '1.0.0',
        author: 'Jules',
        description: 'A test plugin.',
        icon: Icons.abc,
      );

      expect(manifest.id, 'test_plugin');
      expect(manifest.name, 'Test Plugin');
      expect(manifest.version, '1.0.0');
      expect(manifest.author, 'Jules');
      expect(manifest.description, 'A test plugin.');
      expect(manifest.icon, Icons.abc);
    });
  });
}
