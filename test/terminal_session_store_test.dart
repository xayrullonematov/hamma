import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/terminal/session_store.dart';
import 'package:hamma/core/terminal/terminal_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('trimTerminalScrollback keeps the newest tail', () {
    expect(trimTerminalScrollback('abcdef', 4), 'cdef');
    expect(trimTerminalScrollback('abcdef', 0), '');
    expect(trimTerminalScrollback('abc', 10), 'abc');
  });

  test('TerminalSession.append updates scrollback and timestamp', () {
    const session = TerminalSession(
      serverId: 'srv-1',
      sessionId: 'term-1',
      serverName: 'prod',
      scrollback: 'abc',
      createdAtMs: 1,
      updatedAtMs: 1,
    );

    final next = session.append('def', nowMs: 2, maxChars: 4);

    expect(next.scrollback, 'cdef');
    expect(next.createdAtMs, 1);
    expect(next.updatedAtMs, 2);
  });

  test('save and loadLatest round-trip the newest terminal session', () async {
    final store = TerminalSessionStore(nowMs: () => 1000);
    final session = store.create(serverId: 'srv-1', serverName: 'prod');
    await store.save(
      session.copyWith(scrollback: 'hello\n', updatedAtMs: 1001),
    );

    final loaded = await store.loadLatest(serverId: 'srv-1');

    expect(loaded, isNotNull);
    expect(loaded!.serverId, 'srv-1');
    expect(loaded.sessionId, session.sessionId);
    expect(loaded.scrollback, 'hello\n');
  });

  test('save trims scrollback before persisting', () async {
    const store = TerminalSessionStore(maxScrollbackChars: 5);
    const session = TerminalSession(
      serverId: 'srv-1',
      sessionId: 'term-1',
      serverName: 'prod',
      scrollback: '0123456789',
      createdAtMs: 1,
      updatedAtMs: 2,
    );

    await store.save(session);
    final loaded = await store.loadSession(
      serverId: 'srv-1',
      sessionId: 'term-1',
    );

    expect(loaded?.scrollback, '56789');
  });

  test('loadLatest chooses the most recently updated session', () async {
    const store = TerminalSessionStore();
    await store.save(
      const TerminalSession(
        serverId: 'srv-1',
        sessionId: 'old',
        serverName: 'prod',
        scrollback: 'old',
        createdAtMs: 1,
        updatedAtMs: 10,
      ),
    );
    await store.save(
      const TerminalSession(
        serverId: 'srv-1',
        sessionId: 'new',
        serverName: 'prod',
        scrollback: 'new',
        createdAtMs: 2,
        updatedAtMs: 20,
      ),
    );

    final loaded = await store.loadLatest(serverId: 'srv-1');

    expect(loaded?.sessionId, 'new');
  });

  test('save evicts old sessions beyond maxSessionsPerServer', () async {
    const store = TerminalSessionStore(maxSessionsPerServer: 1);
    await store.save(
      const TerminalSession(
        serverId: 'srv-1',
        sessionId: 'old',
        serverName: 'prod',
        scrollback: 'old',
        createdAtMs: 1,
        updatedAtMs: 10,
      ),
    );
    await store.save(
      const TerminalSession(
        serverId: 'srv-1',
        sessionId: 'new',
        serverName: 'prod',
        scrollback: 'new',
        createdAtMs: 2,
        updatedAtMs: 20,
      ),
    );

    final sessions = await store.listSessions(serverId: 'srv-1');
    final old = await store.loadSession(serverId: 'srv-1', sessionId: 'old');

    expect(sessions.map((s) => s.sessionId), ['new']);
    expect(old, isNull);
  });
}
