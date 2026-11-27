import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'HTTP $statusCode: $message';
}

class SyncBatch {
  SyncBatch({
    required this.events,
    required this.latestSeq,
    required this.hasMore,
  });

  final List<SyncEvent> events;
  final int latestSeq;
  final bool hasMore;
}

class CreatedSourceResult {
  CreatedSourceResult({
    required this.source,
    required this.token,
    required this.callbackSecret,
  });

  final DinglinSource source;
  final String token;
  final String callbackSecret;
}

class PairDeviceResult {
  PairDeviceResult({
    required this.device,
    required this.deviceToken,
  });

  final DinglinDevice device;
  final String deviceToken;
}

class PairingCodeResult {
  PairingCodeResult({
    required this.code,
    required this.expiresAt,
    required this.ttlSec,
  });

  final String code;
  final DateTime expiresAt;
  final int ttlSec;
}

class ApiClient {
  ApiClient({
    required String baseUrl,
    required String token,
    http.Client? httpClient,
  })  : _baseUrl = _normalizeBase(baseUrl),
        _token = token.trim(),
        _client = httpClient ?? http.Client();

  String _baseUrl;
  String _token;
  final http.Client _client;

  String get baseUrl => _baseUrl;
  String get token => _token;

  void updateCredentials({required String baseUrl, required String token}) {
    _baseUrl = _normalizeBase(baseUrl);
    _token = token.trim();
  }

  static String _normalizeBase(String url) {
    final t = url.trim();
    if (t.endsWith('/')) return t.substring(0, t.length - 1);
    return t;
  }

  Map<String, String> _headers({bool auth = true}) => {
        'Content-Type': 'application/json',
        if (auth && _token.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool auth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    late http.Response resp;
    final encoded = body != null ? jsonEncode(body) : null;
    switch (method) {
      case 'GET':
        resp = await _client.get(uri, headers: _headers(auth: auth));
      case 'POST':
        resp = await _client.post(uri,
            headers: _headers(auth: auth), body: encoded);
      case 'PATCH':
        resp = await _client.patch(uri,
            headers: _headers(auth: auth), body: encoded);
      case 'DELETE':
        resp = await _client.delete(uri, headers: _headers(auth: auth));
      default:
        throw ApiException(400, 'Unsupported method $method');
    }

    if (resp.statusCode == 204 || resp.body.isEmpty) {
      if (resp.statusCode >= 400) {
        throw ApiException(resp.statusCode, 'Request failed');
      }
      return const {};
    }

    final decoded = jsonDecode(resp.body);
    if (resp.statusCode >= 400) {
      String msg = 'Request failed';
      if (decoded is Map<String, dynamic> && decoded['error'] is Map) {
        msg = (decoded['error']['message'] ?? msg).toString();
      }
      throw ApiException(resp.statusCode, msg);
    }
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Future<bool> healthz() async {
    final data = await _request('GET', '/healthz', auth: false);
    return data['status'] == 'ok';
  }

  Future<List<DinglinNotification>> listNotifications({
    String? q,
    String? sourceId,
    String? priority,
    String? status,
    int limit = 100,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (q != null && q.isNotEmpty) query['q'] = q;
    if (sourceId != null && sourceId.isNotEmpty) query['source_id'] = sourceId;
    if (priority != null && priority.isNotEmpty) query['priority'] = priority;
    if (status != null && status.isNotEmpty) query['status'] = status;
    final data = await _request('GET', '/api/v1/notifications', query: query);
    final raw = data['notifications'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DinglinNotification.fromJson)
        .toList();
  }

  Future<int> markAllNotificationsRead({String? sourceId}) async {
    final data = await _request(
      'POST',
      '/api/v1/notifications/read-all',
      body: {
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
      },
    );
    return (data['updated'] as num?)?.toInt() ?? 0;
  }

  Future<void> deleteNotification(String id) async {
    await _request('DELETE', '/api/v1/notifications/$id');
  }

  Future<int> batchNotifications({
    required String action,
    required List<String> ids,
  }) async {
    final data = await _request(
      'POST',
      '/api/v1/notifications/batch',
      body: {
        'action': action,
        'ids': ids,
      },
    );
    return (data['affected'] as num?)?.toInt() ?? 0;
  }

  Future<int> clearReadNotifications({String? sourceId}) async {
    final data = await _request(
      'POST',
      '/api/v1/notifications/clear-read',
      body: {
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
      },
    );
    return (data['deleted'] as num?)?.toInt() ?? 0;
  }

  Future<(DinglinReceipt, DinglinNotification)> submitReceipt({
    required String notificationId,
    required String actionId,
    int? snoozeMinutes,
    Map<String, dynamic>? payload,
  }) async {
    final data = await _request(
      'POST',
      '/api/v1/notifications/$notificationId/receipt',
      body: {
        'action_id': actionId,
        'snooze_minutes': ?snoozeMinutes,
        'payload': ?payload,
      },
    );
    return (
      DinglinReceipt.fromJson(data['receipt'] as Map<String, dynamic>),
      DinglinNotification.fromJson(
          data['notification'] as Map<String, dynamic>),
    );
  }

  Future<List<DinglinReceipt>> listReceipts(String notificationId) async {
    final data =
        await _request('GET', '/api/v1/notifications/$notificationId/receipts');
    final raw = data['receipts'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DinglinReceipt.fromJson)
        .toList();
  }

  Future<List<DinglinSchedule>> listSchedules({String? kind}) async {
    final data = await _request(
      'GET',
      '/api/v1/schedules',
      query: kind != null && kind.isNotEmpty ? {'kind': kind} : null,
    );
    final raw = data['schedules'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DinglinSchedule.fromJson)
        .toList();
  }

  Future<DinglinSchedule> createSchedule(Map<String, dynamic> payload) async {
    final data = await _request('POST', '/api/v1/schedules', body: payload);
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<DinglinSchedule> updateSchedule(
      String id, Map<String, dynamic> payload) async {
    final data = await _request('PATCH', '/api/v1/schedules/$id', body: payload);
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<void> deleteSchedule(String id) async {
    await _request('DELETE', '/api/v1/schedules/$id');
  }

  Future<DinglinSchedule> toggleSchedule(String id, bool enabled) async {
    final data = await _request(
      'POST',
      '/api/v1/schedules/$id/toggle',
      body: {'enabled': enabled},
    );
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<DinglinSchedule> snoozeSchedule(String id, {int? minutes}) async {
    final data = await _request(
      'POST',
      '/api/v1/schedules/$id/snooze',
      body: {'minutes': ?minutes},
    );
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<DinglinSchedule> dismissSchedule(String id) async {
    final data = await _request('POST', '/api/v1/schedules/$id/dismiss');
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<DinglinSchedule> countdownAction(String id, String action) async {
    final data = await _request(
      'POST',
      '/api/v1/schedules/$id/action',
      body: {'action': action},
    );
    return DinglinSchedule.fromJson(data['schedule'] as Map<String, dynamic>);
  }

  Future<List<DinglinSource>> listSources() async {
    final data = await _request('GET', '/api/v1/sources');
    final raw = data['sources'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DinglinSource.fromJson)
        .toList();
  }

  Future<CreatedSourceResult> createSource({
    required String name,
    required String slug,
    required String kind,
    required String color,
    String callbackUrl = '',
  }) async {
    final data = await _request('POST', '/api/v1/sources', body: {
      'name': name,
      'slug': slug,
      'kind': kind,
      'color': color,
      'callback_url': callbackUrl,
    });
    return CreatedSourceResult(
      source: DinglinSource.fromJson(data['source'] as Map<String, dynamic>),
      token: (data['token'] ?? '').toString(),
      callbackSecret: (data['callback_secret'] ?? '').toString(),
    );
  }

  Future<DinglinSource> updateSource(
    String id, {
    String? name,
    String? color,
    String? callbackUrl,
    bool? enabled,
  }) async {
    final data = await _request('PATCH', '/api/v1/sources/$id', body: {
      'name': ?name,
      'color': ?color,
      'callback_url': ?callbackUrl,
      'enabled': ?enabled,
    });
    return DinglinSource.fromJson(data['source'] as Map<String, dynamic>);
  }

  Future<String> rotateSourceToken(String id) async {
    final data = await _request('POST', '/api/v1/sources/$id/rotate-token');
    return (data['token'] ?? '').toString();
  }

  Future<void> deleteSource(String id) async {
    await _request('DELETE', '/api/v1/sources/$id');
  }

  Future<List<DinglinDevice>> listDevices() async {
    final data = await _request('GET', '/api/v1/devices');
    final raw = data['devices'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DinglinDevice.fromJson)
        .toList();
  }

  Future<PairingCodeResult> createPairingCode() async {
    final data = await _request('POST', '/api/v1/pairing-codes');
    return PairingCodeResult(
      code: (data['code'] ?? '').toString(),
      expiresAt: DateTime.tryParse((data['expires_at'] ?? '').toString()) ??
          DateTime.now().add(const Duration(minutes: 5)),
      ttlSec: (data['ttl_sec'] as num?)?.toInt() ?? 300,
    );
  }

  Future<PairDeviceResult> pairDevice({
    required String code,
    required String name,
    required String platform,
    required bool hasGms,
  }) async {
    final data = await _request(
      'POST',
      '/api/v1/devices/pair',
      auth: false,
      body: {
        'code': code,
        'name': name,
        'platform': platform,
        'has_gms': hasGms,
      },
    );
    return PairDeviceResult(
      device: DinglinDevice.fromJson(data['device'] as Map<String, dynamic>),
      deviceToken: (data['device_token'] ?? '').toString(),
    );
  }

  Future<String> testDevicePush(String id) async {
    final data = await _request('POST', '/api/v1/devices/$id/test');
    return (data['channel'] ?? 'ws').toString();
  }

  Future<void> deleteDevice(String id) async {
    await _request('DELETE', '/api/v1/devices/$id');
  }

  Future<DinglinDevice> updateDevice(
    String id, {
    String? name,
    String? pushMode,
  }) async {
    final data = await _request('PATCH', '/api/v1/devices/$id', body: {
      'name': ?name,
      'push_mode': ?pushMode,
    });
    return DinglinDevice.fromJson(data['device'] as Map<String, dynamic>);
  }

  Future<void> registerFcmToken(
    String deviceId,
    String fcmToken,
    bool hasGms, {
    String? pushMode,
  }) async {
    await _request('POST', '/api/v1/devices/$deviceId/fcm-token', body: {
      'fcm_token': fcmToken,
      'has_gms': hasGms,
      'push_mode': ?pushMode,
    });
  }

  Future<DinglinSettings> getSettings() async {
    final data = await _request('GET', '/api/v1/settings');
    final raw = data['settings'];
    if (raw is Map<String, dynamic>) {
      return DinglinSettings.fromJson(raw);
    }
    return DinglinSettings.defaults;
  }

  Future<DinglinSettings> updateSettings(DinglinSettings settings) async {
    final data =
        await _request('PATCH', '/api/v1/settings', body: settings.toJson());
    final raw = data['settings'];
    if (raw is Map<String, dynamic>) {
      return DinglinSettings.fromJson(raw);
    }
    return settings;
  }

  Future<SyncBatch> syncEvents(int sinceSeq, {int limit = 100}) async {
    final data = await _request('GET', '/api/v1/sync', query: {
      'since_seq': '$sinceSeq',
      'limit': '$limit',
    });
    final raw = data['events'];
    final list = raw is List
        ? raw.whereType<Map<String, dynamic>>().map(SyncEvent.fromJson).toList()
        : const <SyncEvent>[];
    return SyncBatch(
      events: list,
      latestSeq: (data['latest_seq'] as num?)?.toInt() ?? sinceSeq,
      hasMore: data['has_more'] == true,
    );
  }
}
