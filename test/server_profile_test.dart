import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/models/server_profile.dart';

void main() {
  const _base = ServerProfile(
    id: 'srv-1',
    name: 'Production',
    host: '10.0.0.1',
    port: 22,
    username: 'admin',
    password: 's3cr3t',
  );

  group('ServerProfile.isValid', () {
    test('returns true when all required fields are set (password auth)', () {
      expect(_base.isValid, isTrue);
    });

    test('returns true when private key is provided instead of password', () {
      final profile = _base.copyWith(password: '', privateKey: '-----BEGIN...');
      expect(profile.isValid, isTrue);
    });

    test('returns false when host is blank', () {
      final profile = _base.copyWith(host: '   ');
      expect(profile.isValid, isFalse);
    });

    test('returns false when name is blank', () {
      final profile = _base.copyWith(name: '');
      expect(profile.isValid, isFalse);
    });

    test('returns false when username is blank', () {
      final profile = _base.copyWith(username: '   ');
      expect(profile.isValid, isFalse);
    });

    test('returns false when both password and private key are blank', () {
      final profile = _base.copyWith(password: '', privateKey: null);
      expect(profile.isValid, isFalse);
    });

    test('returns false when port is 0', () {
      final profile = _base.copyWith(port: 0);
      expect(profile.isValid, isFalse);
    });

    test('returns false when port exceeds 65535', () {
      final profile = _base.copyWith(port: 65536);
      expect(profile.isValid, isFalse);
    });

    test('returns true for port boundary value 65535', () {
      final profile = _base.copyWith(port: 65535);
      expect(profile.isValid, isTrue);
    });
  });

  group('ServerProfile.toJson / fromJson', () {
    test('round-trips all fields including optional ones', () {
      const profile = ServerProfile(
        id: 'srv-42',
        name: 'Staging',
        host: 'staging.example.com',
        port: 2222,
        username: 'deploy',
        password: 'p@ssword',
        privateKey: '-----BEGIN RSA PRIVATE KEY-----',
        privateKeyPassword: 'key-pass',
      );

      final restored = ServerProfile.fromJson(profile.toJson());

      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.host, profile.host);
      expect(restored.port, profile.port);
      expect(restored.username, profile.username);
      expect(restored.password, profile.password);
      expect(restored.privateKey, profile.privateKey);
      expect(restored.privateKeyPassword, profile.privateKeyPassword);
    });

    test('round-trips correctly when optional fields are null', () {
      final restored = ServerProfile.fromJson(_base.toJson());

      expect(restored.privateKey, isNull);
      expect(restored.privateKeyPassword, isNull);
    });

    test('toJson contains all expected keys', () {
      final json = _base.toJson();

      expect(json.keys, containsAll(['id', 'name', 'host', 'port', 'username', 'password', 'privateKey', 'privateKeyPassword']));
    });
  });

  // ── New: hardened fromJson behavior (regression coverage for the
  //        null-guard fix that replaced hard `as String` casts) ──────────
  group('ServerProfile.fromJson — defensive parsing', () {
    test('does not throw when string fields are missing entirely', () {
      // Old hard-cast version threw TypeError; new version returns empty
      // strings so isValid (not the parser) flags the corrupted profile.
      final restored = ServerProfile.fromJson({});

      expect(restored.id, '');
      expect(restored.name, '');
      expect(restored.host, '');
      expect(restored.port, 22); // default for absent port
      expect(restored.username, '');
      expect(restored.password, '');
      expect(restored.privateKey, isNull);
      expect(restored.privateKeyPassword, isNull);
      expect(restored.isValid, isFalse);
    });

    test('does not throw when string fields are explicitly null', () {
      final restored = ServerProfile.fromJson({
        'id': null,
        'name': null,
        'host': null,
        'port': null,
        'username': null,
        'password': null,
        'privateKey': null,
        'privateKeyPassword': null,
      });

      expect(restored.id, '');
      expect(restored.host, '');
      expect(restored.port, 22);
      expect(restored.isValid, isFalse);
    });

    test('parses string-encoded port (legitimate JSON variation)', () {
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'port': '2222',
      });

      expect(restored.port, 2222);
      expect(restored.isValid, isTrue);
    });

    test('marks port as invalid (0) when stored value is malformed string', () {
      // We want a corrupted port to fail isValid rather than silently
      // defaulting to 22 and connecting somewhere unexpected.
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'port': 'not-a-number',
      });

      expect(restored.port, 0);
      expect(restored.isValid, isFalse);
    });

    test('marks port as invalid (0) when stored value is wrong type', () {
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'port': true,
      });

      expect(restored.port, 0);
      expect(restored.isValid, isFalse);
    });

    test('does not silently coerce maps/lists into string fields', () {
      // Old `?.toString() ?? ''` would have coerced `{a: 1}` to a string,
      // which could superficially pass isValid. Type-checked accessors
      // return empty string instead so isValid catches the corruption.
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'host': {'nested': 'object'},
        'username': [1, 2, 3],
      });

      expect(restored.host, '');
      expect(restored.username, '');
      expect(restored.isValid, isFalse);
    });

    test('does not coerce non-string privateKey values to a string', () {
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'privateKey': 12345,
      });

      // Wrong-typed optional fields should round-trip to null, not "12345".
      expect(restored.privateKey, isNull);
    });

    test('does not coerce non-string privateKeyPassword values to a string', () {
      // Symmetry with privateKey — both optional string fields must apply
      // the same type-checking rules.
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'privateKeyPassword': {'wrong': 'type'},
      });

      expect(restored.privateKeyPassword, isNull);
    });

    test('legacy JSON missing the port field stays valid (defaults to 22)', () {
      // Backward-compat path: older saved profiles may not have a port
      // key at all. They must still load as valid SSH profiles on port 22.
      final json = _base.toJson()..remove('port');
      final restored = ServerProfile.fromJson(json);

      expect(restored.port, 22);
      expect(restored.isValid, isTrue);
    });

    test('JSON with explicit null port stays valid (defaults to 22)', () {
      final restored = ServerProfile.fromJson({
        ..._base.toJson(),
        'port': null,
      });

      expect(restored.port, 22);
      expect(restored.isValid, isTrue);
    });
  });

  group('ServerProfile.copyWith', () {
    test('returns new instance with updated field', () {
      final updated = _base.copyWith(host: '192.168.1.1');

      expect(updated.host, '192.168.1.1');
      expect(updated.name, _base.name);
      expect(updated.id, _base.id);
    });

    test('explicitly clears privateKey when passed null', () {
      final withKey = _base.copyWith(privateKey: '-----BEGIN...');
      final cleared = withKey.copyWith(privateKey: null);

      expect(cleared.privateKey, isNull);
    });

    test('preserves existing privateKey when not specified in copyWith', () {
      final withKey = _base.copyWith(privateKey: '-----BEGIN...');
      final updated = withKey.copyWith(name: 'New Name');

      expect(updated.privateKey, '-----BEGIN...');
    });
  });
}
