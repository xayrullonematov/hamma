import 'package:flutter/foundation.dart';
import '../ssh/connection_status.dart';

abstract class ShellService {
  bool get isConnected;
  ConnectionStatus get currentStatus;
  ValueListenable<ConnectionStatus> get statusNotifier;
  Stream<ConnectionStatus> get status;
  List<int> get activeForwardedPorts;
  Future<String> execute(String command, {Iterable<dynamic> vaultSecrets});
  Future<dynamic> streamCommand(String command);
  Future<dynamic> startShell({int width, int height});
  Future<void> disconnect({bool updateStatus, bool cancelAuto});
  Future<void> startLocalForwarding({required int localPort, required String remoteHost, required int remotePort});
  Future<void> stopLocalForwarding(int localPort);
  bool isHealthy();
}
