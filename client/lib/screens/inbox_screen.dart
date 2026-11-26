import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/apple_primitives.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.store,
    this.searchFocusNode,
  });

  final AppStore store;
  final FocusNode? searchFocusNode;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late final TextEditingController _searchCtrl;
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.store.searchQuery);
    if (widget.searchFocusNode != null) {
      _focusNode = widget.searchFocusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final store = widget.store;
    final selectedSource = store.sourceById(store.selectedSourceId);

    return Column(
      children: [
        // Frosted Top Bar (search input stays mounted across list rebuilds)
        FrostedSurface(
          color: t.bgTopbar,
          border: Border(bottom: BorderSide(color: t.borderHairline)),
          child: SizedBox(
            height: AppleTokens.topbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    selectedSource?.name ?? '通知',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: t.inkPrimary,
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 220,
                    height: 32,
                    child: TextField(
                      controller: _searchCtrl,
                      focusNode: _focusNode,
                      onChanged: store.setSearchQuery,
                      style: TextStyle(fontSize: 13, color: t.inkPrimary),
                      decoration: InputDecoration(
                        hintText: '搜索',
                        hintStyle: TextStyle(fontSize: 13, color: t.inkTertiary),
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(left: 10, right: 6),
                          child: AppIcon(
                            AppIconName.search,
                            size: 14,
                            color: t.inkTertiary,
                            semanticsLabel: '搜索',
                          ),
                        ),
                        prefixIconConstraints:
                            const BoxConstraints(minWidth: 30, minHeight: 32),
                        filled: true,
                        fillColor: t.bgSurfaceSecondary,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppleTokens.radiusSm),
                          borderSide: BorderSide(color: t.borderHairline),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppleTokens.radiusSm),
                          borderSide: BorderSide(color: t.borderHairline),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppleTokens.radiusSm),
                          borderSide: BorderSide(color: t.accent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppleIconButton(
                    icon: AppIconName.refresh,
                    tooltip: '刷新',
                    onPressed: store.refreshAll,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 780),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (store.errorMessage != null)
                        _ErrorBanner(
                          message: store.errorMessage!,
                          onRetry: store.refreshAll,
                        ),
                      Row(
                        children: [
                          AppleSegmentedControl<InboxFilter>(
                            value: store.inboxFilter,
                            options: const [
                              (value: InboxFilter.all, label: '全部'),
                              (value: InboxFilter.unread, label: '未读'),
                              (value: InboxFilter.critical, label: '强提醒'),
                            ],
                            onChanged: store.setInboxFilter,
                          ),
                          const Spacer(),
                          if (store.selectedSourceId != null)
                            AppleActionChip(
                              icon: AppIconName.close,
                              label: selectedSource?.name ?? '',
                              onPressed: () => store.setSelectedSource(null),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (store.isLoading && store.notifications.isEmpty)
                        const _InboxSkeleton()
                      else
                        _buildGroupedList(context, store),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGroupedList(BuildContext context, AppStore store) {
    final t = AppleTokens.of(context);
    final items = store.filteredNotifications;

    if (store.connectionStatus == ConnectionStatus.unconfigured &&
        items.isEmpty) {
      return _EmptyState(
        icon: AppIconName.link,
        title: '未连接网关',
        actionLabel: '前往设置',
        onAction: () => store.setTab(AppTab.settings),
      );
    }

    if (items.isEmpty) {
      return _EmptyState(
        icon: AppIconName.bell,
        title: '暂无通知',
        actionLabel: '刷新',
        onAction: store.refreshAll,
      );
    }

    final now = DateTime.now();
    final critical = <DinglinNotification>[];
    final today = <DinglinNotification>[];
    final earlier = <DinglinNotification>[];

    for (final n in items) {
      if (n.isCritical && n.isUnread) {
        critical.add(n);
      } else {
        final local = n.createdAt.toLocal();
        if (local.year == now.year &&
            local.month == now.month &&
            local.day == now.day) {
          today.add(n);
        } else {
          earlier.add(n);
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (critical.isNotEmpty) ...[
          _GroupHeader(title: '强提醒', color: t.critical),
          AppleCardGroup(
            children: [
              for (final n in critical)
                _NotificationRow(store: store, notification: n),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (today.isNotEmpty) ...[
          _GroupHeader(title: '今天', color: t.inkSecondary),
          AppleCardGroup(
            children: [
              for (final n in today)
                _NotificationRow(store: store, notification: n),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (earlier.isNotEmpty) ...[
          _GroupHeader(title: '更早', color: t.inkSecondary),
          AppleCardGroup(
            children: [
              for (final n in earlier)
                _NotificationRow(store: store, notification: n),
            ],
          ),
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.color});
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _NotificationRow extends StatefulWidget {
  const _NotificationRow({
    required this.store,
    required this.notification,
  });

  final AppStore store;
  final DinglinNotification notification;

  @override
  State<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<_NotificationRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final n = widget.notification;
    final src = widget.store.sourceById(n.sourceId);
    final selected = widget.store.selectedNotificationId == n.id;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.store.selectNotification(n.id),
        child: AnimatedContainer(
          duration: AppleTokens.motion,
          color: selected
              ? t.bgSelected
              : _hovered
                  ? t.bgHover
                  : Colors.transparent,
          child: Stack(
            children: [
              if (n.isCritical)
                Positioned(
                  left: 0,
                  top: 10,
                  bottom: 10,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: t.critical,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              Opacity(
                opacity: n.isUnread ? 1.0 : 0.72,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(top: 6),
                        decoration: BoxDecoration(
                          color: !n.isUnread
                              ? Colors.transparent
                              : n.isCritical
                                  ? t.critical
                                  : t.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (src != null) ...[
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: parseHexColor(src.color,
                                          fallback: t.accent),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    src.name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: t.inkPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                if (n.isCritical)
                                  ApplePill(
                                    label: '强提醒',
                                    background: t.criticalBg,
                                    foreground: t.critical,
                                  ),
                                if (n.priority == 'silent')
                                  ApplePill(
                                    label: '静默',
                                    background: t.bgSurfaceSecondary,
                                    foreground: t.inkSecondary,
                                  ),
                                const Spacer(),
                                Text(
                                  formatRelativeTime(n.createdAt),
                                  style: AppleTokens.tabular.copyWith(
                                    fontSize: 12,
                                    color: t.inkTertiary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              n.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: t.inkPrimary,
                              ),
                            ),
                            if (n.body.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                n.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: t.inkSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                AppleActionChip(
                                  icon: AppIconName.checkDouble,
                                  tooltip: '已读',
                                  done: n.status == 'read',
                                  onPressed: () => widget.store.submitReceipt(
                                    n.id,
                                    'read',
                                    toastLabel: '已读',
                                  ),
                                ),
                                AppleActionChip(
                                  icon: AppIconName.check,
                                  tooltip: '确认',
                                  done: n.status == 'acked',
                                  onPressed: () => widget.store.submitReceipt(
                                    n.id,
                                    'ack',
                                    toastLabel: '已确认',
                                  ),
                                ),
                                AppleActionChip(
                                  icon: AppIconName.snooze,
                                  tooltip: '延后',
                                  done: n.status == 'snoozed',
                                  onPressed: () => widget.store.submitReceipt(
                                    n.id,
                                    'snooze',
                                    toastLabel: '已延后',
                                  ),
                                ),
                                for (final act in n.actions)
                                  AppleActionChip(
                                    label: act.label,
                                    onPressed: () => widget.store.submitReceipt(
                                      n.id,
                                      act.id,
                                      toastLabel: act.label,
                                    ),
                                  ),
                              ],
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
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.criticalBg,
        borderRadius: BorderRadius.circular(AppleTokens.radiusMd),
        border: Border.all(color: t.critical.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          AppIcon(AppIconName.alert,
              size: 16, color: t.critical, semanticsLabel: '错误'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: t.critical,
              ),
            ),
          ),
          AppleActionChip(label: '重试', onPressed: onRetry),
        ],
      ),
    );
  }
}

class _InboxSkeleton extends StatelessWidget {
  const _InboxSkeleton();

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return AppleCardGroup(
      children: List.generate(
        3,
        (_) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 140,
                height: 12,
                decoration: BoxDecoration(
                  color: t.bgSurfaceSecondary,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: 260,
                height: 14,
                decoration: BoxDecoration(
                  color: t.bgSurfaceSecondary,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                height: 12,
                decoration: BoxDecoration(
                  color: t.bgSurfaceSecondary,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final AppIconName icon;
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Column(
        children: [
          AppIcon(icon, size: 32, color: t.inkTertiary, semanticsLabel: title),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: t.inkSecondary,
            ),
          ),
          const SizedBox(height: 14),
          AppleActionChip(label: actionLabel, onPressed: onAction),
        ],
      ),
    );
  }
}
