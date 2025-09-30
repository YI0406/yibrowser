import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );

    final initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
    );
    try {
      await _plugin.initialize(initializationSettings);
      _initialized = true;
    } catch (e) {
      debugPrint('Notification init failed: $e');
    }
  }

  Future<void> showDownloadCompleted({
    required String title,
    required String body,
  }) async {
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux)) {
      return;
    }
    if (!_initialized) {
      await init();
    }

    const androidDetails = AndroidNotificationDetails(
      'downloads',
      'Downloads',
      channelDescription: 'Notifications for completed downloads',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBadge: true,
    );

    const linuxDetails = LinuxNotificationDetails();

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
    );

    try {
      await _plugin.show(
        0,
        title,
        body,
        notificationDetails,
        payload: 'download_complete',
      );
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }

  Future<bool> ensurePermissions() async {
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux)) {
      return false;
    }
    if (!_initialized) {
      await init();
    }

    if (Platform.isAndroid) {
      final androidPlugin =
          _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      if (androidPlugin != null) {
        final enabled = await androidPlugin.areNotificationsEnabled();
        if (enabled ?? true) {
          return true;
        }
        final granted = await androidPlugin.requestNotificationsPermission();
        return granted ?? false;
      }
      return true;
    }

    if (Platform.isIOS) {
      final iosPlugin =
          _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >();
      if (iosPlugin != null) {
        final granted = await iosPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
      return false;
    }

    if (Platform.isMacOS) {
      final macPlugin =
          _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >();
      if (macPlugin != null) {
        final granted = await macPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
      return false;
    }

    if (Platform.isLinux) {
      return true;
    }

    return false;
  }

  Future<void> openNotificationSettings() async {
    if (!_initialized) {
      await init();
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final uri = Uri.parse('app-settings:');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
      return;
    }
  }
}
