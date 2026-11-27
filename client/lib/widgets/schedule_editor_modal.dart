import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import 'app_icon.dart';
import 'apple_primitives.dart';

enum RepeatPreset { daily, weekdays, weekends, once, custom }

String buildCronFromPreset(
  RepeatPreset preset,
  int hour,
  int minute,
  String customCron,
) {
  return switch (preset) {
    RepeatPreset.daily => '$minute $hour * * *',
    RepeatPreset.weekdays => '$minute $hour * * 1-5',
    RepeatPreset.weekends => '$minute $hour * * 0,6',
    RepeatPreset.custom => customCron.trim(),
    RepeatPreset.once => '',
  };
}

Future<void> showScheduleEditorModal(
  BuildContext context, {
  required AppStore store,
  DinglinSchedule? existing,
}) {
  return showAppleAdaptiveModal<void>(
    context: context,
    title: existing == null ? '新建调度' : '编辑调度',
    showClose: true,
    maxWidth: 440,
    builder: (_) => ScheduleEditorModal(
      store: store,
      existing: existing,
      embedded: true,
    ),
  );
}

class ScheduleEditorModal extends StatefulWidget {
  const ScheduleEditorModal({
    super.key,
    required this.store,
    this.existing,
    this.embedded = false,
  });

  final AppStore store;
  final DinglinSchedule? existing;
  final bool embedded;

  @override
  State<ScheduleEditorModal> createState() => _ScheduleEditorModalState();
}

class _ScheduleEditorModalState extends State<ScheduleEditorModal> {
  final _formKey = GlobalKey<FormState>();
  late String _kind;
  late String _priority;
  late RepeatPreset _repeat;
  late String _timezone;
  late bool _vibrate;
  late int _hour;
  late int _minute;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _cronCtrl;
  late final TextEditingController _durationMinCtrl;
  late final TextEditingController _snoozeCtrl;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? 'alarm';
    _priority = _kind == 'alarm'
        ? 'critical'
        : (e?.priority ?? 'normal');
    _timezone = (e != null && e.timezone.isNotEmpty)
        ? e.timezone
        : widget.store.localTimezone;
    _vibrate = e?.vibrate ?? true;
    _titleCtrl = TextEditingController(text: e?.title ?? '');
    _bodyCtrl = TextEditingController(text: e?.body ?? '');
    _cronCtrl = TextEditingController(text: e?.cronExpr ?? '0 8 * * 1-5');
    _durationMinCtrl = TextEditingController(
      text: e != null && e.durationSec > 0
          ? '${(e.durationSec / 60).ceil()}'
          : '15',
    );
    _snoozeCtrl = TextEditingController(text: '${e?.snoozeMinutes ?? 10}');

    final now = DateTime.now().add(const Duration(minutes: 10));
    _hour = now.hour;
    _minute = now.minute;
    _repeat = RepeatPreset.daily;

    if (e != null && e.scheduleType == 'once' && e.fireAt != null) {
      _repeat = RepeatPreset.once;
      final loc = e.fireAt!.toLocal();
      _hour = loc.hour;
      _minute = loc.minute;
    } else if (e != null && e.cronExpr.isNotEmpty) {
      final parts = e.cronExpr.split(RegExp(r'\s+'));
      if (parts.length == 5) {
        _minute = int.tryParse(parts[0]) ?? _minute;
        _hour = int.tryParse(parts[1]) ?? _hour;
        if (parts[4] == '*') {
          _repeat = RepeatPreset.daily;
        } else if (parts[4] == '1-5') {
          _repeat = RepeatPreset.weekdays;
        } else if (parts[4] == '0,6' || parts[4] == '6,0') {
          _repeat = RepeatPreset.weekends;
        } else {
          _repeat = RepeatPreset.custom;
        }
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _cronCtrl.dispose();
    _durationMinCtrl.dispose();
    _snoozeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    var tempHour = _hour;
    var tempMinute = _minute;
    final confirmed = await showAppleAdaptiveModal<bool>(
      context: context,
      title: '选择时间',
      showClose: true,
      maxWidth: 340,
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 180,
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: t.isDark ? Brightness.dark : Brightness.light,
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: AppleTokens.tabular.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w500,
                      color: t.inkPrimary,
                    ),
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: true,
                  initialDateTime: DateTime(2026, 1, 1, _hour, _minute),
                  onDateTimeChanged: (dt) {
                    tempHour = dt.hour;
                    tempMinute = dt.minute;
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: Colors.white,
              ),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) {
      setState(() {
        _hour = tempHour;
        _minute = tempMinute;
      });
    }
  }

  Future<void> _pickTimezone() async {
    final zones = <String>{...commonIanaTimezones, _timezone}.toList();
    final picked = await showAppleAdaptiveModal<String>(
      context: context,
      title: '时区',
      showClose: true,
      maxWidth: 360,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
      builder: (ctx) {
        final t = AppleTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final tz in zones)
              ApplePressable(
                onTap: () => Navigator.of(ctx).pop(tz),
                pressedScale: 0.99,
                builder: (context, hovered, pressed) {
                  final selected = tz == _timezone;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? t.bgSelected
                          : pressed
                              ? t.bgPressed
                              : hovered
                                  ? t.bgHover
                                  : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tz,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected ? t.accent : t.inkPrimary,
                            ),
                          ),
                        ),
                        if (selected)
                          AppIcon(
                            AppIconName.check,
                            size: 15,
                            color: t.accent,
                            semanticsLabel: '已选中',
                          ),
                      ],
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _timezone = picked);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final snoozeMins = int.tryParse(_snoozeCtrl.text.trim()) ?? 0;
    if (_kind != 'countdown' && snoozeMins <= 0) {
      setState(() => _error = '贪睡时长须为正整数');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final payload = <String, dynamic>{
        'kind': _kind,
        'title': _titleCtrl.text.trim(),
        'body': _bodyCtrl.text.trim(),
        'priority': _kind == 'alarm' ? 'critical' : _priority,
        'snooze_minutes': snoozeMins > 0 ? snoozeMins : 10,
        'timezone': _timezone,
        'vibrate': _vibrate,
      };

      if (_kind == 'countdown') {
        final mins = int.tryParse(_durationMinCtrl.text.trim()) ?? 0;
        if (mins <= 0) {
          setState(() {
            _error = '倒计时时长须大于 0 分钟';
            _submitting = false;
          });
          return;
        }
        payload['schedule_type'] = 'duration';
        payload['duration_sec'] = mins * 60;
        payload['auto_start'] = true;
      } else if (_repeat == RepeatPreset.once) {
        final now = DateTime.now();
        var target = DateTime(now.year, now.month, now.day, _hour, _minute);
        if (!target.isAfter(now)) {
          target = target.add(const Duration(days: 1));
        }
        payload['schedule_type'] = 'once';
        payload['fire_at'] = target.toUtc().toIso8601String();
      } else {
        final cron =
            buildCronFromPreset(_repeat, _hour, _minute, _cronCtrl.text);
        if (cron.split(RegExp(r'\s+')).length != 5) {
          setState(() {
            _error = 'Cron 表达式须为 5 字段';
            _submitting = false;
          });
          return;
        }
        payload['schedule_type'] = 'cron';
        payload['cron_expr'] = cron;
      }

      if (widget.existing == null) {
        await widget.store.createSchedule(payload);
      } else {
        await widget.store.updateSchedule(widget.existing!.id, payload);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    }
  }

  Widget _buildFormContent(AppleTokens t) {
    final currentDuration = int.tryParse(_durationMinCtrl.text.trim());
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.existing == null) ...[
            Center(
              child: AppleSegmentedControl<String>(
                value: _kind,
                options: const [
                  (value: 'alarm', label: '闹钟'),
                  (value: 'scheduled_notification', label: '定时通知'),
                  (value: 'countdown', label: '倒计时'),
                ],
                onChanged: (v) => setState(() {
                  _kind = v;
                  _priority = v == 'alarm' ? 'critical' : 'normal';
                }),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _LabeledField(
            label: '标题',
            child: TextFormField(
              controller: _titleCtrl,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '请输入标题' : null,
              decoration: appleInputDecoration(t, hint: '标题'),
            ),
          ),
          const SizedBox(height: 12),
          _LabeledField(
            label: '备注',
            child: TextFormField(
              controller: _bodyCtrl,
              decoration: appleInputDecoration(t, hint: '备注'),
            ),
          ),
          const SizedBox(height: 12),
          if (_kind == 'countdown')
            _LabeledField(
              label: '时长（分钟）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppleChipSelector<int>(
                    value: currentDuration,
                    options: const [
                      (value: 5, label: '5m'),
                      (value: 15, label: '15m'),
                      (value: 25, label: '25m'),
                      (value: 45, label: '45m'),
                    ],
                    onChanged: (mins) => setState(
                      () => _durationMinCtrl.text = '$mins',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _durationMinCtrl,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    validator: (v) =>
                        (int.tryParse((v ?? '').trim()) ?? 0) <= 0
                            ? '请输入正整数'
                            : null,
                    decoration: appleInputDecoration(t, hint: '分钟'),
                  ),
                ],
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: _LabeledField(
                    label: '时间',
                    child: ApplePressable(
                      onTap: _pickTime,
                      pressedScale: 0.98,
                      builder: (context, hovered, pressed) {
                        return AnimatedContainer(
                          duration: AppleTokens.motionFast,
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: pressed
                                ? t.bgPressed
                                : hovered
                                    ? t.bgHover
                                    : t.bgSurfaceSecondary,
                            borderRadius:
                                BorderRadius.circular(AppleTokens.radiusSm),
                            border: Border.all(
                              color: hovered ? t.accent : t.borderHairline,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}',
                                  style: AppleTokens.tabular.copyWith(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: t.inkPrimary,
                                  ),
                                ),
                              ),
                              AppIcon(
                                AppIconName.clock,
                                size: 14,
                                color: t.inkTertiary,
                                semanticsLabel: '选择时间',
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LabeledField(
                    label: '贪睡（分钟）',
                    child: TextFormField(
                      controller: _snoozeCtrl,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          (int.tryParse((v ?? '').trim()) ?? 0) <= 0
                              ? '须为正整数'
                              : null,
                      decoration: appleInputDecoration(t, hint: '分钟'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _LabeledField(
              label: '时区',
              child: ApplePressable(
                onTap: _pickTimezone,
                pressedScale: 0.99,
                builder: (context, hovered, pressed) {
                  return AnimatedContainer(
                    duration: AppleTokens.motionFast,
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: pressed
                          ? t.bgPressed
                          : hovered
                              ? t.bgHover
                              : t.bgSurfaceSecondary,
                      borderRadius:
                          BorderRadius.circular(AppleTokens.radiusSm),
                      border: Border.all(
                        color: hovered ? t.accent : t.borderHairline,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _timezone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: t.inkPrimary,
                            ),
                          ),
                        ),
                        AppIcon(
                          AppIconName.chevronRight,
                          size: 14,
                          color: t.inkTertiary,
                          semanticsLabel: '选择时区',
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            _LabeledField(
              label: '重复',
              child: AppleChipSelector<RepeatPreset>(
                value: _repeat,
                options: const [
                  (value: RepeatPreset.daily, label: '每天'),
                  (value: RepeatPreset.weekdays, label: '工作日'),
                  (value: RepeatPreset.weekends, label: '周末'),
                  (value: RepeatPreset.once, label: '单次'),
                  (value: RepeatPreset.custom, label: '自定义'),
                ],
                onChanged: (preset) => setState(() => _repeat = preset),
              ),
            ),
            if (_repeat == RepeatPreset.custom) ...[
              const SizedBox(height: 10),
              _LabeledField(
                label: 'Cron（5 字段）',
                child: TextFormField(
                  controller: _cronCtrl,
                  decoration: appleInputDecoration(t, hint: '0 8 * * 1-5'),
                ),
              ),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '震动',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: t.inkSecondary,
                ),
              ),
              const Spacer(),
              AppleSwitch(
                value: _vibrate,
                semanticsLabel: '震动',
                onChanged: (v) => setState(() => _vibrate = v),
              ),
            ],
          ),
          if (_kind != 'alarm') ...[
            const SizedBox(height: 12),
            _LabeledField(
              label: '级别',
              child: AppleSegmentedControl<String>(
                value: _priority,
                options: const [
                  (value: 'silent', label: '静默'),
                  (value: 'normal', label: '普通'),
                  (value: 'critical', label: '强提醒'),
                ],
                onChanged: (v) => setState(() => _priority = v),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: t.critical),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _submitting ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: Colors.white,
                ),
                child: Text(_submitting ? '保存中…' : '保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    if (widget.embedded) {
      return _buildFormContent(t);
    }
    return AppleDialogShell(
      title: widget.existing == null ? '新建调度' : '编辑调度',
      showClose: true,
      maxWidth: 440,
      child: _buildFormContent(t),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: t.inkSecondary,
          ),
        ),
        const SizedBox(height: 5),
        child,
      ],
    );
  }
}
