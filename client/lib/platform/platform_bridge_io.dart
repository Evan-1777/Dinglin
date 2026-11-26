import 'dart:async';

import 'package:flutter/services.dart';

import '../models/models.dart';
import 'platform_bridge.dart';

PlatformBridge createPlatformBridge() => IoPlatformBridge();

class IoPlatformBridge implements PlatformBridge {
  static const MethodChannel _method = MethodChannel('dev.dinglin/native');
  static const EventChannel _events = EventChannel('dev.dinglin/events');

  final StreamController<Map<String, dynamic>> _eventCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _nativeSub;

  @override
  String get platformName => 'android';

  @override
  bool get supportsKeepAlive => true;

  @override
  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  }) async {
    try {
      await _method.invokeMethod('configure', {
        'server_url': serverUrl,
        'auth_token': authToken,
        'device_id': deviceId,
      });
      _nativeSub ??= _events.receiveBroadcastStream().listen((event) {
        if (event is Map) {
          _eventCtrl.add(Map<String, dynamic>.from(event));
        }
      }, onError: (_) {});
    } on MissingPluginException {
      // Non-Android VM / unit tests.
    }
  }

  @override
  Future<void> syncSchedules(List<DinglinSchedule> schedules) async {
    try {
      await _method.invokeMethod('syncSchedules', {
        'schedules': schedules.map((s) => s.toNativeJson()).toList(),
      });
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Future<void> showLocalNotification(DinglinNotification notification) async {
    try {
      await _method.invokeMethod('showNotification', {
        'id': notification.id,
        'title': notification.title,
        'body': notification.body,
        'priority': notification.priority,
      });
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Future<void> stopRinging() async {
    try {
      await _method.invokeMethod('stopRinging');
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Future<bool> hasGms() async {
    try {
      final res = await _method.invokeMethod<bool>('hasGms');
      return res ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<String?> getFcmToken() async {
    try {
      return await _method.invokeMethod<String>('getFcmToken');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> configureKeepAlive(KeepAliveConfig config) async {
    try {
      await _method.invokeMethod('configureKeepAlive', {
        'mode': config.mode.wireName,
        'interval_min': config.intervalMinutes,
      });
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Future<PermissionStatus> getPermissionStatus() async {
    try {
      final raw = await _method.invokeMapMethod<String, dynamic>('getPermissionStatus');
      if (raw == null) return PermissionStatus.allOk;
      return PermissionStatus.fromMap(raw);
    } on MissingPluginException {
      return PermissionStatus.allOk;
    }
  }

  @override
  Future<bool> requestPermission(String permission) async {
    try {
      final granted = await _method.invokeMethod<bool>('requestPermission', {
        'permission': permission,
      });
      return granted ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> updateSyncCursor(int lastSeq, {bool reset = false}) async {
    try {
      await _method.invokeMethod('updateSyncCursor', {
        'last_seq': lastSeq,
        'reset': reset,
      });
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Future<int> getSyncCursor() async {
    try {
      final res = await _method.invokeMethod<int>('getSyncCursor');
      return res ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  @override
  Future<String> getLocalTimezone() async {
    try {
      final tz = await _method.invokeMethod<String>('getLocalTimezone');
      if (tz != null && tz.isNotEmpty) return tz;
    } on MissingPluginException {
      // Fallback below.
    }
    return detectLocalIanaTimezone();
  }

  @override
  Future<void> updateDndPolicy({
    required bool enabled,
    required String start,
    required String end,
  }) async {
    try {
      await _method.invokeMethod('updateDndPolicy', {
        'enabled': enabled,
        'start': start,
        'end': end,
      });
    } on MissingPluginException {
      // Ignore in tests.
    }
  }

  @override
  Stream<Map<String, dynamic>> get nativeEvents => _eventCtrl.stream;

  @override
  void dispose() {
    _nativeSub?.cancel();
    _eventCtrl.close();
  }
}
