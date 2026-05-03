import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/backup/cloud_sync_adapter.dart';
import 'package:hamma/core/backup/dropbox_adapter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('DropboxAdapter', () {
    test('put POSTs to /2/files/upload with bearer auth + octet-stream',
        () async {
      late http.Request captured;
      final mock = MockClient.streaming((req, bodyStream) async {
        captured = req as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"name":"x"}')),
          200,
        );
      });
      final adapter = DropboxAdapter(
        accessToken: 'sl.token',
        appFolder: '/Apps/Hamma',
        httpClient: mock,
      );

      await adapter.put('snapshot.aes',
          Uint8List.fromList(utf8.encode('CIPHERTEXT')));

      expect(captured.url.toString(),
          'https://content.dropboxapi.com/2/files/upload');
      expect(captured.headers['Authorization'], 'Bearer sl.token');
      expect(captured.headers['Content-Type'], 'application/octet-stream');
      final apiArg = jsonDecode(captured.headers['Dropbox-API-Arg']!);
      expect(apiArg['path'], '/Apps/Hamma/snapshot.aes');
      expect(apiArg['mode'], 'overwrite');
      expect(utf8.decode(captured.bodyBytes), 'CIPHERTEXT');
    });

    test('get downloads from content endpoint', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('CIPHERTEXT')),
          200,
        );
      });
      final adapter = DropboxAdapter(
        accessToken: 'tok',
        httpClient: mock,
      );
      final bytes = await adapter.get('snapshot.aes');
      expect(utf8.decode(bytes), 'CIPHERTEXT');
    });

    test('list treats 409 (folder missing) as empty', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"not_found"}')),
          409,
        );
      });
      final adapter = DropboxAdapter(
        accessToken: 'tok',
        httpClient: mock,
      );
      final objects = await adapter.list();
      expect(objects, isEmpty);
    });

    test('list parses file entries', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'entries': [
              {
                '.tag': 'file',
                'name': 'snapshot.aes',
                'path_display': '/Apps/Hamma/snapshot.aes',
                'size': 4096,
                'server_modified': '2026-05-02T12:00:00Z',
              },
              {
                '.tag': 'folder',
                'name': 'conflicts',
                'path_display': '/Apps/Hamma/conflicts',
              },
            ],
          }))),
          200,
        );
      });
      final adapter = DropboxAdapter(
        accessToken: 'tok',
        appFolder: '/Apps/Hamma',
        httpClient: mock,
      );
      final objects = await adapter.list();
      expect(objects, hasLength(1));
      expect(objects.first.key, 'snapshot.aes');
      expect(objects.first.size, 4096);
    });

    test('upload non-2xx surfaces CloudSyncException', () async {
      final mock = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode('forbidden')),
          401,
        );
      });
      final adapter = DropboxAdapter(
        accessToken: 'tok',
        httpClient: mock,
      );
      expect(
        () => adapter.put('snapshot.aes', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<CloudSyncException>()),
      );
    });

    test('isConfigured requires non-empty token', () {
      expect(DropboxAdapter(accessToken: '').isConfigured, isFalse);
      expect(DropboxAdapter(accessToken: 't').isConfigured, isTrue);
    });
  });
}
