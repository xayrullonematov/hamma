import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// In-app keyboard shortcut scopes. A binding applies in its declared
/// scope plus the global scope (which applies everywhere). The cheatsheet
/// uses this to filter the shortcut list down to "what's actually live
/// on the screen the user is looking at."
enum KeymapScope { global, palette, terminal, sftp, dashboard }

/// Logical modifiers used by [KeyChord]. [primary] is the
/// platform-shifting modifier: Cmd on macOS, Ctrl elsewhere. Keeping
/// it as a distinct token (rather than baking the per-platform choice
/// into the data) means the same registry entry renders correctly on
/// every desktop without forking the table.
enum KeymapModifier { primary, control, meta, shift, alt }

/// A single chord. Either a [logicalKey] (e.g. `LogicalKeyboardKey.keyK`)
/// or a [character] (e.g. `'?'`) is required.
///
/// Character chords exist because some shortcuts (`?` to open the
/// cheatsheet, `/` to focus search) want to match the produced
/// character regardless of keyboard layout — on a German layout the
/// `?` key is `Shift+ß`, not `Shift+/`. [CharacterActivator] in Flutter
/// handles that for us.
@immutable
class KeyChord {
  const KeyChord({
    this.logicalKey,
    this.character,
    this.modifiers = const <KeymapModifier>{},
  }) : assert(
         (logicalKey == null) != (character == null),
         'KeyChord needs exactly one of logicalKey or character',
       );

  final LogicalKeyboardKey? logicalKey;
  final String? character;
  final Set<KeymapModifier> modifiers;

  /// Render the chord for the current platform — `⌘K` on macOS,
  /// `Ctrl+K` elsewhere. Order is fixed (modifiers then key) so the
  /// cheatsheet doesn't display the same chord two different ways.
  String displayFor(TargetPlatform platform) {
    final isMac = platform == TargetPlatform.macOS;
    final parts = <String>[];
    final ordered = _orderedModifiers();
    for (final m in ordered) {
      parts.add(_modLabel(m, isMac));
    }
    parts.add(_keyLabel());
    return isMac ? parts.join() : parts.join('+');
  }

  List<KeymapModifier> _orderedModifiers() {
    const order = [
      KeymapModifier.control,
      KeymapModifier.alt,
      KeymapModifier.shift,
      KeymapModifier.meta,
      KeymapModifier.primary,
    ];
    return order.where(modifiers.contains).toList(growable: false);
  }

  static String _modLabel(KeymapModifier m, bool isMac) {
    switch (m) {
      case KeymapModifier.primary:
        return isMac ? '⌘' : 'Ctrl';
      case KeymapModifier.control:
        return isMac ? '⌃' : 'Ctrl';
      case KeymapModifier.meta:
        return isMac ? '⌘' : 'Win';
      case KeymapModifier.shift:
        return isMac ? '⇧' : 'Shift';
      case KeymapModifier.alt:
        return isMac ? '⌥' : 'Alt';
    }
  }

  String _keyLabel() {
    if (character != null) return character!;
    final key = logicalKey!;
    final label = key.keyLabel;
    if (label.isNotEmpty) {
      // LogicalKeyboardKey.keyK reports "K" — but for chord display we
      // want the bare character without case noise on letters, and the
      // pretty name for navigation keys.
      switch (key) {
        case LogicalKeyboardKey.arrowUp:
          return '↑';
        case LogicalKeyboardKey.arrowDown:
          return '↓';
        case LogicalKeyboardKey.arrowLeft:
          return '←';
        case LogicalKeyboardKey.arrowRight:
          return '→';
        case LogicalKeyboardKey.enter:
          return 'Enter';
        case LogicalKeyboardKey.escape:
          return 'Esc';
        case LogicalKeyboardKey.tab:
          return 'Tab';
        case LogicalKeyboardKey.space:
          return 'Space';
        default:
          return label;
      }
    }
    return key.debugName ?? key.toString();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyChord &&
          other.logicalKey == logicalKey &&
          other.character == character &&
          setEquals(other.modifiers, modifiers);

  @override
  int get hashCode =>
      Object.hash(logicalKey, character, Object.hashAllUnordered(modifiers));
}

/// One row in the central shortcut registry.
@immutable
class KeymapEntry {
  const KeymapEntry({
    required this.id,
    required this.scope,
    required this.chord,
    required this.label,
    required this.group,
  });

  /// Stable id (e.g. `palette.open`). Tests pin behaviour against this
  /// id; conflict reports cite it; future code can look an entry up by
  /// id to bind its actual handler without hard-coding the chord.
  final String id;
  final KeymapScope scope;
  final KeyChord chord;
  final String label;

  /// Display group on the cheatsheet (e.g. "Navigation", "Editing").
  /// Free-form on purpose so the registry can grow without a
  /// closed-set rewrite.
  final String group;
}

/// Single source of truth for in-app keyboard shortcuts.
///
/// As features migrate off ad-hoc bindings (the xterm copy/paste
/// shortcuts in `hamma_terminal_view.dart`, the system-level
/// `hotKeyManager` chord in `global_command_palette.dart`, etc.), they
/// register here. The cheatsheet renders directly off this list, so
/// every binding that lands here becomes discoverable for free.
class Keymap {
  Keymap._();

  static const List<KeymapEntry> entries = <KeymapEntry>[
    // Global
    KeymapEntry(
      id: 'palette.open',
      scope: KeymapScope.global,
      chord: KeyChord(
        logicalKey: LogicalKeyboardKey.keyK,
        modifiers: {KeymapModifier.primary},
      ),
      label: 'Open command palette',
      group: 'Navigation',
    ),
    KeymapEntry(
      id: 'cheatsheet.show',
      scope: KeymapScope.global,
      chord: KeyChord(character: '?'),
      label: 'Show keyboard shortcuts',
      group: 'Help',
    ),
    KeymapEntry(
      id: 'dialog.close',
      scope: KeymapScope.global,
      chord: KeyChord(logicalKey: LogicalKeyboardKey.escape),
      label: 'Close current dialog',
      group: 'Navigation',
    ),

    // Palette — informational for now; the dialog wires these itself
    // in Phase 1. Listing them here makes them discoverable.
    KeymapEntry(
      id: 'palette.next',
      scope: KeymapScope.palette,
      chord: KeyChord(logicalKey: LogicalKeyboardKey.arrowDown),
      label: 'Next result',
      group: 'Palette',
    ),
    KeymapEntry(
      id: 'palette.prev',
      scope: KeymapScope.palette,
      chord: KeyChord(logicalKey: LogicalKeyboardKey.arrowUp),
      label: 'Previous result',
      group: 'Palette',
    ),
    KeymapEntry(
      id: 'palette.invoke',
      scope: KeymapScope.palette,
      chord: KeyChord(logicalKey: LogicalKeyboardKey.enter),
      label: 'Invoke selected result',
      group: 'Palette',
    ),
    KeymapEntry(
      id: 'palette.scope',
      scope: KeymapScope.palette,
      chord: KeyChord(logicalKey: LogicalKeyboardKey.tab),
      label: 'Cycle source scope',
      group: 'Palette',
    ),

    // Terminal — currently bound inside `defaultTerminalShortcuts`
    // in xterm; described here so the cheatsheet surfaces them. Phase
    // 5 (thicken) migrates the actual binding here.
    KeymapEntry(
      id: 'terminal.copy',
      scope: KeymapScope.terminal,
      chord: KeyChord(
        logicalKey: LogicalKeyboardKey.keyC,
        modifiers: {KeymapModifier.control, KeymapModifier.shift},
      ),
      label: 'Copy selection',
      group: 'Editing',
    ),
    KeymapEntry(
      id: 'terminal.paste',
      scope: KeymapScope.terminal,
      chord: KeyChord(
        logicalKey: LogicalKeyboardKey.keyV,
        modifiers: {KeymapModifier.control, KeymapModifier.shift},
      ),
      label: 'Paste from clipboard',
      group: 'Editing',
    ),
  ];

  /// Entries visible while [scope] is active: anything declared in
  /// [scope] plus everything global.
  static List<KeymapEntry> forScope(KeymapScope scope) {
    if (scope == KeymapScope.global) {
      return List<KeymapEntry>.unmodifiable(entries);
    }
    return entries
        .where((e) => e.scope == scope || e.scope == KeymapScope.global)
        .toList(growable: false);
  }

  /// Group [es] by [KeymapEntry.group] preserving insertion order.
  /// The cheatsheet renders each group as its own labelled block.
  static Map<String, List<KeymapEntry>> grouped(List<KeymapEntry> es) {
    final out = <String, List<KeymapEntry>>{};
    for (final e in es) {
      out.putIfAbsent(e.group, () => <KeymapEntry>[]).add(e);
    }
    return out;
  }

  /// Returns conflicts: two entries whose chords collide in a scope
  /// the user might be inside at the same time. Two scoped entries
  /// conflict only when they share a scope; a global entry conflicts
  /// with anything that re-uses its chord, because the global binding
  /// is reachable from every scope.
  static List<KeymapConflict> conflicts({List<KeymapEntry>? source}) {
    final es = source ?? entries;
    final out = <KeymapConflict>[];
    for (var i = 0; i < es.length; i++) {
      for (var j = i + 1; j < es.length; j++) {
        final a = es[i];
        final b = es[j];
        if (a.chord != b.chord) continue;
        final sameScope = a.scope == b.scope;
        final crossesGlobal =
            a.scope == KeymapScope.global || b.scope == KeymapScope.global;
        if (sameScope || crossesGlobal) {
          out.add(KeymapConflict(first: a, second: b));
        }
      }
    }
    return out;
  }
}

@immutable
class KeymapConflict {
  const KeymapConflict({required this.first, required this.second});
  final KeymapEntry first;
  final KeymapEntry second;

  @override
  String toString() =>
      'Keymap conflict: "${first.id}" (${first.scope.name}) and '
      '"${second.id}" (${second.scope.name}) share the same chord.';
}
