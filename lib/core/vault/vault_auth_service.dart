import 'dart:async';
import 'package:local_auth/local_auth.dart';
import '../storage/app_lock_storage.dart';

/// Gates vault reveal/copy actions behind biometric or PIN authentication.
///
/// This service handles the session grace period, lockout logic for failed
/// PIN attempts, and biometric integration via [local_auth].
class VaultAuthService {
  VaultAuthService({
    LocalAuthentication? localAuth,
    AppLockStorage? appLockStorage,
    this.gracePeriodDuration = const Duration(minutes: 5),
  })  : _localAuth = localAuth ?? LocalAuthentication(),
        _appLockStorage = appLockStorage ?? const AppLockStorage();

  final LocalAuthentication _localAuth;
  final AppLockStorage _appLockStorage;

  /// Duration after a successful authentication during which subsequent
  /// calls to [authenticate] return true immediately.
  final Duration gracePeriodDuration;

  DateTime? _lastAuthenticatedAt;
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;

  /// Returns true if the session grace period is currently active.
  bool get isAuthenticated {
    if (_lastAuthenticatedAt == null) return false;
    final now = DateTime.now();
    return now.difference(_lastAuthenticatedAt!) < gracePeriodDuration;
  }

  /// Returns true if the service is currently locked out due to too many
  /// failed PIN attempts.
  bool get isLockedOut {
    if (_lockoutUntil == null) return false;
    return DateTime.now().isBefore(_lockoutUntil!);
  }

  /// Remaining duration of the current lockout, if any.
  Duration get lockoutRemaining {
    if (!isLockedOut) return Duration.zero;
    return _lockoutUntil!.difference(DateTime.now());
  }

  /// Checks if the device supports biometric authentication.
  Future<bool> canUseBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;

      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Resets the grace period. Typically called when the app is backgrounded.
  void resetGracePeriod() {
    _lastAuthenticatedAt = null;
  }

  /// Primary entry point for vault authentication.
  ///
  /// 1. Returns true if already [isAuthenticated].
  /// 2. Returns false if [isLockedOut].
  /// 3. Attempts biometric authentication if available.
  /// 4. If biometrics fail or are unavailable, returns false (UI should
  ///    then trigger a PIN prompt via [verifyPin]).
  ///
  /// NOTE: This method returns false when a PIN prompt is needed because
  /// this service does not build UI. The caller is responsible for
  /// showing a PIN input and calling [verifyPin].
  Future<bool> authenticate(String reason) async {
    if (isAuthenticated) return true;
    if (isLockedOut) return false;

    if (await canUseBiometrics()) {
      try {
        final success = await _localAuth.authenticate(
          localizedReason: reason,
          options: const AuthenticationOptions(
            biometricOnly: true,
            stickyAuth: true,
          ),
        );

        if (success) {
          _onSuccess();
          return true;
        }
      } catch (_) {
        // Fall back to PIN
      }
    }

    // Biometrics failed, unavailable, or not enrolled.
    // The requirement says "fall back to PIN prompt". Since we don't build UI,
    // we return false and expect the UI layer (which likely uses VaultAuthState)
    // to handle the transition.
    return false;
  }

  /// Verifies the provided [pin] against the stored app PIN.
  ///
  /// Increments failure counter and applies lockout if necessary.
  /// Resets failure counter on success.
  Future<bool> verifyPin(String pin) async {
    if (isLockedOut) return false;

    final storedPin = await _appLockStorage.readPin();
    
    // TODO: Verify if AppLockStorage has a canonical way to check PINs.
    // Currently using direct comparison with readPin().
    if (storedPin != null && storedPin == pin) {
      _onSuccess();
      return true;
    }

    _onFailure();
    return false;
  }

  void _onSuccess() {
    _lastAuthenticatedAt = DateTime.now();
    _failedAttempts = 0;
    _lockoutUntil = null;
  }

  void _onFailure() {
    _failedAttempts++;
    if (_failedAttempts >= 9) {
      _lockoutUntil = DateTime.now().add(const Duration(minutes: 15));
    } else if (_failedAttempts >= 6) {
      _lockoutUntil = DateTime.now().add(const Duration(minutes: 5));
    } else if (_failedAttempts >= 3) {
      _lockoutUntil = DateTime.now().add(const Duration(minutes: 1));
    }
  }
}
