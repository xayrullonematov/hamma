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
