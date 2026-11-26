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
      onSeqAdvanced: (seq) {
        unawaited(platform.updateSyncCursor(seq));
      },
      channelFactory: wsFactory,
    );
    _nativeEventSub = platform.nativeEvents.listen(_handleNativeEvent);
  }

  final ApiClient api;
  final PlatformBridge platform;
  late final SyncEngine syncEngine;
  StreamSubscription<Map<String, dynamic>>? _nativeEventSub;

  AppTab activeTab = AppTab.inbox;
  InboxFilter inboxFilter = InboxFilter.all;
  String scheduleKindFilter = 'all';
  String? selectedSourceId;
  String searchQuery = '';

  String? selectedNotificationId;
  String? selectedScheduleId;

  ConnectionStatus connectionStatus = ConnectionStatus.unconfigured;
  ThemePreference themePreference = ThemePreference.system;
  KeepAliveConfig keepAliveConfig = const KeepAliveConfig();
  PermissionStatus permissionStatus = PermissionStatus.allOk;
  String localTimezone = detectLocalIanaTimezone();

  bool isLoading = false;
  String? errorMessage;
  String? toastMessage;
  bool toastIsError = false;
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
    keepAliveConfig = saved.keepAlive;
    serverUrl = saved.serverUrl.isNotEmpty
        ? saved.serverUrl
        : (defaultWebOrigin ?? '');
    authToken = saved.token;
    deviceId = saved.deviceId;
    api.updateCredentials(baseUrl: serverUrl, token: authToken);
    localTimezone = await platform.getLocalTimezone();
    await _reconcileSyncCursor();
    await refreshPermissions();

    if (serverUrl.isNotEmpty && authToken.isNotEmpty) {
      await _initPlatform();
      await platform.configureKeepAlive(keepAliveConfig);
      await refreshAll();
      await syncEngine.start();
    } else {
      connectionStatus = ConnectionStatus.unconfigured;
      notifyListeners();
    }
  }

  Future<void> _reconcileSyncCursor() async {
    final nativeSeq = await platform.getSyncCursor();
    if (nativeSeq > syncEngine.lastSeq) {
      await syncEngine.advanceSeqFromExternal(nativeSeq);
    } else if (syncEngine.lastSeq > nativeSeq) {
      await platform.updateSyncCursor(syncEngine.lastSeq);
    }
  }

  Future<void> _initPlatform() async {
    await platform.initialize(
      serverUrl: serverUrl,
      authToken: authToken,
      deviceId: deviceId,
    );
    if (deviceId.isNotEmpty && keepAliveConfig.mode == KeepAliveMode.auto) {
      final fcm = await platform.getFcmToken();
      if (fcm != null && fcm.isNotEmpty) {
        final gms = await platform.hasGms();
        try {
          await api.registerFcmToken(deviceId, fcm, gms);
        } catch (_) {}
      }
    }
  }

  Future<void> onAppResumed() async {
    localTimezone = await platform.getLocalTimezone();
    await _reconcileSyncCursor();
    await refreshPermissions();
    if (serverUrl.isNotEmpty && authToken.isNotEmpty) {
      await syncEngine.resume();
    }
  }

  Future<void> disconnect() async {
    keepAliveConfig = const KeepAliveConfig();
    await syncEngine.saveKeepAlive(keepAliveConfig);
    await platform.configureKeepAlive(keepAliveConfig);
    await platform.updateSyncCursor(0, reset: true);
    await syncEngine.clearCredentials();
    serverUrl = '';
    authToken = '';
    deviceId = '';
    notifications = const [];
    schedules = const [];
    sources = const [];
    devices = const [];
    receiptsByNotification.clear();
    selectedNotificationId = null;
    selectedScheduleId = null;
    selectedSourceId = null;
    errorMessage = null;
    connectionStatus = ConnectionStatus.unconfigured;
    notifyListeners();
    showToast('已断开连接');
  }

  void _handleNativeEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'schedule_fired':
      case 'fcm_wakeup':
      case 'background_schedule_changed':
        unawaited(_syncOnceSafe());
      case 'background_synced':
        final seq = (event['latest_seq'] as num?)?.toInt() ?? 0;
        if (seq > 0) {
          unawaited(syncEngine.advanceSeqFromExternal(seq));
        }
        unawaited(_syncOnceSafe());
      case 'fcm_token':
        final tok = event['token']?.toString() ?? '';
        if (tok.isNotEmpty &&
            deviceId.isNotEmpty &&
            keepAliveConfig.mode == KeepAliveMode.auto) {
          unawaited(
            api.registerFcmToken(deviceId, tok, true).catchError((_) {}),
          );
        }
    }
  }

  Future<void> _syncOnceSafe() async {
    try {
      await syncEngine.syncOnce();
    } catch (_) {}
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
      await platform.updateDndPolicy(
        enabled: settings.dndEnabled,
        start: settings.dndStart,
        end: settings.dndEnd,
      );
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

  void showToast(String message, {bool isError = false}) {
    toastMessage = message;
    toastIsError = isError;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () {
      toastMessage = null;
      toastIsError = false;
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

  int unreadCountForSource(String sourceId) =>
      notifications.where((n) => n.sourceId == sourceId && n.isUnread).length;

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
    await platform.stopRinging();
    final updated = await api.snoozeSchedule(id, minutes: minutes);
    _upsertSchedule(updated);
    await platform.syncSchedules(schedules);
    showToast('已延后');
  }

  Future<void> dismissSchedule(String id) async {
    await platform.stopRinging();
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

  Future<void> updateDevice(
    String id, {
    String? name,
    String? pushMode,
  }) async {
    final updated = await api.updateDevice(id, name: name, pushMode: pushMode);
    devices = devices.map((d) => d.id == id ? updated : d).toList();
    notifyListeners();
    showToast('设备已更新');
  }

  Future<void> markAllRead({String? sourceId}) async {
    final prev = notifications;
    notifications = notifications
        .map((n) => n.isUnread && (sourceId == null || n.sourceId == sourceId)
            ? n.copyWith(status: 'read')
            : n)
        .toList();
    notifyListeners();
    try {
      await api.markAllNotificationsRead(sourceId: sourceId);
      showToast('已全部标为已读');
    } catch (e) {
      notifications = prev;
      errorMessage = e.toString();
      notifyListeners();
      showToast(e.toString(), isError: true);
    }
  }

  Future<void> refreshPermissions() async {
    permissionStatus = await platform.getPermissionStatus();
    notifyListeners();
  }

  Future<bool> requestPermission(String key) async {
    final ok = await platform.requestPermission(key);
    await refreshPermissions();
    return ok;
  }

  Future<void> setKeepAliveMode(KeepAliveMode mode) async {
    keepAliveConfig = keepAliveConfig.copyWith(mode: mode);
    await syncEngine.saveKeepAlive(keepAliveConfig);
    await platform.configureKeepAlive(keepAliveConfig);
    notifyListeners();
    if (deviceId.isNotEmpty && platform.supportsKeepAlive) {
      String targetPushMode;
      if (mode == KeepAliveMode.auto) {
        final gms = await platform.hasGms();
        targetPushMode = gms ? 'fcm' : 'ws';
      } else {
        targetPushMode = 'ws';
      }
      try {
        await updateDevice(deviceId, pushMode: targetPushMode);
      } catch (_) {}
    }
  }

  Future<void> setKeepAliveInterval(int minutes) async {
    final clamped = minutes < 5 ? 5 : minutes;
    keepAliveConfig = keepAliveConfig.copyWith(intervalMinutes: clamped);
    await syncEngine.saveKeepAlive(keepAliveConfig);
    await platform.configureKeepAlive(keepAliveConfig);
    notifyListeners();
  }

  bool isWithinDnd([DateTime? now]) {
    if (!settings.dndEnabled) return false;
    final startMin = _parseHhMm(settings.dndStart);
    final endMin = _parseHhMm(settings.dndEnd);
    if (startMin == null || endMin == null || startMin == endMin) return false;
    final local = (now ?? DateTime.now()).toLocal();
    final curMin = local.hour * 60 + local.minute;
    if (startMin < endMin) {
      return curMin >= startMin && curMin < endMin;
    }
    return curMin >= startMin || curMin < endMin;
  }

  static int? _parseHhMm(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return h * 60 + m;
  }

  Future<void> saveSettings(DinglinSettings next) async {
    settings = await api.updateSettings(next);
    await platform.updateDndPolicy(
      enabled: settings.dndEnabled,
      start: settings.dndStart,
      end: settings.dndEnd,
    );
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
          final effective = (n.priority == 'normal' && isWithinDnd())
              ? n.copyWith(priority: 'silent')
              : n;
          platform.showLocalNotification(effective);
        }
      case 'notifications.read_all':
        final targetSrc = ev.payload['source_id']?.toString() ?? '';
        notifications = notifications
            .map((n) => n.isUnread && (targetSrc.isEmpty || n.sourceId == targetSrc)
                ? n.copyWith(status: 'read')
                : n)
            .toList();
        notifyListeners();
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
        if (sc.state != 'ringing') {
          platform.stopRinging();
        }
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
    _nativeEventSub?.cancel();
    syncEngine.stop();
    platform.dispose();
    super.dispose();
  }
}
