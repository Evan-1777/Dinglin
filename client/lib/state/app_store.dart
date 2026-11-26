import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../platform/platform_bridge.dart';
import '../services/api_client.dart';
import '../services/sync_engine.dart';

enum AppTab { inbox, schedules, settings }

enum InboxFilter { all, unread, critical }

class AppStore extends ChangeNotifier {
  AppStore({
    ApiClient? apiClient,
    PlatformBridge? platformBridge,
    WsChannelFactory? wsFactory,
  })  : api = apiClient ?? ApiClient(baseUrl: '', token: ''),
        platform = platformBridge ?? PlatformBridge() {
    syncEngine = SyncEngine(
      api: api,
      onEvent: _applySyncEvent,
      onStatusChanged: (status) {
        if (connectionStatus != status) {
          connectionStatus = status;
          notifyListeners();
        }
      },
      channelFactory: wsFactory,
    );
  }

  final ApiClient api;
  final PlatformBridge platform;
  late final SyncEngine syncEngine;

  AppTab activeTab = AppTab.inbox;
  InboxFilter inboxFilter = InboxFilter.all;
  String scheduleKindFilter = 'all';
  String? selectedSourceId;
  String searchQuery = '';

  String? selectedNotificationId;
  String? selectedScheduleId;

  ConnectionStatus connectionStatus = ConnectionStatus.unconfigured;
  ThemePreference themePreference = ThemePreference.system;

  bool isLoading = false;
  String? errorMessage;
  String? toastMessage;
  Timer? _toastTimer;

  String serverUrl = '';
  String authToken = '';
  String deviceId = '';

  List<DinglinNotification> notifications = const [];
  List<DinglinSchedule> schedules = const [];
  List<DinglinSource> sources = const [];
  List<DinglinDevice> devices = const [];
  DinglinSettings settings = DinglinSettings.defaults;
  final Map<String, List<DinglinReceipt>> receiptsByNotification = {};

  Future<void> init({String? defaultWebOrigin}) async {
    final saved = await syncEngine.loadPersisted();
    themePreference = saved.theme;
    serverUrl = saved.serverUrl.isNotEmpty
        ? saved.serverUrl
        : (defaultWebOrigin ?? '');
    authToken = saved.token;
    deviceId = saved.deviceId;
    api.updateCredentials(baseUrl: serverUrl, token: authToken);

    if (serverUrl.isNotEmpty && authToken.isNotEmpty) {
      await _initPlatform();
      await refreshAll();
      await syncEngine.start();
    } else {
      connectionStatus = ConnectionStatus.unconfigured;
      notifyListeners();
    }
  }

  Future<void> _initPlatform() async {
    await platform.initialize(
      serverUrl: serverUrl,
      authToken: authToken,
      deviceId: deviceId,
    );
    if (deviceId.isNotEmpty) {
      final fcm = await platform.getFcmToken();
      if (fcm != null && fcm.isNotEmpty) {
        final gms = await platform.hasGms();
        try {
          await api.registerFcmToken(deviceId, fcm, gms);
        } catch (_) {}
      }
    }
  }

  Future<void> connectWithToken({
    required String url,
    required String token,
    String devId = '',
  }) async {
    serverUrl = url.trim();
    authToken = token.trim();
    deviceId = devId;
    await syncEngine.saveCredentials(
      serverUrl: serverUrl,
      token: authToken,
      deviceId: deviceId,
    );
    errorMessage = null;
    await _initPlatform();
    await refreshAll();
    await syncEngine.start();
    showToast('已连接至网关');
  }

  Future<void> connectWithPairingCode({
    required String url,
    required String code,
    required String deviceName,
  }) async {
    api.updateCredentials(baseUrl: url.trim(), token: '');
    final gms = await platform.hasGms();
    final res = await api.pairDevice(
      code: code.trim(),
      name: deviceName.trim(),
      platform: platform.platformName,
      hasGms: gms,
    );
    await connectWithToken(
      url: url.trim(),
      token: res.deviceToken,
      devId: res.device.id,
    );
  }

  Future<void> refreshAll() async {
    if (api.baseUrl.isEmpty || api.token.isEmpty) return;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.listNotifications(),
        api.listSchedules(),
        api.listSources(),
        api.listDevices(),
        api.getSettings(),
      ]);
      notifications = results[0] as List<DinglinNotification>;
      schedules = results[1] as List<DinglinSchedule>;
      sources = results[2] as List<DinglinSource>;
      devices = results[3] as List<DinglinDevice>;
      settings = results[4] as DinglinSettings;
      await platform.syncSchedules(schedules);
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void setTab(AppTab tab) {
    if (activeTab == tab) return;
    activeTab = tab;
    if (tab != AppTab.inbox) selectedNotificationId = null;
    if (tab != AppTab.schedules) selectedScheduleId = null;
    notifyListeners();
  }

  void setInboxFilter(InboxFilter f) {
    inboxFilter = f;
    notifyListeners();
  }

  void setScheduleKindFilter(String kind) {
    scheduleKindFilter = kind;
    notifyListeners();
  }

  void setSelectedSource(String? id) {
    selectedSourceId = id;
    activeTab = AppTab.inbox;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    if (searchQuery == q) return;
    searchQuery = q;
    notifyListeners();
  }

  void selectNotification(String? id) {
    selectedNotificationId = id;
    notifyListeners();
    if (id != null) {
      loadReceipts(id);
    }
  }

  void selectSchedule(String? id) {
    selectedScheduleId = id;
    notifyListeners();
  }

  void closeInspector() {
    selectedNotificationId = null;
    selectedScheduleId = null;
    notifyListeners();
  }

  Future<void> setThemePreference(ThemePreference pref) async {
    themePreference = pref;
    await syncEngine.saveTheme(pref);
    notifyListeners();
  }

  void showToast(String message) {
    toastMessage = message;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      toastMessage = null;
      notifyListeners();
    });
  }

  DinglinSource? sourceById(String? id) {
    if (id == null) return null;
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  int get unreadCount => notifications.where((n) => n.isUnread).length;

  int get activeScheduleCount =>
      schedules.where((s) => s.enabled && s.state == 'active').length;

  List<DinglinNotification> get filteredNotifications {
    final q = searchQuery.trim().toLowerCase();
    return notifications.where((n) {
      if (selectedSourceId != null && n.sourceId != selectedSourceId) {
        return false;
      }
      if (inboxFilter == InboxFilter.unread && !n.isUnread) return false;
      if (inboxFilter == InboxFilter.critical && !n.isCritical) return false;
      if (q.isNotEmpty) {
        final inTitle = n.title.toLowerCase().contains(q);
        final inBody = n.body.toLowerCase().contains(q);
        final inCat = n.category.toLowerCase().contains(q);
        if (!inTitle && !inBody && !inCat) return false;
      }
      return true;
    }).toList();
  }

  List<DinglinSchedule> get filteredSchedules {
    if (scheduleKindFilter == 'all') return schedules;
    return schedules.where((s) => s.kind == scheduleKindFilter).toList();
  }

  DinglinNotification? get selectedNotification {
    if (selectedNotificationId == null) return null;
    for (final n in notifications) {
      if (n.id == selectedNotificationId) return n;
    }
    return null;
  }

  Future<void> loadReceipts(String notificationId) async {
    try {
      final list = await api.listReceipts(notificationId);
      receiptsByNotification[notificationId] = list;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> submitReceipt(
    String notificationId,
    String actionId, {
    int? snoozeMinutes,
    String? toastLabel,
  }) async {
    // Optimistic status update
    final prev = notifications;
    final optimisticStatus = switch (actionId) {
      'read' => 'read',
      'dismiss' => 'dismissed',
      'snooze' => 'snoozed',
      _ => 'acked',
    };
    notifications = notifications
        .map((n) => n.id == notificationId
            ? n.copyWith(status: optimisticStatus)
            : n)
        .toList();
    notifyListeners();

    try {
      final (receipt, updated) = await api.submitReceipt(
        notificationId: notificationId,
        actionId: actionId,
        snoozeMinutes: snoozeMinutes,
      );
      _upsertNotification(updated);
      final existing =
          List<DinglinReceipt>.from(receiptsByNotification[notificationId] ?? []);
      if (!existing.any((r) => r.id == receipt.id)) {
        existing.add(receipt);
      }
      receiptsByNotification[notificationId] = existing;
      showToast(toastLabel ?? receipt.actionLabel);
    } catch (e) {
      notifications = prev;
      errorMessage = e.toString();
      notifyListeners();
    }
  }

  Future<void> createSchedule(Map<String, dynamic> payload) async {
    final created = await api.createSchedule(payload);
    _upsertSchedule(created);
    await platform.syncSchedules(schedules);
    showToast('已创建调度');
  }

  Future<void> updateSchedule(String id, Map<String, dynamic> payload) async {
    final updated = await api.updateSchedule(id, payload);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
    showToast('已保存调度');
  }

  Future<void> toggleSchedule(String id, bool enabled) async {
    final updated = await api.toggleSchedule(id, enabled);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
  }

  Future<void> snoozeSchedule(String id, {int? minutes}) async {
    final updated = await api.snoozeSchedule(id, minutes: minutes);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
    showToast('已延后');
  }

  Future<void> dismissSchedule(String id) async {
    final updated = await api.dismissSchedule(id);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
    showToast('已关闭');
  }

  Future<void> countdownAction(String id, String action) async {
    final updated = await api.countdownAction(id, action);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
  }

  Future<void> deleteSchedule(String id) async {
    await api.deleteSchedule(id);
    schedules = schedules.where((s) => s.id != id).toList();
    if (selectedScheduleId == id) selectedScheduleId = null;
    await platform.syncSchedules(schedules);
    notifyListeners();
    showToast('已删除调度');
  }

  Future<CreatedSourceResult> createSource({
    required String name,
    required String slug,
    required String kind,
    required String color,
    String callbackUrl = '',
  }) async {
    final res = await api.createSource(
      name: name,
      slug: slug,
      kind: kind,
      color: color,
      callbackUrl: callbackUrl,
    );
    sources = [...sources, res.source];
    notifyListeners();
    return res;
  }

  Future<void> updateSource(
    String id, {
    String? name,
    String? color,
    String? callbackUrl,
    bool? enabled,
  }) async {
    final updated = await api.updateSource(
      id,
      name: name,
      color: color,
      callbackUrl: callbackUrl,
      enabled: enabled,
    );
    sources = sources.map((s) => s.id == id ? updated : s).toList();
    notifyListeners();
    showToast('来源已更新');
  }

  Future<String> rotateSourceToken(String id) async {
    final tok = await api.rotateSourceToken(id);
    sources = await api.listSources();
    notifyListeners();
    return tok;
  }

  Future<void> deleteSource(String id) async {
    await api.deleteSource(id);
    sources = sources.where((s) => s.id != id).toList();
    if (selectedSourceId == id) selectedSourceId = null;
    notifyListeners();
    showToast('已删除来源');
  }

  Future<PairingCodeResult> createPairingCode() => api.createPairingCode();

  Future<void> testDevicePush(String id) async {
    final ch = await api.testDevicePush(id);
    showToast('测试推送已发送 ($ch)');
  }

  Future<void> deleteDevice(String id) async {
    await api.deleteDevice(id);
    devices = devices.where((d) => d.id != id).toList();
    notifyListeners();
    showToast('已解绑设备');
  }

  Future<void> saveSettings(DinglinSettings next) async {
    settings = await api.updateSettings(next);
    notifyListeners();
    showToast('偏好设置已保存');
  }

  void _applySyncEvent(SyncEvent ev) {
    switch (ev.eventType) {
      case 'notification.created':
        final n = DinglinNotification.fromJson(ev.payload);
        final isNew = !notifications.any((x) => x.id == n.id);
        _upsertNotification(n);
        if (isNew) {
          platform.showLocalNotification(n);
        }
      case 'receipt.created':
        if (ev.payload['notification'] is Map<String, dynamic>) {
          _upsertNotification(DinglinNotification.fromJson(
              ev.payload['notification'] as Map<String, dynamic>));
        }
        if (ev.payload['receipt'] is Map<String, dynamic>) {
          final r = DinglinReceipt.fromJson(
              ev.payload['receipt'] as Map<String, dynamic>);
          final list = List<DinglinReceipt>.from(
              receiptsByNotification[r.notificationId] ?? []);
          if (!list.any((x) => x.id == r.id)) {
            list.add(r);
            receiptsByNotification[r.notificationId] = list;
          }
          notifyListeners();
        }
      case 'schedule.upsert':
        final sc = DinglinSchedule.fromJson(ev.payload);
        _upsertSchedule(sc);
        platform.syncSchedules(schedules);
      case 'schedule.delete':
        schedules = schedules.where((s) => s.id != ev.entityId).toList();
        platform.syncSchedules(schedules);
        notifyListeners();
      case 'device.test':
        showToast((ev.payload['title'] ?? '测试推送已送达').toString());
    }
  }

  void _upsertNotification(DinglinNotification n) {
    final idx = notifications.indexWhere((x) => x.id == n.id);
    if (idx >= 0) {
      final copy = List<DinglinNotification>.from(notifications);
      copy[idx] = n;
      notifications = copy;
    } else {
      notifications = [n, ...notifications];
    }
    notifyListeners();
  }

  void _upsertSchedule(DinglinSchedule s) {
    final idx = schedules.indexWhere((x) => x.id == s.id);
    if (idx >= 0) {
      final copy = List<DinglinSchedule>.from(schedules);
      copy[idx] = s;
      schedules = copy;
    } else {
      schedules = [s, ...schedules];
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    syncEngine.stop();
    platform.dispose();
    super.dispose();
  }
}
