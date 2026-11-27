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

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showAppleConfirmDialog(
      context,
      title: '删除通知',
      message: '确认永久删除「${notification.title}」？',
      confirmLabel: '删除',
    );
    if (ok) {
      await store.deleteNotification(notification.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final src = store.sourceById(notification.sourceId);

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
                icon: notification.isUnread
                    ? AppIconName.checkDouble
                    : AppIconName.bell,
                tooltip: notification.isUnread ? '标为已看' : '标为未读',
                onPressed: () => store.markNotificationRead(
                  notification.id,
                  read: notification.isUnread,
                  showFeedback: true,
                ),
              ),
              const SizedBox(width: 2),
              AppleIconButton(
                icon: AppIconName.trash,
                tooltip: '删除通知',
                danger: true,
                onPressed: () => _confirmDelete(context),
              ),
              const SizedBox(width: 2),
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
                      Expanded(
                        child: Row(
                          children: [
                            if (src != null) ...[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: parseHexColor(
                                    src.color,
                                    fallback: t.accent,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  src.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: t.inkSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            _PriorityPill(priority: notification.priority),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatRelativeTime(notification.createdAt),
                        style: AppleTokens.tabular.copyWith(
                          fontSize: 12,
                          color: t.inkTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    notification.title,
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.25,
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
                  if (notification.actions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
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
                  ],
                  const SizedBox(height: 18),
                  // Compact metadata KV card
                  Builder(
                    builder: (context) {
                      final kvEntries = <(String, String)>[
                        ('状态', notification.isUnread ? '未读' : '已看'),
                        if (notification.category.isNotEmpty)
                          ('分类', notification.category),
                        for (final entry in notification.metadata.entries)
                          if (entry.value != null &&
                              entry.value.toString().isNotEmpty)
                            (entry.key, entry.value.toString()),
                      ];
                      return Container(
                        decoration: BoxDecoration(
                          color: t.bgCanvas,
                          borderRadius:
                              BorderRadius.circular(AppleTokens.radiusMd),
                          border: Border.all(color: t.borderHairline),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < kvEntries.length; i++)
                              _KvRow(
                                label: kvEntries[i].$1,
                                value: kvEntries[i].$2,
                                isLast: i == kvEntries.length - 1,
                                copyable: kvEntries[i].$2.startsWith('http') ||
                                    kvEntries[i].$2.length > 20,
                                onCopied: () => store.showToast('已复制'),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PriorityPill extends StatelessWidget {
  const _PriorityPill({required this.priority});
  final String priority;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return switch (priority) {
      'critical' => ApplePill(
          label: '强提醒',
          background: t.criticalBg,
          foreground: t.critical,
        ),
      'silent' => ApplePill(
          label: '静默',
          background: t.bgSurfaceSecondary,
          foreground: t.inkSecondary,
        ),
      _ => ApplePill(
          label: '普通',
          background: t.bgSelected,
          foreground: t.accent,
        ),
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
            const SizedBox(width: 6),
            Tooltip(
              message: '复制',
              child: ApplePressable(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: value));
                  onCopied?.call();
                },
                pressedScale: 0.9,
                builder: (context, hovered, _) => AppIcon(
                  AppIconName.copy,
                  size: 13,
                  color: hovered ? t.accent : t.inkTertiary,
                  semanticsLabel: '复制 $label',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
