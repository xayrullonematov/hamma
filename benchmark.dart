import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hamma/core/terminal/session_store.dart';
import 'package:hamma/core/terminal/terminal_session.dart';

void main() async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = TerminalSessionStore(maxSessionsPerServer: 1);

  // Setup 100 sessions
  print('Setting up 100 sessions...');
  for (int i = 0; i < 100; i++) {
    await store.save(
      TerminalSession(
        serverId: 'srv-1',
        sessionId: 'old-$i',
        serverName: 'prod',
        scrollback: 'old',
        createdAtMs: 1,
        updatedAtMs: 10 + i,
      ),
    );
  }

  // Now, saving one more will trigger eviction of 100 sessions
  final stopwatch = Stopwatch()..start();
  await store.save(
    TerminalSession(
      serverId: 'srv-1',
      sessionId: 'new',
      serverName: 'prod',
      scrollback: 'new',
      createdAtMs: 2,
      updatedAtMs: 200,
    ),
  );
  stopwatch.stop();

  print('Eviction took: ${stopwatch.elapsedMicroseconds} microseconds');
}
