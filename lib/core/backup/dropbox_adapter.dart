import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_sync_adapter.dart';

/// Dropbox v2 content-API adapter. Uses an OAuth 2.0 access token the
/// user pasted in (or that the onboarding wizard's PKCE flow produced).
///
/// All blobs land under [appFolder]; the only auth in flight is the
/// `Authorization: Bearer …` header. Dropbox sees opaque ciphertext.
class DropboxAdapter implements CloudSyncAdapter {
  DropboxAdapter({
    required this.accessToken,
    this.appFolder = '/Apps/Hamma',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String accessToken;

  /// Always starts with `/`. The wizard ships `/Apps/Hamma` by default
  /// (matching Dropbox's app-folder permission scope).
  final String appFolder;
  final http.Client _http;

  static const _apiHost = 'https://api.dropboxapi.com';
  static const _contentHost = 'https://content.dropboxapi.com';

  @override
  String get destinationLabel => 'Dropbox';

  @override
  bool get isConfigured => accessToken.isNotEmpty;

  String _path(String key) {
    final folder = appFolder.endsWith('/')
        ? appFolder.substring(0, appFolder.length - 1)
        : appFolder;
    final k = key.startsWith('/') ? key.substring(1) : key;
    return '$folder/$k';
  }

  @override
  Future<List<CloudObject>> list() async {
    final res = await _http.post(
      Uri.parse('$_apiHost/2/files/list_folder'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'path': appFolder,
        'recursive': false,
      }),
    );
    // Dropbox returns 409 when the folder doesn't exist yet — treat as empty.
    if (res.statusCode == 409) return const [];
    if (res.statusCode != 200) {
      throw CloudSyncException(
        'Dropbox list failed: ${res.statusCode} ${res.body}',
      );
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final entries = (decoded['entries'] as List?) ?? const [];
    return entries.whereType<Map<String, dynamic>>().where((e) {
      return e['.tag'] == 'file';
    }).map((e) {
      return CloudObject(
        key: (e['path_display'] as String? ?? e['name'] as String? ?? '')
            .replaceFirst('${appFolder.endsWith('/') ? appFolder.substring(0, appFolder.length - 1) : appFolder}/', ''),
        size: (e['size'] as num?)?.toInt() ?? 0,
        lastModified: DateTime.tryParse(
              (e['server_modified'] as String?) ?? '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    }).toList();
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    final res = await _http.post(
      Uri.parse('$_contentHost/2/files/upload'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': _path(key),
          'mode': 'overwrite',
          'mute': true,
          'autorename': false,
          'strict_conflict': false,
        }),
      },
      body: bytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'Dropbox upload $key failed: ${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<Uint8List> get(String key) async {
    final res = await _http.post(
      Uri.parse('$_contentHost/2/files/download'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Dropbox-API-Arg': jsonEncode({'path': _path(key)}),
      },
    );
    if (res.statusCode != 200) {
      throw CloudSyncException(
        'Dropbox download $key failed: ${res.statusCode} ${res.body}',
      );
    }
    return Uint8List.fromList(res.bodyBytes);
  }

  @override
  Future<void> delete(String key) async {
    final res = await _http.post(
      Uri.parse('$_apiHost/2/files/delete_v2'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'path': _path(key)}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'Dropbox delete $key failed: ${res.statusCode} ${res.body}',
      );
    }
  }

  @override
  Future<void> rename(String fromKey, String toKey) async {
    final res = await _http.post(
      Uri.parse('$_apiHost/2/files/move_v2'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'from_path': _path(fromKey),
        'to_path': _path(toKey),
        'allow_shared_folder': false,
        'autorename': false,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudSyncException(
        'Dropbox move $fromKey -> $toKey failed: ${res.statusCode}',
      );
    }
  }

  void close() => _http.close();
}
