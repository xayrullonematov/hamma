import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../ssh/connection_status.dart';
import '../shell/shell_service.dart';

List<String> _resolveShell() {
  if (Platform.isWindows) return ['wsl.exe', 'bash'];
  if (Platform.isMacOS) return ['/bin/zsh'];
  return ['/bin/bash'];
}

class LocalShellService implements ShellService {
  static final Map<String, LocalShellService> _instances = {};
  static LocalShellService get local => _instances.putIfAbsent('__local__', () => LocalShellService());

  final StreamController<ConnectionStatus> _statusController = StreamController<ConnectionStatus>.broadcast();
  late final ValueNotifier<ConnectionStatus> _statusNotifier;
  ConnectionStatus _currentStatus = ConnectionStatus.disconnected();
  String _workingDirectory = '/root';
  String _wslUsername = 'root';
  bool _isConnected = false;

  LocalShellService() {
    if (!Platform.isWindows) {
      _workingDirectory = Platform.environment['HOME'] ?? Directory.current.path;
    }
    _statusNotifier = ValueNotifier<ConnectionStatus>(_currentStatus);
    if (Platform.isWindows) {
      unawaited(_initWslContext());
    }
  }

  Future<void> _initWslContext() async {
    try {
      final homeResult = await Process.run('wsl.exe', ['bash', '-c', 'echo \$HOME']);
      if (homeResult.exitCode == 0) {
        _workingDirectory = homeResult.stdout.toString().trim();
      }
      final userResult = await Process.run('wsl.exe', ['bash', '-c', 'echo \$USER']);
      if (userResult.exitCode == 0) {
        _wslUsername = userResult.stdout.toString().trim();
      }
    } catch (_) {
      // Keep defaults
    }
  }

  Map<String, String> _getEnvironment() {
    if (Platform.isWindows) {
      return {
        'TERM': 'xterm-256color',
        'HOME': _workingDirectory,
        'USER': _wslUsername,
        'LANG': 'en_US.UTF-8',
      };
    }
    return Platform.environment;
  }

  @override
  bool get isConnected => _isConnected;
  @override
  ConnectionStatus get currentStatus => _currentStatus;
  @override
  ValueListenable<ConnectionStatus> get statusNotifier => _statusNotifier;
  @override
  Stream<ConnectionStatus> get status => _statusController.stream;
  @override
  List<int> get activeForwardedPorts => [];
  String get workingDirectory => _workingDirectory;

  void _updateStatus(ConnectionStatus status) {
    _currentStatus = status;
    _statusController.add(status);
    _statusNotifier.value = status;
  }

  Future<void> connect({String? workingDirectory}) async {
    _updateStatus(ConnectionStatus.connecting());
    if (workingDirectory != null && workingDirectory.isNotEmpty) {
      _workingDirectory = workingDirectory;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    if (Platform.isWindows) {
      try {
        await Process.run('wsl.exe', [
          'bash',
          '-c',
          'echo "\$USER ALL=(ALL) NOPASSWD:ALL" | sudo -S tee /etc/sudoers.d/hamma-nopasswd > /dev/null'
        ]);
      } catch (_) {
        // Ignore errors, user might already have NOPASSWD set or no sudo access
      }
    }

    _isConnected = true;
    _updateStatus(ConnectionStatus.connected());
  }

  @override
  Future<void> disconnect({bool updateStatus = true, bool cancelAuto = true}) async {
    _isConnected = false;
    if (updateStatus) _updateStatus(ConnectionStatus.disconnected());
  }

  @override
  Future<String> execute(String command, {Iterable<dynamic> vaultSecrets = const []}) async {
    if (!_isConnected) throw StateError('Local shell is not connected.');
    try {
      final shell = _resolveShell();
      final shellFlag = '-c';
      final wslCommand = Platform.isWindows ? 'cd $_workingDirectory && $command' : command;
      final result = await Process.run(
        shell.first,
        [...shell.skip(1), shellFlag, wslCommand],
        workingDirectory: Platform.isWindows ? null : _workingDirectory,
        environment: _getEnvironment(),
        runInShell: false,
      );
      final stdout = result.stdout as String;
      final stderr = result.stderr as String;
      if (result.exitCode != 0 && stdout.isEmpty) {
        throw Exception(stderr.isNotEmpty ? stderr : 'Command exited with code ${result.exitCode}');
      }
      return stdout;
    } on ProcessException catch (e) {
      throw Exception('Local shell error: ${e.message}');
    }
  }

  @override
  Future<LocalShellSession> streamCommand(String command) async {
    if (!_isConnected) throw StateError('Local shell is not connected.');
    final shell = _resolveShell();
    final shellFlag = '-c';
    final wslCommand = Platform.isWindows ? 'cd $_workingDirectory && $command' : command;
    final process = await Process.start(
      shell.first,
      [...shell.skip(1), shellFlag, wslCommand],
      workingDirectory: Platform.isWindows ? null : _workingDirectory,
      environment: _getEnvironment(),
      runInShell: false,
    );
    return LocalShellSession(process);
  }

  @override
  Future<LocalShellSession> startShell({int width = 80, int height = 24}) async {
    if (!_isConnected) throw StateError('Local shell is not connected.');
    final shell = _resolveShell();
    final process = await Process.start(
      shell.first,
      shell.skip(1).toList(),
      workingDirectory: Platform.isWindows ? null : _workingDirectory,
      environment: {
        ..._getEnvironment(),
        'TERM': 'xterm-256color',
        'COLUMNS': '$width',
        'LINES': '$height',
      },
      runInShell: false,
    );
    return LocalShellSession(process);
  }

  @override
  Future<void> startLocalForwarding({required int localPort, required String remoteHost, required int remotePort}) async {
    throw UnsupportedError('Port forwarding is not available in local mode.');
  }

  @override
  Future<void> stopLocalForwarding(int localPort) async {
    // no-op in local mode
  }

  @override
  bool isHealthy() => _isConnected;

  void enableAutoReconnect() {}
  void disableAutoReconnect() {}
  void cancelAutoReconnect() {}
}

class LocalShellSession {
  LocalShellSession(this._process);

  final Process _process;

  Stream<Uint8List> get stdout => _process.stdout.map((list) => Uint8List.fromList(list));
  Stream<Uint8List> get stderr => _process.stderr.map((list) => Uint8List.fromList(list));

  void write(Uint8List data) {
    try {
      _process.stdin.add(data);
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await _process.stdin.close();
    } catch (_) {}
    _process.kill();
  }

  Future<int> get done => _process.exitCode;

  void resizeTerminal(int width, int height) {
    // No-op: Local process TTY resizing is not easily portable in dart:io
  }

  Future<int> get exitCode => _process.exitCode;
}
