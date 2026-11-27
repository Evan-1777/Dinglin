import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/models.dart';
import 'api_client.dart';

typedef WsChannelFactory = WebSocketChannel Function(Uri uri);

/// Manages incremental /api/v1/sync cursor catch-up and fixed-30s-ping WebSocket streaming.
class SyncEngine {
  SyncEngine({
    required this.api,
    required this.onEvent,
    required this.onStatusChanged,
    this.onSeqAdvanced,
    WsChannelFactory? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  static const _kServerUrl = 'dinglin.server_url';
  static const _kAuthToken = 'dinglin.auth_token';
  static const _kDeviceId = 'dinglin.device_id';
  static const _kLastSeq = 'dinglin.last_seq';
  static const _kThemePref = 'dinglin.theme_pref';
  static const _kKeepAliveMode = 'dinglin.keepalive_mode';
  static const _kKeepAliveInterval = 'dinglin.keepalive_interval_min';

  static const List<int> _backoffSeconds = [2, 4, 8, 30];

  final ApiClient api;
  final void Function(SyncEvent event) onEvent;
  final void Function(ConnectionStatus status) onStatusChanged;
  final void Function(int seq)? onSeqAdvanced;
  final WsChannelFactory _channelFactory;

  int _lastSeq = 0;
  int _reconnectAttempt = 0;
  bool _stopped = false;
  bool _pausedForBackground = false;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  int get lastSeq => _lastSeq;

  Future<({
    String serverUrl,
    String token,
    String deviceId,
    int lastSeq,
    ThemePreference theme,
    KeepAliveConfig keepAlive,
  })> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kServerUrl) ?? '';
    final tok = prefs.getString(_kAuthToken) ?? '';
    final devId = prefs.getString(_kDeviceId) ?? '';
    _lastSeq = prefs.getInt(_kLastSeq) ?? 0;
    final themeStr = prefs.getString(_kThemePref) ?? 'system';
    final theme = ThemePreference.values.firstWhere(
      (e) => e.name == themeStr,
      orElse: () => ThemePreference.system,
    );
    final keepAlive = KeepAliveConfig(
      mode: KeepAliveMode.fromString(prefs.getString(_kKeepAliveMode)),
      intervalMinutes: prefs.getInt(_kKeepAliveInterval) ?? 5,
    );
    return (
      serverUrl: url,
      token: tok,
      deviceId: devId,
      lastSeq: _lastSeq,
      theme: theme,
      keepAlive: keepAlive,
    );
  }

  Future<void> saveCredentials({
    required String serverUrl,
    required String token,
    String deviceId = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerUrl, serverUrl);
    await prefs.setString(_kAuthToken, token);
    await prefs.setString(_kDeviceId, deviceId);
    api.updateCredentials(baseUrl: serverUrl, token: token);
  }

  Future<void> clearCredentials() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disconnectWs();
    _lastSeq = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kServerUrl);
    await prefs.remove(_kAuthToken);
    await prefs.remove(_kDeviceId);
    await prefs.remove(_kLastSeq);
    api.updateCredentials(baseUrl: '', token: '');
    onStatusChanged(ConnectionStatus.unconfigured);
  }

  Future<void> saveKeepAlive(KeepAliveConfig cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKeepAliveMode, cfg.mode.wireName);
    await prefs.setInt(_kKeepAliveInterval, cfg.intervalMinutes);
  }

  Future<void> saveTheme(ThemePreference pref) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemePref, pref.name);
  }

  Future<void> advanceSeqFromExternal(int seq) => _saveSeq(seq);

  Future<void> _saveSeq(int seq) async {
    if (seq <= _lastSeq) return;
    _lastSeq = seq;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastSeq, _lastSeq);
    onSeqAdvanced?.call(_lastSeq);
  }

  Future<void> start() async {
    _stopped = false;
    _pausedForBackground = false;
    if (api.baseUrl.isEmpty || api.token.isEmpty) {
      onStatusChanged(ConnectionStatus.unconfigured);
      return;
    }
    await _syncAndConnect();
  }

  void pauseForBackground() {
    if (_stopped || _pausedForBackground) return;
    _pausedForBackground = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disconnectWs();
  }

  Future<void> resume() async {
    if (_stopped || api.baseUrl.isEmpty || api.token.isEmpty) return;
    _pausedForBackground = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await syncOnce();
      if (_channel == null) {
        _connectWs();
      }
    } catch (_) {
      _scheduleReconnect();
    }
  }

  Future<void> syncOnce() async {
    if (api.baseUrl.isEmpty || api.token.isEmpty) return;
    var hasMore = true;
    var guard = 0;
    while (hasMore && guard < 20) {
      guard++;
      final batch = await api.syncEvents(_lastSeq);
      for (final ev in batch.events) {
        onEvent(ev);
      }
      await _saveSeq(batch.latestSeq);
      hasMore = batch.hasMore;
    }
  }

  Future<void> _syncAndConnect() async {
    if (_stopped || _pausedForBackground) return;
    _disconnectWs();
    try {
      await syncOnce();
      if (!_stopped && !_pausedForBackground) {
        _connectWs();
      }
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _connectWs() {
    if (_stopped || _pausedForBackground) return;
    final httpUri = Uri.parse(api.baseUrl);
    final wsScheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUri = httpUri.replace(
      scheme: wsScheme,
      path: '${httpUri.path}/api/v1/ws',
      queryParameters: {'token': api.token},
    );

    try {
      _channel = _channelFactory(wsUri);
      _reconnectAttempt = 0;
      onStatusChanged(ConnectionStatus.connected);

      _wsSub = _channel!.stream.listen(
        (raw) {
          _handleFrame(raw);
        },
        onError: (_) => _scheduleReconnect(),
        onDone: () => _scheduleReconnect(),
        cancelOnError: true,
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _channel?.sink.add(jsonEncode({
            'type': 'ping',
            'ts': DateTime.now().toUtc().millisecondsSinceEpoch,
          }));
        } catch (_) {}
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _handleFrame(dynamic raw) {
    if (raw is! String) return;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return;
      if (map['type'] == 'event') {
        final ev = SyncEvent.fromJson(map);
        onEvent(ev);
        if (ev.seq > 0) {
          _saveSeq(ev.seq);
        }
      }
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_stopped || _pausedForBackground) return;
    _disconnectWs();
    final idx = _reconnectAttempt < _backoffSeconds.length
        ? _reconnectAttempt
        : _backoffSeconds.length - 1;
    final delaySec = _backoffSeconds[idx];
    _reconnectAttempt++;
    onStatusChanged(ConnectionStatus.reconnecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), _syncAndConnect);
  }

  void _disconnectWs() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disconnectWs();
    onStatusChanged(ConnectionStatus.offline);
  }
}
