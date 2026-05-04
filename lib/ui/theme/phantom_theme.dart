import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ── Accent presets ────────────────────────────────────────────────────────────
// Lo único que el usuario puede cambiar ahora.
// En el futuro esto se expande a ThemeManifest completo.

enum PhantomAccent {
  ghost(   'Ghost',    Color(0xFFE8E8E8), Color(0xFFAAAAAA)),
  cyan(    'Cyan',     Color(0xFF18FFFF), Color(0xFF00ACC1)),
  violet(  'Violet',  Color(0xFFD9A8E8), Color(0xFF9C27B0)),
  amber(   'Amber',   Color(0xFFFFE082), Color(0xFFF9A825)),
  red(     'Red',     Color(0xFFFF8A80), Color(0xFFD32F2F)),
  green(   'Green',   Color(0xFFB9F6CA), Color(0xFF388E3C)),
  rose(    'Rose',    Color(0xFFFF80AB), Color(0xFFC2185B)),
  ice(     'Ice',     Color(0xFFE1F5FE), Color(0xFF0288D1));

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

  factory PhantomTokens.dark(PhantomAccent accent, {double intensity = 1.0}) {
    final al = _scaled(accent.light, intensity, isDark: true);
    final ad = _scaled(accent.dark,  intensity, isDark: true);
    // Tint every surface slightly toward the accent colour at high intensity.
    final s = intensity * 0.055;
    return PhantomTokens(
      bgBase:        Color.lerp(const Color(0xFF0A0A0A), al, s * 0.7)!,
      bgSurface:     Color.lerp(const Color(0xFF141414), al, s)!,
      bgSubtle:      Color.lerp(const Color(0xFF1E1E1E), al, s * 1.4)!,
      textPrimary:   const Color(0xFFF0F0F0),
      textSecondary: const Color(0xFF888888),
      textDisabled:  const Color(0xFF444444),
      accentLight:   al,
      accentDark:    ad,
      bubbleOut:     al.withValues(alpha: 0.10 + 0.20 * intensity),
      bubbleOutText: al,
      bubbleIn:      Color.lerp(const Color(0xFF1E1E1E), al, s * 1.2)!,
      bubbleInText:  const Color(0xFFE0E0E0),
      divider:       Color.lerp(const Color(0xFF222222), al, s * 1.8)!,
      inputBorder:   Color.lerp(const Color(0xFF2A2A2A), al, s * 1.8)!,
      iconDefault:   const Color(0xFF8A8A8A),
      iconActive:    al,
      radiusBubble:  14,
      radiusCard:    12,
      radiusInput:   10,
    );
  }

  factory PhantomTokens.light(PhantomAccent accent, {double intensity = 1.0}) {
    final al = _scaled(accent.dark,  intensity, isDark: false);
    final ad = _scaled(accent.light, intensity, isDark: false);
    final s  = intensity * 0.045;
    return PhantomTokens(
      bgBase:        Color.lerp(const Color(0xFFFAFAFA), al, s * 0.5)!,
      bgSurface:     Color.lerp(const Color(0xFFFFFFFF), al, s * 0.7)!,
      bgSubtle:      Color.lerp(const Color(0xFFF0F0F0), al, s)!,
      textPrimary:   const Color(0xFF0A0A0A),
      textSecondary: const Color(0xFF666666),
      textDisabled:  const Color(0xFFBBBBBB),
      accentLight:   al,
      accentDark:    ad,
      bubbleOut:     al.withValues(alpha: 0.10 + 0.18 * intensity),
      bubbleOutText: al,
      bubbleIn:      Color.lerp(const Color(0xFFEEEEEE), al, s * 0.8)!,
      bubbleInText:  const Color(0xFF1A1A1A),
      divider:       Color.lerp(const Color(0xFFE8E8E8), al, s * 1.5)!,
      inputBorder:   Color.lerp(const Color(0xFFDDDDDD), al, s * 1.5)!,
      iconDefault:   const Color(0xFF777777),
      iconActive:    al,
      radiusBubble:  14,
      radiusCard:    12,
      radiusInput:   10,
    );
  }

  // Blend accent toward a neutral grey based on intensity [0..1].
  static Color _scaled(Color c, double intensity, {required bool isDark}) {
    final neutral = isDark ? const Color(0xFF828282) : const Color(0xFF909090);
    return Color.lerp(neutral, c, intensity.clamp(0.0, 1.0))!;
  }
}

// ── PhantomTheme — InheritedWidget ────────────────────────────────────────────

class PhantomTheme extends InheritedWidget {
  final PhantomTokens tokens;
  final PhantomAccent accent;
  final bool   isDark;
  final double intensity;

  const PhantomTheme({
    super.key,
    required this.tokens,
    required this.accent,
    required this.isDark,
    required this.intensity,
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
      old.accent != accent || old.isDark != isDark || old.intensity != intensity;
}

// ── ThemeController — gestiona el estado global del tema ─────────────────────

class ThemeController extends ChangeNotifier {
  static const _store         = FlutterSecureStorage();
  static const _keyAccent     = 'theme_accent';
  static const _keyDark       = 'theme_dark';
  static const _keyIntensity  = 'theme_intensity';

  PhantomAccent _accent;
  bool   _isDark;
  double _intensity;

  ThemeController({
    PhantomAccent accent    = PhantomAccent.cyan,
    bool          isDark    = true,
    double        intensity = 1.0,
  })  : _accent    = accent,
        _isDark    = isDark,
        _intensity = intensity;

  /// Loads persisted theme from secure storage; falls back to defaults.
  static Future<ThemeController> load() async {
    final accentStr    = await _store.read(key: _keyAccent);
    final darkStr      = await _store.read(key: _keyDark);
    final intensityStr = await _store.read(key: _keyIntensity);
    final accent = PhantomAccent.values.firstWhere(
      (a) => a.name == accentStr,
      orElse: () => PhantomAccent.cyan,
    );
    final intensity = double.tryParse(intensityStr ?? '') ?? 1.0;
    return ThemeController(accent: accent, isDark: darkStr != 'false', intensity: intensity);
  }

  Future<void> _persist() async {
    await _store.write(key: _keyAccent,    value: _accent.name);
    await _store.write(key: _keyDark,      value: _isDark.toString());
    await _store.write(key: _keyIntensity, value: _intensity.toString());
  }

  PhantomAccent get accent    => _accent;
  bool          get isDark    => _isDark;
  double        get intensity => _intensity;

  PhantomTokens get tokens => _isDark
      ? PhantomTokens.dark(_accent,  intensity: _intensity)
      : PhantomTokens.light(_accent, intensity: _intensity);

  void setAccent(PhantomAccent accent) {
    _accent = accent;
    notifyListeners();
    _persist();
  }

  void setIntensity(double v) {
    _intensity = v.clamp(0.0, 1.0);
    notifyListeners();
    _persist();
  }

  void toggleDarkMode() {
    _isDark = !_isDark;
    notifyListeners();
    _persist();
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
