import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/gen/app_localizations.dart';
import 'home_screen.dart';

/// The two locales this app ships with. Order matters only for
/// [MaterialApp.supportedLocales]; the toggle in [HomeScreen] switches
/// between exactly these two.
const List<Locale> appSupportedLocales = <Locale>[Locale('en'), Locale('ar')];

/// The app's theme, built once so every screen and every future action
/// button on an [AppBar] gets a foreground colour that actually contrasts
/// with the bar instead of each call site guessing one.
///
/// The default Material 3 [AppBar] paints on [ColorScheme.surface] and reads
/// its own title in [ColorScheme.onSurface] (see
/// `_AppBarDefaultsM3.foregroundColor` in the framework), which is why the
/// app bar title is legible without any of this. A plain [TextButton]
/// dropped into [AppBar.actions], though, is not part of that wiring: an
/// [AppBar] only threads its foreground colour into an [IconTheme] and an
/// [IconButtonTheme] for its actions row, never into a [TextButtonTheme] or a
/// [DefaultTextStyle], so a [TextButton] there falls back to whatever
/// [ThemeData.textButtonTheme] says regardless of which bar it sits on. That
/// gap is what let the locale toggle sit uncoloured until someone hardcoded
/// white on it, and white happened to be right for the coloured app bars of
/// Material 2, not the near-white surface app bar Material 3 renders here.
/// Setting [ThemeData.textButtonTheme] once, to the same [ColorScheme.
/// onSurface] the bar already uses for its title, fixes every text button on
/// every app bar in the app, this one and any added later, rather than
/// re-guessing a colour at each call site.
ThemeData buildAppTheme() {
  final base = ThemeData(useMaterial3: true);
  return base.copyWith(
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: base.colorScheme.onSurface),
    ),
  );
}

/// Root widget. Owns the current locale so a locale toggle reachable from the
/// home screen can flip it without touching the phone's system language.
class LudoApp extends StatefulWidget {
  const LudoApp({super.key, this.initialLocale = const Locale('en')});

  /// The locale the app starts in. Defaults to English; exposed so tests can
  /// pump the widget tree directly into Arabic without going through the
  /// toggle button.
  final Locale initialLocale;

  @override
  State<LudoApp> createState() => _LudoAppState();
}

class _LudoAppState extends State<LudoApp> {
  late Locale _locale = widget.initialLocale;

  void _toggleLocale() {
    setState(() {
      _locale = _locale.languageCode == 'en'
          ? const Locale('ar')
          : const Locale('en');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      locale: _locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      home: HomeScreen(onToggleLocale: _toggleLocale),
    );
  }
}
