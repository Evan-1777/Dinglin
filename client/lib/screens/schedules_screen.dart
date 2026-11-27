import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/apple_primitives.dart';
import '../widgets/schedule_editor_modal.dart';

class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({
    super.key,
    required this.store,
  });

  final AppStore store;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  Duration? _currentInterval;
  bool _paused = false;
  DateTime _now = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(_onStoreChanged);
    _reconcileTimer();
  }

  @override
  void didUpdateWidget(covariant SchedulesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    _reconcileTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _paused = true;
      _stopTimer();
    } else if (state == AppLifecycleState.resumed) {
      _paused = false;
      if (mounted) setState(() => _now = DateTime.now().toUtc());
      _reconcileTimer();
    }
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _reconcileTimer();
  }

  Duration? _desiredInterval(DateTime now) {
    if (_paused) return null;
    final list = widget.store.schedules;
    if (list.isEmpty) return null;

    var needsSecond = false;
    var hasUpcoming = false;
    for (final s in list) {
      if (s.state == 'ringing') {
        needsSecond = true;
        break;
      }
      if (s.kind == 'countdown' && s.state == 'active') {
        needsSecond = true;
        break;
      }
      if (s.enabled && s.nextFireAt != null) {
        hasUpcoming = true;
        final diffSec = s.nextFireAt!.difference(now).inSeconds;
        if (diffSec >= -5 && diffSec <= 65) {
          needsSecond = true;
          break;
        }
      }
    }
    if (needsSecond) return const Duration(seconds: 1);
    if (hasUpcoming) return const Duration(seconds: 30);
    return null;
  }

  void _reconcileTimer() {
    final desired = _desiredInterval(_now);
    if (desired == _currentInterval) return;
    _stopTimer();
    if (desired == null) return;
    _currentInterval = desired;
    _ticker = Timer.periodic(desired, (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now().toUtc());
      _reconcileTimer();
    });
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
    _currentInterval = null;
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    super.dispose();
  }

  void _openEditor({DinglinSchedule? existing}) {
    showScheduleEditorModal(
      context,
      store: widget.store,
      existing: existing,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final store = widget.store;
    final items = store.filteredSchedules;

    return Column(
      children: [
        AppleTopBar(
          title: '调度',
          trailing: [
            AppleIconButton(
              icon: AppIconName.plus,
              tooltip: '新建调度',
              primary: true,
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            color: t.accent,
            onRefresh: store.refreshAll,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppleSegmentedControl<String>(
                            value: store.scheduleKindFilter,
                            options: const [
                              (value: 'all', label: '全部'),
                              (value: 'alarm', label: '闹钟'),
                              (value: 'scheduled_notification', label: '定时通知'),
                              (value: 'countdown', label: '倒计时'),
                            ],
                            onChanged: store.setScheduleKindFilter,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 72),
                            child: Column(
                              children: [
                                AppIcon(
                                  AppIconName.alarmClock,
                                  size: 32,
                                  color: t.inkTertiary,
                                  semanticsLabel: '暂无调度',
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '暂无调度',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: t.inkSecondary,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                AppleActionChip(
                                  icon: AppIconName.plus,
                                  label: '新建调度',
                                  onPressed: () => _openEditor(),
                                ),
                              ],
                            ),
                          )
                        else
                          LayoutBuilder(
                            builder: (context, c) {
                              final cols = c.maxWidth >= 640 ? 2 : 1;
                              final cardWidth =
                                  (c.maxWidth - (cols - 1) * 12) / cols;
                              return Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  for (final sc in items)
                                    SizedBox(
                                      width: cardWidth,
                                      child: _ScheduleCard(
                                        schedule: sc,
                                        now: _now,
                                        store: store,
                                        onEdit: () => _openEditor(existing: sc),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.schedule,
    required this.now,
    required this.store,
    required this.onEdit,
  });

  final DinglinSchedule schedule;
  final DateTime now;
  final AppStore store;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final isCountdown = schedule.kind == 'countdown';
    final isAlarm = schedule.kind == 'alarm';
    final isRinging = schedule.state == 'ringing';
    final rem = schedule.liveRemainingSec(now);
    final progress = isCountdown && schedule.durationSec > 0
        ? (rem / schedule.durationSec).clamp(0.0, 1.0)
        : 0.0;

    final kindIcon = switch (schedule.kind) {
      'alarm' => AppIconName.alarmClock,
      'countdown' => AppIconName.timer,
      _ => AppIconName.calendar,
    };
    final kindLabel = switch (schedule.kind) {
      'alarm' => '闹钟',
      'countdown' => '倒计时',
      _ => '定时通知',
    };

    return Opacity(
      opacity: schedule.enabled || isCountdown || isRinging ? 1.0 : 0.56,
      child: Container(
        decoration: BoxDecoration(
          color: t.bgSurface,
          borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
          border: Border.all(
            color: isRinging ? t.critical : t.borderHairline,
            width: isRinging ? 1.25 : 1.0,
          ),
          boxShadow: t.cardShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 1,
              child: ColoredBox(
                color: isRinging ? t.critical.withValues(alpha: 0.4) : t.borderSpecular,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                AppIcon(
                                  kindIcon,
                                  size: 13.5,
                                  color: isRinging
                                      ? t.critical
                                      : isAlarm
                                          ? t.accent
                                          : t.inkSecondary,
                                  semanticsLabel: kindLabel,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  kindLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: isRinging
                                        ? t.critical
                                        : t.inkSecondary,
                                  ),
                                ),
                                if (isRinging) ...[
                                  const SizedBox(width: 8),
                                  ApplePill(
                                    label: '响铃中',
                                    background: t.criticalBg,
                                    foreground: t.critical,
                                  ),
                                ] else if (!isAlarm &&
                                    schedule.priority == 'critical') ...[
                                  const SizedBox(width: 8),
                                  ApplePill(
                                    label: '强提醒',
                                    background: t.criticalBg,
                                    foreground: t.critical,
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              formatClockFromSchedule(schedule, now),
                              style: AppleTokens.tabular.copyWith(
                                fontSize: 32,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -1.0,
                                height: 1.08,
                                color: t.inkPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!isCountdown)
                        AppleSwitch(
                          value: schedule.enabled,
                          semanticsLabel: schedule.title,
                          onChanged: (v) =>
                              store.toggleSchedule(schedule.id, v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    schedule.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: t.inkPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        isCountdown
                            ? (schedule.state == 'active'
                                ? '运行中'
                                : schedule.state == 'paused'
                                    ? '已暂停'
                                    : '已完成')
                            : schedule.scheduleType == 'cron'
                                ? formatCronLabel(schedule.cronExpr)
                                : '单次',
                        style: TextStyle(fontSize: 12, color: t.inkSecondary),
                      ),
                      if (!isCountdown &&
                          schedule.enabled &&
                          schedule.nextFireAt != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '· ${formatFutureTime(schedule.nextFireAt!, now: now)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppleTokens.tabular.copyWith(
                              fontSize: 12,
                              color: t.inkTertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (isCountdown) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: t.bgSurfaceSecondary,
                        valueColor: AlwaysStoppedAnimation(t.accent),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (isCountdown) ...[
                        if (schedule.state == 'active')
                          AppleActionChip(
                            icon: AppIconName.pause,
                            tooltip: '暂停',
                            onPressed: () =>
                                store.countdownAction(schedule.id, 'pause'),
                          )
                        else
                          AppleActionChip(
                            icon: AppIconName.play,
                            tooltip: '开始',
                            onPressed: () => store.countdownAction(
                              schedule.id,
                              schedule.state == 'paused' ? 'resume' : 'start',
                            ),
                          ),
                        const SizedBox(width: 6),
                        AppleActionChip(
                          icon: AppIconName.reset,
                          tooltip: '重置',
                          onPressed: () =>
                              store.countdownAction(schedule.id, 'reset'),
                        ),
                      ] else if (isRinging) ...[
                        AppleActionChip(
                          icon: AppIconName.snooze,
                          label: '贪睡',
                          onPressed: () => store.snoozeSchedule(schedule.id),
                        ),
                        const SizedBox(width: 6),
                        AppleActionChip(
                          icon: AppIconName.close,
                          label: '关闭',
                          danger: true,
                          onPressed: () => store.dismissSchedule(schedule.id),
                        ),
                      ],
                      const Spacer(),
                      AppleIconButton(
                        icon: AppIconName.edit,
                        tooltip: '编辑',
                        onPressed: onEdit,
                      ),
                      AppleIconButton(
                        icon: AppIconName.trash,
                        tooltip: '删除',
                        danger: true,
                        onPressed: () async {
                          final ok = await showAppleConfirmDialog(
                            context,
                            title: '删除调度',
                            message: '确认删除「${schedule.title}」？此操作不可撤销。',
                            confirmLabel: '删除',
                          );
                          if (ok) {
                            try {
                              await store.deleteSchedule(schedule.id);
                            } catch (e) {
                              store.showToast(e.toString(), isError: true);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
