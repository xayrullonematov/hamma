import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../error/error_reporter.dart';

class AppPrefsStorage {
  const AppPrefsStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _onboardingCompleteKey = 'onboarding_complete';
  static const _showHiddenFilesKey = 'show_hidden_files';
  static const _fileSortModeKey = 'file_sort_mode';
  static const _healthMonitoringEnabledKey = 'health_monitoring_enabled';
  static const _healthCheckIntervalKey = 'health_check_interval';
  static const _serverLastStatesKey = 'server_last_states';
  static const _localAiOnboardingSeenKey = 'local_ai_onboarding_seen';
  static const _sidebarCollapsedKey = 'dashboard_sidebar_collapsed';

  final FlutterSecureStorage _secureStorage;

  /// Whether the user has already seen (or dismissed) the Local AI
  /// onboarding wizard. Used by Settings to auto-launch the wizard once
  /// when the user picks the Local AI provider and no engine is reachable.
  Future<bool> isLocalAiOnboardingSeen() async {
    final value = await _secureStorage.read(key: _localAiOnboardingSeenKey);
    return value == 'true';
  }

  Future<void> setLocalAiOnboardingSeen() async {
    await _secureStorage.write(key: _localAiOnboardingSeenKey, value: 'true');
  }

  Future<bool> isOnboardingComplete() async {
    final value = await _secureStorage.read(key: _onboardingCompleteKey);
    return value == 'true';
  }

  Future<void> setOnboardingComplete() async {
    await _secureStorage.write(key: _onboardingCompleteKey, value: 'true');
  }

  Future<void> resetOnboarding() async {
    await _secureStorage.delete(key: _onboardingCompleteKey);
  }

  Future<bool> shouldShowHiddenFiles() async {
    final value = await _secureStorage.read(key: _showHiddenFilesKey);
    return value == 'true';
  }

  Future<void> setShowHiddenFiles(bool value) async {
    await _secureStorage.write(
      key: _showHiddenFilesKey,
      value: value.toString(),
    );
  }

  Future<String> getFileSortMode() async {
    return await _secureStorage.read(key: _fileSortModeKey) ?? 'name';
  }

  Future<void> setFileSortMode(String mode) async {
    await _secureStorage.write(key: _fileSortModeKey, value: mode);
  }

  Future<bool> isHealthMonitoringEnabled() async {
    final value = await _secureStorage.read(key: _healthMonitoringEnabledKey);
    return value == 'true';
  }

  Future<void> setHealthMonitoringEnabled(bool value) async {
    await _secureStorage.write(
      key: _healthMonitoringEnabledKey,
      value: value.toString(),
    );
  }

  Future<int> getHealthCheckInterval() async {
    final value = await _secureStorage.read(key: _healthCheckIntervalKey);
    return int.tryParse(value ?? '') ?? 30; // Default 30 minutes
  }

  Future<void> setHealthCheckInterval(int minutes) async {
    await _secureStorage.write(
      key: _healthCheckIntervalKey,
      value: minutes.toString(),
    );
  }

  Future<Map<String, String>> getServerLastStates() async {
    final value = await _secureStorage.read(key: _serverLastStatesKey);
    if (value == null || value.isEmpty) {
      return {};
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e, stack) {
      // Stored value is corrupt or no longer matches the schema. Fall
      // back to an empty map (the safe default) but report so we know
      // when this happens in the wild.
      unawaited(ErrorReporter.report(
        e,
        stack,
        hint: 'AppPrefsStorage.getServerLastStates: corrupt stored value',
      ));
    }
    return {};
  }

  Future<void> setServerLastStates(Map<String, String> states) async {
    await _secureStorage.write(
      key: _serverLastStatesKey,
      value: jsonEncode(states),
    );
  }

  /// User preference for the desktop dashboard sidebar.
  /// `null` means "not yet set" — caller should pick a sensible default
  /// based on current viewport width (rail on tablet, full on desktop).
  Future<bool?> getSidebarCollapsed() async {
    final value = await _secureStorage.read(key: _sidebarCollapsedKey);
    if (value == null) return null;
    return value == 'true';
  }

  Future<void> setSidebarCollapsed(bool collapsed) async {
    await _secureStorage.write(
      key: _sidebarCollapsedKey,
      value: collapsed.toString(),
    );
  }
}
