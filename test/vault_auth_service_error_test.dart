import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:hamma/core/vault/vault_auth_service.dart';

class _ThrowingLocalAuth extends Fake implements LocalAuthentication {
  @override
  Future<bool> get canCheckBiometrics async => throw Exception('error');

  @override
  Future<bool> isDeviceSupported() async => throw Exception('error');

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => throw Exception('error');

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticate) {
      return Future<bool>.error(Exception('error'));
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('VaultAuthService handles errors from LocalAuthentication gracefully', () async {
    final service = VaultAuthService(localAuth: _ThrowingLocalAuth());
    final result = await service.canUseBiometrics();
    expect(result, isFalse);

    final authResult = await service.authenticate('test');
    expect(authResult, isFalse);
  });
}
