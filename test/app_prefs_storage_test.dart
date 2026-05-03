import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hamma/core/storage/app_prefs_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPrefsStorage prefs;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    prefs = const AppPrefsStorage();
  });

  // ── Onboarding ──────────────────────────────────────────────────────────────

  group('onboarding', () {
    test('defaults to incomplete', () async {
      expect(await prefs.isOnboardingComplete(), isFalse);
    });

    test('setOnboardingComplete → isOnboardingComplete returns true', () async {
      await prefs.setOnboardingComplete();
      expect(await prefs.isOnboardingComplete(), isTrue);
    });

    test('resetOnboarding → isOnboardingComplete returns false again', () async {
      await prefs.setOnboardingComplete();
      await prefs.resetOnboarding();
      expect(await prefs.isOnboardingComplete(), isFalse);
    });
  });

  // ── Show hidden files ────────────────────────────────────────────────────────

  group('showHiddenFiles', () {
    test('defaults to false', () async {
      expect(await prefs.shouldShowHiddenFiles(), isFalse);
    });

    test('setShowHiddenFiles(true) persists', () async {
      await prefs.setShowHiddenFiles(true);
      expect(await prefs.shouldShowHiddenFiles(), isTrue);
    });

    test('setShowHiddenFiles(false) after true returns false', () async {
      await prefs.setShowHiddenFiles(true);
      await prefs.setShowHiddenFiles(false);
      expect(await prefs.shouldShowHiddenFiles(), isFalse);
    });
  });

  // ── File sort mode ───────────────────────────────────────────────────────────

  group('fileSortMode', () {
    test('defaults to "name"', () async {
      expect(await prefs.getFileSortMode(), 'name');
    });

    test('setFileSortMode persists the given value', () async {
      await prefs.setFileSortMode('date');
      expect(await prefs.getFileSortMode(), 'date');
    });

    test('setFileSortMode can be changed multiple times', () async {
      await prefs.setFileSortMode('date');
      await prefs.setFileSortMode('size');
      expect(await prefs.getFileSortMode(), 'size');
    });
  });

  // ── Health monitoring ────────────────────────────────────────────────────────

  group('healthMonitoring', () {
    test('defaults to disabled', () async {
      expect(await prefs.isHealthMonitoringEnabled(), isFalse);
    });

    test('setHealthMonitoringEnabled(true) persists', () async {
      await prefs.setHealthMonitoringEnabled(true);
      expect(await prefs.isHealthMonitoringEnabled(), isTrue);
    });

    test('setHealthMonitoringEnabled(false) after true returns false', () async {
      await prefs.setHealthMonitoringEnabled(true);
      await prefs.setHealthMonitoringEnabled(false);
      expect(await prefs.isHealthMonitoringEnabled(), isFalse);
    });
  });

  // ── Health check interval ────────────────────────────────────────────────────

  group('healthCheckInterval', () {
    test('defaults to 30 minutes', () async {
      expect(await prefs.getHealthCheckInterval(), 30);
    });

    test('setHealthCheckInterval persists the given value', () async {
      await prefs.setHealthCheckInterval(60);
      expect(await prefs.getHealthCheckInterval(), 60);
    });

    test('persists value of 5 (minimum meaningful interval)', () async {
      await prefs.setHealthCheckInterval(5);
      expect(await prefs.getHealthCheckInterval(), 5);
    });
  });

  // ── Sidebar collapsed ────────────────────────────────────────────────────────

  group('sidebarCollapsed', () {
    test('defaults to null when never set', () async {
      expect(await prefs.getSidebarCollapsed(), isNull);
    });

    test('setSidebarCollapsed(true) persists', () async {
      await prefs.setSidebarCollapsed(true);
      expect(await prefs.getSidebarCollapsed(), isTrue);
    });

    test('setSidebarCollapsed(false) persists and overrides true', () async {
      await prefs.setSidebarCollapsed(true);
      await prefs.setSidebarCollapsed(false);
      expect(await prefs.getSidebarCollapsed(), isFalse);
    });
  });

  // ── Sidebar width ────────────────────────────────────────────────────────────

  group('sidebarWidth', () {
    test('defaults to null when never set', () async {
      expect(await prefs.getSidebarWidth(), isNull);
    });

    test('setSidebarWidth persists a value within range', () async {
      await prefs.setSidebarWidth(280);
      expect(await prefs.getSidebarWidth(), 280);
    });

    test('setSidebarWidth clamps below the minimum', () async {
      await prefs.setSidebarWidth(50);
      expect(
        await prefs.getSidebarWidth(),
        AppPrefsStorage.sidebarMinWidth,
      );
    });

    test('setSidebarWidth clamps above the maximum', () async {
      await prefs.setSidebarWidth(9999);
      expect(
        await prefs.getSidebarWidth(),
        AppPrefsStorage.sidebarMaxWidth,
      );
    });

    test('getSidebarWidth re-clamps a corrupt out-of-range stored value',
        () async {
      // Simulate storage corruption: stored width far above max.
      FlutterSecureStorage.setMockInitialValues({
        'dashboard_sidebar_width': '10000',
      });
      final fresh = const AppPrefsStorage();
      expect(
        await fresh.getSidebarWidth(),
        AppPrefsStorage.sidebarMaxWidth,
      );
    });

    test('getSidebarWidth returns null for an unparseable stored value',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'dashboard_sidebar_width': 'not-a-number',
      });
      final fresh = const AppPrefsStorage();
      expect(await fresh.getSidebarWidth(), isNull);
    });
  });

  // ── Server last states ───────────────────────────────────────────────────────

  group('serverLastStates', () {
    test('defaults to empty map', () async {
      expect(await prefs.getServerLastStates(), isEmpty);
    });

    test('setServerLastStates persists and retrieves the map', () async {
      final states = {'srv-1': 'healthy', 'srv-2': 'warning'};
      await prefs.setServerLastStates(states);

      final result = await prefs.getServerLastStates();

      expect(result, equals(states));
    });

    test('overwrites previous map on second set', () async {
      await prefs.setServerLastStates({'srv-1': 'healthy'});
      await prefs.setServerLastStates({'srv-2': 'critical'});

      final result = await prefs.getServerLastStates();

      expect(result, equals({'srv-2': 'critical'}));
      expect(result.containsKey('srv-1'), isFalse);
    });

    test('persists empty map explicitly', () async {
      await prefs.setServerLastStates({'srv-1': 'healthy'});
      await prefs.setServerLastStates({});

      final result = await prefs.getServerLastStates();
      expect(result, isEmpty);
    });
  });
}
