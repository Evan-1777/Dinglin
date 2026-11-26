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

class _InboxScreenState extends State<InboxScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _searchCtrl;
  late final FocusNode _focusNode;
  late final AnimationController _spinCtrl;
  bool _ownsFocusNode = false;
  bool _mobileSearchExpanded = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.store.searchQuery);
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.searchFocusNode != null) {
      _focusNode = widget.searchFocusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    _syncSpinner();
  }

  @override
  void didUpdateWidget(covariant InboxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpinner();
  }

  void _syncSpinner() {
    if (widget.store.isLoading) {
      if (!_spinCtrl.isAnimating) _spinCtrl.repeat();
    } else {
      if (_spinCtrl.isAnimating) {
        _spinCtrl.stop();
        _spinCtrl.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _searchCtrl.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  Widget _buildSearchField(AppleTokens t, AppStore store, {bool autoFocus = false}) {
    return SizedBox(
      height: 32,
      child: TextField(
        controller: _searchCtrl,
        focusNode: _focusNode,
        autofocus: autoFocus,
        onChanged: (v) {
          store.setSearchQuery(v);
          setState(() {});
        },
        style: TextStyle(fontSize: 13, color: t.inkPrimary),
        decoration: appleInputDecoration(
          t,
          hint: '搜索',
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
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
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? GestureDetector(
                  onTap: () {
                    _searchCtrl.clear();
                    store.setSearchQuery('');
                    setState(() {});
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AppIcon(
                      AppIconName.xCircle,
                      size: 14,
                      color: t.inkTertiary,
                      semanticsLabel: '清除搜索',
                    ),
                  ),
                )
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 26, minHeight: 32),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final store = widget.store;
    final selectedSource = store.sourceById(store.selectedSourceId);
    final isWide = MediaQuery.sizeOf(context).width >= 640;
    _syncSpinner();

    return Column(
      children: [
        AppleTopBar(
          title: selectedSource?.name ?? '通知',
          expandedContent: !isWide && _mobileSearchExpanded
              ? Row(
                  children: [
                    Expanded(
                      child: _buildSearchField(t, store, autoFocus: true),
                    ),
                    const SizedBox(width: 8),
                    AppleIconButton(
                      icon: AppIconName.close,
                      tooltip: '收起搜索',
                      onPressed: () {
                        _searchCtrl.clear();
                        store.setSearchQuery('');
                        setState(() => _mobileSearchExpanded = false);
                      },
                    ),
                  ],
                )
              : null,
          trailing: [
            if (isWide) ...[
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 230),
                  child: _buildSearchField(t, store),
                ),
              ),
              const SizedBox(width: 8),
            ] else ...[
              AppleIconButton(
                icon: AppIconName.search,
                tooltip: '搜索',
                active: store.searchQuery.isNotEmpty,
                onPressed: () {
                  setState(() => _mobileSearchExpanded = true);
                },
              ),
              const SizedBox(width: 4),
            ],
            AppleIconButton(
              icon: AppIconName.checkDouble,
              tooltip: '全部已读',
              onPressed: store.unreadCount > 0
                  ? () => store.markAllRead(sourceId: store.selectedSourceId)
                  : null,
            ),
            const SizedBox(width: 4),
            RotationTransition(
              turns: _spinCtrl,
              child: AppleIconButton(
                icon: AppIconName.refresh,
                tooltip: '刷新',
                onPressed: store.refreshAll,
              ),
            ),
          ],
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
                          Flexible(
                            child: AppleSegmentedControl<InboxFilter>(
                              value: store.inboxFilter,
                              options: const [
                                (value: InboxFilter.all, label: '全部'),
                                (value: InboxFilter.unread, label: '未读'),
                                (value: InboxFilter.critical, label: '强提醒'),
                              ],
                              onChanged: store.setInboxFilter,
                            ),
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
                      if (MediaQuery.sizeOf(context).width < 960 &&
                          store.sources.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _CompactSourceFilterBar(store: store),
                      ],
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
                                  Flexible(
                                    child: Text(
                                      src.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: t.inkPrimary,
                                      ),
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
                                if (n.status == 'snoozed' &&
                                    n.snoozedUntil != null) ...[
                                  const SizedBox(width: 6),
                                  ApplePill(
                                    label:
                                        '延后至 ${formatClockHm(n.snoozedUntil!)}',
                                    background: t.warningBg,
                                    foreground: t.warning,
                                  ),
                                ],
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

class _CompactSourceFilterBar extends StatelessWidget {
  const _CompactSourceFilterBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _SourceFilterChip(
            label: '全部来源',
            selected: store.selectedSourceId == null,
            badge: store.unreadCount,
            onTap: () => store.setSelectedSource(null),
          ),
          for (final src in store.sources) ...[
            const SizedBox(width: 6),
            _SourceFilterChip(
              label: src.name,
              dotColor: parseHexColor(src.color, fallback: t.accent),
              selected: store.selectedSourceId == src.id,
              badge: store.unreadCountForSource(src.id),
              onTap: () => store.setSelectedSource(
                store.selectedSourceId == src.id ? null : src.id,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceFilterChip extends StatelessWidget {
  const _SourceFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
    this.badge = 0,
  });

  final String label;
  final Color? dotColor;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppleTokens.motion,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? t.bgSelected : t.bgSurface,
            borderRadius: BorderRadius.circular(AppleTokens.radiusPill),
            border: Border.all(
              color: selected ? t.accent : t.borderHairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? t.accent : t.inkSecondary,
                ),
              ),
              if (badge > 0) ...[
                const SizedBox(width: 5),
                Text(
                  '$badge',
                  style: AppleTokens.tabular.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected ? t.accent : t.inkTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
