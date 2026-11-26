import 'package:flutter/material.dart';

/// Apple HIG Layer 0–3 design tokens for Dinglin (Light & Dark).
@immutable
class AppleTokens extends ThemeExtension<AppleTokens> {
  const AppleTokens({
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgSurfaceSecondary,
    required this.bgRail,
    required this.bgTopbar,
    required this.bgHover,
    required this.bgSelected,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.borderHairline,
    required this.borderSpecular,
    required this.accent,
    required this.accentHover,
    required this.critical,
    required this.criticalBg,
    required this.warning,
    required this.warningBg,
    required this.success,
    required this.successBg,
    required this.scrim,
    required this.cardShadow,
    required this.floatShadow,
    required this.modalShadow,
    required this.isDark,
  });

  final Color bgCanvas;
  final Color bgSurface;
  final Color bgSurfaceSecondary;
  final Color bgRail;
  final Color bgTopbar;
  final Color bgHover;
  final Color bgSelected;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkTertiary;
  final Color borderHairline;
  final Color borderSpecular;
  final Color accent;
  final Color accentHover;
  final Color critical;
  final Color criticalBg;
  final Color warning;
  final Color warningBg;
  final Color success;
  final Color successBg;
  final Color scrim;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatShadow;
  final List<BoxShadow> modalShadow;
  final bool isDark;

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusPill = 999;

  static const double sidebarWidth = 232;
  static const double railWidth = 68;
  static const double inspectorWidth = 348;
  static const double topbarHeight = 56;
  static const double blurSigma = 22;
  static const Duration motion = Duration(milliseconds: 180);

  static const TextStyle tabular = TextStyle(
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const AppleTokens light = AppleTokens(
    bgCanvas: Color(0xFFF5F5F7),
    bgSurface: Color(0xFFFFFFFF),
    bgSurfaceSecondary: Color(0xFFF2F2F7),
    bgRail: Color(0xC7F5F5F7),
    bgTopbar: Color(0xC2FFFFFF),
    bgHover: Color(0x0A000000),
    bgSelected: Color(0x1A007AFF),
    inkPrimary: Color(0xFF1D1D1F),
    inkSecondary: Color(0xFF6E6E73),
    inkTertiary: Color(0xFF8E8E93),
    borderHairline: Color(0x14000000),
    borderSpecular: Color(0xBFFFFFFF),
    accent: Color(0xFF007AFF),
    accentHover: Color(0xFF0066D6),
    critical: Color(0xFFFF3B30),
    criticalBg: Color(0x1AFF3B30),
    warning: Color(0xFFFF9500),
    warningBg: Color(0x1FFF9500),
    success: Color(0xFF34C759),
    successBg: Color(0x1F34C759),
    scrim: Color(0x57000000),
    cardShadow: [
      BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x08000000), blurRadius: 12, offset: Offset(0, 4)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x1A000000), blurRadius: 30, offset: Offset(0, 10)),
      BoxShadow(color: Color(0x0F000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
    modalShadow: [
      BoxShadow(color: Color(0x38000000), blurRadius: 60, offset: Offset(0, 24)),
      BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 2)),
    ],
    isDark: false,
  );

  static const AppleTokens dark = AppleTokens(
    bgCanvas: Color(0xFF000000),
    bgSurface: Color(0xFF1C1C1E),
    bgSurfaceSecondary: Color(0xFF2C2C2E),
    bgRail: Color(0xC71C1C1E),
    bgTopbar: Color(0xC21C1C1E),
    bgHover: Color(0x0FFFFFFF),
    bgSelected: Color(0x2E0A84FF),
    inkPrimary: Color(0xFFF5F5F7),
    inkSecondary: Color(0xFF98989D),
    inkTertiary: Color(0xFF636366),
    borderHairline: Color(0x1AFFFFFF),
    borderSpecular: Color(0x1FFFFFFF),
    accent: Color(0xFF0A84FF),
    accentHover: Color(0xFF409CFF),
    critical: Color(0xFFFF453A),
    criticalBg: Color(0x29FF453A),
    warning: Color(0xFFFF9F0A),
    warningBg: Color(0x29FF9F0A),
    success: Color(0xFF30D158),
    successBg: Color(0x2930D158),
    scrim: Color(0x94000000),
    cardShadow: [
      BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
    floatShadow: [
      BoxShadow(color: Color(0x73000000), blurRadius: 32, offset: Offset(0, 12)),
    ],
    modalShadow: [
      BoxShadow(color: Color(0xA6000000), blurRadius: 70, offset: Offset(0, 28)),
    ],
    isDark: true,
  );

  static AppleTokens of(BuildContext context) {
    return Theme.of(context).extension<AppleTokens>() ?? light;
  }

  static ThemeData buildTheme(Brightness brightness) {
    final t = brightness == Brightness.dark ? dark : light;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: t.bgCanvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: t.accent,
        brightness: brightness,
        surface: t.bgSurface,
        error: t.critical,
      ),
      fontFamilyFallback: const [
        '-apple-system',
        'SF Pro Text',
        'PingFang SC',
        'Segoe UI',
        'sans-serif',
      ],
      dividerColor: t.borderHairline,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: t.bgHover,
      extensions: [t],
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: t.inkPrimary,
        displayColor: t.inkPrimary,
      ),
    );
  }

  @override
  AppleTokens copyWith({
    Color? bgCanvas,
    Color? bgSurface,
    Color? bgSurfaceSecondary,
    Color? bgRail,
    Color? bgTopbar,
    Color? bgHover,
    Color? bgSelected,
    Color? inkPrimary,
    Color? inkSecondary,
    Color? inkTertiary,
    Color? borderHairline,
    Color? borderSpecular,
    Color? accent,
    Color? accentHover,
    Color? critical,
    Color? criticalBg,
    Color? warning,
    Color? warningBg,
    Color? success,
    Color? successBg,
    Color? scrim,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? floatShadow,
    List<BoxShadow>? modalShadow,
    bool? isDark,
  }) {
    return AppleTokens(
      bgCanvas: bgCanvas ?? this.bgCanvas,
      bgSurface: bgSurface ?? this.bgSurface,
      bgSurfaceSecondary: bgSurfaceSecondary ?? this.bgSurfaceSecondary,
      bgRail: bgRail ?? this.bgRail,
      bgTopbar: bgTopbar ?? this.bgTopbar,
      bgHover: bgHover ?? this.bgHover,
      bgSelected: bgSelected ?? this.bgSelected,
      inkPrimary: inkPrimary ?? this.inkPrimary,
      inkSecondary: inkSecondary ?? this.inkSecondary,
      inkTertiary: inkTertiary ?? this.inkTertiary,
      borderHairline: borderHairline ?? this.borderHairline,
      borderSpecular: borderSpecular ?? this.borderSpecular,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      critical: critical ?? this.critical,
      criticalBg: criticalBg ?? this.criticalBg,
      warning: warning ?? this.warning,
      warningBg: warningBg ?? this.warningBg,
      success: success ?? this.success,
      successBg: successBg ?? this.successBg,
      scrim: scrim ?? this.scrim,
      cardShadow: cardShadow ?? this.cardShadow,
      floatShadow: floatShadow ?? this.floatShadow,
      modalShadow: modalShadow ?? this.modalShadow,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  AppleTokens lerp(ThemeExtension<AppleTokens>? other, double t) {
    if (other is! AppleTokens) return this;
    return AppleTokens(
      bgCanvas: Color.lerp(bgCanvas, other.bgCanvas, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgSurfaceSecondary:
          Color.lerp(bgSurfaceSecondary, other.bgSurfaceSecondary, t)!,
      bgRail: Color.lerp(bgRail, other.bgRail, t)!,
      bgTopbar: Color.lerp(bgTopbar, other.bgTopbar, t)!,
      bgHover: Color.lerp(bgHover, other.bgHover, t)!,
      bgSelected: Color.lerp(bgSelected, other.bgSelected, t)!,
      inkPrimary: Color.lerp(inkPrimary, other.inkPrimary, t)!,
      inkSecondary: Color.lerp(inkSecondary, other.inkSecondary, t)!,
      inkTertiary: Color.lerp(inkTertiary, other.inkTertiary, t)!,
      borderHairline: Color.lerp(borderHairline, other.borderHairline, t)!,
      borderSpecular: Color.lerp(borderSpecular, other.borderSpecular, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      criticalBg: Color.lerp(criticalBg, other.criticalBg, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningBg: Color.lerp(warningBg, other.warningBg, t)!,
      success: Color.lerp(success, other.success, t)!,
      successBg: Color.lerp(successBg, other.successBg, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      cardShadow: t < 0.5 ? cardShadow : other.cardShadow,
      floatShadow: t < 0.5 ? floatShadow : other.floatShadow,
      modalShadow: t < 0.5 ? modalShadow : other.modalShadow,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

Color parseHexColor(String hex, {Color fallback = const Color(0xFF007AFF)}) {
  final cleaned = hex.trim().replaceFirst('#', '');
  if (cleaned.length == 6) {
    final v = int.tryParse('FF$cleaned', radix: 16);
    if (v != null) return Color(v);
  }
  return fallback;
}
