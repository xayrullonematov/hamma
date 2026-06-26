import 'package:flutter/material.dart';

import '../fuzzy_match.dart';
import '../palette_source.dart';

/// A recently opened SFTP file, supplied by the host app.
class SftpRecentFile {
  const SftpRecentFile({
    required this.serverId,
    required this.serverName,
    required this.path,
  });

  static const separator = '\u001F';

  final String serverId;
  final String serverName;
  final String path;

  String get id => frecencyId(serverId: serverId, path: path);

  String get name {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx < 0 || idx == normalized.length - 1) return normalized;
    return normalized.substring(idx + 1);
  }

  static String frecencyId({required String serverId, required String path}) {
    return '$serverId$separator$path';
  }

  static SftpRecentFile? fromFrecencyId(
    String raw, {
    required String Function(String serverId) serverNameFor,
  }) {
    final separatorIndex = raw.indexOf(separator);
    if (separatorIndex > 0) {
      final serverId = raw.substring(0, separatorIndex);
      final path = raw.substring(separatorIndex + separator.length);
      if (path.isEmpty) return null;
      return SftpRecentFile(
        serverId: serverId,
        serverName: serverNameFor(serverId),
        path: path,
      );
    }

    // Lenient parsing for early development records that used ':' as
    // the separator. Linux paths can contain ':', so Phase 2 should use
    // [frecencyId] exclusively when adding write call sites.
    final legacyIndex = raw.indexOf(':');
    if (legacyIndex <= 0) return null;
    final serverId = raw.substring(0, legacyIndex);
    final path = raw.substring(legacyIndex + 1);
    if (path.isEmpty) return null;
    return SftpRecentFile(
      serverId: serverId,
      serverName: serverNameFor(serverId),
      path: path,
    );
  }
}

/// Palette source for recently opened SFTP files.
class SftpFilesSource extends PaletteSource {
  const SftpFilesSource({required this.loader, required this.onSelect});

  final Future<List<SftpRecentFile>> Function() loader;
  final Future<void> Function(SftpRecentFile file, BuildContext context)
  onSelect;

  @override
  String get id => 'sftp_files';

  @override
  String get displayName => 'Files';

  @override
  Future<List<PaletteResult>> query(String input) async {
    final files = await loader();
    final results = <PaletteResult>[];
    for (final file in files) {
      final score = fuzzyBestScore(input, [
        file.name,
        file.path,
        file.serverName,
      ]);
      if (score <= 0) continue;
      results.add(
        PaletteResult(
          id: file.id,
          sourceId: id,
          label: file.name,
          subtitle: '${file.serverName} · ${file.path}',
          icon: Icons.insert_drive_file_outlined,
          matchScore: score,
          onInvoke: (context) => onSelect(file, context),
        ),
      );
    }
    return results;
  }
}
