import 'package:flutter/material.dart';

/// Token warna CarterTag Connect. Gaya: aplikasi chat modern (Minimalism, ui-ux-pro-max "Chat & Messaging App"):
/// latar putih bersih, border tipis, bayangan halus, aksen biru CarterTag #1D5DAA, hijau untuk "online".
@immutable
class CT extends ThemeExtension<CT> {
  const CT({
    required this.bg,
    required this.card,
    required this.cardLow,
    required this.line,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentBg,
    required this.ok,
    required this.okBg,
    required this.amber,
    required this.amberBg,
    required this.danger,
    required this.dangerBg,
    required this.chatBg,
    required this.bubbleMine,
    required this.bubbleOther,
    required this.onBubbleMine,
  });

  final Color bg, card, cardLow, line, ink, muted, accent, onAccent, accentBg, ok, okBg, amber, amberBg, danger, dangerBg;
  final Color chatBg, bubbleMine, bubbleOther, onBubbleMine;

  static const light = CT(
    bg: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    cardLow: Color(0xFFF1F5FB),
    line: Color(0xFFE3E9F2),
    ink: Color(0xFF0F172A),
    muted: Color(0xFF526077),
    accent: Color(0xFF1D5DAA),
    onAccent: Color(0xFFFFFFFF),
    accentBg: Color(0xFFE3EEFB),
    ok: Color(0xFF047857),
    okBg: Color(0xFFD9F5E8),
    amber: Color(0xFF8A5300),
    amberBg: Color(0xFFFFF1CC),
    danger: Color(0xFFC62828),
    dangerBg: Color(0xFFFDE4E4),
    chatBg: Color(0xFFEEF2F7),
    bubbleMine: Color(0xFFD7E7FB),
    bubbleOther: Color(0xFFFFFFFF),
    onBubbleMine: Color(0xFF0F172A),
  );

  static const dark = CT(
    bg: Color(0xFF0F141B),
    card: Color(0xFF18202A),
    cardLow: Color(0xFF1E2833),
    line: Color(0xFF2A3542),
    ink: Color(0xFFE8EDF3),
    muted: Color(0xFF9AA8B8),
    accent: Color(0xFF6CB2F0),
    onAccent: Color(0xFF0B1220),
    accentBg: Color(0xFF16324F),
    ok: Color(0xFF4ADE80),
    okBg: Color(0xFF123A24),
    amber: Color(0xFFFFD166),
    amberBg: Color(0xFF3A3110),
    danger: Color(0xFFFF8A8A),
    dangerBg: Color(0xFF40191B),
    chatBg: Color(0xFF0B1016),
    bubbleMine: Color(0xFF1B4373),
    bubbleOther: Color(0xFF1E2833),
    onBubbleMine: Color(0xFFF2F6FB),
  );

  /// Merah SOS: tetap merah tua di kedua tema supaya teks putih kontras.
  static const sosRed = Color(0xFFB3261E);

  static CT of(BuildContext context) => Theme.of(context).extension<CT>()!;

  @override
  CT copyWith() => this;

  @override
  CT lerp(ThemeExtension<CT>? other, double t) => t < 0.5 ? this : (other as CT? ?? this);
}

const kSans = 'Inter';
const kMono = 'JetBrainsMono';
const kBorder = 1.0;
const kRadius = 14.0;

TextStyle mono(double size, {FontWeight w = FontWeight.w500, Color? color}) =>
    TextStyle(fontFamily: kMono, fontSize: size, fontWeight: w, color: color, fontFeatures: const [FontFeature.tabularFigures()]);

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.light ? CT.light : CT.dark;
  final scheme = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentBg,
    onPrimaryContainer: c.ink,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.danger,
    onError: Colors.white,
    surface: c.bg,
    onSurface: c.ink,
    surfaceContainerHighest: c.cardLow,
    outline: c.line,
    outlineVariant: c.line,
  );
  final text = TextTheme(
    displaySmall: TextStyle(fontFamily: kSans, fontSize: 26, height: 32 / 26, fontWeight: FontWeight.w700, color: c.ink, letterSpacing: -0.4),
    headlineSmall: TextStyle(fontFamily: kSans, fontSize: 22, fontWeight: FontWeight.w700, color: c.ink, letterSpacing: -0.3),
    titleLarge: TextStyle(fontFamily: kSans, fontSize: 19, height: 25 / 19, fontWeight: FontWeight.w700, color: c.ink, letterSpacing: -0.2),
    titleMedium: TextStyle(fontFamily: kSans, fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, color: c.ink),
    bodyLarge: TextStyle(fontFamily: kSans, fontSize: 16, height: 1.45, fontWeight: FontWeight.w400, color: c.ink),
    bodyMedium: TextStyle(fontFamily: kSans, fontSize: 14.5, height: 1.4, fontWeight: FontWeight.w400, color: c.ink),
    bodySmall: TextStyle(fontFamily: kSans, fontSize: 13, height: 1.35, color: c.muted),
    labelLarge: TextStyle(fontFamily: kSans, fontSize: 15, fontWeight: FontWeight.w600, color: c.ink),
    labelMedium: TextStyle(fontFamily: kSans, fontSize: 13, fontWeight: FontWeight.w600, color: c.ink),
  );
  final field = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.line));
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    fontFamily: kSans,
    textTheme: text,
    extensions: [c],
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
      shadowColor: c.line,
      titleTextStyle: text.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        minimumSize: const Size(48, 50),
        shape: const StadiumBorder(),
        textStyle: text.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: 22),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
        side: BorderSide(color: c.line, width: 1.2),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accent, minimumSize: const Size(48, 44), textStyle: text.labelLarge),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.accent,
      foregroundColor: c.onAccent,
      elevation: 3,
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.cardLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: field,
      enabledBorder: field.copyWith(borderSide: const BorderSide(color: Colors.transparent)),
      focusedBorder: field.copyWith(borderSide: BorderSide(color: c.accent, width: 2)),
      errorBorder: field.copyWith(borderSide: BorderSide(color: c.danger)),
      focusedErrorBorder: field.copyWith(borderSide: BorderSide(color: c.danger, width: 2)),
      labelStyle: TextStyle(color: c.muted, fontWeight: FontWeight.w500),
      floatingLabelStyle: TextStyle(color: c.accent, fontWeight: FontWeight.w600),
      hintStyle: TextStyle(color: c.muted),
      helperStyle: TextStyle(color: c.muted, fontSize: 12.5),
      errorStyle: TextStyle(color: c.danger, fontSize: 12.5, fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.bg,
      indicatorColor: c.accentBg,
      surfaceTintColor: Colors.transparent,
      height: 66,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: kSans, fontSize: 12, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500, color: s.contains(WidgetState.selected) ? c.ink : c.muted)),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.accent : c.muted, size: 24)),
    ),
    listTileTheme: ListTileThemeData(iconColor: c.muted, titleTextStyle: text.titleMedium, subtitleTextStyle: text.bodySmall),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: b == Brightness.light ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
      contentTextStyle: TextStyle(fontFamily: kSans, color: b == Brightness.light ? Colors.white : const Color(0xFF0F172A), fontSize: 14.5, fontWeight: FontWeight.w500),
      actionTextColor: b == Brightness.light ? const Color(0xFF93C5FD) : c.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    chipTheme: ChipThemeData(
      backgroundColor: c.cardLow,
      selectedColor: c.accentBg,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(fontFamily: kSans, fontWeight: FontWeight.w600, color: c.ink, fontSize: 13),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(BorderSide(color: c.line)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accentBg : c.bg),
        foregroundColor: WidgetStatePropertyAll(c.ink),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : null),
    ),
  );
}

/// Kotak kartu standar: latar kartu, border tipis, bayangan halus (opsional).
BoxDecoration brutalBox(BuildContext context, {Color? color, double radius = kRadius, bool shadow = true, Color? border}) {
  final c = CT.of(context);
  return BoxDecoration(
    color: color ?? c.card,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border ?? c.line, width: 1),
    boxShadow: shadow ? [BoxShadow(color: const Color(0xFF0F172A).withValues(alpha: 0.05), offset: const Offset(0, 2), blurRadius: 8)] : null,
  );
}
