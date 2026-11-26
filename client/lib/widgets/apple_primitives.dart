import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import 'app_icon.dart';

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
    this.trailing = const [],
    this.expandedContent,
    this.horizontalPadding = 20,
  });

  final String title;
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
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                          color: t.inkPrimary,
                        ),
                      ),
                    ),
                    const Spacer(),
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
      borderSide: BorderSide(color: t.accent),
    ),
  );
}

/// Unified Apple HIG dialog container with hairline border and mobile-safe inset.
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
      backgroundColor: t.bgSurface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleTokens.radiusLg),
        side: BorderSide(color: t.borderHairline),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SingleChildScrollView(
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
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
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
      ),
    );
  }
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
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) {
        items.add(Divider(height: 1, thickness: 1, color: t.borderHairline));
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
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: items,
      ),
    );
  }
}

class AppleIconButton extends StatefulWidget {
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
  State<AppleIconButton> createState() => _AppleIconButtonState();
}

class _AppleIconButtonState extends State<AppleIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    Color bg = Colors.transparent;
    Color fg = t.inkSecondary;

    if (widget.primary) {
      bg = _hovered ? t.accentHover : t.accent;
      fg = Colors.white;
    } else if (widget.active) {
      bg = t.bgSelected;
      fg = t.accent;
    } else if (_hovered) {
      bg = widget.danger ? t.criticalBg : t.bgHover;
      fg = widget.danger ? t.critical : t.inkPrimary;
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: widget.onPressed != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Semantics(
            button: true,
            label: widget.tooltip,
            child: AnimatedContainer(
              duration: AppleTokens.motion,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppleTokens.radiusSm),
              ),
              alignment: Alignment.center,
              child: AppIcon(
                widget.icon,
                size: widget.iconSize,
                color: widget.onPressed == null
                    ? fg.withValues(alpha: 0.4)
                    : fg,
                semanticsLabel: widget.tooltip,
              ),
            ),
          ),
        ),
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
            for (final opt in options)
              _buildSegment(t, opt),
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
          onChanged(opt.value);
        },
        child: AnimatedContainer(
          duration: AppleTokens.motion,
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
              fontWeight: FontWeight.w500,
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
          onTap: onChanged != null ? () => onChanged!(!value) : null,
          child: AnimatedContainer(
            duration: AppleTokens.motion,
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

class AppleActionChip extends StatefulWidget {
  const AppleActionChip({
    super.key,
    this.icon,
    this.label,
    required this.onPressed,
    this.done = false,
    this.tooltip,
  });

  final AppIconName? icon;
  final String? label;
  final VoidCallback onPressed;
  final bool done;
  final String? tooltip;

  @override
  State<AppleActionChip> createState() => _AppleActionChipState();
}

class _AppleActionChipState extends State<AppleActionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = AppleTokens.of(context);
    final iconOnly = widget.label == null || widget.label!.isEmpty;
    final bg = widget.done
        ? t.successBg
        : _hovered
            ? t.bgSelected
            : t.bgSurfaceSecondary;
    final fg = widget.done
        ? t.success
        : _hovered
            ? t.accent
            : t.inkPrimary;
    final border = widget.done
        ? Colors.transparent
        : _hovered
            ? t.accent
            : t.borderHairline;

    final chip = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppleTokens.motion,
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
              if (widget.icon != null)
                AppIcon(
                  widget.icon!,
                  size: 13,
                  color: fg,
                  semanticsLabel: widget.tooltip ?? widget.label,
                ),
              if (widget.icon != null && !iconOnly) const SizedBox(width: 5),
              if (!iconOnly)
                Text(
                  widget.label!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(
        message: widget.tooltip!,
        waitDuration: const Duration(milliseconds: 500),
        child: chip,
      );
    }
    return chip;
  }
}
