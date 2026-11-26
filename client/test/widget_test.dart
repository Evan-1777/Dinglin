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
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  @override
  String get platformName => 'web';
  @override
  Future<void> initialize({
    required String serverUrl,
    required String authToken,
    required String deviceId,
  }) async {}
  @override
  Future<void> syncSchedules(List<DinglinSchedule> schedules) async {}
  @override
  Future<void> showLocalNotification(DinglinNotification notification) async {}
  @override
  Future<void> stopRinging() async {}
  @override
  Future<bool> hasGms() async => false;
  @override
  Future<String?> getFcmToken() async => null;
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
}
