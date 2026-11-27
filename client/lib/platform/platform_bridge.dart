import '../models/models.dart';
import 'platform_bridge_io.dart'
    if (dart.library.js_interop) 'platform_bridge_web.dart' as impl;

abstract class PlatformBridge {
  factory PlatformBridge() => impl.createPlatformBridge();

  String get platformName;

  bool get supportsKeepAlive;

  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  });

  Future<void> syncSchedules(List<DinglinSchedule> schedules);

  Future<void> showLocalNotification(DinglinNotification notification);

  Future<void> startAlarmRinging(DinglinSchedule schedule);

  Future<void> stopRinging({String? scheduleId});

  Future<void> setAppForeground(bool foreground);

  Future<bool> supportsAutoStartSettings();

  Future<bool> hasGms();

  Future<String?> getFcmToken();

  Future<void> configureKeepAlive(KeepAliveConfig config);

  Future<PermissionStatus> getPermissionStatus();

  Future<bool> requestPermission(String permission);

  Future<void> updateSyncCursor(int lastSeq, {bool reset = false});

  Future<int> getSyncCursor();

  Future<String> getLocalTimezone();

  Future<void> updateDndPolicy({
    required bool enabled,
    required String start,
    required String end,
  });

  Stream<Map<String, dynamic>> get nativeEvents;

  void dispose();
}
