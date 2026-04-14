import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/server_profile.dart';

class SavedServersStorage {
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  const SavedServersStorage({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ??
            const FlutterSecureStorage(aOptions: _androidOptions);

  static const _savedServersStorageKey = 'saved_servers';

  final FlutterSecureStorage _secureStorage;

  Future<List<ServerProfile>> loadServers() async {
    try {
      final rawValue = await _secureStorage.read(key: _savedServersStorageKey);
      if (rawValue == null || rawValue.trim().isEmpty) {
        return const [];
      }

      final decoded = jsonDecode(rawValue);
      if (decoded is! List) {
        throw const SavedServersStorageException(
          'Saved server data is invalid.',
        );
      }

      final servers = <ServerProfile>[];
      final seenIds = <String>{};
      var shouldNormalize = false;

      for (final item in decoded) {
        if (item is! Map) {
          throw const SavedServersStorageException(
            'Saved server data is invalid.',
          );
        }

        var server = ServerProfile.fromJson(Map<String, dynamic>.from(item));
        if (!seenIds.add(server.id)) {
          server = server.copyWith(id: _generateServerId());
          shouldNormalize = true;
          seenIds.add(server.id);
        }

        servers.add(server);
      }

      if (shouldNormalize) {
        await saveServers(servers);
      }

      return servers;
    } catch (error) {
      if (error is SavedServersStorageException) {
        rethrow;
      }

      throw SavedServersStorageException(
        'Could not load saved servers: $error',
      );
    }
  }

  Future<void> saveServers(List<ServerProfile> servers) async {
    try {
      final encoded = jsonEncode(
        servers.map((server) => server.toJson()).toList(),
      );

      await _secureStorage.write(
        key: _savedServersStorageKey,
        value: encoded,
      );
    } catch (error) {
      throw SavedServersStorageException(
        'Could not save saved servers: $error',
      );
    }
  }

  Future<void> clearServers() async {
    try {
      await _secureStorage.delete(key: _savedServersStorageKey);
    } catch (error) {
      throw SavedServersStorageException(
        'Could not clear saved servers: $error',
      );
    }
  }

  String _generateServerId() {
    final random = Random.secure().nextInt(1 << 32);
    return '${DateTime.now().microsecondsSinceEpoch}-$random';
  }
}

class SavedServersStorageException implements Exception {
  const SavedServersStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}
