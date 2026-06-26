import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'bundled_model_catalog.dart';

/// Progress event emitted while a GGUF model is being fetched.
class BundledModelDownloadProgress {
  const BundledModelDownloadProgress({
    required this.completedBytes,
    required this.totalBytes,
    this.done = false,
  });

  final int completedBytes;
  final int totalBytes;
  final bool done;

  /// 0.0 .. 1.0 when total is known, `null` when the server didn't send
  /// a `Content-Length` (rare for HuggingFace).
  double? get fraction {
    if (totalBytes <= 0) return null;
    final f = completedBytes / totalBytes;
    if (f.isNaN || f.isInfinite) return null;
    return f.clamp(0.0, 1.0);
  }
}

/// Streams a catalog [BundledModel] from its public download URL into
/// [destinationDir] and yields progress events as bytes arrive.
///
/// Three correctness invariants:
///
///   1. The URL **must** be `https://`. Plain HTTP is rejected before
///      any socket is opened.
///   2. The downloaded bytes must match the catalog's exact size and
///      SHA-256 digest before the final file is exposed to the engine.
///   3. The download is written to a `.partial` file and only renamed
///      to its final name on success — a crash mid-download leaves a
///      `.partial` for the next run to resume / discard, never a
///      truncated GGUF that the engine would happily try to load.
///   4. Cancelling the returned [Stream] subscription closes the
///      underlying connection and removes the partial file, so a user
///      who cancels twice doesn't end up with stale gigabytes on disk.
class BundledModelDownloader {
  BundledModelDownloader({
    HttpClient Function()? httpClientFactory,
    Duration connectionTimeout = const Duration(seconds: 30),
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _connectionTimeout = connectionTimeout;

  final HttpClient Function() _httpClientFactory;
  final Duration _connectionTimeout;

  /// Returns the on-disk path the model lives at after a successful
  /// download. The directory is created if it doesn't exist.
  static String resolvePath(BundledModel model, String destinationDir) {
    return '$destinationDir${Platform.pathSeparator}${model.filename}';
  }

  /// True if a candidate cached file exists and has the exact expected
  /// byte length. Use [isCachedVerified] before loading a model into the
  /// engine; this quick check exists for UI states that must stay cheap.
  static bool isCached(BundledModel model, String destinationDir) {
    final f = File(resolvePath(model, destinationDir));
    if (!f.existsSync()) return false;
    return f.lengthSync() == model.sizeBytes;
  }

  /// True only when the cached file has both the expected byte length
  /// and the expected SHA-256 digest.
  static Future<bool> isCachedVerified(
    BundledModel model,
    String destinationDir,
  ) async {
    final f = File(resolvePath(model, destinationDir));
    if (!f.existsSync()) return false;
    if (await f.length() != model.sizeBytes) return false;
    final actual = await sha256ForFile(f);
    return actual == model.sha256;
  }

  /// Removes a cached final or partial model file. Used when an old cache
  /// predates integrity checking or fails verification.
  static Future<void> deleteCached(
    BundledModel model,
    String destinationDir,
  ) async {
    final finalFile = File(resolvePath(model, destinationDir));
    final partialFile = File('${resolvePath(model, destinationDir)}.partial');
    for (final file in [finalFile, partialFile]) {
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          /* best-effort cache cleanup */
        }
      }
    }
  }

  static Future<String> sha256ForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Stream the file. The stream completes after one final
  /// `done: true` event. Throws [BundledModelDownloadException] on
  /// failure (HTTP error, redirect to non-https, IO error).
  Stream<BundledModelDownloadProgress> download({
    required BundledModel model,
    required String destinationDir,
  }) async* {
    final validation = model.validate();
    if (validation != null) {
      throw BundledModelDownloadException('invalid catalog entry: $validation');
    }
    final uri = Uri.parse(model.downloadUrl);
    if (uri.scheme != 'https') {
      throw const BundledModelDownloadException(
        'refusing to download model over plain HTTP',
      );
    }

    Directory(destinationDir).createSync(recursive: true);
    final finalPath = resolvePath(model, destinationDir);
    final partialPath = '$finalPath.partial';
    final partial = File(partialPath);
    if (partial.existsSync()) {
      // Stale from a previous failed run — start fresh. Resume support
      // is a future enhancement; correctness first.
      partial.deleteSync();
    }

    final client = _httpClientFactory();
    client.connectionTimeout = _connectionTimeout;

    HttpClientResponse? resp;
    IOSink? sink;
    try {
      final req = await client.getUrl(uri).timeout(_connectionTimeout);
      resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw BundledModelDownloadException(
          'HTTP ${resp.statusCode} from ${uri.host}',
        );
      }
      // Sanity-check the redirect target if present.
      final finalUrl =
          resp.redirects.isNotEmpty ? resp.redirects.last.location : uri;
      if (finalUrl.scheme != 'https') {
        throw const BundledModelDownloadException(
          'redirect leaves https; aborting',
        );
      }

      final total =
          resp.contentLength > 0 ? resp.contentLength : model.sizeBytes;
      var done = 0;
      final digestCapture = _DigestCaptureSink();
      final digestSink = sha256.startChunkedConversion(digestCapture);
      sink = partial.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        digestSink.add(chunk);
        done += chunk.length;
        yield BundledModelDownloadProgress(
          completedBytes: done,
          totalBytes: total,
        );
      }
      digestSink.close();
      await sink.flush();
      await sink.close();
      sink = null;
      if (done != model.sizeBytes) {
        throw BundledModelDownloadException(
          'size mismatch for ${model.id}: expected ${model.sizeBytes} bytes, got $done',
        );
      }
      final actualSha256 = digestCapture.value?.toString();
      if (actualSha256 != model.sha256) {
        throw BundledModelDownloadException(
          'checksum mismatch for ${model.id}: expected ${model.sha256}, got ${actualSha256 ?? 'unknown'}',
        );
      }
      // Atomic rename: on POSIX this is a single syscall; on Windows
      // the dart:io implementation falls back to a copy+delete which
      // is still safe — either we have the full file or we don't.
      partial.renameSync(finalPath);
      yield BundledModelDownloadProgress(
        completedBytes: done,
        totalBytes: total,
        done: true,
      );
    } on SocketException catch (e) {
      throw BundledModelDownloadException('network: ${e.message}');
    } on TimeoutException {
      throw const BundledModelDownloadException('connection timed out');
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        /* already closed */
      }
      // If we didn't successfully rename, drop the partial so the next
      // run starts clean.
      if (File(partialPath).existsSync()) {
        try {
          File(partialPath).deleteSync();
        } catch (_) {
          /* best-effort */
        }
      }
      client.close(force: true);
    }
  }
}

class BundledModelDownloadException implements Exception {
  const BundledModelDownloadException(this.message);
  final String message;
  @override
  String toString() => 'BundledModelDownloadException: $message';
}

class _DigestCaptureSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
