import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import 'app_icon.dart';
import 'apple_primitives.dart';

enum ShellLayout { desktop, tablet, mobile }

ShellLayout resolveShellLayout(double width) {
  if (width >= 960) return ShellLayout.desktop;
  if (width >= 640) return ShellLayout.tablet;
  return ShellLayout.mobile;
}

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.store,
    required this.body,
    this.inspector,
    this.onFocusSearch,
    this.onCreateSchedule,
  });

  final AppStore store;
  final Widget body;
  final Widget? inspector;
  final VoidCallback? onFocusSearch;
  final VoidCallback? onCreateSchedule;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: t.isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: t.isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: t.bgCanvas,
      systemNavigationBarIconBrightness:
          t.isDark ? Brightness.light : Brightness.dark,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = resolveShellLayout(constraints.maxWidth);
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                store.closeInspector();
              },
              const SingleActivator(LogicalKeyboardKey.slash): () {
                if (!_isTextInputFocused()) onFocusSearch?.call();
              },
              const SingleActivator(LogicalKeyboardKey.keyN): () {
                if (!_isTextInputFocused()) onCreateSchedule?.call();
              },
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: t.bgCanvas,
                body: Stack(
                  children: [
                    Row(
                      children: [
                        if (layout == ShellLayout.desktop)
                          _DesktopSidebar(store: store),
                        if (layout == ShellLayout.tablet)
                          _CompactRail(store: store),
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: body),
                              if (layout == ShellLayout.mobile)
                                _MobileTabBar(store: store),
                            ],
                          ),
                        ),
                        if (layout == ShellLayout.desktop && inspector != null)
                          SizedBox(
                            width: AppleTokens.inspectorWidth,
                            child: inspector!,
                          ),
                      ],
                    ),
                    // Tablet slide-over inspector drawer
                    if (layout == ShellLayout.tablet && inspector != null) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: store.closeInspector,
                          child: ColoredBox(color: t.scrim),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: AppleTokens.inspectorWidth,
                        child: DecoratedBox(
                          decoration: BoxDecoration(boxShadow: t.floatShadow),
                          child: inspector!,
                        ),
                      ),
                    ],
                    // Mobile full-screen inspector overlay
                    if (layout == ShellLayout.mobile && inspector != null)
                      Positioned.fill(child: inspector!),
                    // Toast feedback
                    if (store.toastMessage != null)
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: (layout == ShellLayout.mobile ? 76.0 : 24.0) +
                            MediaQuery.paddingOf(context).bottom,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: store.toastIsError
                                    ? t.critical
                                    : (t.isDark
                                        ? const Color(0xFF2C2C2E)
                                        : const Color(0xFF1D1D1F)),
                                borderRadius: BorderRadius.circular(
                                    AppleTokens.radiusPill),
                                boxShadow: t.floatShadow,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppIcon(
                                    store.toastIsError
                                        ? AppIconName.alert
                                        : AppIconName.checkCircle,
                                    size: 14,
                                    color: store.toastIsError
                                        ? Colors.white
                                        : t.success,
                                    semanticsLabel:
                                        store.toastIsError ? '错误' : '成功',
                                  ),
                                  const SizedBox(width: 7),
                                  Flexible(
                                    child: Text(
                                      store.toastMessage!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  bool _isTextInputFocused() {
    final primary = FocusManager.instance.primaryFocus;
    final w = primary?.context?.widget;
    return w is EditableText || (w is Focus && w.debugLabel == 'EditableText');
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return SizedBox(
      width: AppleTokens.sidebarWidth,
      child: FrostedSurface(
        color: t.bgRail,
        border: Border(right: BorderSide(color: t.borderHairline)),
        child: SafeArea(
          bottom: false,
          right: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Brand header
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 6, 14),
                child: Row(
                  children: [
                    const DinglinBrandMark(size: 26),
                    const SizedBox(width: 9),
                    Text(
                      'Dinglin',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                        color: t.inkPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              _SidebarNavItem(
                icon: AppIconName.bell,
                label: '通知',
                badge: store.unreadCount,
                active: store.activeTab == AppTab.inbox &&
                    store.selectedSourceId == null,
                onTap: () {
                  store.setSelectedSource(null);
                  store.setTab(AppTab.inbox);
                },
              ),
              const SizedBox(height: 2),
              _SidebarNavItem(
                icon: AppIconName.clock,
                label: '调度',
                badge: store.activeScheduleCount,
                active: store.activeTab == AppTab.schedules,
                onTap: () => store.setTab(AppTab.schedules),
              ),
              if (store.sources.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 18, 10, 6),
                  child: Text(
                    '来源',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: t.inkTertiary,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final src in store.sources)
                        _SourceNavItem(
                          source: src,
                          unreadCount: store.unreadCountForSource(src.id),
                          active: store.activeTab == AppTab.inbox &&
                              store.selectedSourceId == src.id,
                          onTap: () => store.setSelectedSource(src.id),
                        ),
                    ],
                  ),
                ),
              ] else
                const Spacer(),
              // Footer: connection pill + settings SVG icon
              Container(
                padding: const EdgeInsets.only(top: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: t.borderHairline)),
                ),
                child: Row(
                  children: [
                    _ConnectionIndicator(
                      status: store.connectionStatus,
                      onTap: () => store.setTab(AppTab.settings),
                    ),
                    const Spacer(),
                    AppleIconButton(
                      icon: AppIconName.settings,
                      tooltip: '设置',
                      active: store.activeTab == AppTab.settings,
                      onPressed: () => store.setTab(AppTab.settings),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _CompactRail extends StatelessWidget {
  const _CompactRail({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return SizedBox(
      width: AppleTokens.railWidth,
      child: FrostedSurface(
        color: t.bgRail,
        border: Border(right: BorderSide(color: t.borderHairline)),
        child: SafeArea(
          bottom: false,
          right: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
            children: [
              const DinglinBrandMark(size: 30),
              const SizedBox(height: 18),
              AppleIconButton(
                icon: AppIconName.bell,
                tooltip: '通知',
                size: 40,
                iconSize: 19,
                active: store.activeTab == AppTab.inbox,
                onPressed: () => store.setTab(AppTab.inbox),
              ),
              const SizedBox(height: 6),
              AppleIconButton(
                icon: AppIconName.clock,
                tooltip: '调度',
                size: 40,
                iconSize: 19,
                active: store.activeTab == AppTab.schedules,
                onPressed: () => store.setTab(AppTab.schedules),
              ),
              const Spacer(),
              Tooltip(
                message: '连接设置',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => store.setTab(AppTab.settings),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: _StatusDot(status: store.connectionStatus),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              AppleIconButton(
                icon: AppIconName.settings,
                tooltip: '设置',
                size: 40,
                iconSize: 19,
                active: store.activeTab == AppTab.settings,
                onPressed: () => store.setTab(AppTab.settings),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _MobileTabBar extends StatelessWidget {
  const _MobileTabBar({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return FrostedSurface(
      color: t.bgRail,
      border: Border(top: BorderSide(color: t.borderHairline)),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MobileTabItem(
                icon: AppIconName.bell,
                label: '通知',
                badge: store.unreadCount,
                active: store.activeTab == AppTab.inbox,
                onTap: () => store.setTab(AppTab.inbox),
              ),
              _MobileTabItem(
                icon: AppIconName.clock,
                label: '调度',
                active: store.activeTab == AppTab.schedules,
                onTap: () => store.setTab(AppTab.schedules),
              ),
              _MobileTabItem(
                icon: AppIconName.settings,
                label: '设置',
                active: store.activeTab == AppTab.settings,
                onTap: () => store.setTab(AppTab.settings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileTabItem extends StatelessWidget {
  const _MobileTabItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final AppIconName icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final color = active ? t.accent : t.inkSecondary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AppIcon(icon, size: 20, color: color, semanticsLabel: label),
                if (badge > 0)
                  Positioned(
                    top: -5,
                    right: -11,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      decoration: BoxDecoration(
                        color: t.critical,
                        borderRadius:
                            BorderRadius.circular(AppleTokens.radiusPill),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: AppleTokens.tabular.copyWith(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarNavItem extends StatefulWidget {
  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.badge,
    required this.active,
    required this.onTap,
  });

  final AppIconName icon;
  final String label;
  final int badge;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppleTokens.motion,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.active
                ? t.bgSelected
                : _hovered
                    ? t.bgHover
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
          ),
          child: Row(
            children: [
              AppIcon(
                widget.icon,
                size: 16,
                color: widget.active ? t.accent : t.inkSecondary,
                semanticsLabel: widget.label,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        widget.active ? FontWeight.w500 : FontWeight.w400,
                    color: widget.active ? t.accent : t.inkPrimary,
                  ),
                ),
              ),
              if (widget.badge > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: widget.active ? t.accent : t.bgHover,
                    borderRadius:
                        BorderRadius.circular(AppleTokens.radiusPill),
                  ),
                  child: Text(
                    '${widget.badge}',
                    style: AppleTokens.tabular.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: widget.active ? Colors.white : t.inkSecondary,
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

class _SourceNavItem extends StatelessWidget {
  const _SourceNavItem({
    required this.source,
    required this.unreadCount,
    required this.active,
    required this.onTap,
  });

  final DinglinSource source;
  final int unreadCount;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: active ? t.bgSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: parseHexColor(source.color, fallback: t.accent),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  source.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                    color: active ? t.accent : t.inkPrimary,
                  ),
                ),
              ),
              if (unreadCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: active ? t.accent : t.bgHover,
                    borderRadius:
                        BorderRadius.circular(AppleTokens.radiusPill),
                  ),
                  child: Text(
                    '$unreadCount',
                    style: AppleTokens.tabular.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: active ? Colors.white : t.inkSecondary,
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

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.status, this.onTap});
  final ConnectionStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final label = switch (status) {
      ConnectionStatus.connected => '已连接',
      ConnectionStatus.reconnecting => '重连中',
      ConnectionStatus.offline => '离线',
      ConnectionStatus.unconfigured => '未配置',
    };
    return Tooltip(
      message: '网关连接设置',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 6),
                _StatusDot(status: status),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: t.inkSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final (dot, halo) = switch (status) {
      ConnectionStatus.connected => (t.success, t.successBg),
      ConnectionStatus.reconnecting => (t.warning, t.warningBg),
      ConnectionStatus.offline => (t.critical, t.criticalBg),
      ConnectionStatus.unconfigured => (t.inkTertiary, t.bgHover),
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: dot,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: halo, spreadRadius: 3)],
      ),
    );
  }
}
