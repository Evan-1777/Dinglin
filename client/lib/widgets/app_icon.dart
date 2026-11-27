import 'package:flutter/material.dart' show Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum AppIconName {
  bell,
  clock,
  timer,
  calendar,
  settings,
  search,
  refresh,
  plus,
  check,
  checkDouble,
  snooze,
  close,
  trash,
  play,
  pause,
  reset,
  copy,
  rotate,
  send,
  link,
  device,
  sun,
  moon,
  edit,
  alert,
  chevronRight,
  xCircle,
  shield,
  code,
  disconnect,
  checkCircle,
  sliders,
  filter,
  checkSquare,
  square,
  listChecks,
  bellOff,
  alarmClock,
  eraser,
  arrowLeft,
  qrCode,
  rocket,
}

/// Crisp 1.5px stroke Apple HIG SVG icon component with mandatory semantics.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.name, {
    super.key,
    this.size = 18,
    this.color,
    this.semanticsLabel,
  });

  final AppIconName name;
  final double size;
  final Color? color;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF1D1D1F);
    final svg = _svgBody[name]!;
    return SvgPicture.string(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
      'stroke="currentColor" stroke-width="1.65" stroke-linecap="round" '
      'stroke-linejoin="round">$svg</svg>',
      width: size,
      height: size,
      semanticsLabel: semanticsLabel ?? name.name,
      colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
    );
  }

  static const Map<AppIconName, String> _svgBody = {
    AppIconName.bell:
        '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/>'
        '<path d="M13.73 21a2 2 0 0 1-3.46 0"/>',
    AppIconName.clock:
        '<circle cx="12" cy="12" r="9"/>'
        '<polyline points="12 7 12 12 15.5 14"/>',
    AppIconName.timer:
        '<line x1="10" y1="2" x2="14" y2="2"/>'
        '<line x1="12" y1="14" x2="15" y2="11"/>'
        '<circle cx="12" cy="14" r="8"/>',
    AppIconName.calendar:
        '<rect x="3" y="4" width="18" height="18" rx="2"/>'
        '<line x1="16" y1="2" x2="16" y2="6"/>'
        '<line x1="8" y1="2" x2="8" y2="6"/>'
        '<line x1="3" y1="10" x2="21" y2="10"/>',
    AppIconName.settings:
        '<circle cx="12" cy="12" r="3"/>'
        '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    AppIconName.search:
        '<circle cx="11" cy="11" r="7"/>'
        '<line x1="20" y1="20" x2="16.2" y2="16.2"/>',
    AppIconName.refresh:
        '<polyline points="23 4 23 10 17 10"/>'
        '<path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>',
    AppIconName.plus:
        '<line x1="12" y1="5" x2="12" y2="19"/>'
        '<line x1="5" y1="12" x2="19" y2="12"/>',
    AppIconName.check:
        '<polyline points="20 6 9 17 4 12"/>',
    AppIconName.checkDouble:
        '<path d="M18 6 7 17l-5-5"/>'
        '<path d="m22 10-7.5 7.5L13 16"/>',
    AppIconName.snooze:
        '<circle cx="12" cy="13" r="8"/>'
        '<path d="M12 9v4l2 2"/>'
        '<path d="M5 3 2 6"/>'
        '<path d="m22 6-3-3"/>',
    AppIconName.close:
        '<line x1="18" y1="6" x2="6" y2="18"/>'
        '<line x1="6" y1="6" x2="18" y2="18"/>',
    AppIconName.trash:
        '<polyline points="3 6 5 6 21 6"/>'
        '<path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
    AppIconName.play:
        '<polygon points="6 4 20 12 6 20 6 4"/>',
    AppIconName.pause:
        '<rect x="6" y="4" width="4" height="16" rx="1"/>'
        '<rect x="14" y="4" width="4" height="16" rx="1"/>',
    AppIconName.reset:
        '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/>'
        '<path d="M3 3v5h5"/>',
    AppIconName.copy:
        '<rect x="9" y="9" width="13" height="13" rx="2"/>'
        '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    AppIconName.rotate:
        '<path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/>'
        '<path d="M3 3v5h5"/>'
        '<path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16"/>'
        '<path d="M16 16h5v5"/>',
    AppIconName.send:
        '<line x1="22" y1="2" x2="11" y2="13"/>'
        '<polygon points="22 2 15 22 11 13 2 9 22 2"/>',
    AppIconName.link:
        '<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>'
        '<path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>',
    AppIconName.device:
        '<rect x="5" y="2" width="14" height="20" rx="2"/>'
        '<line x1="12" y1="18" x2="12.01" y2="18"/>',
    AppIconName.sun:
        '<circle cx="12" cy="12" r="4"/>'
        '<path d="M12 2v2"/><path d="M12 20v2"/>'
        '<path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/>'
        '<path d="M2 12h2"/><path d="M20 12h2"/>'
        '<path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>',
    AppIconName.moon:
        '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>',
    AppIconName.edit:
        '<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/>'
        '<path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>',
    AppIconName.alert:
        '<circle cx="12" cy="12" r="9"/>'
        '<line x1="12" y1="8" x2="12" y2="12"/>'
        '<line x1="12" y1="16" x2="12.01" y2="16"/>',
    AppIconName.chevronRight:
        '<polyline points="9 18 15 12 9 6"/>',
    AppIconName.xCircle:
        '<circle cx="12" cy="12" r="9"/>'
        '<line x1="15" y1="9" x2="9" y2="15"/>'
        '<line x1="9" y1="9" x2="15" y2="15"/>',
    AppIconName.shield:
        '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
    AppIconName.code:
        '<polyline points="16 18 22 12 16 6"/>'
        '<polyline points="8 6 2 12 8 18"/>',
    AppIconName.disconnect:
        '<path d="m18.84 12.25 1.72-1.71h-.02a5.004 5.004 0 0 0-.12-7.07 5.006 5.006 0 0 0-6.95 0l-1.72 1.71"/>'
        '<path d="m5.17 11.75-1.71 1.71a5.004 5.004 0 0 0 .12 7.07 5.006 5.006 0 0 0 6.95 0l1.71-1.71"/>'
        '<line x1="8" y1="2" x2="8" y2="5"/>'
        '<line x1="2" y1="8" x2="5" y2="8"/>'
        '<line x1="16" y1="19" x2="16" y2="22"/>'
        '<line x1="19" y1="16" x2="22" y2="16"/>',
    AppIconName.checkCircle:
        '<circle cx="12" cy="12" r="9"/>'
        '<polyline points="9 12 11 14 15 10"/>',
    AppIconName.sliders:
        '<line x1="4" y1="21" x2="4" y2="14"/>'
        '<line x1="4" y1="10" x2="4" y2="3"/>'
        '<line x1="12" y1="21" x2="12" y2="12"/>'
        '<line x1="12" y1="8" x2="12" y2="3"/>'
        '<line x1="20" y1="21" x2="20" y2="16"/>'
        '<line x1="20" y1="12" x2="20" y2="3"/>'
        '<line x1="1" y1="14" x2="7" y2="14"/>'
        '<line x1="9" y1="8" x2="15" y2="8"/>'
        '<line x1="17" y1="16" x2="23" y2="16"/>',
    AppIconName.filter:
        '<polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>',
    AppIconName.checkSquare:
        '<rect x="3" y="3" width="18" height="18" rx="4"/>'
        '<polyline points="8.5 12.2 10.8 14.5 15.8 9.5"/>',
    AppIconName.square:
        '<rect x="3" y="3" width="18" height="18" rx="4"/>',
    AppIconName.listChecks:
        '<path d="m3 17 2 2 4-4"/>'
        '<path d="m3 7 2 2 4-4"/>'
        '<path d="M13 6h8"/>'
        '<path d="M13 12h8"/>'
        '<path d="M13 18h8"/>',
    AppIconName.bellOff:
        '<path d="M8.7 3A6 6 0 0 1 18 8a21.3 21.3 0 0 0 .6 5"/>'
        '<path d="M17 17H3s3-2 3-9a4.67 4.67 0 0 1 .3-1.7"/>'
        '<path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>'
        '<line x1="2" y1="2" x2="22" y2="22"/>',
    AppIconName.alarmClock:
        '<circle cx="12" cy="13" r="8"/>'
        '<path d="M12 9v4l2.5 1.5"/>'
        '<path d="M5 3 2 6"/>'
        '<path d="m22 6-3-3"/>'
        '<path d="M6.38 18.7 4 21"/>'
        '<path d="M17.64 18.67 20 21"/>',
    AppIconName.eraser:
        '<path d="m7 21-4.3-4.3c-1-1-1-2.5 0-3.4l9.6-9.6c1-1 2.5-1 3.4 0l5.6 5.6c1 1 1 2.5 0 3.4L13 21"/>'
        '<path d="M22 21H7"/>'
        '<path d="m5 11 9 9"/>',
    AppIconName.arrowLeft:
        '<line x1="19" y1="12" x2="5" y2="12"/>'
        '<polyline points="12 19 5 12 12 5"/>',
    AppIconName.qrCode:
        '<rect x="3" y="3" width="7" height="7" rx="1"/>'
        '<rect x="14" y="3" width="7" height="7" rx="1"/>'
        '<rect x="3" y="14" width="7" height="7" rx="1"/>'
        '<path d="M14 14h3v3h-3z"/>'
        '<path d="M20 14v3"/>'
        '<path d="M14 20h7"/>',
    AppIconName.rocket:
        '<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/>'
        '<path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/>'
        '<path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/>'
        '<path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>',
  };
}

/// Pure light-surface Dinglin brand emblem rendered from the single SVG source.
class DinglinBrandMark extends StatelessWidget {
  const DinglinBrandMark({
    super.key,
    this.size = 28,
    this.semanticsLabel = 'Dinglin',
  });

  final double size;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.23;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: isDark
            ? Border.all(color: const Color(0x33FFFFFF), width: 0.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: isDark
                ? const Color(0x52000000)
                : const Color(0x1A0A66FF),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.08),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SvgPicture.asset(
          'assets/icons/dinglin_logo.svg',
          width: size,
          height: size,
          fit: BoxFit.cover,
          semanticsLabel: semanticsLabel,
        ),
      ),
    );
  }
}
