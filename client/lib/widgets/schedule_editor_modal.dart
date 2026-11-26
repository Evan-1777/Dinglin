import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import 'apple_primitives.dart';

enum RepeatPreset { daily, weekdays, weekends, once, custom }

String buildCronFromPreset(RepeatPreset preset, int hour, int minute, String customCron) {
  return switch (preset) {
    RepeatPreset.daily => '$minute $hour * * *',
    RepeatPreset.weekdays => '$minute $hour * * 1-5',
    RepeatPreset.weekends => '$minute $hour * * 0,6',
    RepeatPreset.custom => customCron.trim(),
    RepeatPreset.once => '',
  };
}

class ScheduleEditorModal extends StatefulWidget {
  const ScheduleEditorModal({
    super.key,
    required this.store,
    this.existing,
  });

  final AppStore store;
  final DinglinSchedule? existing;

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
    _priority = e?.priority ?? (_kind == 'alarm' ? 'critical' : 'normal');
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
        'priority': _priority,
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

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return AppleDialogShell(
      title: widget.existing == null ? '新建调度' : '编辑调度',
      showClose: true,
      maxWidth: 440,
      child: Form(
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
                decoration: appleInputDecoration(t, hint: '例如：晨会闹钟'),
              ),
            ),
            const SizedBox(height: 12),
            _LabeledField(
              label: '备注',
              child: TextFormField(
                controller: _bodyCtrl,
                decoration: appleInputDecoration(t, hint: '可选'),
              ),
            ),
            const SizedBox(height: 12),
            if (_kind == 'countdown')
              _LabeledField(
                label: '时长（分钟）',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final mins in const [5, 15, 25, 45])
                          ChoiceChip(
                            label: Text('${mins}m'),
                            selected: _durationMinCtrl.text.trim() == '$mins',
                            onSelected: (_) => setState(
                              () => _durationMinCtrl.text = '$mins',
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _durationMinCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      validator: (v) => (int.tryParse((v ?? '').trim()) ?? 0) <= 0
                          ? '请输入正整数'
                          : null,
                      decoration: appleInputDecoration(t, hint: '15'),
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
                      child: GestureDetector(
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime:
                                TimeOfDay(hour: _hour, minute: _minute),
                          );
                          if (picked != null) {
                            setState(() {
                              _hour = picked.hour;
                              _minute = picked.minute;
                            });
                          }
                        },
                        child: Container(
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: t.bgSurfaceSecondary,
                            borderRadius:
                                BorderRadius.circular(AppleTokens.radiusSm),
                            border: Border.all(color: t.borderHairline),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}',
                            style: AppleTokens.tabular.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: t.inkPrimary,
                            ),
                          ),
                        ),
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
                        decoration: appleInputDecoration(t, hint: '10'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: '时区',
                child: DropdownButtonFormField<String>(
                  initialValue: _timezone,
                  isExpanded: true,
                  decoration: appleInputDecoration(t, hint: '选择时区'),
                  dropdownColor: t.bgSurface,
                  style: TextStyle(fontSize: 13, color: t.inkPrimary),
                  items: [
                    for (final tz in {
                      ...commonIanaTimezones,
                      _timezone,
                    })
                      DropdownMenuItem(value: tz, child: Text(tz)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _timezone = v);
                  },
                ),
              ),
              const SizedBox(height: 12),
              _LabeledField(
                label: '重复',
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final item in const [
                      (RepeatPreset.daily, '每天'),
                      (RepeatPreset.weekdays, '工作日'),
                      (RepeatPreset.weekends, '周末'),
                      (RepeatPreset.once, '单次'),
                      (RepeatPreset.custom, '自定义'),
                    ])
                      ChoiceChip(
                        label: Text(item.$2),
                        selected: _repeat == item.$1,
                        onSelected: (_) => setState(() => _repeat = item.$1),
                      ),
                  ],
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
                  '震动提醒',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: t.inkSecondary,
                  ),
                ),
                const Spacer(),
                AppleSwitch(
                  value: _vibrate,
                  semanticsLabel: '震动提醒',
                  onChanged: (v) => setState(() => _vibrate = v),
                ),
              ],
            ),
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
      ),
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
