import 'dart:async';
import 'dart:math';

class VaultSecret {
  final String id;
  VaultSecret(this.id);
}

class VaultAccessLog {
  Future<DateTime?> lastAccessed(String id) async {
    // Simulate some async work, e.g. db query
    await Future.delayed(Duration(milliseconds: 1));
    return DateTime.now();
  }
}

void main() async {
  final accessLog = VaultAccessLog();
  final secrets = List.generate(100, (i) => VaultSecret(i.toString()));

  // Sequential
  final sw1 = Stopwatch()..start();
  final times1 = <String, DateTime?>{};
  for (final s in secrets) {
    times1[s.id] = await accessLog.lastAccessed(s.id);
  }
  sw1.stop();
  print('Sequential: ${sw1.elapsedMilliseconds} ms');

  // Concurrent
  final sw2 = Stopwatch()..start();
  final times2 = <String, DateTime?>{};
  final results = await Future.wait(
    secrets.map((s) => accessLog.lastAccessed(s.id))
  );
  for (var i = 0; i < secrets.length; i++) {
    times2[secrets[i].id] = results[i];
  }
  sw2.stop();
  print('Concurrent: ${sw2.elapsedMilliseconds} ms');
}
