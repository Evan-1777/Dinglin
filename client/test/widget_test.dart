import 'dart:async';
import 'dart:convert';

import 'package:dinglin_client/main.dart';
import 'package:dinglin_client/models/models.dart';
import 'package:dinglin_client/platform/platform_bridge.dart';
import 'package:dinglin_client/services/api_client.dart';
import 'package:dinglin_client/state/app_store.dart';
import 'package:dinglin_client/widgets/app_shell.dart';
import 'package:dinglin_client/widgets/schedule_editor_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakePlatform implements PlatformBridge {
  _FakePlatform({
    this.keepAliveSupported = false,
    this.permissions = PermissionStatus.allOk,
  });

  final bool keepAliveSupported;
  PermissionStatus permissions;
  int nativeCursor = 0;
  String timezone = 'Asia/Shanghai';
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  final List<DinglinNotification> shownNotifications = [];
  final List<KeepAliveConfig> keepAliveConfigs = [];
  final List<String> requestedPermissions = [];
  int stopRingingCalls = 0;
  int startAlarmRingingCalls = 0;
  int resetCursorCalls = 0;
  bool autoStartSupported = false;
  final List<bool> foregroundEvents = [];

  void emitNativeEvent(Map<String, dynamic> event) => _ctrl.add(event);

  @override
  String get platformName => keepAliveSupported ? 'android' : 'web';
  @override
  bool get supportsKeepAlive => keepAliveSupported;
  @override
  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  }) async {}
  @override
  Future<void> syncSchedules(List<DinglinSchedule> schedules) async {}
  @override
  Future<void> showLocalNotification(DinglinNotification notification) async {
    shownNotifications.add(notification);
  }
  @override
  Future<void> startAlarmRinging(DinglinSchedule schedule) async {
    startAlarmRingingCalls++;
  }
  @override
  Future<void> stopRinging({String? scheduleId}) async {
    stopRingingCalls++;
  }
  @override
  Future<void> setAppForeground(bool foreground) async {
    foregroundEvents.add(foreground);
  }
  @override
  Future<bool> supportsAutoStartSettings() async => autoStartSupported;
  @override
  Future<bool> hasGms() async => keepAliveSupported;
  @override
  Future<String?> getFcmToken() async => null;
  @override
  Future<void> configureKeepAlive(KeepAliveConfig config) async {
    keepAliveConfigs.add(config);
  }
  @override
  Future<PermissionStatus> getPermissionStatus() async => permissions;
  @override
  Future<bool> requestPermission(String permission) async {
    requestedPermissions.add(permission);
    return true;
  }
  @override
  Future<void> updateSyncCursor(int lastSeq, {bool reset = false}) async {
    if (reset) {
      nativeCursor = 0;
      resetCursorCalls++;
    } else if (lastSeq > nativeCursor) {
      nativeCursor = lastSeq;
    }
  }
  @override
  Future<int> getSyncCursor() async => nativeCursor;
  @override
  Future<String> getLocalTimezone() async => timezone;
  @override
  Future<void> updateDndPolicy({
    required bool enabled,
    required String start,
    required String end,
  }) async {}
  @override
  Stream<Map<String, dynamic>> get nativeEvents => _ctrl.stream;
  @override
  void dispose() => _ctrl.close();
}

class _FakeWsChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeWsChannel() {
    _in = StreamController<dynamic>.broadcast();
    _out = StreamController<dynamic>();
  }

  late final StreamController<dynamic> _in;
  late final StreamController<dynamic> _out;

  void pushServerEvent(Map<String, dynamic> frame) =>
      _in.add(jsonEncode(frame));

  void drop() => _in.close();

  @override
  Stream<dynamic> get stream => _in.stream;
  @override
  WebSocketSink get sink => _FakeWsSink(_out);
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  Future<void> get ready => Future.value();
}

class _FakeWsSink implements WebSocketSink {
  _FakeWsSink(this._ctrl);
  final StreamController<dynamic> _ctrl;
  @override
  void add(dynamic data) => _ctrl.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _ctrl.addError(error, stackTrace);
  @override
  Future<dynamic> addStream(Stream<dynamic> stream) => _ctrl.addStream(stream);
  @override
  Future<dynamic> close([int? closeCode, String? closeReason]) => _ctrl.close();
  @override
  Future<dynamic> get done => _ctrl.done;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Responsive layout breakpoints switch at 960 and 640', () {
    expect(resolveShellLayout(1280), ShellLayout.desktop);
    expect(resolveShellLayout(768), ShellLayout.tablet);
    expect(resolveShellLayout(390), ShellLayout.mobile);
  });

  test('Cron preset builder and formatter round-trip cleanly', () {
    final weekdays = buildCronFromPreset(RepeatPreset.weekdays, 8, 30, '');
    expect(weekdays, '30 8 * * 1-5');
    expect(formatCronLabel(weekdays), '工作日');

    final daily = buildCronFromPreset(RepeatPreset.daily, 7, 0, '');
    expect(daily, '0 7 * * *');
    expect(formatCronLabel(daily), '每天');
  });

  test('SyncEngine cursor advancement, optimistic receipt & reconnect states',
      () async {
    final ws = _FakeWsChannel();
    var receiptCalled = false;

    final mockHttp = MockClient((req) async {
      if (req.url.path == '/api/v1/sync') {
        return http.Response(
          jsonEncode({
            'events': [
              {
                'seq': 5,
                'event_type': 'notification.created',
                'entity_id': 'n1',
                'payload': {
                  'id': 'n1',
                  'seq': 5,
                  'priority': 'critical',
                  'title': 'Server Alert',
                  'body': 'Disk 95%',
                  'status': 'unread',
                  'created_at': '2026-11-26T01:00:00Z',
                  'updated_at': '2026-11-26T01:00:00Z',
                },
              },
            ],
            'latest_seq': 5,
            'has_more': false,
          }),
          200,
        );
      }
      if (req.url.path == '/api/v1/notifications/n1/receipt') {
        receiptCalled = true;
        return http.Response(
          jsonEncode({
            'receipt': {
              'id': 'r1',
              'notification_id': 'n1',
              'action_id': 'ack',
              'action_label': '确认',
              'created_at': '2026-11-26T01:01:00Z',
            },
            'notification': {
              'id': 'n1',
              'seq': 5,
              'priority': 'critical',
              'title': 'Server Alert',
              'body': 'Disk 95%',
              'status': 'acked',
              'created_at': '2026-11-26T01:00:00Z',
              'updated_at': '2026-11-26T01:01:00Z',
            },
          }),
          201,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
    });

    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'dev_tok',
        httpClient: mockHttp,
      ),
      platformBridge: _FakePlatform(),
      wsFactory: (_) => ws,
    );

    await store.syncEngine.start();
    expect(store.syncEngine.lastSeq, 5);
    expect(store.notifications.length, 1);
    expect(store.connectionStatus, ConnectionStatus.connected);

    // Duplicate event via WS does not duplicate notification
    ws.pushServerEvent({
      'type': 'event',
      'seq': 6,
      'event_type': 'notification.created',
      'entity_id': 'n1',
      'data': {
        'id': 'n1',
        'seq': 5,
        'priority': 'critical',
        'title': 'Server Alert',
        'body': 'Disk 95%',
        'status': 'unread',
        'created_at': '2026-11-26T01:00:00Z',
        'updated_at': '2026-11-26T01:00:00Z',
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(store.notifications.length, 1);

    // Optimistic receipt updates status & invokes API
    await store.submitReceipt('n1', 'ack');
    expect(receiptCalled, isTrue);
    expect(store.notifications.first.status, 'acked');

    // Dropping WS transitions to reconnecting
    ws.drop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(store.connectionStatus, ConnectionStatus.reconnecting);

    store.dispose();
  });

  testWidgets(
      'Inbox preserves search focus across filtering and renders responsive shells',
      (tester) async {
    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'tok',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
      platformBridge: _FakePlatform(),
    );
    store.connectionStatus = ConnectionStatus.connected;
    store.notifications = [
      DinglinNotification(
        id: 'n1',
        seq: 1,
        priority: 'critical',
        title: 'Deploy Production',
        body: 'Release v2.0 ready',
        status: 'unread',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
      DinglinNotification(
        id: 'n2',
        seq: 2,
        priority: 'normal',
        title: 'Weekly Digest',
        body: 'Summary',
        status: 'read',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    ];

    // Desktop 1280px
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(DinglinApp(store: store));
    await tester.pump();
    expect(find.text('Dinglin'), findsOneWidget);
    expect(find.text('Deploy Production'), findsOneWidget);

    // Type in search box and verify focus is retained while filtering
    final searchField = find.byType(TextField);
    await tester.tap(searchField);
    await tester.enterText(searchField, 'Deploy');
    await tester.pump();
    expect(find.text('Deploy Production'), findsOneWidget);
    expect(find.text('Weekly Digest'), findsNothing);
    expect(tester.widget<TextField>(searchField).focusNode?.hasFocus, isTrue);

    // Mobile 390px shows bottom tab bar
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(DinglinApp(store: store));
    await tester.pump();
    expect(find.text('设置'), findsOneWidget);

    store.dispose();
  });

  testWidgets('ScheduleEditorModal validates required title', (tester) async {
    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'tok',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
      platformBridge: _FakePlatform(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ScheduleEditorModal(store: store),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('请输入标题'), findsOneWidget);

    store.dispose();
  });

  test('detectLocalIanaTimezone and DND cross-midnight filtering work', () {
    expect(detectLocalIanaTimezone(const Duration(hours: 8)), 'Asia/Shanghai');
    expect(detectLocalIanaTimezone(Duration.zero), 'UTC');

    final fakePlatform = _FakePlatform();
    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'tok',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
      platformBridge: fakePlatform,
    );
    store.settings = const DinglinSettings(
      dndEnabled: true,
      dndStart: '23:00',
      dndEnd: '07:00',
      defaultSnoozeMinutes: 10,
      retentionDays: 30,
    );

    expect(store.isWithinDnd(DateTime(2026, 11, 26, 23, 30)), isTrue);
    expect(store.isWithinDnd(DateTime(2026, 11, 26, 6, 45)), isTrue);
    expect(store.isWithinDnd(DateTime(2026, 11, 26, 12, 0)), isFalse);
    store.dispose();
  });

  test('Native events, stopRinging, keepAlive device sync, and disconnect closure',
      () async {
    final fakePlatform = _FakePlatform(keepAliveSupported: true);
    var syncCalls = 0;
    String? patchedPushMode;
    var readAllCalled = false;

    final mockHttp = MockClient((req) async {
      if (req.url.path == '/api/v1/sync') {
        syncCalls++;
        return http.Response(
          jsonEncode({'events': [], 'latest_seq': syncCalls, 'has_more': false}),
          200,
        );
      }
      if (req.url.path == '/api/v1/schedules/sc1/dismiss' ||
          req.url.path == '/api/v1/schedules/sc1/snooze') {
        return http.Response(
          jsonEncode({
            'schedule': {
              'id': 'sc1',
              'seq': 2,
              'kind': 'alarm',
              'title': 'Morning',
              'priority': 'critical',
              'schedule_type': 'once',
              'state': 'completed',
              'enabled': false,
              'created_at': '2026-11-26T00:00:00Z',
              'updated_at': '2026-11-26T00:00:00Z',
            },
          }),
          200,
        );
      }
      if (req.url.path == '/api/v1/devices/dev1' && req.method == 'PATCH') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        patchedPushMode = body['push_mode']?.toString();
        return http.Response(
          jsonEncode({
            'device': {
              'id': 'dev1',
              'name': 'Pixel',
              'platform': 'android',
              'has_gms': true,
              'push_mode': patchedPushMode ?? 'ws',
              'online': true,
              'created_at': '2026-11-26T00:00:00Z',
            },
          }),
          200,
        );
      }
      if (req.url.path == '/api/v1/notifications/read-all') {
        readAllCalled = true;
        return http.Response(jsonEncode({'updated': 1}), 200);
      }
      return http.Response('{}', 200);
    });

    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'dev_tok',
        httpClient: mockHttp,
      ),
      platformBridge: fakePlatform,
      wsFactory: (_) => _FakeWsChannel(),
    );
    store.serverUrl = 'http://localhost:8080';
    store.authToken = 'dev_tok';
    store.deviceId = 'dev1';

    fakePlatform.emitNativeEvent({'type': 'schedule_fired'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(syncCalls, greaterThanOrEqualTo(1));

    await store.dismissSchedule('sc1');
    await store.snoozeSchedule('sc1');
    expect(fakePlatform.stopRingingCalls, 2);

    await store.setKeepAliveMode(KeepAliveMode.polling);
    expect(patchedPushMode, 'ws');
    expect(fakePlatform.keepAliveConfigs.last.mode, KeepAliveMode.polling);

    // Reconcile native cursor advanced while app was backgrounded
    fakePlatform.nativeCursor = 42;
    await store.onAppResumed();
    expect(store.syncEngine.lastSeq, 42);

    store.notifications = [
      DinglinNotification(
        id: 'n-unread',
        seq: 1,
        priority: 'normal',
        title: 'Unread',
        body: '',
        status: 'unread',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    ];
    await store.markAllRead();
    expect(readAllCalled, isTrue);
    expect(store.notifications.first.status, 'read');

    await store.disconnect();
    expect(store.connectionStatus, ConnectionStatus.unconfigured);
    expect(store.serverUrl, isEmpty);
    expect(fakePlatform.resetCursorCalls, 1);

    store.dispose();
  });

  testWidgets(
      'Mobile 360x800 with top safe area renders all tabs and inspector without overflow',
      (tester) async {
    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'http://localhost:8080',
        token: 'tok',
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/v1/settings') {
            return http.Response(
              jsonEncode({
                'settings': {
                  'dnd_enabled': true,
                  'dnd_start': '22:00',
                  'dnd_end': '06:30',
                  'default_snooze_minutes': 15,
                  'retention_days': 45,
                },
              }),
              200,
            );
          }
          if (req.url.path == '/api/v1/notifications') {
            return http.Response(jsonEncode({'notifications': []}), 200);
          }
          if (req.url.path == '/api/v1/schedules') {
            return http.Response(jsonEncode({'schedules': []}), 200);
          }
          if (req.url.path == '/api/v1/sources') {
            return http.Response(jsonEncode({'sources': []}), 200);
          }
          if (req.url.path == '/api/v1/devices') {
            return http.Response(jsonEncode({'devices': []}), 200);
          }
          return http.Response('{}', 200);
        }),
      ),
      platformBridge: _FakePlatform(),
    );
    store.connectionStatus = ConnectionStatus.connected;
    store.notifications = [
      DinglinNotification(
        id: 'n1',
        seq: 1,
        priority: 'normal',
        title: 'Safe Area Check',
        body: 'Body content',
        status: 'unread',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    ];

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetViewPadding();
      tester.view.resetPadding();
    });

    await tester.pumpWidget(DinglinApp(store: store));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final inboxTitleTop = tester.getTopLeft(find.text('通知').first).dy;
    expect(inboxTitleTop, greaterThanOrEqualTo(44));

    // Open mobile inspector
    await tester.tap(find.text('Safe Area Check'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final inspectorTitleTop = tester.getTopLeft(find.text('通知详情')).dy;
    expect(inspectorTitleTop, greaterThanOrEqualTo(44));
    store.closeInspector();
    await tester.pump();

    // Schedules tab
    await tester.tap(find.text('调度'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('调度').first).dy, greaterThanOrEqualTo(44));

    // Settings tab + async settings sync
    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('设置').first).dy, greaterThanOrEqualTo(44));

    await store.refreshAll();
    await tester.pump();
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('06:30'), findsOneWidget);

    store.dispose();
  });

  testWidgets(
      'Mobile 390px renders source filter bar and collapsible search cleanly',
      (tester) async {
    final store = AppStore(platformBridge: _FakePlatform());
    store.connectionStatus = ConnectionStatus.connected;
    final now = DateTime.now().toUtc();
    store.sources = [
      DinglinSource(
        id: 's1',
        slug: 'github-ci',
        name: 'GitHub CI',
        kind: 'webhook',
        color: '#007AFF',
        tokenPrefix: 'src_1234',
        callbackUrl: '',
        enabled: true,
        createdAt: now,
      ),
      DinglinSource(
        id: 's2',
        slug: 'claude-bot',
        name: 'Claude Agent',
        kind: 'agent',
        color: '#34C759',
        tokenPrefix: 'src_5678',
        callbackUrl: '',
        enabled: true,
        createdAt: now,
      ),
    ];
    store.notifications = [
      DinglinNotification(
        id: 'n1',
        seq: 1,
        sourceId: 's1',
        priority: 'normal',
        title: 'Build Passed',
        body: 'main branch ok',
        status: 'unread',
        createdAt: now,
        updatedAt: now,
      ),
      DinglinNotification(
        id: 'n2',
        seq: 2,
        sourceId: 's2',
        priority: 'normal',
        title: 'Agent Task Ready',
        body: 'awaiting review',
        status: 'unread',
        createdAt: now,
        updatedAt: now,
      ),
    ];

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(DinglinApp(store: store));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('全部来源'), findsOneWidget);
    expect(find.text('Build Passed'), findsOneWidget);
    expect(find.text('Agent Task Ready'), findsOneWidget);

    // Filter by Claude Agent source chip (scroll horizontal filter bar if needed under Ahem test font)
    await tester.drag(find.text('全部来源'), const Offset(-120, 0));
    await tester.pump();
    await tester.tap(find.text('Claude Agent').first);
    await tester.pump();
    expect(find.text('Agent Task Ready'), findsOneWidget);
    expect(find.text('Build Passed'), findsNothing);

    // Clear source filter and test mobile collapsible search
    await tester.drag(find.text('GitHub CI').first, const Offset(120, 0));
    await tester.pump();
    await tester.tap(find.text('全部来源'));
    await tester.pump();
    expect(find.text('Build Passed'), findsOneWidget);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Build');
    await tester.pump();
    expect(find.text('Build Passed'), findsOneWidget);
    expect(find.text('Agent Task Ready'), findsNothing);

    await tester.tap(find.byTooltip('收起搜索'));
    await tester.pump();
    expect(find.text('Agent Task Ready'), findsOneWidget);

    store.dispose();
  });

  testWidgets(
      'SettingsScreen renders Android keep-alive/permissions, remote device SSOT & source snippets',
      (tester) async {
    String? patchedDevicePayload;
    final fakePlatform = _FakePlatform(
      keepAliveSupported: true,
      permissions: const PermissionStatus(
        notifications: true,
        batteryOptimization: false,
        exactAlarm: true,
        fullScreenIntent: false,
      ),
    );
    final mockHttp = MockClient((req) async {
      if (req.url.path == '/api/v1/devices/dev-remote') {
        patchedDevicePayload = req.body;
        return http.Response(
          jsonEncode({
            'device': {
              'id': 'dev-remote',
              'name': 'Backup Phone',
              'platform': 'android',
              'has_gms': true,
              'push_mode': 'ws',
              'online': false,
              'created_at': '2026-11-26T00:00:00Z',
            },
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });

    final now = DateTime.now().toUtc();
    final store = AppStore(
      apiClient: ApiClient(
        baseUrl: 'https://dinglin.test',
        token: 'dev_tok',
        httpClient: mockHttp,
      ),
      platformBridge: fakePlatform,
    );
    store.serverUrl = 'https://dinglin.test';
    store.authToken = 'dev_tok';
    store.deviceId = 'dev-self';
    store.connectionStatus = ConnectionStatus.connected;
    store.permissionStatus = fakePlatform.permissions;
    store.sources = [
      DinglinSource(
        id: 's-wh',
        slug: 'ci-hook',
        name: 'CI Hook',
        kind: 'webhook',
        color: '#007AFF',
        tokenPrefix: 'src_wh01',
        callbackUrl: '',
        enabled: true,
        createdAt: now,
      ),
      DinglinSource(
        id: 's-ag',
        slug: 'agent-box',
        name: 'Agent Box',
        kind: 'agent',
        color: '#34C759',
        tokenPrefix: 'src_ag01',
        callbackUrl: '',
        enabled: true,
        createdAt: now,
      ),
    ];
    store.devices = [
      DinglinDevice(
        id: 'dev-self',
        name: 'Pixel 8',
        platform: 'android',
        hasGms: true,
        pushMode: 'fcm',
        online: true,
        hasFcmToken: true,
        createdAt: now,
      ),
      DinglinDevice(
        id: 'dev-remote',
        name: 'Backup Phone',
        platform: 'android',
        hasGms: true,
        pushMode: 'fcm',
        online: false,
        hasFcmToken: false,
        createdAt: now,
      ),
    ];

    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(DinglinApp(store: store));
    await tester.tap(find.byTooltip('设置').first);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Gateway disconnect action present when connected
    expect(find.text('断开'), findsOneWidget);

    // Android Reception Policy & Permissions panel
    expect(find.text('接收策略与权限'), findsOneWidget);
    expect(find.text('忽略电池优化'), findsOneWidget);
    expect(find.text('锁屏全屏提醒'), findsOneWidget);
    await tester.tap(find.text('定时拉取'));
    await tester.pump();
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('15m'), findsOneWidget);
    expect(find.text('30m'), findsOneWidget);

    // Single-permission button invokes requestPermission once for that key
    await tester.tap(find.text('授权').first);
    await tester.pump();
    expect(fakePlatform.requestedPermissions, ['battery_optimization']);

    // Remote device WS toggle triggers PATCH /api/v1/devices/dev-remote
    final mainScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Backup Phone'),
      200,
      scrollable: mainScrollable,
    );
    await tester.ensureVisible(find.text('WS').last);
    await tester.pump();
    await tester.tap(find.text('WS').last);
    await tester.pump();
    expect(patchedDevicePayload, contains('"push_mode":"ws"'));

    // Source snippet modal for webhook & agent
    await tester.scrollUntilVisible(
      find.byTooltip('接入片段').first,
      -200,
      scrollable: mainScrollable,
    );
    await tester.ensureVisible(find.byTooltip('接入片段').first);
    await tester.pump();
    await tester.tap(find.byTooltip('接入片段').first);
    await tester.pump();
    expect(find.textContaining('/api/v1/webhook/ci-hook'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pump();

    await tester.ensureVisible(find.byTooltip('接入片段').last);
    await tester.pump();
    await tester.tap(find.byTooltip('接入片段').last);
    await tester.pump();
    expect(find.textContaining('streamable-http'), findsOneWidget);
    await tester.tap(find.text('MCP Stdio'));
    await tester.pump();
    expect(find.textContaining('mcp-stdio'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pump();

    store.dispose();
  });

  testWidgets(
      'SettingsScreen in Web mode hides Android permissions and shows browser notification permission',
      (tester) async {
    final fakePlatform = _FakePlatform(
      keepAliveSupported: false,
      permissions: const PermissionStatus(
        notifications: false,
        batteryOptimization: true,
        exactAlarm: true,
        fullScreenIntent: true,
      ),
    );
    final store = AppStore(platformBridge: fakePlatform);
    store.permissionStatus = fakePlatform.permissions;
    store.activeTab = AppTab.settings;

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(DinglinApp(store: store));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('推送通道'), findsOneWidget);
    expect(find.text('浏览器通知'), findsOneWidget);
    expect(find.text('忽略电池优化'), findsNothing);
    expect(find.text('定时拉取'), findsNothing);

    await tester.tap(find.text('授权'));
    await tester.pump();
    expect(fakePlatform.requestedPermissions, ['notifications']);

    store.dispose();
  });
}
