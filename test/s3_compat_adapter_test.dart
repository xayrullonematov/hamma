import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/backup/s3_compat_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('S3CompatAdapter — SigV4 signing', () {
    test('signed Authorization header has the AWS4-HMAC-SHA256 shape', () {
      final adapter = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        clock: () => DateTime.utc(2026, 5, 2, 12, 30, 0),
      );

      final headers = adapter.debugSignHeaders(
        method: 'PUT',
        uri: Uri.parse('https://vault.s3.example.com/hamma/snapshot.aes'),
        body: Uint8List.fromList([1, 2, 3, 4, 5]),
        contentType: 'application/octet-stream',
        at: DateTime.utc(2026, 5, 2, 12, 30, 0),
      );

      expect(headers['x-amz-date'], '20260502T123000Z');
      expect(headers['x-amz-content-sha256'], isNotEmpty);
      final auth = headers['Authorization']!;
      expect(auth, startsWith('AWS4-HMAC-SHA256 Credential='));
      expect(
        auth,
        contains('AKIAIOSFODNN7EXAMPLE/20260502/us-east-1/s3/aws4_request'),
      );
      expect(auth, contains('SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date'));
      expect(auth, contains('Signature='));
      // Signature is 64 hex chars.
      final sigMatch = RegExp(r'Signature=([0-9a-f]{64})').firstMatch(auth);
      expect(sigMatch, isNotNull,
          reason: 'Signature must be a lowercase 64-char hex string.');
    });

    test('two requests at the same time produce identical signatures', () {
      DateTime clock() => DateTime.utc(2026, 5, 2, 12, 0, 0);
      final a = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        clock: clock,
      );
      final h1 = a.debugSignHeaders(
        method: 'GET',
        uri: Uri.parse('https://vault.s3.example.com/hamma/manifest.json'),
        body: const [],
      );
      final h2 = a.debugSignHeaders(
        method: 'GET',
        uri: Uri.parse('https://vault.s3.example.com/hamma/manifest.json'),
        body: const [],
      );
      expect(h1['Authorization'], h2['Authorization']);
    });
  });

  group('S3CompatAdapter — request shape via mocked client', () {
    test('PUT writes body to {bucket}.{host}/{key} with octet-stream', () async {
      late http.Request captured;
      final mock = MockClient.streaming((req, bodyStream) async {
        captured = req as http.Request;
        return http.StreamedResponse(
          Stream.value(const []),
          200,
        );
      });
      final adapter = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        httpClient: mock,
      );

      await adapter.put(
        'hamma/snapshot.aes',
        Uint8List.fromList(utf8.encode('CIPHERTEXT')),
      );

      expect(captured.method, 'PUT');
      expect(captured.url.host, 'vault.s3.example.com');
      expect(captured.url.path, '/hamma/snapshot.aes');
      expect(captured.headers['content-type'], 'application/octet-stream');
      expect(captured.headers['Authorization'], startsWith('AWS4-HMAC-SHA256'));
      expect(utf8.decode(captured.bodyBytes), 'CIPHERTEXT');
    });

    test('list parses ListObjectsV2 XML', () async {
      const xml = '''<?xml version="1.0"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Contents>
    <Key>hamma/snapshot-2026-05-02T12-00-00Z-aaa.aes</Key>
    <LastModified>2026-05-02T12:00:00.000Z</LastModified>
    <Size>1234</Size>
  </Contents>
  <Contents>
    <Key>hamma/manifest.json</Key>
    <LastModified>2026-05-02T12:00:01.000Z</LastModified>
    <Size>200</Size>
  </Contents>
</ListBucketResult>''';
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(xml)),
          200,
        );
      });
      final adapter = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        httpClient: mock,
      );
      final objects = await adapter.list();
      expect(objects, hasLength(2));
      expect(objects.first.key,
          'hamma/snapshot-2026-05-02T12-00-00Z-aaa.aes');
      expect(objects.first.size, 1234);
      expect(objects[1].key, 'hamma/manifest.json');
    });

    test('GET surfaces non-200 as CloudSyncException', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('forbidden')),
          403,
        );
      });
      final adapter = S3CompatAdapter(
        endpoint: 'https://s3.example.com',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        httpClient: mock,
      );
      expect(
        () => adapter.get('hamma/snapshot.aes'),
        throwsA(isA<CloudSyncException>()),
      );
    });

    test('path-style endpoint puts bucket in the path', () async {
      late http.Request captured;
      final mock = MockClient.streaming((req, bodyStream) async {
        captured = req as http.Request;
        return http.StreamedResponse(Stream.value(const []), 200);
      });
      final adapter = S3CompatAdapter(
        endpoint: 'http://127.0.0.1:9000',
        region: 'us-east-1',
        bucket: 'vault',
        accessKeyId: 'k',
        secretAccessKey: 's',
        usePathStyle: true,
        httpClient: mock,
      );
      await adapter.put(
        'hamma/snapshot.aes',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(captured.url.host, '127.0.0.1');
      expect(captured.url.port, 9000);
      expect(captured.url.path, '/vault/hamma/snapshot.aes');
    });
  });
}
