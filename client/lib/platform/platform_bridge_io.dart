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
  Stream<Map<String, dynamic>> get nativeEvents => _eventCtrl.stream;

  @override
  void dispose() {
    _nativeSub?.cancel();
    _eventCtrl.close();
  }
}
