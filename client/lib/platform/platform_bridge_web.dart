import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../models/models.dart';
import 'platform_bridge.dart';

@JS('Intl.DateTimeFormat')
extension type _JsDateTimeFormat._(JSObject _) implements JSObject {
  external factory _JsDateTimeFormat();
  external _JsResolvedOptions resolvedOptions();
}

@JS()
extension type _JsResolvedOptions._(JSObject _) implements JSObject {
  external String? get timeZone;
}

PlatformBridge createPlatformBridge() => WebPlatformBridge();

class WebPlatformBridge implements PlatformBridge {
  final StreamController<Map<String, dynamic>> _eventCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Timer> _foregroundTimers = {};

  @override
  String get platformName => 'web';

  @override
  bool get supportsKeepAlive => false;

  @override
  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  }) async {
    // Web notification permission is requested explicitly on user gesture.
  }

  @override
  Future<void> syncSchedules(List<DinglinSchedule> schedules) async {
    for (final t in _foregroundTimers.values) {
      t.cancel();
    }
    _foregroundTimers.clear();

    final now = DateTime.now().toUtc();
    for (final s in schedules) {
      if (!s.enabled || s.state != 'active' || s.nextFireAt == null) continue;
      final delay = s.nextFireAt!.difference(now);
      if (delay.isNegative || delay.inHours > 24) continue;
      _foregroundTimers[s.id] = Timer(delay, () {
        _playBeep(s.priority == 'critical');
        _emitWebNotification(s.title, s.body);
        _eventCtrl.add({
          'type': 'schedule_fired',
          'schedule_id': s.id,
        });
      });
    }
  }

  @override
  Future<void> showLocalNotification(DinglinNotification notification) async {
    if (notification.priority != 'silent') {
      _playBeep(notification.isCritical);
    }
    _emitWebNotification(notification.title, notification.body);
  }

  void _emitWebNotification(String title, String body) {
    try {
      if (web.Notification.permission == 'granted') {
        web.Notification(
          title,
          web.NotificationOptions(body: body),
        );
      }
    } catch (_) {}
  }

  void _playBeep(bool critical) {
    try {
      final ctx = web.AudioContext();
      final osc = ctx.createOscillator();
      final gain = ctx.createGain();
      osc.type = critical ? 'triangle' : 'sine';
      osc.frequency.value = critical ? 880 : 660;
      gain.gain.value = 0.08;
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start();
      osc.stop(ctx.currentTime + (critical ? 0.35 : 0.18));
    } catch (_) {}
  }

  @override
  Future<void> stopRinging() async {}

  @override
  Future<bool> hasGms() async => false;

  @override
  Future<String?> getFcmToken() async => null;

  @override
  Future<void> configureKeepAlive(KeepAliveConfig config) async {}

  @override
  Future<PermissionStatus> getPermissionStatus() async {
    var notifGranted = false;
    try {
      notifGranted = web.Notification.permission == 'granted';
    } catch (_) {
      notifGranted = false;
    }
    return PermissionStatus(
      notifications: notifGranted,
      batteryOptimization: true,
      exactAlarm: true,
      fullScreenIntent: true,
    );
  }

  @override
  Future<bool> requestPermission(String permission) async {
    if (permission != 'notifications') return true;
    try {
      final result = await web.Notification.requestPermission().toDart;
      return result.toDart == 'granted';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> updateSyncCursor(int lastSeq, {bool reset = false}) async {}

  @override
  Future<int> getSyncCursor() async => 0;

  @override
  Future<String> getLocalTimezone() async {
    try {
      final tz = _JsDateTimeFormat().resolvedOptions().timeZone;
      if (tz != null && tz.isNotEmpty) return tz;
    } catch (_) {}
    return detectLocalIanaTimezone();
  }

  @override
  Future<void> updateDndPolicy({
    required bool enabled,
    required String start,
    required String end,
  }) async {}

  @override
  Stream<Map<String, dynamic>> get nativeEvents => _eventCtrl.stream;

  @override
  void dispose() {
    for (final t in _foregroundTimers.values) {
      t.cancel();
    }
    _foregroundTimers.clear();
    _eventCtrl.close();
  }
}
