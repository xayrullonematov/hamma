import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../storage/backup_storage.dart';
import 'cloud_sync_adapter.dart';

/// Outcome of a single sync attempt — surfaced to the UI status pill.
class CloudSyncResult {
  const CloudSyncResult({
    required this.uploadedKey,
    required this.timestamp,
    required this.blobHash,
    required this.sizeBytes,
    required this.movedToConflicts,
  });

  final String uploadedKey;
  final DateTime timestamp;
  final String blobHash;
  final int sizeBytes;

  /// Keys that the engine moved into the `conflicts/` prefix because
  /// they were older snapshots from this same device.
  final List<String> movedToConflicts;
}

/// Orchestrates the encrypted-cloud-sync write path:
///
///   1. Encrypt the vault snapshot via [encrypter] (the caller already
///      wraps `BackupCrypto.encrypt`).
///   2. Upload the resulting ciphertext blob to the configured
///      [CloudSyncAdapter] under `<prefix>snapshot-<ts>-<deviceId>.aes`.
///   3. Append a manifest entry to `<prefix>manifest.json`.
///   4. Move any older snapshots **from this same device** into
///      `<prefix>conflicts/`. Snapshots from *other* devices are left
///      untouched (they're handled at restore time by picking the
///      highest-timestamp manifest entry).
///
/// The engine is the only production caller of `adapter.put`. It refuses
/// to ship plaintext bytes by construction — `encrypter` is invoked
/// before `adapter.put` and the result is passed verbatim.
class CloudSyncEngine {
  CloudSyncEngine({
    required this.adapter,
    required this.deviceId,
    required this.prefix,
    required this.encrypter,
    required this.decrypter,
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final CloudSyncAdapter adapter;
  final String deviceId;
  final String prefix;

  /// Wraps `BackupCrypto.encrypt(password, plaintext)`. Injecting the
  /// closure rather than the password keeps the engine ignorant of the
  /// PIN and makes testing trivial.
  final Uint8List Function(Uint8List plaintext) encrypter;

  /// Wraps `BackupCrypto.decrypt(password, ciphertext)`. Used to read
  /// the encrypted manifest. The manifest itself is wrapped in HMBK
  /// ciphertext so the cloud provider never sees device IDs, snapshot
  /// timestamps, or blob hashes in the clear.
  final Uint8List Function(Uint8List ciphertext) decrypter;

  final DateTime Function() _clock;
  final Random _random;

  String get _manifestKey => '${prefix}manifest.json';
  String get _conflictsPrefix => '${prefix}conflicts/';

  /// Performs one sync cycle: encrypt → upload → update manifest →
  /// resolve conflicts. Returns the new manifest entry.
  Future<CloudSyncResult> sync(Uint8List plaintextSnapshot) async {
    if (!adapter.isConfigured) {
      throw const CloudSyncException(
        'Cloud destination is not fully configured.',
      );
    }
    final ciphertext = encrypter(plaintextSnapshot);
    if (!_isHmbk(ciphertext)) {
      // Defence in depth: the BackupCrypto v2 format starts with the
      // ASCII magic "HMBK" followed by version=0x02. If the supplied
      // encrypter returned something that doesn't look like ciphertext,
      // refuse to upload — better to surface a loud failure than to
      // silently leak plaintext into a third-party bucket.
      throw const CloudSyncException(
        'Refusing to upload: payload is not a valid encrypted backup blob '
        '(missing HMBK header). This would have leaked plaintext.',
      );
    }

    final now = _clock().toUtc();
    final key = _newSnapshotKey(now);
    final blobHash = sha256Hex(ciphertext);

    await adapter.put(key, ciphertext);

    // Read existing manifest (if any) and append our entry.
    final existing = await _readManifest();
    final ourPriorEntries = existing.entries
        .where((e) => e.deviceId == deviceId)
        .toList();
    final updated = CloudSyncManifest(
      entries: [
        ...existing.entries.where((e) => e.deviceId != deviceId),
        CloudSyncManifestEntry(
          key: key,
          deviceId: deviceId,
          timestamp: now,
          blobHash: blobHash,
          sizeBytes: ciphertext.length,
        ),
      ],
    );
    await _writeManifest(updated);

    // Move our previous snapshots to the conflicts/ prefix so we keep
    // exactly one current snapshot per device. Best-effort — we don't
    // want a missing object to fail the whole sync.
    final moved = <String>[];
    for (final stale in ourPriorEntries) {
      try {
        final to =
            '$_conflictsPrefix${stale.key.split('/').last}';
        await adapter.rename(stale.key, to);
        moved.add(stale.key);
      } on CloudSyncException {
        // ignore
      }
    }

    return CloudSyncResult(
      uploadedKey: key,
      timestamp: now,
      blobHash: blobHash,
      sizeBytes: ciphertext.length,
      movedToConflicts: moved,
    );
  }

  /// Reads the manifest from the cloud and returns it. Returns an
  /// empty manifest when the file doesn't exist yet (first device).
  Future<CloudSyncManifest> readManifest() => _readManifest();

  /// Pulls the newest ciphertext blob across all devices. Used by the
  /// restore-on-new-device path. Caller decrypts with `BackupCrypto`.
  Future<({CloudSyncManifestEntry entry, Uint8List ciphertext})>
      fetchLatestSnapshot() async {
    final manifest = await _readManifest();
    final latest = manifest.latest;
    if (latest == null) {
      throw const CloudSyncException(
        'No cloud snapshots are available for this account yet.',
      );
    }
    final bytes = await adapter.get(latest.key);
    if (!_isHmbk(bytes)) {
      throw const CloudSyncException(
        'Cloud snapshot is corrupt or was not produced by Hamma '
        '(missing HMBK header).',
      );
    }
    return (entry: latest, ciphertext: bytes);
  }

  // ---------------------------------------------------------------------------

  Future<CloudSyncManifest> _readManifest() async {
    try {
      final bytes = await adapter.get(_manifestKey);
      if (!_isHmbk(bytes)) {
        // Either the bucket is empty or someone wrote a plaintext
        // manifest. Either way: do not trust it, return empty.
        return const CloudSyncManifest(entries: []);
      }
      final plaintext = decrypter(bytes);
      return CloudSyncManifest.decode(plaintext);
    } on CloudSyncException {
      return const CloudSyncManifest(entries: []);
    } catch (_) {
      // Decrypt failure (wrong password, tampered) — surface as empty
      // rather than crashing the sync. The HMBK guard above ensures
      // we never accidentally treat plaintext as a manifest.
      return const CloudSyncManifest(entries: []);
    }
  }

  Future<void> _writeManifest(CloudSyncManifest m) async {
    final encryptedManifest = encrypter(m.encode());
    if (!_isHmbk(encryptedManifest)) {
      throw const CloudSyncException(
        'Refusing to upload manifest: encrypter did not produce a '
        'valid HMBK ciphertext blob. This would have leaked device '
        'IDs, snapshot keys, and blob hashes in plaintext.',
      );
    }
    await adapter.put(_manifestKey, encryptedManifest);
  }

  String _newSnapshotKey(DateTime now) {
    final ts = '${now.year.toString().padLeft(4, '0')}'
        '-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}'
        'T${now.hour.toString().padLeft(2, '0')}'
        '-${now.minute.toString().padLeft(2, '0')}'
        '-${now.second.toString().padLeft(2, '0')}Z';
    final nonce = List<int>.generate(4, (_) => _random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${prefix}snapshot-$ts-$deviceId-$nonce.aes';
  }

  /// Strict guard: matches the BackupCrypto v2 format header
  /// (ASCII "HMBK" + version byte 0x02). Any future format bump
  /// MUST update this constant in lockstep.
  static bool _isHmbk(List<int> bytes) {
    return bytes.length >= 5 &&
        bytes[0] == 0x48 &&
        bytes[1] == 0x4D &&
        bytes[2] == 0x42 &&
        bytes[3] == 0x4B &&
        bytes[4] == 0x02;
  }

  static String sha256Hex(List<int> bytes) {
    final digest = sha256.convert(bytes).bytes;
    final buf = StringBuffer();
    for (final b in digest) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}

/// Generates a stable, non-PII device id when one is not yet stored.
/// Uses 16 bytes of cryptographically-random data → 32-char hex.
String generateDeviceId([Random? random]) {
  final r = random ?? Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Cadence interval for [CloudSyncCadence]. `manual` returns null —
/// no timer should fire.
Duration? cadenceInterval(CloudSyncCadence cadence) {
  switch (cadence) {
    case CloudSyncCadence.manual:
      return null;
    case CloudSyncCadence.hourly:
      return const Duration(hours: 1);
    case CloudSyncCadence.daily:
      return const Duration(hours: 24);
  }
}
