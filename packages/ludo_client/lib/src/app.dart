import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/gen/app_localizations.dart';
import 'home_screen.dart';

/// The two locales this app ships with. Order matters only for
/// [MaterialApp.supportedLocales]; the toggle in [HomeScreen] switches
/// between exactly these two.
const List<Locale> appSupportedLocales = <Locale>[Locale('en'), Locale('ar')];

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
