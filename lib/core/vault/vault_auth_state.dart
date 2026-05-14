import 'dart:async';
import 'package:flutter/material.dart';
import 'vault_auth_service.dart';

/// ChangeNotifier wrapper for [VaultAuthService].
///
/// Exposes authentication and lockout state and handles app lifecycle
/// events to reset the session grace period.
class VaultAuthState extends ChangeNotifier with WidgetsBindingObserver {
  VaultAuthState(this._service) {
    WidgetsBinding.instance.addObserver(this);
    _startLockoutTimer();
  }

  final VaultAuthService _service;
  Timer? _lockoutTimer;

  bool get isAuthenticated => _service.isAuthenticated;
  bool get isLockedOut => _service.isLockedOut;
  Duration get lockoutRemaining => _service.lockoutRemaining;

  /// Attempts to authenticate the user using biometrics if possible.
  ///
  /// Returns true if authentication succeeded (grace period or biometric).
  /// If it returns false, the UI should decide whether to show a PIN prompt.
  Future<bool> authenticate(String reason) async {
    final success = await _service.authenticate(reason);
    if (success) {
      notifyListeners();
    }
    return success;
  }

  /// Verifies the provided [pin].
  Future<bool> verifyPin(String pin) async {
    final success = await _service.verifyPin(pin);
    notifyListeners();
    return success;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _service.resetGracePeriod();
      notifyListeners();
    }
  }

  /// Periodically notifies listeners while locked out so the UI can
  /// update the countdown timer.
  void _startLockoutTimer() {
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_service.isLockedOut) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockoutTimer?.cancel();
    super.dispose();
  }
}
