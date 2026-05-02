import 'dart:async';
import 'dart:io';

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
///   2. The download is written to a `.partial` file and only renamed
///      to its final name on success — a crash mid-download leaves a
///      `.partial` for the next run to resume / discard, never a
///      truncated GGUF that the engine would happily try to load.
///   3. Cancelling the returned [Stream] subscription closes the
///      underlying connection and removes the partial file, so a user
///      who cancels twice doesn't end up with stale gigabytes on disk.
class BundledModelDownloader {
  BundledModelDownloader({
    HttpClient Function()? httpClientFactory,
    Duration connectionTimeout = const Duration(seconds: 30),
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _connectionTimeout = connectionTimeout;

  final HttpClient Function() _httpClientFactory;
  final Duration _connectionTimeout;

  /// Returns the on-disk path the model lives at after a successful
  /// download. The directory is created if it doesn't exist.
  static String resolvePath(BundledModel model, String destinationDir) {
    return '$destinationDir${Platform.pathSeparator}${model.filename}';
  }

  /// True if a fully-downloaded copy of [model] already exists on disk
  /// in [destinationDir]. Best-effort — only checks file size against
  /// the catalog estimate (±5%) to catch obvious truncations.
  static bool isCached(BundledModel model, String destinationDir) {
    final f = File(resolvePath(model, destinationDir));
    if (!f.existsSync()) return false;
    final size = f.lengthSync();
    if (size <= 0) return false;
    final lower = (model.sizeBytes * 0.95).floor();
    return size >= lower;
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
      throw BundledModelDownloadException(
        'invalid catalog entry: $validation',
      );
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
      final finalUrl = resp.redirects.isNotEmpty
          ? resp.redirects.last.location
          : uri;
      if (finalUrl.scheme != 'https') {
        throw const BundledModelDownloadException(
          'redirect leaves https; aborting',
        );
      }

      final total = resp.contentLength > 0
          ? resp.contentLength
          : model.sizeBytes;
      var done = 0;
      sink = partial.openWrite();
      await for (final chunk in resp) {
        sink.add(chunk);
        done += chunk.length;
        yield BundledModelDownloadProgress(
          completedBytes: done,
          totalBytes: total,
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
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
      } catch (_) {/* already closed */}
      // If we didn't successfully rename, drop the partial so the next
      // run starts clean.
      if (File(partialPath).existsSync()) {
        try {
          File(partialPath).deleteSync();
        } catch (_) {/* best-effort */}
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
