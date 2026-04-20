import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:permission_handler/permission_handler.dart';

class BackgroundKeepalive {
  BackgroundKeepalive._();

  static bool _initialized = false;

  static Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) {
      return;
    }

    // Request notification permissions for Android 13+ compliance
    await Permission.notification.request();

    try {
      await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'Hamma SSH',
          notificationText: 'SSH session is active in the background',
          notificationImportance: AndroidNotificationImportance.normal,
        ),
      );
      _initialized = true;
    } catch (e) {
      debugPrint('Failed to initialize background keepalive: $e');
    }
  }

  static Future<void> enable() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (!_initialized) {
      await initialize();
    }

    try {
      await FlutterBackground.enableBackgroundExecution();
    } catch (error) {
      debugPrint('Background execution unavailable: $error');
    }
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid || !_initialized) {
      return;
    }

    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (error) {
      debugPrint('Failed to disable background execution cleanly: $error');
    }
  }
}
