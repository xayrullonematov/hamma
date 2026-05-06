import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// A robust downloader for large AI model files (GGUF).
///
/// Features:
/// - Resumable downloads via Range headers.
/// - Progress tracking through a [Stream<double>].
/// - Secure storage in the application's local documents directory.
/// - Atomic completion (partial file renaming).
class ModelDownloader {
  ModelDownloader({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(minutes: 10);
  }

  final Dio _dio;
  final _progressController = StreamController<double>.broadcast();

  /// Stream of download progress percentage (0.0 to 100.0).
  Stream<double> get progressStream => _progressController.stream;

  /// Downloads a model from [url] and saves it as [filename].
  ///
  /// The file is saved to the app's local documents directory.
  /// Returns the [File] object on success.
  Future<File> downloadModel({
    required String url,
    required String filename,
  }) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(p.join(docDir.path, 'models'));
      
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }

      final finalPath = p.join(modelsDir.path, filename);
      final partialPath = '$finalPath.partial';
      final finalFile = File(finalPath);
      final partialFile = File(partialPath);

      // If the final file already exists, we are done.
      if (await finalFile.exists()) {
        _progressController.add(100.0);
        return finalFile;
      }

      int startByte = 0;
      if (await partialFile.exists()) {
        startByte = await partialFile.length();
      }

      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: startByte > 0 ? {'Range': 'bytes=$startByte-'} : null,
        ),
      );

      final totalBytesHeader = response.headers.value('content-length');
      final int? totalBytes = totalBytesHeader != null 
          ? int.tryParse(totalBytesHeader) 
          : null;

      final actualTotal = (totalBytes ?? 0) + startByte;

      final IOSink sink = partialFile.openWrite(
        mode: startByte > 0 ? FileMode.append : FileMode.write,
      );

      int downloadedBytes = startByte;

      await for (final List<int> chunk in response.data!.stream) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        
        if (actualTotal > 0) {
          final progress = (downloadedBytes / actualTotal) * 100.0;
          _progressController.add(progress.clamp(0.0, 100.0));
        }
      }

      await sink.flush();
      await sink.close();

      // Atomic rename
      final renamedFile = await partialFile.rename(finalPath);
      _progressController.add(100.0);
      
      return renamedFile;
    } catch (e) {
      // Logic for handling download errors. 
      // Partial file is preserved for resumption.
      rethrow;
    }
  }

  void dispose() {
    _progressController.close();
  }
}
