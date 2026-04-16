import 'dart:io';

import 'package:flutter_background/flutter_background.dart';

class BackgroundKeepalive {
  BackgroundKeepalive._();

  static bool _initialized = false;

  static Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) {
      return;
    }

    await FlutterBackground.initialize(
      androidConfig: const FlutterBackgroundAndroidConfig(
        notificationTitle: 'Hamma SSH',
        notificationText: 'SSH session is active in the background',
        notificationImportance: AndroidNotificationImportance.normal,
      ),
    );
    _initialized = true;
  }

  static Future<void> enable() async {
    if (!Platform.isAndroid) {
      return;
    }

    if (!_initialized) {
      await initialize();
    }

    await FlutterBackground.enableBackgroundExecution();
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid || !_initialized) {
      return;
    }

    await FlutterBackground.disableBackgroundExecution();
  }
}
