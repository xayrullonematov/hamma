import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:hamma/core/vault/vault_auth_state.dart';
import 'package:hamma/core/vault/vault_auth_service.dart';

class FakeVaultAuthService implements VaultAuthService {
  @override
  bool isAuthenticated = false;

  @override
  bool isLockedOut = false;

  @override
  Duration lockoutRemaining = Duration.zero;

  bool authenticateReturns = false;
  int authenticateCallCount = 0;
  String? lastAuthenticateReason;

  @override
  Future<bool> authenticate(String reason) async {
    authenticateCallCount++;
    lastAuthenticateReason = reason;
    return authenticateReturns;
  }

  bool verifyPinReturns = false;
  int verifyPinCallCount = 0;
  String? lastVerifyPin;

  @override
  Future<bool> verifyPin(String pin) async {
    verifyPinCallCount++;
    lastVerifyPin = pin;
    return verifyPinReturns;
  }

  int resetGracePeriodCallCount = 0;

  @override
  void resetGracePeriod() {
    resetGracePeriodCallCount++;
  }

  @override
  Future<bool> canUseBiometrics() async => false;

  @override
  Duration get gracePeriodDuration => const Duration(minutes: 5);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVaultAuthService fakeService;

  setUp(() {
    fakeService = FakeVaultAuthService();
  });

  group('VaultAuthState', () {
    test('getters delegate to service', () {
      final state = VaultAuthState(fakeService);

      fakeService.isAuthenticated = true;
      fakeService.isLockedOut = false;
      fakeService.lockoutRemaining = const Duration(seconds: 10);

      expect(state.isAuthenticated, true);
      expect(state.isLockedOut, false);
      expect(state.lockoutRemaining, const Duration(seconds: 10));

      state.dispose();
    });

    test('authenticate delegates and notifies on success', () async {
      final state = VaultAuthState(fakeService);
      fakeService.authenticateReturns = true;

      int notifyCount = 0;
      state.addListener(() {
        notifyCount++;
      });

      final result = await state.authenticate('reason');

      expect(result, true);
      expect(fakeService.authenticateCallCount, 1);
      expect(fakeService.lastAuthenticateReason, 'reason');
      expect(notifyCount, 1);

      state.dispose();
    });

    test('authenticate delegates and does not notify on failure', () async {
      final state = VaultAuthState(fakeService);
      fakeService.authenticateReturns = false;

      int notifyCount = 0;
      state.addListener(() {
        notifyCount++;
      });

      final result = await state.authenticate('reason');

      expect(result, false);
      expect(fakeService.authenticateCallCount, 1);
      expect(fakeService.lastAuthenticateReason, 'reason');
      expect(notifyCount, 0);

      state.dispose();
    });

    test('verifyPin delegates and notifies regardless of success', () async {
      final state = VaultAuthState(fakeService);
      fakeService.verifyPinReturns = false;

      int notifyCount = 0;
      state.addListener(() {
        notifyCount++;
      });

      final result = await state.verifyPin('1234');

      expect(result, false);
      expect(fakeService.verifyPinCallCount, 1);
      expect(fakeService.lastVerifyPin, '1234');
      expect(notifyCount, 1);

      fakeService.verifyPinReturns = true;
      final result2 = await state.verifyPin('4321');

      expect(result2, true);
      expect(fakeService.verifyPinCallCount, 2);
      expect(fakeService.lastVerifyPin, '4321');
      expect(notifyCount, 2);

      state.dispose();
    });

    test('didChangeAppLifecycleState calls resetGracePeriod on pause', () {
      final state = VaultAuthState(fakeService);

      int notifyCount = 0;
      state.addListener(() {
        notifyCount++;
      });

      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(fakeService.resetGracePeriodCallCount, 0);
      expect(notifyCount, 0);

      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(fakeService.resetGracePeriodCallCount, 1);
      expect(notifyCount, 1);

      state.dispose();
    });

    test('periodic timer notifies listeners when locked out', () {
      fakeAsync((async) {
        final state = VaultAuthState(fakeService);

        int notifyCount = 0;
        state.addListener(() {
          notifyCount++;
        });

        // Initially not locked out, timer fires but doesn't notify
        fakeService.isLockedOut = false;
        async.elapse(const Duration(seconds: 1));
        expect(notifyCount, 0);

        // Lock out the service, timer should now notify
        fakeService.isLockedOut = true;
        async.elapse(const Duration(seconds: 1));
        expect(notifyCount, 1);

        async.elapse(const Duration(seconds: 2));
        expect(notifyCount, 3);

        state.dispose();
      });
    });
  });
}
