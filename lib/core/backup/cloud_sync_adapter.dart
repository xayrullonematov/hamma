import 'dart:typed_data';
import 'dart:convert';

/// One object listed in a cloud destination — typically the encrypted
/// blob itself or a manifest entry.
class CloudObject {
  const CloudObject({
    required this.key,
    required this.size,
    required this.lastModified,
  });

  /// Path within the destination, *including* any prefix the adapter
  /// uses (e.g. `hamma/snapshot-2026-05-02T12-00-00Z-deadbeef.aes`).
  final String key;
  final int size;
  final DateTime lastModified;
}

/// One entry in the cross-device sync manifest. The manifest is a
/// small JSON document listing every blob each device has uploaded
/// so other devices can pick the newest snapshot to restore.
///
/// The manifest is *not* encrypted by the cloud-sync layer because it
/// only contains opaque metadata (timestamps, device ids, blob hashes).
/// It cannot be used to decrypt or even partially read the encrypted
/// vault — that still requires the user's master PIN, which never
/// leaves the device.
class CloudSyncManifestEntry {
  const CloudSyncManifestEntry({
    required this.key,
    required this.deviceId,
    required this.timestamp,
    required this.blobHash,
    required this.sizeBytes,
  });

  final String key;
  final String deviceId;
  final DateTime timestamp;

  /// SHA-256 of the *ciphertext* blob, hex-encoded. Used by other
  /// devices to detect identical snapshots and de-dupe.
  final String blobHash;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
        'key': key,
        'deviceId': deviceId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'blobHash': blobHash,
        'sizeBytes': sizeBytes,
      };

  factory CloudSyncManifestEntry.fromJson(Map<String, dynamic> json) {
    return CloudSyncManifestEntry(
      key: json['key'] as String,
      deviceId: json['deviceId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
      blobHash: json['blobHash'] as String,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
    );
  }
}

class CloudSyncManifest {
  const CloudSyncManifest({required this.entries});

  final List<CloudSyncManifestEntry> entries;

  /// Latest entry across all devices, or `null` for an empty manifest.
  CloudSyncManifestEntry? get latest {
    if (entries.isEmpty) return null;
    final sorted = [...entries]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return sorted.first;
  }

  Uint8List encode() {
    final json = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    return Uint8List.fromList(utf8.encode(json));
  }

  static CloudSyncManifest decode(Uint8List bytes) {
    if (bytes.isEmpty) return const CloudSyncManifest(entries: []);
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        return const CloudSyncManifest(entries: []);
      }
      final raw = decoded['entries'];
      if (raw is! List) return const CloudSyncManifest(entries: []);
      return CloudSyncManifest(
        entries: raw
            .whereType<Map<String, dynamic>>()
            .map(CloudSyncManifestEntry.fromJson)
            .toList(),
      );
    } catch (_) {
      return const CloudSyncManifest(entries: []);
    }
  }
}

/// Thin transport interface every cloud destination must implement.
/// Adapters MUST only ever upload bytes that were produced by
/// [BackupCrypto.encrypt] — the [CloudSyncEngine] is the sole caller
/// in production and enforces that contract by construction.
abstract class CloudSyncAdapter {
  /// Human-readable destination label (for status pills / errors).
  String get destinationLabel;

  /// `true` when the adapter has enough configuration (credentials,
  /// bucket, etc.) to attempt I/O. `false` should disable Sync Now.
  bool get isConfigured;

  /// List objects under the configured prefix / app folder. Used to
  /// hydrate the conflict-resolution manifest.
  Future<List<CloudObject>> list();

  /// Upload [bytes] to [key]. Bytes MUST be encrypted ciphertext.
  Future<void> put(String key, Uint8List bytes);

  /// Download [key] as raw bytes (still ciphertext).
  Future<Uint8List> get(String key);

  /// Delete [key]. Used when moving older snapshots into `conflicts/`.
  Future<void> delete(String key);

  /// Server-side rename (or download + reupload + delete on
  /// destinations that lack native rename — e.g. S3). Default falls
  /// back to that copy-then-delete shape so adapters only need to
  /// implement the cheap path when they support it natively.
  Future<void> rename(String fromKey, String toKey) async {
    final body = await get(fromKey);
    await put(toKey, body);
    await delete(fromKey);
  }
}

class CloudSyncException implements Exception {
  const CloudSyncException(this.message);
  final String message;
  @override
  String toString() => 'CloudSyncException: $message';
}
