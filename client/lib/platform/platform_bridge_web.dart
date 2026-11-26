import 'dart:async';

import 'package:web/web.dart' as web;

import '../models/models.dart';
import 'platform_bridge.dart';

PlatformBridge createPlatformBridge() => WebPlatformBridge();

class WebPlatformBridge implements PlatformBridge {
  final StreamController<Map<String, dynamic>> _eventCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  final Map<String, Timer> _foregroundTimers = {};

  @override
  String get platformName => 'web';

  @override
  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  }) async {
    try {
      if (web.Notification.permission == 'default') {
        web.Notification.requestPermission();
      }
    } catch (_) {
      // Notification API unavailable in restricted contexts.
    }
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
