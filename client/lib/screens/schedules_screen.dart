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

class _SchedulesScreenState extends State<SchedulesScreen> {
  Timer? _ticker;
  DateTime _now = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now().toUtc());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _openEditor({DinglinSchedule? existing}) {
    showDialog<void>(
      context: context,
      builder: (_) => ScheduleEditorModal(
        store: widget.store,
        existing: existing,
      ),
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
          child: ListView(
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
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: AppleSegmentedControl<String>(
                            value: store.scheduleKindFilter,
                            options: const [
                              (value: 'all', label: '全部'),
                              (value: 'scheduled_notification', label: '定时通知'),
                              (value: 'alarm', label: '闹钟'),
                              (value: 'countdown', label: '倒计时'),
                            ],
                            onChanged: store.setScheduleKindFilter,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 72),
                          child: Column(
                            children: [
                              AppIcon(
                                AppIconName.clock,
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
    final rem = schedule.liveRemainingSec(now);
    final progress = isCountdown && schedule.durationSec > 0
        ? (rem / schedule.durationSec).clamp(0.0, 1.0)
        : 0.0;

    final kindIcon = switch (schedule.kind) {
      'alarm' => AppIconName.clock,
      'countdown' => AppIconName.timer,
      _ => AppIconName.calendar,
    };
    final kindLabel = switch (schedule.kind) {
      'alarm' => '闹钟',
      'countdown' => '倒计时',
      _ => '定时通知',
    };

    return Opacity(
      opacity: schedule.enabled || isCountdown ? 1.0 : 0.6,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.bgSurface,
          borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
          border: Border.all(
            color: schedule.state == 'ringing' ? t.critical : t.borderHairline,
          ),
          boxShadow: t.cardShadow,
        ),
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
                          AppIcon(kindIcon,
                              size: 13,
                              color: t.inkSecondary,
                              semanticsLabel: kindLabel),
                          const SizedBox(width: 5),
                          Text(
                            kindLabel,
                            style: TextStyle(
                              fontSize: 12,
                              color: t.inkSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (schedule.priority == 'critical')
                            ApplePill(
                              label: '强提醒',
                              background: t.criticalBg,
                              foreground: t.critical,
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        formatClockFromSchedule(schedule, now),
                        style: AppleTokens.tabular.copyWith(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.8,
                          height: 1.1,
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
                    onChanged: (v) => store.toggleSchedule(schedule.id, v),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              schedule.title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
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
                if (!isCountdown && schedule.enabled) ...[
                  const SizedBox(width: 8),
                  ApplePill(
                    label: '已同步',
                    background: t.successBg,
                    foreground: t.success,
                  ),
                  if (schedule.nextFireAt != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '下次 · ${formatFutureTime(schedule.nextFireAt!, now: now)}',
                        overflow: TextOverflow.ellipsis,
                        style: AppleTokens.tabular.copyWith(
                          fontSize: 12,
                          color: t.inkTertiary,
                        ),
                      ),
                    ),
                  ],
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
                ] else if (schedule.state == 'ringing') ...[
                  AppleActionChip(
                    icon: AppIconName.snooze,
                    label: '贪睡',
                    onPressed: () => store.snoozeSchedule(schedule.id),
                  ),
                  const SizedBox(width: 6),
                  AppleActionChip(
                    icon: AppIconName.close,
                    label: '关闭',
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
                        store.showToast(e.toString());
                      }
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
