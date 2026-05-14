import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import '../ssh/connection_status.dart';
import '../ssh/ssh_exception.dart';
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
  String _workingDirectory = '';
  String _wslUser = 'root';
  bool _isConnected = false;

  LocalShellService() {
    _statusNotifier = ValueNotifier<ConnectionStatus>(_currentStatus);
  }

  Map<String, String> _getEnvironment(int width, int height) {
    if (Platform.isWindows) {
      return {
        'HOME': _workingDirectory,
        'USER': _wslUser,
        'TERM': 'xterm-256color',
        'LANG': 'en_US.UTF-8',
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      };
    }
    return {
      ...Platform.environment,
      'TERM': 'xterm-256color',
      'COLUMNS': '$width',
      'LINES': '$height',
    };
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
    _isConnected = false; // Always reset state fully
    _updateStatus(ConnectionStatus.connecting());

    try {
      if (Platform.isWindows) {
        // Verify wsl.exe is reachable
        final check = await Process.run('wsl.exe', ['--status'])
            .catchError((_) => ProcessResult(-1, 1, '', ''));
        if (check.exitCode != 0) {
          throw Exception('WSL not found. Please install WSL to use local shell on Windows.');
        }

        // Resolve WSL home directory and user
        final homeR = await Process.run('wsl.exe', ['bash', '-c', 'echo \$HOME']);
        _workingDirectory = (homeR.stdout as String).trim();
        final userR = await Process.run('wsl.exe', ['bash', '-c', 'echo \$USER']);
        _wslUser = (userR.stdout as String).trim();

        // Passwordless sudo setup
        await Process.run('wsl.exe', [
          'bash', '-c',
          'echo "\$USER ALL=(ALL) NOPASSWD:ALL" | sudo SUDO_ASKPASS=/bin/true sudo -A tee /etc/sudoers.d/hamma-nopasswd >/dev/null 2>&1 || true'
        ], environment: {'USER': _wslUser});
      } else {
        _workingDirectory = workingDirectory ?? Platform.environment['HOME'] ?? Directory.current.path;
      }

      _isConnected = true;
      _updateStatus(ConnectionStatus.connected());
    } catch (e) {
      _isConnected = false;
      _updateStatus(ConnectionStatus.failed(SshUnknownException(userMessage: e.toString())));
      rethrow;
    }
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
      final actualCommand = Platform.isWindows ? 'cd "$_workingDirectory" && $command' : command;
      
      final result = await Process.run(
        shell.first,
        [...shell.skip(1), shellFlag, actualCommand],
        workingDirectory: Platform.isWindows ? null : _workingDirectory,
        environment: Platform.isWindows ? _getEnvironment(80, 24) : Platform.environment,
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
    final actualCommand = Platform.isWindows ? 'cd "$_workingDirectory" && $command' : command;

    final process = await Process.start(
      shell.first,
      [...shell.skip(1), shellFlag, actualCommand],
      workingDirectory: Platform.isWindows ? null : _workingDirectory,
      environment: Platform.isWindows ? _getEnvironment(80, 24) : Platform.environment,
      runInShell: false,
    );
    return LocalShellSession(process);
  }

  @override
  Future<LocalPtySession> startShell({int width = 80, int height = 24}) async {
    if (!_isConnected) throw StateError('Local shell is not connected.');
    final shell = _resolveShell();
    
    final pty = Pty.start(
      shell.first,
      arguments: shell.skip(1).toList(),
      columns: width,
      rows: height,
      environment: _getEnvironment(width, height),
      workingDirectory: Platform.isWindows ? null : _workingDirectory,
    );
    
    return LocalPtySession(pty);
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
    // No-op for direct process
  }

  Future<int> get exitCode => _process.exitCode;
}

class LocalPtySession {
  LocalPtySession(this._pty);

  final Pty _pty;

  Stream<Uint8List> get stdout => _pty.output;
  Stream<Uint8List> get stderr => const Stream.empty();

  void write(Uint8List data) {
    _pty.write(data);
  }

  Future<void> close() async {
    _pty.kill();
  }

  Future<int> get done => _pty.exitCode;

  void resizeTerminal(int width, int height) {
    _pty.resize(height, width); // flutter_pty uses (rows, columns)
  }

  Future<int> get exitCode => _pty.exitCode;
}
