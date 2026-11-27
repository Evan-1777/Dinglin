import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/apple_tokens.dart';
import 'app_icon.dart';

enum AppleHaptic { none, selection, light }

/// Unified Apple HIG pressable primitive providing desktop hover, tactile press
/// scale, and optional haptic feedback.
class ApplePressable extends StatefulWidget {
  const ApplePressable({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
    this.haptic = AppleHaptic.selection,
    this.cursor,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget Function(BuildContext context, bool hovered, bool pressed)
      builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final AppleHaptic haptic;
  final MouseCursor? cursor;
  final HitTestBehavior behavior;

  @override
  State<ApplePressable> createState() => _ApplePressableState();
}

class _ApplePressableState extends State<ApplePressable> {
  bool _hovered = false;
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _triggerHaptic() {
    switch (widget.haptic) {
      case AppleHaptic.none:
        return;
      case AppleHaptic.selection:
        HapticFeedback.selectionClick();
      case AppleHaptic.light:
        HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      cursor: widget.cursor ??
          (_enabled ? SystemMouseCursors.click : SystemMouseCursors.basic),
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap != null
            ? () {
                _triggerHaptic();
                widget.onTap!();
              }
            : null,
        onLongPress: widget.onLongPress != null
            ? () {
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? widget.pressedScale : 1.0,
          duration: AppleTokens.motionFast,
          curve: AppleTokens.motionCurve,
          child: widget.builder(context, _hovered, _pressed),
        ),
      ),
    );
  }
}

class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    super.key,
    required this.color,
    required this.child,
    this.border,
  });

  final Color color;
  final Widget child;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: AppleTokens.blurSigma,
          sigmaY: AppleTokens.blurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, border: border),
          child: child,
        ),
      ),
    );
  }
}

class AppleTopBar extends StatelessWidget {
  const AppleTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing = const [],
    this.expandedContent,
    this.horizontalPadding = 20,
  });

  final String title;
  final Widget? leading;
  final List<Widget> trailing;
  final Widget? expandedContent;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return FrostedSurface(
      color: t.bgTopbar,
      border: Border(bottom: BorderSide(color: t.borderHairline)),
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: SizedBox(
          height: AppleTokens.topbarHeight,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: expandedContent ??
                Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.35,
                          color: t.inkPrimary,
                        ),
                      ),
                    ),
                    if (trailing.isNotEmpty) const SizedBox(width: 12),
                    ...trailing,
                  ],
                ),
          ),
        ),
      ),
    );
  }
}

/// Shared Apple-styled input field decoration across forms and search inputs.
InputDecoration appleInputDecoration(
  AppleTokens t, {
  String? hint,
  Widget? prefixIcon,
  Widget? suffixIcon,
  BoxConstraints? prefixIconConstraints,
  BoxConstraints? suffixIconConstraints,
  EdgeInsetsGeometry? contentPadding,
}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
    borderSide: BorderSide(color: t.borderHairline),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: t.inkTertiary),
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    prefixIconConstraints: prefixIconConstraints,
    suffixIconConstraints: suffixIconConstraints,
    filled: true,
    fillColor: t.bgSurfaceSecondary,
    isDense: true,
    contentPadding: contentPadding ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
      borderSide: BorderSide(color: t.accent, width: 1.25),
    ),
  );
}

/// Unified Apple HIG dialog container with specular top highlight and hairline border.
class AppleDialogShell extends StatelessWidget {
  const AppleDialogShell({
    super.key,
    required this.child,
    this.title,
    this.maxWidth = 440,
    this.padding = const EdgeInsets.all(20),
    this.showClose = false,
  });

  final Widget child;
  final String? title;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          decoration: BoxDecoration(
            color: t.bgCardElevated,
            borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
            border: Border.all(color: t.borderHairline),
            boxShadow: t.modalShadow,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 1,
                child: ColoredBox(color: t.borderSpecular),
              ),
              SingleChildScrollView(
                padding: padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (title != null || showClose) ...[
                      Row(
                        children: [
                          if (title != null)
                            Expanded(
                              child: Text(
                                title!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.25,
                                  color: t.inkPrimary,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                          if (showClose)
                            AppleIconButton(
                              icon: AppIconName.close,
                              tooltip: '关闭',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    child,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows an Apple rounded bottom sheet on narrow screens (< 640px) with grabber
/// and keyboard inset avoidance, or a centered [AppleDialogShell] on wider viewports.
Future<T?> showAppleAdaptiveModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool showClose = true,
  double maxWidth = 440,
  EdgeInsetsGeometry padding = const EdgeInsets.all(20),
}) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < 640) {
    final t = AppleTokens.of(context);
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: t.scrim,
      builder: (ctx) {
        final st = AppleTokens.of(ctx);
        final viewInsets = MediaQuery.viewInsetsOf(ctx);
        final maxH = MediaQuery.sizeOf(ctx).height * 0.9;
        return Padding(
          padding: EdgeInsets.only(bottom: viewInsets.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: Container(
              decoration: BoxDecoration(
                color: st.bgCardElevated,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppleTokens.radiusSheet),
                ),
                border: Border(
                  top: BorderSide(color: st.borderHairline),
                  left: BorderSide(color: st.borderHairline),
                  right: BorderSide(color: st.borderHairline),
                ),
                boxShadow: st.modalShadow,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 1,
                    child: ColoredBox(color: st.borderSpecular),
                  ),
                  SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(top: 10, bottom: 4),
                            decoration: BoxDecoration(
                              color: st.inkTertiary.withValues(alpha: 0.35),
                              borderRadius:
                                  BorderRadius.circular(AppleTokens.radiusPill),
                            ),
                          ),
                        ),
                        if (title != null || showClose)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 14, 6),
                            child: Row(
                              children: [
                                if (title != null)
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.25,
                                        color: st.inkPrimary,
                                      ),
                                    ),
                                  )
                                else
                                  const Spacer(),
                                if (showClose)
                                  AppleIconButton(
                                    icon: AppIconName.close,
                                    tooltip: '关闭',
                                    onPressed: () => Navigator.of(ctx).pop(),
                                  ),
                              ],
                            ),
                          ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: padding,
                            child: builder(ctx),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  return showDialog<T>(
    context: context,
    builder: (ctx) => AppleDialogShell(
      title: title,
      showClose: showClose,
      maxWidth: maxWidth,
      padding: padding,
      child: builder(ctx),
    ),
  );
}

Future<bool> showAppleConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool danger = true,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final t = AppleTokens.of(ctx);
      return AppleDialogShell(
        title: title,
        maxWidth: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: t.inkSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(cancelLabel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: danger ? t.critical : t.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
  return res ?? false;
}

class AppleCardGroup extends StatelessWidget {
  const AppleCardGroup({
    super.key,
    required this.children,
    this.padding,
    this.dividerIndent = 0,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) {
        items.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: dividerIndent,
            color: t.borderHairline,
          ),
        );
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: t.bgSurface,
        borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
        border: Border.all(color: t.borderHairline),
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
            child: ColoredBox(color: t.borderSpecular),
          ),
          Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: items,
            ),
          ),
        ],
      ),
    );
  }
}

class AppleIconButton extends StatelessWidget {
  const AppleIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
    this.active = false,
    this.danger = false,
    this.size = 32,
    this.iconSize = 16,
  });

  final AppIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;
  final bool active;
  final bool danger;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: ApplePressable(
        onTap: onPressed,
        pressedScale: 0.94,
        haptic: primary ? AppleHaptic.light : AppleHaptic.selection,
        builder: (context, hovered, pressed) {
          Color bg = Colors.transparent;
          Color fg = danger ? t.critical : t.inkSecondary;

          if (primary) {
            bg = pressed
                ? t.accentHover
                : hovered
                    ? t.accentHover
                    : t.accent;
            fg = Colors.white;
          } else if (active) {
            bg = pressed ? t.bgPressed : t.bgSelected;
            fg = t.accent;
          } else if (pressed) {
            bg = danger ? t.criticalBg : t.bgPressed;
            fg = danger ? t.critical : t.inkPrimary;
          } else if (hovered) {
            bg = danger ? t.criticalBg : t.bgHover;
            fg = danger ? t.critical : t.inkPrimary;
          }

          return Semantics(
            button: true,
            label: tooltip,
            child: AnimatedContainer(
              duration: AppleTokens.motionFast,
              curve: AppleTokens.motionCurve,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
              ),
              alignment: Alignment.center,
              child: AppIcon(
                icon,
                size: iconSize,
                color: onPressed == null ? fg.withValues(alpha: 0.36) : fg,
                semanticsLabel: tooltip,
              ),
            ),
          );
        },
      ),
    );
  }
}

class AppleSegmentedControl<T> extends StatelessWidget {
  const AppleSegmentedControl({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.disabledValues = const {},
    this.onDisabledSelected,
    this.compact = false,
  });

  final T value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;
  final Set<T> disabledValues;
  final ValueChanged<T>? onDisabledSelected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: t.bgSurfaceSecondary,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: t.borderHairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final opt in options) _buildSegment(t, opt),
          ],
        ),
      ),
    );
  }

  Widget _buildSegment(AppleTokens t, ({T value, String label}) opt) {
    final selected = value == opt.value;
    final disabled = disabledValues.contains(opt.value);
    return MouseRegion(
      cursor: disabled && onDisabledSelected == null
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (disabled) {
            onDisabledSelected?.call(opt.value);
            return;
          }
          if (!selected) {
            HapticFeedback.selectionClick();
            onChanged(opt.value);
          }
        },
        child: AnimatedContainer(
          duration: AppleTokens.motion,
          curve: AppleTokens.motionCurve,
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? t.bgSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x18000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            opt.label,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: disabled
                  ? t.inkTertiary
                  : selected
                      ? t.inkPrimary
                      : t.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple-styled wrap chip selector replacing Material ChoiceChip in forms.
class AppleChipSelector<T> extends StatelessWidget {
  const AppleChipSelector({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T? value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final opt in options)
          ApplePressable(
            onTap: () => onChanged(opt.value),
            pressedScale: 0.96,
            builder: (context, hovered, pressed) {
              final selected = value == opt.value;
              final bg = selected
                  ? t.bgSelected
                  : pressed
                      ? t.bgPressed
                      : hovered
                          ? t.bgHover
                          : t.bgSurfaceSecondary;
              final borderColor = selected ? t.accent : t.borderHairline;
              final fg = selected ? t.accent : t.inkSecondary;
              return AnimatedContainer(
                duration: AppleTokens.motionFast,
                curve: AppleTokens.motionCurve,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
                  border: Border.all(color: borderColor),
                ),
                child: Text(
                  opt.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class AppleSwitch extends StatelessWidget {
  const AppleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticsLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    return Semantics(
      toggled: value,
      label: semanticsLabel,
      child: MouseRegion(
        cursor: onChanged != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onChanged != null
              ? () {
                  HapticFeedback.selectionClick();
                  onChanged!(!value);
                }
              : null,
          child: AnimatedContainer(
            duration: AppleTokens.motion,
            curve: AppleTokens.motionCurve,
            width: 44,
            height: 26,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value ? t.success : t.bgSurfaceSecondary,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: value ? Colors.transparent : t.borderHairline,
              ),
            ),
            child: AnimatedAlign(
              duration: AppleTokens.motion,
              curve: AppleTokens.motionCurve,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x38000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
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

class ApplePill extends StatelessWidget {
  const ApplePill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppleTokens.radiusPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
      ),
    );
  }
}

class AppleActionChip extends StatelessWidget {
  const AppleActionChip({
    super.key,
    this.icon,
    this.label,
    required this.onPressed,
    this.done = false,
    this.danger = false,
    this.tooltip,
  });

  final AppIconName? icon;
  final String? label;
  final VoidCallback? onPressed;
  final bool done;
  final bool danger;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final iconOnly = label == null || label!.isEmpty;
    final disabled = onPressed == null;

    final chip = ApplePressable(
      onTap: onPressed,
      pressedScale: 0.96,
      builder: (context, hovered, pressed) {
        final bg = done
            ? t.successBg
            : danger
                ? (pressed || hovered ? t.criticalBg : t.bgSurfaceSecondary)
                : pressed
                    ? t.bgPressed
                    : hovered
                        ? t.bgSelected
                        : t.bgSurfaceSecondary;
        final fg = done
            ? t.success
            : danger
                ? t.critical
                : hovered
                    ? t.accent
                    : t.inkPrimary;
        final border = done
            ? Colors.transparent
            : danger && hovered
                ? t.critical
                : hovered
                    ? t.accent
                    : t.borderHairline;

        return Opacity(
          opacity: disabled ? 0.45 : 1.0,
          child: AnimatedContainer(
            duration: AppleTokens.motionFast,
            curve: AppleTokens.motionCurve,
            height: 28,
            width: iconOnly ? 28 : null,
            padding: iconOnly
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null)
                  AppIcon(
                    icon!,
                    size: 13,
                    color: fg,
                    semanticsLabel: tooltip ?? label,
                  ),
                if (icon != null && !iconOnly) const SizedBox(width: 5),
                if (!iconOnly)
                  Text(
                    label!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (tooltip != null) {
      return Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 500),
        child: chip,
      );
    }
    return chip;
  }
}
