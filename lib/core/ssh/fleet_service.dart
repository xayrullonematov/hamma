import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_profile.dart';
import '../storage/trusted_host_key_storage.dart';
import 'ssh_service.dart'
    show
        SshHostKeyMismatchException,
        SshUnknownHostKeyException,
        SshUnknownHostKeyRejectedException;

class FleetService {
  const FleetService({
    TrustedHostKeyStorage? trustedHostKeyStorage,
    Duration connectTimeout = const Duration(seconds: 5),
    Duration commandTimeout = const Duration(seconds: 8),
  }) : _trustedHostKeyStorage =
           trustedHostKeyStorage ?? const TrustedHostKeyStorage(),
       _connectTimeout = connectTimeout,
       _commandTimeout = commandTimeout;

  static const _metricsCommand = '''
export LC_ALL=C
printf '__HAMMA_CPU_BEGIN__\n'
grep 'cpu ' /proc/stat
sleep 1
grep 'cpu ' /proc/stat
printf '__HAMMA_RAM_BEGIN__\n'
free -m
printf '__HAMMA_DISK_BEGIN__\n'
df -P /
''';

  final TrustedHostKeyStorage _trustedHostKeyStorage;
  final Duration _connectTimeout;
  final Duration _commandTimeout;

  Future<Map<String, ServerMetrics>> pollFleet(
    List<ServerProfile> servers,
  ) async {
    final entries = await Future.wait(
      servers.map((server) async {
        final metrics = await pollServer(server);
        return MapEntry(server.id, metrics);
      }),
      eagerError: false,
    );

    return Map<String, ServerMetrics>.fromEntries(entries);
  }

  Future<ServerMetrics> pollServer(ServerProfile server) async {
    if (!server.isValid) {
      return ServerMetrics.failed('Saved profile is incomplete.');
    }

    SSHClient? client;

    try {
      final trustedHostKey = await _trustedHostKeyStorage.loadTrustedHostKey(
        host: server.host,
        port: server.port,
      );
      final identities = _resolveIdentities(
        privateKey: server.privateKey,
        privateKeyPassword: server.privateKeyPassword,
      );

      final socket = await SSHSocket.connect(
        server.host,
        server.port,
      ).timeout(_connectTimeout);

      client = SSHClient(
        socket,
        username: server.username,
        identities: identities,
        onPasswordRequest: () => server.password,
        onVerifyHostKey: (algorithm, fingerprintBytes) async {
          final fingerprint = _formatFingerprint(fingerprintBytes);

          if (trustedHostKey == null) {
            throw SshUnknownHostKeyException(
              host: server.host,
              port: server.port,
              algorithm: algorithm,
              fingerprint: fingerprint,
            );
          }

          final isTrustedFingerprint =
              trustedHostKey.fingerprint == fingerprint &&
              trustedHostKey.algorithm == algorithm;
          if (isTrustedFingerprint) {
            return true;
          }

          throw SshHostKeyMismatchException(
            host: server.host,
            port: server.port,
            expectedAlgorithm: trustedHostKey.algorithm,
            expectedFingerprint: trustedHostKey.fingerprint,
            actualAlgorithm: algorithm,
            actualFingerprint: fingerprint,
          );
        },
      );

      await client.authenticated.timeout(_connectTimeout);

      final output = utf8.decode(
        await client.run(_metricsCommand).timeout(_commandTimeout),
        allowMalformed: true,
      );

      return _parseMetrics(output);
    } on TimeoutException {
      return ServerMetrics.failed('Timed out while polling the server.');
    } on SshUnknownHostKeyException catch (error) {
      return ServerMetrics.failed(error.toString());
    } on SshUnknownHostKeyRejectedException catch (error) {
      return ServerMetrics.failed(error.toString());
    } on SshHostKeyMismatchException catch (error) {
      return ServerMetrics.failed(error.toString());
    } catch (error) {
      return ServerMetrics.failed(_friendlyErrorMessage(error));
    } finally {
      client?.close();
    }
  }

  List<SSHKeyPair>? _resolveIdentities({
    required String? privateKey,
    required String? privateKeyPassword,
  }) {
    final resolvedPrivateKey = privateKey?.trim();
    if (resolvedPrivateKey == null || resolvedPrivateKey.isEmpty) {
      return null;
    }

    return SSHKeyPair.fromPem(resolvedPrivateKey, privateKeyPassword);
  }

  ServerMetrics _parseMetrics(String output) {
    final normalizedOutput = output
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final cpuSection = _extractSection(
      normalizedOutput,
      startMarker: '__HAMMA_CPU_BEGIN__',
      endMarker: '__HAMMA_RAM_BEGIN__',
    );
    final ramSection = _extractSection(
      normalizedOutput,
      startMarker: '__HAMMA_RAM_BEGIN__',
      endMarker: '__HAMMA_DISK_BEGIN__',
    );
    final diskSection = _extractSection(
      normalizedOutput,
      startMarker: '__HAMMA_DISK_BEGIN__',
    );

    final cpuPercentage = _parseCpuPercentage(cpuSection);
    final ramPercentage = _parseRamPercentage(ramSection);
    final diskPercentage = _parseDiskPercentage(diskSection);

    if (cpuPercentage == null ||
        ramPercentage == null ||
        diskPercentage == null) {
      return ServerMetrics.failed('Could not parse server metrics.');
    }

    return ServerMetrics(
      cpuPercentage: cpuPercentage,
      ramPercentage: ramPercentage,
      diskPercentage: diskPercentage,
      collectedAt: DateTime.now(),
    );
  }

  List<String> _extractSection(
    String output, {
    required String startMarker,
    String? endMarker,
  }) {
    final lines = output.split('\n');
    final startIndex = lines.indexOf(startMarker);
    if (startIndex == -1) {
      return const [];
    }

    final endIndex =
        endMarker == null
            ? lines.length
            : lines.indexOf(endMarker, startIndex + 1);
    final boundedEndIndex = endIndex == -1 ? lines.length : endIndex;

    return lines
        .sublist(startIndex + 1, boundedEndIndex)
        .map((line) => line.trimRight())
        .where((line) => line.trim().isNotEmpty)
        .toList();
  }

  double? _parseCpuPercentage(List<String> lines) {
    final cpuLines =
        lines
            .where((line) => line.trimLeft().startsWith('cpu '))
            .take(2)
            .toList();
    if (cpuLines.length < 2) {
      return null;
    }

    final firstSnapshot = _parseCpuSnapshot(cpuLines.first);
    final secondSnapshot = _parseCpuSnapshot(cpuLines.last);
    if (firstSnapshot == null || secondSnapshot == null) {
      return null;
    }

    final totalDiff = secondSnapshot.total - firstSnapshot.total;
    final idleDiff = secondSnapshot.idle - firstSnapshot.idle;
    if (totalDiff <= 0) {
      return null;
    }

    final usage = ((totalDiff - idleDiff) / totalDiff) * 100;
    return usage.clamp(0, 100).toDouble();
  }

  _CpuSnapshot? _parseCpuSnapshot(String line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 5 || fields.first != 'cpu') {
      return null;
    }

    final values = fields.skip(1).map(int.tryParse).whereType<int>().toList();
    if (values.length < 4) {
      return null;
    }

    final total = values.fold<int>(0, (sum, value) => sum + value);
    final idle = values[3] + (values.length > 4 ? values[4] : 0);
    return _CpuSnapshot(total: total, idle: idle);
  }

  double? _parseRamPercentage(List<String> lines) {
    final memLine = lines.cast<String?>().firstWhere(
      (line) => line?.trimLeft().startsWith('Mem:') ?? false,
      orElse: () => null,
    );
    if (memLine == null) {
      return null;
    }

    final fields = memLine.trim().split(RegExp(r'\s+'));
    if (fields.length < 3) {
      return null;
    }

    final total = double.tryParse(fields[1]);
    final used = double.tryParse(fields[2]);
    if (total == null || used == null || total <= 0) {
      return null;
    }

    return ((used / total) * 100).clamp(0, 100).toDouble();
  }

  double? _parseDiskPercentage(List<String> lines) {
    final filesystemLine = lines.reversed.cast<String?>().firstWhere(
      (line) => line != null && !line.startsWith('Filesystem'),
      orElse: () => null,
    );
    if (filesystemLine == null) {
      return null;
    }

    final match = RegExp(r'(\d+)%').firstMatch(filesystemLine);
    final percentage =
        match == null ? null : double.tryParse(match.group(1) ?? '');
    if (percentage == null) {
      return null;
    }

    return percentage.clamp(0, 100).toDouble();
  }

  String _formatFingerprint(Uint8List bytes) {
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  String _friendlyErrorMessage(Object error) {
    final message = error.toString().trim();
    if (message.isEmpty) {
      return 'Failed to poll the server.';
    }

    final normalizedMessage = message.toLowerCase();
    if (normalizedMessage.contains('socketexception')) {
      return 'Could not reach the server.';
    }
    if (normalizedMessage.contains('connection refused')) {
      return 'Connection refused.';
    }
    if (normalizedMessage.contains('timed out')) {
      return 'Timed out while polling the server.';
    }

    return message;
  }
}

class ServerMetrics {
  const ServerMetrics({
    required this.cpuPercentage,
    required this.ramPercentage,
    required this.diskPercentage,
    required this.collectedAt,
    this.errorMessage,
  });

  final double? cpuPercentage;
  final double? ramPercentage;
  final double? diskPercentage;
  final DateTime collectedAt;
  final String? errorMessage;

  bool get isAvailable {
    return cpuPercentage != null &&
        ramPercentage != null &&
        diskPercentage != null &&
        errorMessage == null;
  }

  factory ServerMetrics.failed(String message) {
    return ServerMetrics(
      cpuPercentage: null,
      ramPercentage: null,
      diskPercentage: null,
      collectedAt: DateTime.now(),
      errorMessage: message,
    );
  }
}

class _CpuSnapshot {
  const _CpuSnapshot({required this.total, required this.idle});

  final int total;
  final int idle;
}
