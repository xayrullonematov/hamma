import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/storage/app_lock_storage.dart';

enum AppLockMode {
  setup,
  verify,
  remove,
}

class AppLockScreen extends StatefulWidget {
  const AppLockScreen({
    super.key,
    required this.mode,
    this.appLockStorage = const AppLockStorage(),
    this.nextScreen,
  });

  final AppLockMode mode;
  final AppLockStorage appLockStorage;
  final Widget? nextScreen;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  static const _backgroundColor = Color(0xFF0F172A);
  static const _surfaceColor = Color(0xFF1E293B);
  static const _panelColor = Color(0xFF162033);
  static const _primaryColor = Color(0xFF3B82F6);
  static const _mutedColor = Color(0xFF94A3B8);
  static const _dangerColor = Color(0xFFEF4444);
  static const _shadowColor = Color(0x22000000);

  final LocalAuthentication _localAuthentication = LocalAuthentication();
  final FocusNode _focusNode = FocusNode();

  String _input = '';
  String? _pendingSetupPin;
  String? _storedPin;
  String _status = '';
  bool _isLoading = true;
  bool _isAuthenticating = false;
  bool _biometricsAvailable = false;
  bool _didPromptForBiometrics = false;
  int _failedAttempts = 0;
  bool _isLockedOut = false;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    if (widget.mode == AppLockMode.setup) {
      setState(() {
        _status = 'Create a 4-digit PIN to protect the app.';
        _isLoading = false;
      });
      _focusNode.requestFocus();
      return;
    }

    try {
      final storedPin = await widget.appLockStorage.readPin();
      final biometricsAvailable = await _checkBiometricsAvailable();

      if (!mounted) {
        return;
      }

      if (storedPin == null) {
        if (widget.mode == AppLockMode.verify) {
          await _completeSuccess();
        } else {
          Navigator.of(context).pop(false);
        }
        return;
      }

      setState(() {
        _storedPin = storedPin;
        _biometricsAvailable = biometricsAvailable;
        _status = widget.mode == AppLockMode.verify
            ? 'Enter your PIN to unlock Hamma.'
            : 'Enter your current PIN to remove the app lock.';
        _isLoading = false;
      });
      _focusNode.requestFocus();

      if (widget.mode == AppLockMode.verify && biometricsAvailable) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _authenticateWithBiometrics(autoTriggered: true);
          }
        });
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = widget.mode == AppLockMode.verify
            ? 'Enter your PIN to unlock Hamma.'
            : 'Enter your current PIN to remove the app lock.';
        _isLoading = false;
      });
    }
  }

  Future<bool> _checkBiometricsAvailable() async {
    try {
      final canCheckBiometrics = await _localAuthentication.canCheckBiometrics;
      final isDeviceSupported = await _localAuthentication.isDeviceSupported();
      final availableBiometrics =
          await _localAuthentication.getAvailableBiometrics();

      return canCheckBiometrics &&
          isDeviceSupported &&
          availableBiometrics.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String get _titleText {
    switch (widget.mode) {
      case AppLockMode.setup:
        return _pendingSetupPin == null ? 'Set App PIN' : 'Confirm App PIN';
      case AppLockMode.verify:
        return 'Unlock Hamma';
      case AppLockMode.remove:
        return 'Remove App PIN';
    }
  }

  String get _subtitleText {
    switch (widget.mode) {
      case AppLockMode.setup:
        return _pendingSetupPin == null
            ? 'Create a 4-digit PIN for secure local app access.'
            : 'Re-enter the same 4-digit PIN to confirm.';
      case AppLockMode.verify:
        return 'Use your 4-digit PIN or biometric unlock if available.';
      case AppLockMode.remove:
        return 'Verify your current PIN before removing the app lock.';
    }
  }

  Future<void> _handleDigitTap(String digit) async {
    if (_isLoading || _isAuthenticating || _isLockedOut || _input.length >= 4) {
      return;
    }

    setState(() {
      _input += digit;
    });

    if (_input.length == 4) {
      await _handleCompletedPin();
    }
  }

  void _handleBackspace() {
    if (_isLoading || _isAuthenticating || _input.isEmpty) {
      return;
    }

    setState(() {
      _input = _input.substring(0, _input.length - 1);
    });
  }

  Future<void> _handleCompletedPin() async {
    switch (widget.mode) {
      case AppLockMode.setup:
        await _handleSetupPin();
      case AppLockMode.verify:
        await _handleVerifyPin();
      case AppLockMode.remove:
        await _handleRemovePin();
    }
  }

  Future<void> _handleSetupPin() async {
    if (_pendingSetupPin == null) {
      setState(() {
        _pendingSetupPin = _input;
        _input = '';
        _status = 'Re-enter your PIN to confirm it.';
      });
      return;
    }

    if (_input != _pendingSetupPin) {
      setState(() {
        _input = '';
        _pendingSetupPin = null;
        _status = 'PINs did not match. Enter a new 4-digit PIN.';
      });
      return;
    }

    await widget.appLockStorage.savePin(_input);
    if (!mounted) {
      return;
    }

    await _completeSuccess();
  }

  Future<void> _handleVerifyPin() async {
    if (_storedPin != null && _input == _storedPin) {
      await _completeSuccess();
      return;
    }

    _failedAttempts++;
    if (_failedAttempts >= 5) {
      setState(() {
        _input = '';
        _isLockedOut = true;
        _status = 'Too many attempts. Try again in 30 seconds.';
      });
      _lockoutTimer = Timer(const Duration(seconds: 30), () {
        if (mounted) {
          setState(() {
            _isLockedOut = false;
            _failedAttempts = 0;
            _status = 'Enter your PIN.';
          });
        }
      });
    } else {
      setState(() {
        _input = '';
        _status = 'Incorrect PIN. ${5 - _failedAttempts} attempts remaining.';
      });
    }
  }

  Future<void> _handleRemovePin() async {
    if (_storedPin != null && _input == _storedPin) {
      await widget.appLockStorage.deletePin();
      if (!mounted) {
        return;
      }

      await _completeSuccess();
      return;
    }

    _failedAttempts++;
    if (_failedAttempts >= 5) {
      setState(() {
        _input = '';
        _isLockedOut = true;
        _status = 'Too many attempts. Try again in 30 seconds.';
      });
      _lockoutTimer = Timer(const Duration(seconds: 30), () {
        if (mounted) {
          setState(() {
            _isLockedOut = false;
            _failedAttempts = 0;
            _status = 'Enter your PIN.';
          });
        }
      });
    } else {
      setState(() {
        _input = '';
        _status = 'Incorrect PIN. ${5 - _failedAttempts} attempts remaining.';
      });
    }
  }

  Future<void> _authenticateWithBiometrics({
    bool autoTriggered = false,
  }) async {
    if (_isLoading ||
        _isAuthenticating ||
        !_biometricsAvailable ||
        widget.mode != AppLockMode.verify) {
      return;
    }

    if (autoTriggered) {
      if (_didPromptForBiometrics) {
        return;
      }
      _didPromptForBiometrics = true;
    }

    setState(() {
      _isAuthenticating = true;
      _status = 'Waiting for biometric authentication...';
    });

    try {
      final didAuthenticate = await _localAuthentication.authenticate(
        localizedReason: 'Authenticate to unlock Hamma',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (!mounted) {
        return;
      }

      if (didAuthenticate) {
        await _completeSuccess();
        return;
      }

      setState(() {
        _status = 'Biometric authentication was canceled. Enter your PIN.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Biometric authentication is unavailable. Enter your PIN.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  Future<void> _completeSuccess() async {
    if (widget.mode == AppLockMode.verify && widget.nextScreen != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => widget.nextScreen!,
        ),
      );
      return;
    }

    Navigator.of(context).pop(true);
  }

  Widget _buildPinIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final isFilled = index < _input.length;
        return Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: isFilled ? _primaryColor : _panelColor,
            shape: BoxShape.circle,
            border: Border.all(
              color:
                  isFilled ? _primaryColor : _mutedColor.withValues(alpha: 0.3),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildKey({
    String? label,
    IconData? icon,
    required VoidCallback? onTap,
  }) {
    final isEnabled = onTap != null && !_isLoading;

    return Opacity(
      opacity: isEnabled ? 1 : 0.35,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              color: _panelColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Center(
              child: icon != null
                  ? Icon(icon, color: _mutedColor, size: 28)
                  : Text(
                      label!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
      childAspectRatio: 1.15,
      children: [
        for (final digit in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
          _buildKey(
            label: digit,
            onTap: () => _handleDigitTap(digit),
          ),
        _buildKey(
          icon: Icons.fingerprint_rounded,
          onTap: _biometricsAvailable && widget.mode == AppLockMode.verify
              ? () => _authenticateWithBiometrics()
              : null,
        ),
        _buildKey(
          label: '0',
          onTap: () => _handleDigitTap('0'),
        ),
        _buildKey(
          icon: Icons.backspace_outlined,
          onTap: _input.isEmpty ? null : _handleBackspace,
        ),
      ],
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      final logicalKey = event.logicalKey;

      if (logicalKey == LogicalKeyboardKey.backspace) {
        _handleBackspace();
        return;
      }

      // Handle number keys (0-9) and numpad keys (0-9)
      final numberMap = {
        LogicalKeyboardKey.digit0: '0',
        LogicalKeyboardKey.digit1: '1',
        LogicalKeyboardKey.digit2: '2',
        LogicalKeyboardKey.digit3: '3',
        LogicalKeyboardKey.digit4: '4',
        LogicalKeyboardKey.digit5: '5',
        LogicalKeyboardKey.digit6: '6',
        LogicalKeyboardKey.digit7: '7',
        LogicalKeyboardKey.digit8: '8',
        LogicalKeyboardKey.digit9: '9',
        LogicalKeyboardKey.numpad0: '0',
        LogicalKeyboardKey.numpad1: '1',
        LogicalKeyboardKey.numpad2: '2',
        LogicalKeyboardKey.numpad3: '3',
        LogicalKeyboardKey.numpad4: '4',
        LogicalKeyboardKey.numpad5: '5',
        LogicalKeyboardKey.numpad6: '6',
        LogicalKeyboardKey.numpad7: '7',
        LogicalKeyboardKey.numpad8: '8',
        LogicalKeyboardKey.numpad9: '9',
      };

      if (numberMap.containsKey(logicalKey)) {
        _handleDigitTap(numberMap[logicalKey]!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(
          automaticallyImplyLeading:
              !(widget.mode == AppLockMode.verify && widget.nextScreen != null) &&
                  canPop,
          title: Text(_titleText),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  decoration: BoxDecoration(
                    color: _surfaceColor,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: const [
                      BoxShadow(
                        color: _shadowColor,
                        blurRadius: 24,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: _primaryColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.lock_outline,
                          color: _primaryColor,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _titleText,
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _subtitleText,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: _mutedColor,
                              height: 1.4,
                            ),
                      ),
                      const SizedBox(height: 28),
                      _buildPinIndicator(),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 24,
                        child: Center(
                          child: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(
                                  _status,
                                  textAlign: TextAlign.center,
                                  style:
                                      Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: _status
                                                        .toLowerCase()
                                                        .contains('incorrect') ||
                                                    _status
                                                        .toLowerCase()
                                                        .contains('did not match')
                                                ? _dangerColor
                                                : _mutedColor,
                                          ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildKeypad(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
