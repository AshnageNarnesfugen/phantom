import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static Future<void> initialize() async {
    const channel = AndroidNotificationChannel(
      'phantom_messages',
      'Messages',
      importance: Importance.high,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_launcher'),
    );

    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  static Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showMessage({
    required String contactName,
    required String preview,
    required String contactId,
  }) async {
    if (!_initialized) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'phantom_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
        icon: 'ic_launcher',
      ),
    );

    await _plugin.show(
      contactId.hashCode.abs() % 100000,
      contactName,
      preview,
      details,
    );
  }
}
