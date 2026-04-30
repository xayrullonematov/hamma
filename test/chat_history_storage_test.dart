import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/chat_history_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatHistoryStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const ChatHistoryStorage();
  });

  group('listSessions', () {
    test('returns empty list when no sessions exist', () async {
      final sessions = await storage.listSessions(serverId: 'srv-1');
      expect(sessions, isEmpty);
    });

    test('returns sessions saved for a server', () async {
      final sessions = [
        {'id': 'sess-1', 'title': 'First'},
        {'id': 'sess-2', 'title': 'Second'},
      ];
      await storage.saveSessions(serverId: 'srv-1', sessions: sessions);

      final result = await storage.listSessions(serverId: 'srv-1');
      expect(result, hasLength(2));
      expect(result[0]['id'], 'sess-1');
      expect(result[1]['title'], 'Second');
    });

    test('sessions are isolated per server', () async {
      await storage.saveSessions(serverId: 'srv-A', sessions: [
        {'id': 'sess-A', 'title': 'Server A session'},
      ]);
      final result = await storage.listSessions(serverId: 'srv-B');
      expect(result, isEmpty);
    });
  });

  group('saveSessions', () {
    test('overwrites previous sessions', () async {
      await storage.saveSessions(serverId: 'srv-1', sessions: [
        {'id': 'sess-old', 'title': 'Old'},
      ]);
      await storage.saveSessions(serverId: 'srv-1', sessions: [
        {'id': 'sess-new', 'title': 'New'},
      ]);

      final result = await storage.listSessions(serverId: 'srv-1');
      expect(result, hasLength(1));
      expect(result.first['id'], 'sess-new');
    });

    test('can save an empty sessions list', () async {
      await storage.saveSessions(serverId: 'srv-1', sessions: [
        {'id': 'sess-1', 'title': 'First'},
      ]);
      await storage.saveSessions(serverId: 'srv-1', sessions: []);

      final result = await storage.listSessions(serverId: 'srv-1');
      expect(result, isEmpty);
    });
  });

  group('loadMessages', () {
    test('returns empty list when no messages exist', () async {
      final msgs = await storage.loadMessages(serverId: 'srv-1', sessionId: 'sess-1');
      expect(msgs, isEmpty);
    });

    test('returns saved messages', () async {
      final messages = [
        {'role': 'user', 'content': 'Hello'},
        {'role': 'assistant', 'content': 'Hi there'},
      ];
      await storage.saveMessages(
        serverId: 'srv-1',
        sessionId: 'sess-1',
        messages: messages,
      );

      final result = await storage.loadMessages(serverId: 'srv-1', sessionId: 'sess-1');
      expect(result, hasLength(2));
      expect(result[0]['role'], 'user');
      expect(result[1]['content'], 'Hi there');
    });

    test('messages are isolated per session', () async {
      await storage.saveMessages(
        serverId: 'srv-1',
        sessionId: 'sess-A',
        messages: [
          {'role': 'user', 'content': 'Session A message'},
        ],
      );
      final result = await storage.loadMessages(serverId: 'srv-1', sessionId: 'sess-B');
      expect(result, isEmpty);
    });
  });

  group('saveMessages', () {
    test('overwrites previous messages', () async {
      await storage.saveMessages(
        serverId: 'srv-1',
        sessionId: 'sess-1',
        messages: [
          {'role': 'user', 'content': 'Old message'},
        ],
      );
      await storage.saveMessages(
        serverId: 'srv-1',
        sessionId: 'sess-1',
        messages: [
          {'role': 'user', 'content': 'New message'},
        ],
      );

      final result = await storage.loadMessages(serverId: 'srv-1', sessionId: 'sess-1');
      expect(result, hasLength(1));
      expect(result.first['content'], 'New message');
    });
  });

  group('deleteSession', () {
    test('removes messages for the deleted session', () async {
      await storage.saveMessages(
        serverId: 'srv-1',
        sessionId: 'sess-1',
        messages: [
          {'role': 'user', 'content': 'Hello'},
        ],
      );
      await storage.saveSessions(serverId: 'srv-1', sessions: [
        {'id': 'sess-1', 'title': 'Chat'},
      ]);

      await storage.deleteSession(serverId: 'srv-1', sessionId: 'sess-1');

      final msgs = await storage.loadMessages(serverId: 'srv-1', sessionId: 'sess-1');
      expect(msgs, isEmpty);
    });

    test('removes session from the sessions list', () async {
      await storage.saveSessions(serverId: 'srv-1', sessions: [
        {'id': 'sess-1', 'title': 'Keep'},
        {'id': 'sess-2', 'title': 'Delete'},
      ]);

      await storage.deleteSession(serverId: 'srv-1', sessionId: 'sess-2');

      final sessions = await storage.listSessions(serverId: 'srv-1');
      expect(sessions, hasLength(1));
      expect(sessions.first['id'], 'sess-1');
    });
  });
}
