import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import 'app_icon.dart';
import 'apple_primitives.dart';

class NotificationInspector extends StatelessWidget {
  const NotificationInspector({
    super.key,
    required this.store,
    required this.notification,
  });

  final AppStore store;
  final DinglinNotification notification;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final src = store.sourceById(notification.sourceId);
    final receipts = store.receiptsByNotification[notification.id] ?? const [];

    return Container(
      decoration: BoxDecoration(
        color: t.bgSurface,
        border: Border(left: BorderSide(color: t.borderHairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppleTopBar(
            title: '通知详情',
            horizontalPadding: 16,
            trailing: [
              AppleIconButton(
                icon: AppIconName.close,
                tooltip: '关闭',
                onPressed: store.closeInspector,
              ),
            ],
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                Row(
                  children: [
                    if (src != null) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: parseHexColor(src.color, fallback: t.accent),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        src.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: t.inkSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _PriorityPill(priority: notification.priority),
                    const Spacer(),
                    Text(
                      formatRelativeTime(notification.createdAt),
                      style: AppleTokens.tabular.copyWith(
                        fontSize: 12,
                        color: t.inkTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  notification.title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: t.inkPrimary,
                  ),
                ),
                if (notification.body.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    notification.body,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.55,
                      color: t.inkSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Quick actions & multi-option snooze
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    AppleActionChip(
                      icon: AppIconName.checkDouble,
                      label: '已读',
                      done: notification.status == 'read',
                      onPressed: () => store.submitReceipt(
                        notification.id,
                        'read',
                        toastLabel: '已标为已读',
                      ),
                    ),
                    AppleActionChip(
                      icon: AppIconName.check,
                      label: '确认',
                      done: notification.status == 'acked',
                      onPressed: () => store.submitReceipt(
                        notification.id,
                        'ack',
                        toastLabel: '已确认',
                      ),
                    ),
                    AppleActionChip(
                      icon: AppIconName.close,
                      label: '忽略',
                      done: notification.status == 'dismissed',
                      onPressed: () => store.submitReceipt(
                        notification.id,
                        'dismiss',
                        toastLabel: '已忽略',
                      ),
                    ),
                    for (final mins in const [5, 15, 60])
                      AppleActionChip(
                        icon: AppIconName.snooze,
                        label: mins == 60 ? '1h' : '${mins}m',
                        onPressed: () => store.submitReceipt(
                          notification.id,
                          'snooze',
                          snoozeMinutes: mins,
                          toastLabel: '已延后 ${mins == 60 ? '1 小时' : '$mins 分钟'}',
                        ),
                      ),
                    for (final act in notification.actions)
                      AppleActionChip(
                        label: act.label,
                        onPressed: () => store.submitReceipt(
                          notification.id,
                          act.id,
                          toastLabel: act.label,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                // Metadata KV box
                Builder(
                  builder: (context) {
                    final kvEntries = <(String, String)>[
                      ('状态', _statusLabel(notification.status)),
                      if (notification.category.isNotEmpty)
                        ('分类', notification.category),
                      if (notification.callbackUrl.isNotEmpty)
                        ('回调', notification.callbackUrl),
                      for (final entry in notification.metadata.entries)
                        (entry.key, entry.value.toString()),
                    ];
                    return Container(
                      decoration: BoxDecoration(
                        color: t.bgCanvas,
                        borderRadius: BorderRadius.circular(AppleTokens.radiusMd),
                        border: Border.all(color: t.borderHairline),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < kvEntries.length; i++)
                            _KvRow(
                              label: kvEntries[i].$1,
                              value: kvEntries[i].$2,
                              isLast: i == kvEntries.length - 1,
                              copyable: kvEntries[i].$1 == '回调' ||
                                  kvEntries[i].$2.startsWith('http') ||
                                  kvEntries[i].$2.length > 24,
                              onCopied: () => store.showToast('已复制'),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 18),
                Text(
                  '回执记录',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.inkSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                if (receipts.isEmpty)
                  Text(
                    '暂无回执',
                    style: TextStyle(fontSize: 12, color: t.inkTertiary),
                  )
                else
                  Container(
                    padding: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: t.borderHairline, width: 2),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final r in receipts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.actionLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: t.inkPrimary,
                                  ),
                                ),
                                Text(
                                  formatRelativeTime(r.createdAt),
                                  style: AppleTokens.tabular.copyWith(
                                    fontSize: 11,
                                    color: t.inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(String s) => switch (s) {
        'unread' => '未读',
        'read' => '已读',
        'acked' => '已确认',
        'snoozed' => '已延后',
        'dismissed' => '已忽略',
        _ => s,
      };
}

class _PriorityPill extends StatelessWidget {
  const _PriorityPill({required this.priority});
  final String priority;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return switch (priority) {
      'critical' =>
        ApplePill(label: '强提醒', background: t.criticalBg, foreground: t.critical),
      'silent' => ApplePill(
          label: '静默',
          background: t.bgSurfaceSecondary,
          foreground: t.inkSecondary,
        ),
      _ => ApplePill(label: '普通', background: t.bgSelected, foreground: t.accent),
    };
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({
    required this.label,
    required this.value,
    this.isLast = false,
    this.copyable = false,
    this.onCopied,
  });
  final String label;
  final String value;
  final bool isLast;
  final bool copyable;
  final VoidCallback? onCopied;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: t.borderHairline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: t.inkSecondary)),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: t.inkPrimary,
              ),
            ),
          ),
          if (copyable) ...[
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                onCopied?.call();
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Tooltip(
                  message: '复制',
                  child: AppIcon(
                    AppIconName.copy,
                    size: 13,
                    color: t.inkTertiary,
                    semanticsLabel: '复制 $label',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
