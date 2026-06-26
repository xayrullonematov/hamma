import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/keymap/keymap.dart';

void main() {
  group('KeyChord', () {
    test('renders primary modifier as ⌘ on macOS and Ctrl elsewhere', () {
      const chord = KeyChord(
        logicalKey: LogicalKeyboardKey.keyK,
        modifiers: {KeymapModifier.primary},
      );
      expect(chord.displayFor(TargetPlatform.macOS), '⌘K');
      expect(chord.displayFor(TargetPlatform.linux), 'Ctrl+K');
      expect(chord.displayFor(TargetPlatform.windows), 'Ctrl+K');
    });

    test('renders multi-modifier chord with stable modifier order', () {
      const chord = KeyChord(
        logicalKey: LogicalKeyboardKey.keyC,
        modifiers: {KeymapModifier.shift, KeymapModifier.control},
      );
      // Order is Ctrl, Alt, Shift, Meta, Primary regardless of insertion.
      expect(chord.displayFor(TargetPlatform.linux), 'Ctrl+Shift+C');
      expect(chord.displayFor(TargetPlatform.macOS), '⌃⇧C');
    });

    test('pretty-prints navigation keys', () {
      expect(
        const KeyChord(
          logicalKey: LogicalKeyboardKey.arrowDown,
        ).displayFor(TargetPlatform.linux),
        '↓',
      );
      expect(
        const KeyChord(
          logicalKey: LogicalKeyboardKey.escape,
        ).displayFor(TargetPlatform.linux),
        'Esc',
      );
      expect(
        const KeyChord(
          logicalKey: LogicalKeyboardKey.enter,
        ).displayFor(TargetPlatform.linux),
        'Enter',
      );
    });

    test('character chord renders the character literal', () {
      expect(
        const KeyChord(character: '?').displayFor(TargetPlatform.linux),
        '?',
      );
      expect(
        const KeyChord(character: '?').displayFor(TargetPlatform.macOS),
        '?',
      );
    });

    test('equality treats modifier set order as unordered', () {
      const a = KeyChord(
        logicalKey: LogicalKeyboardKey.keyC,
        modifiers: {KeymapModifier.control, KeymapModifier.shift},
      );
      const b = KeyChord(
        logicalKey: LogicalKeyboardKey.keyC,
        modifiers: {KeymapModifier.shift, KeymapModifier.control},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('Keymap.forScope', () {
    test('returns global entries when scope is global', () {
      final result = Keymap.forScope(KeymapScope.global);
      expect(result.length, Keymap.entries.length);
    });

    test('returns scoped + global entries when scope is not global', () {
      final result = Keymap.forScope(KeymapScope.palette);
      expect(
        result.every(
          (e) =>
              e.scope == KeymapScope.palette || e.scope == KeymapScope.global,
        ),
        isTrue,
      );
      // Sanity: palette scope must include both the palette.open
      // global binding AND palette-only ones.
      final ids = result.map((e) => e.id).toSet();
      expect(ids, contains('palette.open'));
      expect(ids, contains('palette.invoke'));
    });

    test('terminal scope excludes palette-scoped entries', () {
      final result = Keymap.forScope(KeymapScope.terminal);
      final ids = result.map((e) => e.id).toSet();
      expect(ids, isNot(contains('palette.invoke')));
      expect(ids, contains('terminal.copy'));
    });
  });

  group('Keymap.grouped', () {
    test('groups entries by group label preserving insertion order', () {
      final grouped = Keymap.grouped(Keymap.forScope(KeymapScope.palette));
      expect(grouped.keys, contains('Palette'));
      expect(grouped.keys, contains('Navigation'));
      expect(grouped['Palette']!.every((e) => e.group == 'Palette'), isTrue);
    });
  });

  group('Keymap.conflicts', () {
    test('production registry has zero conflicts', () {
      // If this fails, two shipped bindings collide and the cheatsheet
      // would mislead the user about what fires.
      expect(
        Keymap.conflicts(),
        isEmpty,
        reason: Keymap.conflicts().join('\n'),
      );
    });

    test('detects same-scope conflict', () {
      const a = KeymapEntry(
        id: 'a.open',
        scope: KeymapScope.dashboard,
        chord: KeyChord(logicalKey: LogicalKeyboardKey.keyD),
        label: 'A',
        group: 'X',
      );
      const b = KeymapEntry(
        id: 'b.open',
        scope: KeymapScope.dashboard,
        chord: KeyChord(logicalKey: LogicalKeyboardKey.keyD),
        label: 'B',
        group: 'X',
      );
      final conflicts = Keymap.conflicts(source: const [a, b]);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.first.id, 'a.open');
      expect(conflicts.single.second.id, 'b.open');
    });

    test('detects scoped-vs-global conflict', () {
      const g = KeymapEntry(
        id: 'global.help',
        scope: KeymapScope.global,
        chord: KeyChord(character: '?'),
        label: 'help',
        group: 'X',
      );
      const t = KeymapEntry(
        id: 'terminal.help',
        scope: KeymapScope.terminal,
        chord: KeyChord(character: '?'),
        label: 'help',
        group: 'X',
      );
      final conflicts = Keymap.conflicts(source: const [g, t]);
      expect(conflicts, hasLength(1));
    });

    test(
      'ignores scoped chords that only collide across non-overlapping scopes',
      () {
        const t = KeymapEntry(
          id: 'terminal.x',
          scope: KeymapScope.terminal,
          chord: KeyChord(logicalKey: LogicalKeyboardKey.keyX),
          label: 'x',
          group: 'X',
        );
        const s = KeymapEntry(
          id: 'sftp.x',
          scope: KeymapScope.sftp,
          chord: KeyChord(logicalKey: LogicalKeyboardKey.keyX),
          label: 'x',
          group: 'X',
        );
        // Terminal and SFTP are never both active at the same time, so
        // re-using the same chord across them is fine.
        expect(Keymap.conflicts(source: const [t, s]), isEmpty);
      },
    );
  });
}
