import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colour themes people can pick in Settings > Appearance.
class Palette {
  const Palette(this.id, this.name, this.seed);
  final String id;
  final String name;
  final Color seed;
}

const palettes = [
  Palette('pounce', 'Pounce', Color(0xFFF26A2E)), // the app icon's orange
  Palette('indigo', 'Indigo', Color(0xFF4057D6)),
  Palette('ocean', 'Ocean', Color(0xFF0A7EA4)),
  Palette('forest', 'Forest', Color(0xFF2F7D4F)),
  Palette('berry', 'Berry', Color(0xFFB4306B)),
  Palette('violet', 'Violet', Color(0xFF7048E8)),
];

Palette paletteById(String? id) => palettes.firstWhere((p) => p.id == id, orElse: () => palettes.first);

/// Theme mode and palette, kept on this device.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode, this._palette);

  static const _modeKey = 'theme_mode', _paletteKey = 'theme_palette';

  ThemeMode _mode;
  Palette _palette;
  ThemeMode get mode => _mode;
  Palette get palette => _palette;

  static ThemeController instance = ThemeController._(ThemeMode.system, palettes.first);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mode = ThemeMode.values.where((m) => m.name == prefs.getString(_modeKey)).firstOrNull ?? ThemeMode.system;
      instance = ThemeController._(mode, paletteById(prefs.getString(_paletteKey)));
    } catch (_) {
      // private browsing or blocked storage: use the defaults
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_modeKey, mode.name);
    } catch (_) {}
  }

  Future<void> setPalette(Palette palette) async {
    _palette = palette;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_paletteKey, palette.id);
    } catch (_) {}
  }
}

ThemeData buildTheme(Palette palette, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final dark = brightness == Brightness.dark;
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = base.textTheme.copyWith(
    headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.1),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );
  return base.copyWith(
    scaffoldBackgroundColor: dark ? scheme.surface : scheme.surfaceContainerLowest,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? scheme.surface : scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 1,
      // ThemeData's text styles get their sizes later, so this one needs its own
      titleTextStyle: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? scheme.surfaceContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.8)),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: rounded,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: rounded, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: rounded)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: dark ? scheme.surfaceContainer : scheme.surface,
      indicatorColor: scheme.primaryContainer,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          )),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: dark ? scheme.surfaceContainer : scheme.surface,
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurface),
      unselectedLabelTextStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
    ),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: rounded),
    listTileTheme: ListTileThemeData(shape: rounded),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(shape: rounded, selectedBackgroundColor: scheme.primaryContainer),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6)),
  );
}

/// A soft gradient in the theme's colours, for headers.
LinearGradient brandGradient(ColorScheme scheme) => LinearGradient(
      colors: [scheme.primaryContainer, Color.lerp(scheme.primaryContainer, scheme.secondaryContainer, 0.85)!],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
