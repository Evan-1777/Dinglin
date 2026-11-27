import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme/apple_tokens.dart';
import 'app_icon.dart';
import 'apple_primitives.dart';

/// Cross-platform full-screen Apple Clock alarm ringing overlay.
class AlarmRingingOverlay extends StatefulWidget {
  const AlarmRingingOverlay({
    super.key,
    required this.store,
    required this.schedule,
  });

  final AppStore store;
  final DinglinSchedule schedule;

  @override
  State<AlarmRingingOverlay> createState() => _AlarmRingingOverlayState();
}

class _AlarmRingingOverlayState extends State<AlarmRingingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late Timer _clockTimer;
  DateTime _now = DateTime.now();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.store.dismissSchedule(widget.schedule.id);
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _snooze() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.store.snoozeSchedule(widget.schedule.id);
    } catch (e) {
      widget.store.showToast(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _formatClock(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final schedule = widget.schedule;
    final snoozeMins = schedule.snoozeMinutes > 0 ? schedule.snoozeMinutes : 10;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0C1018),
              Color(0xFF06070A),
              Color(0xFF000000),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    AnimatedBuilder(
                      animation: _pulseCtrl,
                      builder: (context, child) {
                        final v = Curves.easeInOut.transform(_pulseCtrl.value);
                        return Container(
                          width: 82,
                          height: 82,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color.lerp(
                              const Color(0x1F0A84FF),
                              const Color(0x380A84FF),
                              v,
                            ),
                            border: Border.all(
                              color: Color.lerp(
                                const Color(0x4D0A84FF),
                                const Color(0x99409CFF),
                                v,
                              )!,
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0A84FF)
                                    .withValues(alpha: 0.16 + 0.18 * v),
                                blurRadius: 24 + 14 * v,
                                spreadRadius: 2 + 4 * v,
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: child,
                        );
                      },
                      child: const AppIcon(
                        AppIconName.alarmClock,
                        size: 32,
                        color: Color(0xFF409CFF),
                        semanticsLabel: '闹钟响铃中',
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      _formatClock(_now),
                      style: AppleTokens.tabular.copyWith(
                        fontSize: 60,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -2.0,
                        height: 1.05,
                        color: const Color(0xFFF5F5F7),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      schedule.title.isNotEmpty ? schedule.title : '闹钟',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                        color: Color(0xFFF5F5F7),
                      ),
                    ),
                    if (schedule.body.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        schedule.body,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: Color(0xFF98989D),
                        ),
                      ),
                    ],
                    const Spacer(flex: 3),
                    ApplePressable(
                      onTap: _submitting ? null : _snooze,
                      haptic: AppleHaptic.selection,
                      pressedScale: 0.97,
                      builder: (context, hovered, pressed) {
                        return AnimatedContainer(
                          duration: AppleTokens.motionFast,
                          height: 52,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: pressed
                                ? const Color(0xFF3A3A3C)
                                : hovered
                                    ? const Color(0xFF323234)
                                    : const Color(0xFF242426),
                            borderRadius: BorderRadius.circular(
                              AppleTokens.radiusPill,
                            ),
                            border: Border.all(
                              color: const Color(0x26FFFFFF),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const AppIcon(
                                AppIconName.snooze,
                                size: 17,
                                color: Color(0xFFFF9F0A),
                                semanticsLabel: '贪睡',
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '贪睡 $snoozeMins 分钟',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFF5F5F7),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    ApplePressable(
                      onTap: _submitting ? null : _dismiss,
                      haptic: AppleHaptic.light,
                      pressedScale: 0.97,
                      builder: (context, hovered, pressed) {
                        return AnimatedContainer(
                          duration: AppleTokens.motionFast,
                          height: 56,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: pressed
                                ? const Color(0xFF0066D6)
                                : hovered
                                    ? const Color(0xFF2692FF)
                                    : const Color(0xFF0A84FF),
                            borderRadius: BorderRadius.circular(
                              AppleTokens.radiusPill,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x4D0A84FF),
                                blurRadius: 24,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            '关闭',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
