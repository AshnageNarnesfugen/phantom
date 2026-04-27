import 'package:flutter/material.dart';

// ── Accent presets ────────────────────────────────────────────────────────────
// Lo único que el usuario puede cambiar ahora.
// En el futuro esto se expande a ThemeManifest completo.

enum PhantomAccent {
  ghost(   'Ghost',    Color(0xFFE0E0E0), Color(0xFF9E9E9E)),
  cyan(    'Cyan',     Color(0xFF00E5FF), Color(0xFF00838F)),
  violet(  'Violet',  Color(0xFFCE93D8), Color(0xFF7B1FA2)),
  amber(   'Amber',   Color(0xFFFFD54F), Color(0xFFF57F17)),
  red(     'Red',     Color(0xFFEF9A9A), Color(0xFFC62828)),
  green(   'Green',   Color(0xFFA5D6A7), Color(0xFF2E7D32)),
  rose(    'Rose',    Color(0xFFF48FB1), Color(0xFFAD1457)),
  ice(     'Ice',     Color(0xFFB3E5FC), Color(0xFF0277BD));

  final String label;
  final Color light;  // burbuja outgoing, botones activos
  final Color dark;   // texto sobre light, bordes

  const PhantomAccent(this.label, this.light, this.dark);
}

// ── Token system ─────────────────────────────────────────────────────────────
// Cada widget de UI lee tokens, nunca colores hardcodeados.
// Cuando lleguen temas completos, solo cambia PhantomTokens.

@immutable
class PhantomTokens {
  // Superficies
  final Color bgBase;       // fondo de toda la app
  final Color bgSurface;    // cards, input bar, drawers
  final Color bgSubtle;     // hover states, separadores

  // Texto
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;

  // Accent (derivado del PhantomAccent elegido)
  final Color accentLight;
  final Color accentDark;

  // Burbujas
  final Color bubbleOut;      // outgoing — usa accent
  final Color bubbleOutText;
  final Color bubbleIn;       // incoming — siempre neutro
  final Color bubbleInText;

  // UI chrome
  final Color divider;
  final Color inputBorder;
  final Color iconDefault;
  final Color iconActive;

  // Radio de bordes — future theme hook
  final double radiusBubble;
  final double radiusCard;
  final double radiusInput;

  const PhantomTokens({
    required this.bgBase,
    required this.bgSurface,
    required this.bgSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.accentLight,
    required this.accentDark,
    required this.bubbleOut,
    required this.bubbleOutText,
    required this.bubbleIn,
    required this.bubbleInText,
    required this.divider,
    required this.inputBorder,
    required this.iconDefault,
    required this.iconActive,
    required this.radiusBubble,
    required this.radiusCard,
    required this.radiusInput,
  });

  factory PhantomTokens.dark(PhantomAccent accent) {
    return PhantomTokens(
      bgBase:          const Color(0xFF0A0A0A),
      bgSurface:       const Color(0xFF141414),
      bgSubtle:        const Color(0xFF1E1E1E),
      textPrimary:     const Color(0xFFF0F0F0),
      textSecondary:   const Color(0xFF888888),
      textDisabled:    const Color(0xFF444444),
      accentLight:     accent.light,
      accentDark:      accent.dark,
      bubbleOut:       accent.light.withValues(alpha: 0.15),
      bubbleOutText:   accent.light,
      bubbleIn:        const Color(0xFF1E1E1E),
      bubbleInText:    const Color(0xFFE0E0E0),
      divider:         const Color(0xFF222222),
      inputBorder:     const Color(0xFF2A2A2A),
      iconDefault:     const Color(0xFF555555),
      iconActive:      accent.light,
      radiusBubble:    14,
      radiusCard:      12,
      radiusInput:     10,
    );
  }

  factory PhantomTokens.light(PhantomAccent accent) {
    return PhantomTokens(
      bgBase:          const Color(0xFFFAFAFA),
      bgSurface:       const Color(0xFFFFFFFF),
      bgSubtle:        const Color(0xFFF0F0F0),
      textPrimary:     const Color(0xFF0A0A0A),
      textSecondary:   const Color(0xFF666666),
      textDisabled:    const Color(0xFFBBBBBB),
      accentLight:     accent.dark,
      accentDark:      accent.light,
      bubbleOut:       accent.dark.withValues(alpha: 0.12),
      bubbleOutText:   accent.dark,
      bubbleIn:        const Color(0xFFEEEEEE),
      bubbleInText:    const Color(0xFF1A1A1A),
      divider:         const Color(0xFFE8E8E8),
      inputBorder:     const Color(0xFFDDDDDD),
      iconDefault:     const Color(0xFFAAAAAA),
      iconActive:      accent.dark,
      radiusBubble:    14,
      radiusCard:      12,
      radiusInput:     10,
    );
  }
}

// ── PhantomTheme — InheritedWidget ────────────────────────────────────────────

class PhantomTheme extends InheritedWidget {
  final PhantomTokens tokens;
  final PhantomAccent accent;
  final bool isDark;

  const PhantomTheme({
    super.key,
    required this.tokens,
    required this.accent,
    required this.isDark,
    required super.child,
  });

  static PhantomTheme of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<PhantomTheme>();
    assert(theme != null, 'PhantomTheme not found in widget tree');
    return theme!;
  }

  static PhantomTokens tokensOf(BuildContext context) => of(context).tokens;

  @override
  bool updateShouldNotify(PhantomTheme old) =>
      old.accent != accent || old.isDark != isDark;
}

// ── ThemeController — gestiona el estado global del tema ─────────────────────

class ThemeController extends ChangeNotifier {
  PhantomAccent _accent;
  bool _isDark;

  ThemeController({
    PhantomAccent accent = PhantomAccent.cyan,
    bool isDark = true,
  })  : _accent = accent,
        _isDark = isDark;

  PhantomAccent get accent => _accent;
  bool get isDark => _isDark;

  PhantomTokens get tokens =>
      _isDark ? PhantomTokens.dark(_accent) : PhantomTokens.light(_accent);

  void setAccent(PhantomAccent accent) {
    _accent = accent;
    notifyListeners();
  }

  void toggleDarkMode() {
    _isDark = !_isDark;
    notifyListeners();
  }

  // MaterialTheme para widgets Flutter estándar (AppBar, etc.)
  ThemeData get materialTheme => ThemeData(
        brightness: _isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: tokens.bgBase,
        colorScheme: ColorScheme(
          brightness: _isDark ? Brightness.dark : Brightness.light,
          primary: _accent.light,
          onPrimary: _isDark ? Colors.black : Colors.white,
          secondary: _accent.light,
          onSecondary: _isDark ? Colors.black : Colors.white,
          surface: tokens.bgSurface,
          onSurface: tokens.textPrimary,
          error: const Color(0xFFCF6679),
          onError: Colors.black,
        ),
        dividerColor: tokens.divider,
        splashColor: _accent.light.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        useMaterial3: true,
      );
}
