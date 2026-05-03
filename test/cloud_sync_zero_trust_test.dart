import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/backup_crypto.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/backup/cloud_sync_engine.dart';
import 'package:hamma/core/backup/dropbox_adapter.dart';
import 'package:hamma/core/backup/s3_compat_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Plaintext we will inject into the cloud sync path. If the engine or
/// any adapter ever leaks plaintext, this string will appear verbatim
/// inside the request body bytes — the assertions below would catch it.
const String _plaintextSecret = 'PLAINTEXT-SECRET-DO-NOT-LEAK-7f3c91';

/// Wraps an http.Client and records every request body so the test
/// can prove that nothing resembling [_plaintextSecret] left the device.
class _RecordingClient extends MockClient {
  _RecordingClient(this.captured)
      : super.streaming((req, body) async {
          final bytes = await body.fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
          captured.add((
            method: req.method,
            url: req.url,
            body: Uint8List.fromList(bytes),
          ));
          // Synthesise a minimal "ok" response per endpoint so the
          // engine progresses to the next call.
          final path = req.url.path;
          if (path.endsWith('/2/files/list_folder')) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{"entries":[]}')),
              200,
            );
          }
          if (path.endsWith('/2/files/upload')) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('{"name":"x"}')),
              200,
            );
          }
          if (path.endsWith('/2/files/download')) {
            return http.StreamedResponse(
              Stream.value(const []),
              409,
            );
          }
          // S3 list / get / put — return 200 with empty bodies. The 200
          // empty body for GET on the manifest will decode to an empty
          // manifest, which is exactly what we want.
          return http.StreamedResponse(Stream.value(const []), 200);
        });

  final List<({String method, Uri url, Uint8List body})> captured;
}

void main() {
  group('Cloud sync — zero-trust ciphertext-only guarantee', () {
    test('S3 adapter only ever PUTs HMBK ciphertext (never plaintext)',
        () async {
      final captured = <({String method, Uri url, Uint8List body})>[];
      final s3 = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        prefix: 'hamma/',
        httpClient: _RecordingClient(captured),
      );
      final engine = CloudSyncEngine(
        adapter: s3,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        encrypter: (p) => BackupCrypto.encrypt('pw', p),
      );

      await engine.sync(
        Uint8List.fromList(utf8.encode(_plaintextSecret)),
      );

      expect(captured, isNotEmpty,
          reason: 'Engine should have made at least one HTTP call.');

      for (final c in captured.where((c) => c.method == 'PUT')) {
        // Snapshot uploads must be HMBK ciphertext; manifest PUTs are
        // public metadata (JSON listing of keys + hashes — never user
        // plaintext) so we whitelist them by key suffix.
        if (c.url.path.endsWith('/manifest.json')) {
          // Manifest is plain JSON listing opaque keys, not secrets.
          // Verify it does NOT contain the user's plaintext.
          expect(
            String.fromCharCodes(c.body).contains(_plaintextSecret),
            isFalse,
            reason: 'Manifest must not embed user plaintext.',
          );
          continue;
        }
        // Snapshot blob — must start with HMBK magic + version 0x02.
        expect(c.body.length >= 5, isTrue,
            reason: 'PUT body must be a non-trivial encrypted blob.');
        expect(c.body.sublist(0, 5), [0x48, 0x4D, 0x42, 0x4B, 0x02],
            reason:
                'Every snapshot PUT must start with the HMBK ciphertext header.');
        expect(
          String.fromCharCodes(c.body).contains(_plaintextSecret),
          isFalse,
          reason:
              'Plaintext must never appear in any S3 request body — found leak in $c.',
        );
      }
    });

    test('Dropbox adapter only ever uploads HMBK ciphertext', () async {
      final captured = <({String method, Uri url, Uint8List body})>[];
      final dbx = DropboxAdapter(
        accessToken: 'sl.token',
        appFolder: '/Apps/Hamma',
        httpClient: _RecordingClient(captured),
      );
      final engine = CloudSyncEngine(
        adapter: dbx,
        deviceId: 'dev-2',
        prefix: '',
        encrypter: (p) => BackupCrypto.encrypt('pw', p),
      );

      await engine.sync(
        Uint8List.fromList(utf8.encode(_plaintextSecret)),
      );

      final uploads = captured
          .where((c) => c.url.path.endsWith('/2/files/upload'))
          .toList();
      expect(uploads, isNotEmpty);

      for (final u in uploads) {
        // Pull the Dropbox-API-Arg path so we can tell snapshot from
        // manifest uploads.
        final isManifest = u.body.length < 5
            ? false
            : !(u.body[0] == 0x48 &&
                u.body[1] == 0x4D &&
                u.body[2] == 0x42 &&
                u.body[3] == 0x4B);
        if (!isManifest) {
          expect(u.body.sublist(0, 5), [0x48, 0x4D, 0x42, 0x4B, 0x02]);
        }
        expect(
          String.fromCharCodes(u.body).contains(_plaintextSecret),
          isFalse,
          reason: 'Plaintext must never appear in any Dropbox upload body.',
        );
      }
    });

    test('Engine refuses to upload when encrypter is the identity '
        '(would leak plaintext)', () async {
      final captured = <({String method, Uri url, Uint8List body})>[];
      final s3 = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        httpClient: _RecordingClient(captured),
      );
      final engine = CloudSyncEngine(
        adapter: s3,
        deviceId: 'dev-1',
        prefix: 'hamma/',
        // Bug-injection: identity "encrypter" — would leak plaintext.
        encrypter: (p) => p,
      );

      await expectLater(
        engine.sync(Uint8List.fromList(utf8.encode(_plaintextSecret))),
        throwsA(isA<CloudSyncException>()),
      );
      // Most importantly: no PUT must have escaped to S3 carrying the
      // plaintext snapshot.
      final putBodies = captured.where((c) => c.method == 'PUT');
      for (final p in putBodies) {
        expect(
          String.fromCharCodes(p.body).contains(_plaintextSecret),
          isFalse,
          reason: 'No request body should ever contain plaintext.',
        );
      }
    });
  });
}
