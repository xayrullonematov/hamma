import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ollama_client.dart';

enum OllamaModelInstallPhase { downloading, registering, done }

class OllamaModelInstallProgress {
  const OllamaModelInstallProgress({
    required this.phase,
    required this.message,
    this.completedBytes = 0,
    this.totalBytes = 0,
    this.modelPath,
  });

  final OllamaModelInstallPhase phase;
  final String message;
  final int completedBytes;
  final int totalBytes;
  final String? modelPath;

  double? get fraction {
    if (totalBytes <= 0) return null;
    final value = completedBytes / totalBytes;
    if (value.isNaN || value.isInfinite) return null;
    return value.clamp(0.0, 1.0);
  }

  bool get isDone => phase == OllamaModelInstallPhase.done;
}

class OllamaModelInstaller {
  OllamaModelInstaller({
    required OllamaClient client,
    HttpClient Function()? httpClientFactory,
    Duration connectionTimeout = const Duration(seconds: 30),
  }) : _client = client,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _connectionTimeout = connectionTimeout;

  final OllamaClient _client;
  final HttpClient Function() _httpClientFactory;
  final Duration _connectionTimeout;

  Future<String> modelsDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'ollama_models'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Stream<OllamaModelInstallProgress> installModel({
    required String modelName,
    required String downloadUrl,
    int numCtx = 4096,
  }) {
    final normalizedModelName = modelName.trim();
    final normalizedUrl = downloadUrl.trim();
    if (normalizedModelName.isEmpty) {
      throw ArgumentError.value(modelName, 'modelName', 'must not be empty');
    }

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || uri.scheme != 'https') {
      throw ArgumentError.value(
        downloadUrl,
        'downloadUrl',
        'must be a valid https:// URL',
      );
    }

    final sourceFileName = _sourceFilename(uri);
    if (sourceFileName == null) {
      throw ArgumentError.value(
        downloadUrl,
        'downloadUrl',
        'must point directly to a .gguf file',
      );
    }

    final controller = StreamController<OllamaModelInstallProgress>();
    HttpClient? httpClient;
    IOSink? sink;
    File? partialFile;
    var cancelled = false;

    Future<void> cleanupPartial() async {
      final file = partialFile;
      if (file == null) return;
      if (!await file.exists()) return;
      try {
        await file.delete();
      } catch (_) {
        // Best-effort cleanup only.
      }
    }

    Future<void> run() async {
      try {
        final baseDir = await modelsDirectory();
        final modelDir = Directory(
          p.join(baseDir, _safePathSegment(normalizedModelName)),
        );
        if (!await modelDir.exists()) {
          await modelDir.create(recursive: true);
        }

        final finalPath = p.join(modelDir.path, sourceFileName);
        final finalFile = File(finalPath);
        partialFile = File('$finalPath.partial');

        if (!await finalFile.exists()) {
          httpClient = _httpClientFactory();
          httpClient!.connectionTimeout = _connectionTimeout;

          final request = await httpClient!
              .getUrl(uri)
              .timeout(_connectionTimeout);
          final response = await request.close().timeout(
            const Duration(minutes: 2),
          );
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw OllamaModelInstallException(
              'GGUF download failed: HTTP ${response.statusCode}',
            );
          }

          final totalBytes =
              response.contentLength > 0 ? response.contentLength : 0;
          var completedBytes = 0;
          sink = partialFile!.openWrite();

          await for (final chunk in response) {
            if (cancelled) {
              throw const OllamaModelInstallException('Download cancelled.');
            }
            sink!.add(chunk);
            completedBytes += chunk.length;
            controller.add(
              OllamaModelInstallProgress(
                phase: OllamaModelInstallPhase.downloading,
                message: 'Downloading GGUF',
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                modelPath: partialFile!.path,
              ),
            );
          }

          await sink!.flush();
          await sink!.close();
          sink = null;
          await partialFile!.rename(finalPath);
          partialFile = null;
        }

        if (cancelled) return;

        controller.add(
          OllamaModelInstallProgress(
            phase: OllamaModelInstallPhase.registering,
            message: 'Registering model with Ollama',
            completedBytes: 1,
            totalBytes: 1,
            modelPath: finalFile.path,
          ),
        );

        final modelfile = 'FROM ${finalFile.path}\nPARAMETER num_ctx $numCtx';
        await _client.createModel(
          model: normalizedModelName,
          modelfile: modelfile,
          stream: false,
        );

        final models = await _client.listModels();
        final exists = models.any(
          (model) =>
              model.name == normalizedModelName ||
              model.name.startsWith('$normalizedModelName:'),
        );
        if (!exists) {
          throw OllamaModelInstallException(
            'Ollama did not report the registered model after /api/create.',
          );
        }

        controller.add(
          OllamaModelInstallProgress(
            phase: OllamaModelInstallPhase.done,
            message: 'Model installed',
            completedBytes: 1,
            totalBytes: 1,
            modelPath: finalFile.path,
          ),
        );
        await controller.close();
      } on SocketException catch (e) {
        if (!cancelled) {
          controller.addError(
            OllamaModelInstallException('Network error: ${e.message}'),
          );
        }
        await cleanupPartial();
        await controller.close();
      } on TimeoutException {
        if (!cancelled) {
          controller.addError(
            const OllamaModelInstallException(
              'Connection timed out while downloading the model.',
            ),
          );
        }
        await cleanupPartial();
        await controller.close();
      } catch (e) {
        if (!cancelled) {
          controller.addError(
            e is OllamaModelInstallException
                ? e
                : OllamaModelInstallException(e.toString()),
          );
        }
        await cleanupPartial();
        await controller.close();
      } finally {
        try {
          await sink?.close();
        } catch (_) {
          // Best-effort cleanup only.
        }
        httpClient?.close(force: true);
      }
    }

    controller.onCancel = () async {
      cancelled = true;
      httpClient?.close(force: true);
      try {
        await sink?.close();
      } catch (_) {
        // Best-effort cleanup only.
      }
      await cleanupPartial();
    };

    unawaited(run());
    return controller.stream;
  }

  static String? _sourceFilename(Uri uri) {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.trim();
    if (name.isEmpty) return null;
    if (!name.toLowerCase().endsWith('.gguf')) return null;
    return name;
  }

  static String _safePathSegment(String raw) {
    return raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  }
}

class OllamaModelInstallException implements Exception {
  const OllamaModelInstallException(this.message);

  final String message;

  @override
  String toString() => 'OllamaModelInstallException: $message';
}
