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

  Timer? _alarmRingTimer;
  web.AudioContext? _alarmAudioCtx;
  String? _ringingScheduleId;

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
        if (s.kind == 'alarm') {
          startAlarmRinging(s);
          _eventCtrl.add({
            'type': 'alarm_ringing',
            'schedule_id': s.id,
          });
        } else {
          _playBeep(s.priority == 'critical');
          _emitWebNotification(s.title, s.body);
        }
        _eventCtrl.add({
          'type': 'schedule_fired',
          'schedule_id': s.id,
          'kind': s.kind,
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

  @override
  Future<void> startAlarmRinging(DinglinSchedule schedule) async {
    _stopAlarmLoop();
    _ringingScheduleId = schedule.id;
    _playAlarmPulse();
    _alarmRingTimer = Timer.periodic(
      const Duration(milliseconds: 1800),
      (_) => _playAlarmPulse(),
    );
  }

  @override
  Future<void> stopRinging({String? scheduleId}) async {
    if (scheduleId != null &&
        _ringingScheduleId != null &&
        _ringingScheduleId != scheduleId) {
      return;
    }
    _stopAlarmLoop();
  }

  @override
  Future<void> setAppForeground(bool foreground) async {}

  @override
  Future<bool> supportsAutoStartSettings() async => false;

  void _stopAlarmLoop() {
    _alarmRingTimer?.cancel();
    _alarmRingTimer = null;
    _ringingScheduleId = null;
    try {
      _alarmAudioCtx?.close();
    } catch (_) {}
    _alarmAudioCtx = null;
  }

  void _playAlarmPulse() {
    try {
      final ctx = _alarmAudioCtx ??= web.AudioContext();
      if (ctx.state == 'suspended') {
        ctx.resume();
      }
      final now = ctx.currentTime;
      for (final offset in const [0.0, 0.24]) {
        final osc = ctx.createOscillator();
        final gain = ctx.createGain();
        osc.type = 'triangle';
        osc.frequency.value = offset == 0.0 ? 880 : 1046.5;
        gain.gain.setValueAtTime(0.001, now + offset);
        gain.gain.linearRampToValueAtTime(0.11, now + offset + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.001, now + offset + 0.2);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(now + offset);
        osc.stop(now + offset + 0.22);
      }
    } catch (_) {
      // Silently degrade when browser autoplay policy blocks sound before gesture.
    }
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
    _stopAlarmLoop();
    for (final t in _foregroundTimers.values) {
      t.cancel();
    }
    _foregroundTimers.clear();
    _eventCtrl.close();
  }
}
