import 'package:flutter/foundation.dart';

enum ConnectionStatus { unconfigured, connected, reconnecting, offline }

enum ThemePreference { system, light, dark }

enum KeepAliveMode {
  auto,
  ws,
  polling;

  String get wireName => name;

  static KeepAliveMode fromString(String? raw) {
    return KeepAliveMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => KeepAliveMode.auto,
    );
  }
}

@immutable
class KeepAliveConfig {
  const KeepAliveConfig({
    this.mode = KeepAliveMode.auto,
    this.intervalMinutes = 5,
  });

  final KeepAliveMode mode;
  final int intervalMinutes;

  bool get isPolling => mode == KeepAliveMode.polling;

  KeepAliveConfig copyWith({
    KeepAliveMode? mode,
    int? intervalMinutes,
  }) {
    return KeepAliveConfig(
      mode: mode ?? this.mode,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    );
  }
}

@immutable
class PermissionStatus {
  const PermissionStatus({
    required this.notifications,
    required this.batteryOptimization,
    required this.exactAlarm,
    required this.fullScreenIntent,
  });

  final bool notifications;
  final bool batteryOptimization;
  final bool exactAlarm;
  final bool fullScreenIntent;

  static const PermissionStatus allOk = PermissionStatus(
    notifications: true,
    batteryOptimization: true,
    exactAlarm: true,
    fullScreenIntent: true,
  );

  bool get allGranted =>
      notifications && batteryOptimization && exactAlarm && fullScreenIntent;

  List<String> get missingAndroidPermissions => [
        if (!notifications) 'notifications',
        if (!batteryOptimization) 'battery_optimization',
        if (!exactAlarm) 'exact_alarm',
        if (!fullScreenIntent) 'full_screen_intent',
      ];

  factory PermissionStatus.fromMap(Map<dynamic, dynamic> map) {
    return PermissionStatus(
      notifications: map['notifications'] == true,
      batteryOptimization: map['battery_optimization'] == true,
      exactAlarm: map['exact_alarm'] == true,
      fullScreenIntent: map['full_screen_intent'] == true,
    );
  }
}

@immutable
class DinglinSource {
  const DinglinSource({
    required this.id,
    required this.slug,
    required this.name,
    required this.kind,
    required this.color,
    required this.tokenPrefix,
    required this.callbackUrl,
    required this.enabled,
    required this.createdAt,
  });

  final String id;
  final String slug;
  final String name;
  final String kind;
  final String color;
  final String tokenPrefix;
  final String callbackUrl;
  final bool enabled;
  final DateTime createdAt;

  factory DinglinSource.fromJson(Map<String, dynamic> j) {
    return DinglinSource(
      id: (j['id'] ?? '').toString(),
      slug: (j['slug'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      kind: (j['kind'] ?? 'webhook').toString(),
      color: (j['color'] ?? '#007AFF').toString(),
      tokenPrefix: (j['token_prefix'] ?? '').toString(),
      callbackUrl: (j['callback_url'] ?? '').toString(),
      enabled: j['enabled'] != false,
      createdAt: _parseTime(j['created_at']) ?? DateTime.now().toUtc(),
    );
  }
}

@immutable
class DinglinDevice {
  const DinglinDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.hasGms,
    required this.pushMode,
    required this.online,
    this.hasFcmToken = false,
    this.lastSeenAt,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String platform;
  final bool hasGms;
  final String pushMode;
  final bool online;
  final bool hasFcmToken;
  final DateTime? lastSeenAt;
  final DateTime createdAt;

  factory DinglinDevice.fromJson(Map<String, dynamic> j) {
    return DinglinDevice(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      platform: (j['platform'] ?? 'web').toString(),
      hasGms: j['has_gms'] == true,
      pushMode: (j['push_mode'] ?? 'web').toString(),
      online: j['online'] == true,
      hasFcmToken: ((j['fcm_token'] ?? '').toString().isNotEmpty) ||
          j['has_fcm_token'] == true,
      lastSeenAt: _parseTime(j['last_seen_at']),
      createdAt: _parseTime(j['created_at']) ?? DateTime.now().toUtc(),
    );
  }
}

@immutable
class QuickAction {
  const QuickAction({
    required this.id,
    required this.label,
    this.style = '',
    this.payload,
  });

  final String id;
  final String label;
  final String style;
  final Map<String, dynamic>? payload;

  factory QuickAction.fromJson(Map<String, dynamic> j) {
    return QuickAction(
      id: (j['id'] ?? '').toString(),
      label: (j['label'] ?? '').toString(),
      style: (j['style'] ?? '').toString(),
      payload: j['payload'] is Map<String, dynamic>
          ? j['payload'] as Map<String, dynamic>
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (style.isNotEmpty) 'style': style,
        if (payload != null) 'payload': payload,
      };
}

@immutable
class DinglinNotification {
  const DinglinNotification({
    required this.id,
    required this.seq,
    this.sourceId,
    required this.priority,
    required this.title,
    required this.body,
    this.category = '',
    this.actions = const [],
    this.metadata = const {},
    this.callbackUrl = '',
    required this.status,
    this.snoozedUntil,
    this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int seq;
  final String? sourceId;
  final String priority;
  final String title;
  final String body;
  final String category;
  final List<QuickAction> actions;
  final Map<String, dynamic> metadata;
  final String callbackUrl;
  final String status;
  final DateTime? snoozedUntil;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isUnread => status == 'unread';
  bool get isCritical => priority == 'critical';

  DinglinNotification copyWith({
    String? priority,
    String? status,
    DateTime? snoozedUntil,
    DateTime? updatedAt,
  }) {
    return DinglinNotification(
      id: id,
      seq: seq,
      sourceId: sourceId,
      priority: priority ?? this.priority,
      title: title,
      body: body,
      category: category,
      actions: actions,
      metadata: metadata,
      callbackUrl: callbackUrl,
      status: status ?? this.status,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      expiresAt: expiresAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory DinglinNotification.fromJson(Map<String, dynamic> j) {
    final rawActions = j['actions'];
    final actions = rawActions is List
        ? rawActions
            .whereType<Map<String, dynamic>>()
            .map(QuickAction.fromJson)
            .toList()
        : const <QuickAction>[];
    final rawMeta = j['metadata'];
    return DinglinNotification(
      id: (j['id'] ?? '').toString(),
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      sourceId: j['source_id']?.toString(),
      priority: (j['priority'] ?? 'normal').toString(),
      title: (j['title'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      category: (j['category'] ?? '').toString(),
      actions: actions,
      metadata: rawMeta is Map<String, dynamic> ? rawMeta : const {},
      callbackUrl: (j['callback_url'] ?? '').toString(),
      status: (j['status'] ?? 'unread').toString(),
      snoozedUntil: _parseTime(j['snoozed_until']),
      expiresAt: _parseTime(j['expires_at']),
      createdAt: _parseTime(j['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _parseTime(j['updated_at']) ?? DateTime.now().toUtc(),
    );
  }
}

@immutable
class DinglinReceipt {
  const DinglinReceipt({
    required this.id,
    required this.notificationId,
    this.deviceId,
    required this.actionId,
    required this.actionLabel,
    required this.createdAt,
  });

  final String id;
  final String notificationId;
  final String? deviceId;
  final String actionId;
  final String actionLabel;
  final DateTime createdAt;

  factory DinglinReceipt.fromJson(Map<String, dynamic> j) {
    return DinglinReceipt(
      id: (j['id'] ?? '').toString(),
      notificationId: (j['notification_id'] ?? '').toString(),
      deviceId: j['device_id']?.toString(),
      actionId: (j['action_id'] ?? '').toString(),
      actionLabel: (j['action_label'] ?? j['action_id'] ?? '').toString(),
      createdAt: _parseTime(j['created_at']) ?? DateTime.now().toUtc(),
    );
  }
}

@immutable
class DinglinSchedule {
  const DinglinSchedule({
    required this.id,
    required this.seq,
    this.sourceId,
    required this.kind,
    required this.title,
    this.body = '',
    required this.priority,
    required this.scheduleType,
    this.fireAt,
    this.cronExpr = '',
    this.timezone = 'UTC',
    this.durationSec = 0,
    this.targetAt,
    this.remainingSec = 0,
    required this.state,
    this.snoozeMinutes = 10,
    this.soundProfile = 'default',
    this.vibrate = true,
    required this.enabled,
    this.nextFireAt,
    this.version = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int seq;
  final String? sourceId;
  final String kind;
  final String title;
  final String body;
  final String priority;
  final String scheduleType;
  final DateTime? fireAt;
  final String cronExpr;
  final String timezone;
  final int durationSec;
  final DateTime? targetAt;
  final int remainingSec;
  final String state;
  final int snoozeMinutes;
  final String soundProfile;
  final bool vibrate;
  final bool enabled;
  final DateTime? nextFireAt;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  int liveRemainingSec(DateTime now) {
    if (kind != 'countdown') return 0;
    if (state == 'active' && targetAt != null) {
      final diff = targetAt!.difference(now).inSeconds;
      return diff > 0 ? diff : 0;
    }
    return remainingSec;
  }

  Map<String, dynamic> toNativeJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'body': body,
        'priority': priority,
        'schedule_type': scheduleType,
        'next_fire_at_ms': nextFireAt?.millisecondsSinceEpoch ?? 0,
        'snooze_minutes': snoozeMinutes,
        'vibrate': vibrate,
        'enabled': enabled,
        'state': state,
      };

  factory DinglinSchedule.fromJson(Map<String, dynamic> j) {
    return DinglinSchedule(
      id: (j['id'] ?? '').toString(),
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      sourceId: j['source_id']?.toString(),
      kind: (j['kind'] ?? 'scheduled_notification').toString(),
      title: (j['title'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      priority: (j['priority'] ?? 'normal').toString(),
      scheduleType: (j['schedule_type'] ?? 'once').toString(),
      fireAt: _parseTime(j['fire_at']),
      cronExpr: (j['cron_expr'] ?? '').toString(),
      timezone: (j['timezone'] ?? 'UTC').toString(),
      durationSec: (j['duration_sec'] as num?)?.toInt() ?? 0,
      targetAt: _parseTime(j['target_at']),
      remainingSec: (j['remaining_sec'] as num?)?.toInt() ?? 0,
      state: (j['state'] ?? 'active').toString(),
      snoozeMinutes: (j['snooze_minutes'] as num?)?.toInt() ?? 10,
      soundProfile: (j['sound_profile'] ?? 'default').toString(),
      vibrate: j['vibrate'] != false,
      enabled: j['enabled'] != false,
      nextFireAt: _parseTime(j['next_fire_at']),
      version: (j['version'] as num?)?.toInt() ?? 1,
      createdAt: _parseTime(j['created_at']) ?? DateTime.now().toUtc(),
      updatedAt: _parseTime(j['updated_at']) ?? DateTime.now().toUtc(),
    );
  }
}

@immutable
class DinglinSettings {
  const DinglinSettings({
    required this.dndEnabled,
    required this.dndStart,
    required this.dndEnd,
    required this.defaultSnoozeMinutes,
    required this.retentionDays,
  });

  final bool dndEnabled;
  final String dndStart;
  final String dndEnd;
  final int defaultSnoozeMinutes;
  final int retentionDays;

  static const DinglinSettings defaults = DinglinSettings(
    dndEnabled: false,
    dndStart: '23:00',
    dndEnd: '07:00',
    defaultSnoozeMinutes: 10,
    retentionDays: 30,
  );

  DinglinSettings copyWith({
    bool? dndEnabled,
    String? dndStart,
    String? dndEnd,
    int? defaultSnoozeMinutes,
    int? retentionDays,
  }) {
    return DinglinSettings(
      dndEnabled: dndEnabled ?? this.dndEnabled,
      dndStart: dndStart ?? this.dndStart,
      dndEnd: dndEnd ?? this.dndEnd,
      defaultSnoozeMinutes: defaultSnoozeMinutes ?? this.defaultSnoozeMinutes,
      retentionDays: retentionDays ?? this.retentionDays,
    );
  }

  Map<String, dynamic> toJson() => {
        'dnd_enabled': dndEnabled,
        'dnd_start': dndStart,
        'dnd_end': dndEnd,
        'default_snooze_minutes': defaultSnoozeMinutes,
        'retention_days': retentionDays,
      };

  factory DinglinSettings.fromJson(Map<String, dynamic> j) {
    return DinglinSettings(
      dndEnabled: j['dnd_enabled'] == true,
      dndStart: (j['dnd_start'] ?? '23:00').toString(),
      dndEnd: (j['dnd_end'] ?? '07:00').toString(),
      defaultSnoozeMinutes:
          (j['default_snooze_minutes'] as num?)?.toInt() ?? 10,
      retentionDays: (j['retention_days'] as num?)?.toInt() ?? 30,
    );
  }
}

@immutable
class SyncEvent {
  const SyncEvent({
    required this.seq,
    required this.eventType,
    required this.entityId,
    required this.payload,
  });

  final int seq;
  final String eventType;
  final String entityId;
  final Map<String, dynamic> payload;

  factory SyncEvent.fromJson(Map<String, dynamic> j) {
    final raw = j['payload'] ?? j['data'];
    return SyncEvent(
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      eventType: (j['event_type'] ?? '').toString(),
      entityId: (j['entity_id'] ?? '').toString(),
      payload: raw is Map<String, dynamic> ? raw : const {},
    );
  }
}

DateTime? _parseTime(dynamic v) {
  if (v == null) return null;
  if (v is String && v.isNotEmpty) {
    return DateTime.tryParse(v)?.toUtc();
  }
  return null;
}

/// Converts a 5-field Cron expression into a concise Chinese label.
String formatCronLabel(String cron) {
  final parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return cron;
  final dow = parts[4];
  if (parts[2] == '*' && parts[3] == '*') {
    if (dow == '*') return '每天';
    if (dow == '1-5') return '工作日';
    if (dow == '0,6' || dow == '6,0') return '周末';
    const names = {'0': '周日', '1': '周一', '2': '周二', '3': '周三', '4': '周四', '5': '周五', '6': '周六'};
    final mapped = dow.split(',').map((d) => names[d]).whereType<String>().toList();
    if (mapped.isNotEmpty) return mapped.join('、');
  }
  return cron;
}

String formatClockFromSchedule(DinglinSchedule s, DateTime now) {
  if (s.kind == 'countdown') {
    final rem = s.liveRemainingSec(now);
    final h = rem ~/ 3600;
    final m = (rem % 3600) ~/ 60;
    final sec = rem % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
  if (s.scheduleType == 'cron' && s.cronExpr.isNotEmpty) {
    final parts = s.cronExpr.trim().split(RegExp(r'\s+'));
    if (parts.length == 5) {
      final min = int.tryParse(parts[0]);
      final hr = int.tryParse(parts[1]);
      if (min != null && hr != null) {
        return '${hr.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
      }
    }
  }
  final target = (s.nextFireAt ?? s.fireAt)?.toLocal();
  if (target != null) {
    return '${target.hour.toString().padLeft(2, '0')}:${target.minute.toString().padLeft(2, '0')}';
  }
  return '--:--';
}

String formatRelativeTime(DateTime dt, {DateTime? now}) {
  final ref = (now ?? DateTime.now()).toLocal();
  final local = dt.toLocal();
  final diff = ref.difference(local);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && local.day == ref.day) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  if (diff.inDays < 2) {
    return '昨天 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Formats a local timestamp as HH:MM.
String formatClockHm(DateTime dt) {
  final local = dt.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Formats an upcoming trigger time cleanly relative to [now].
String formatFutureTime(DateTime dt, {DateTime? now}) {
  final ref = (now ?? DateTime.now()).toLocal();
  final local = dt.toLocal();
  final diff = local.difference(ref);
  if (diff.inSeconds <= 0) return '即将';
  if (diff.inMinutes < 1) return '${diff.inSeconds} 秒后';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟后';
  final hm = formatClockHm(local);
  final refDay = DateTime(ref.year, ref.month, ref.day);
  final localDay = DateTime(local.year, local.month, local.day);
  final dayDelta = localDay.difference(refDay).inDays;
  if (dayDelta == 0) return '今天 $hm';
  if (dayDelta == 1) return '明天 $hm';
  return '${local.month}/${local.day} $hm';
}

const List<String> commonIanaTimezones = [
  'Asia/Shanghai',
  'Asia/Hong_Kong',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Asia/Singapore',
  'Asia/Bangkok',
  'Asia/Kolkata',
  'Asia/Dubai',
  'Europe/London',
  'Europe/Berlin',
  'Europe/Paris',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'Australia/Sydney',
  'UTC',
];

String detectLocalIanaTimezone([Duration? offset]) {
  final mins = (offset ?? DateTime.now().timeZoneOffset).inMinutes;
  return switch (mins) {
    480 => 'Asia/Shanghai',
    540 => 'Asia/Tokyo',
    420 => 'Asia/Bangkok',
    330 => 'Asia/Kolkata',
    240 => 'Asia/Dubai',
    600 => 'Australia/Sydney',
    60 => 'Europe/Berlin',
    0 => 'UTC',
    -300 => 'America/New_York',
    -360 => 'America/Chicago',
    -420 => 'America/Denver',
    -480 => 'America/Los_Angeles',
    _ => 'UTC',
  };
}
