import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../backup/backup_service.dart';
import '../ssh/fleet_service.dart';
import '../storage/app_prefs_storage.dart';
import '../storage/saved_servers_storage.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (task == BackgroundKeepalive.healthTaskName) {
        return await _handleHealthTask();
      } else if (task == BackgroundKeepalive.backupTaskName) {
        return await _handleBackupTask();
      }
      return true;
    } catch (e) {
      return false;
    }
  });
}

Future<bool> _handleHealthTask() async {
  final prefs = const AppPrefsStorage();
  if (!await prefs.isHealthMonitoringEnabled()) {
    return true;
  }

  final storage = const SavedServersStorage();
  final servers = await storage.loadServers();
  if (servers.isEmpty) {
    return true;
  }

  final fleetService = const FleetService();
  final metricsMap = await fleetService.pollFleet(servers);
  final lastStates = await prefs.getServerLastStates();
  final newStates = <String, String>{};

  final notifications = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await notifications.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
  );

  for (final server in servers) {
    final metrics = metricsMap[server.id];
    if (metrics == null) continue;

    String currentState = 'OK';
    List<String> issues = [];

    if (!metrics.isAvailable) {
      currentState = 'OFFLINE';
      issues.add('Server is unreachable');
    } else {
      if ((metrics.cpuPercentage ?? 0) > 90) {
        issues.add(
          'CPU usage is at ${metrics.cpuPercentage?.toStringAsFixed(1)}%',
        );
        currentState = 'HIGH_CPU';
      }
      if ((metrics.ramPercentage ?? 0) > 90) {
        issues.add(
          'RAM usage is at ${metrics.ramPercentage?.toStringAsFixed(1)}%',
        );
        currentState = 'HIGH_RAM';
      }
      if ((metrics.diskPercentage ?? 0) > 95) {
        issues.add(
          'Disk usage is at ${metrics.diskPercentage?.toStringAsFixed(1)}%',
        );
        currentState = 'HIGH_DISK';
      }
    }

    final combinedState = currentState == 'OK' ? 'OK' : issues.join('|');
    newStates[server.id] = combinedState;

    final lastState = lastStates[server.id];
    if (combinedState != 'OK' && combinedState != lastState) {
      await _showNotification(
        notifications,
        server.name,
        issues.join('\n'),
        server.id.hashCode,
      );
    }
  }

  await prefs.setServerLastStates(newStates);
  return true;
}

Future<bool> _handleBackupTask() async {
  try {
    final backupService = BackupService();
    await backupService.backupToDestination();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _showNotification(
  FlutterLocalNotificationsPlugin plugin,
  String serverName,
  String message,
  int id,
) async {
  const androidDetails = AndroidNotificationDetails(
    'server_health_alerts',
    'Server Health Alerts',
    channelDescription: 'Notifications for server offline or resource alerts',
    importance: Importance.high,
    priority: Priority.high,
    color: Color(0xFF3B82F6),
  );
  const iosDetails = DarwinNotificationDetails();
  const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

  await plugin.show(id, 'Hamma Alert: $serverName', message, details);
}

class BackgroundKeepalive {
  BackgroundKeepalive._();

  static const healthTaskName = 'com.hamma.health_sentinel';
  static const backupTaskName = 'com.hamma.daily_backup';

  static Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await Workmanager().initialize(callbackDispatcher);
  }

  static Future<void> enable({int intervalMinutes = 30}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await Workmanager().registerPeriodicTask(
      healthTaskName,
      healthTaskName,
      frequency: Duration(minutes: intervalMinutes),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    await Workmanager().cancelByUniqueName(healthTaskName);
  }
}
