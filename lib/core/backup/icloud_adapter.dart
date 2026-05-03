import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cloud_sync_adapter.dart';

/// iCloud (Drive) ubiquity-container adapter — only available on
/// iOS/macOS. Wraps a `MethodChannel` that the platform code
/// implements with `NSFileManager` + `NSUbiquitousKeyValueStore`.
///
/// On Android / Linux / Windows this throws `UnsupportedError` from
/// every method except [destinationLabel] / [isConfigured]. The
/// onboarding wizard hides the iCloud option on non-Apple platforms,
/// so users should never hit those throws in normal usage.
class ICloudAdapter implements CloudSyncAdapter {
  ICloudAdapter({
    required this.containerId,
    this.folder = 'hamma',
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? isAppleOverride,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _isAppleOverride = isAppleOverride;

  /// Apple ubiquity container identifier (e.g. `iCloud.com.hamma.app`).
  final String containerId;

  /// Subfolder inside the ubiquity container that stores Hamma blobs.
  final String folder;

  final MethodChannel _channel;
  final bool? _isAppleOverride;

  static const channelName = 'com.hamma/icloud';

  bool get _isApple =>
      _isAppleOverride ?? (Platform.isIOS || Platform.isMacOS);

  @override
  String get destinationLabel => 'iCloud Drive';

  @override
  bool get isConfigured => _isApple && containerId.isNotEmpty;

  void _ensureSupported() {
    if (!_isApple) {
      throw const CloudSyncException(
        'iCloud is only available on iOS and macOS.',
      );
    }
  }

  @override
  Future<List<CloudObject>> list() async {
    _ensureSupported();
    final raw = await _channel.invokeMethod<List<dynamic>>('list', {
      'container': containerId,
      'folder': folder,
    });
    if (raw == null) return const [];
    return raw.whereType<Map<dynamic, dynamic>>().map((e) {
      final m = e.cast<String, dynamic>();
      return CloudObject(
        key: m['key'] as String? ?? '',
        size: (m['size'] as num?)?.toInt() ?? 0,
        lastModified: DateTime.fromMillisecondsSinceEpoch(
          (m['lastModifiedMs'] as num?)?.toInt() ?? 0,
        ),
      );
    }).toList();
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('put', {
      'container': containerId,
      'folder': folder,
      'key': key,
      'bytes': bytes,
    });
  }

  @override
  Future<Uint8List> get(String key) async {
    _ensureSupported();
    final res = await _channel.invokeMethod<Uint8List>('get', {
      'container': containerId,
      'folder': folder,
      'key': key,
    });
    if (res == null) {
      throw CloudNotFoundException('iCloud object not found: $key');
    }
    return res;
  }

  @override
  Future<void> delete(String key) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('delete', {
      'container': containerId,
      'folder': folder,
      'key': key,
    });
  }

  @override
  Future<void> rename(String fromKey, String toKey) async {
    _ensureSupported();
    await _channel.invokeMethod<void>('rename', {
      'container': containerId,
      'folder': folder,
      'from': fromKey,
      'to': toKey,
    });
  }
}
