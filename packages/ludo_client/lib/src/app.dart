import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'feedback.dart';
import 'home_screen.dart';
import 'theme.dart';

export 'theme.dart' show buildAppTheme, LudoBrand, LudoColors, LudoColorsDark;

/// The two locales this app ships with. Order matters only for
/// [MaterialApp.supportedLocales]; the toggle in [HomeScreen] switches
/// between exactly these two.
const List<Locale> appSupportedLocales = <Locale>[Locale('en'), Locale('ar')];

/// Root widget. Owns the current locale so a locale toggle reachable from the
/// home screen can flip it without touching the phone's system language.
class LudoApp extends StatefulWidget {
  const LudoApp({
    super.key,
    this.initialLocale = const Locale('en'),
    this.initialLinkReader = noInitialLink,
    this.linkStream = noLinkStream,
  });

  /// The locale the app starts in. Defaults to English; exposed so tests can
  /// pump the widget tree directly into Arabic without going through the
  /// toggle button.
  final Locale initialLocale;

  /// Passed straight down to [HomeScreen]. See its own doc comment.
  final InitialLinkReader initialLinkReader;

  /// Passed straight down to [HomeScreen]. See its own doc comment.
  final LinkStreamOpener linkStream;

  @override
  State<LudoApp> createState() => _LudoAppState();
}

class _LudoAppState extends State<LudoApp> {
  late Locale _locale = widget.initialLocale;

  // C-236 rule 1: one FeedbackSettings and the PlatformFeedbackService built
  // from it sit above MaterialApp for the life of the app, inside a
  // FeedbackScope that is in the tree from the very first frame. Loading the
  // persisted settings is async, so this starts from FeedbackSettings
  // .forTest's plain in-memory defaults -- haptics and sound both on, the
  // same values FeedbackSettings.load itself falls back to when nothing is
  // persisted yet -- and swaps to the loaded settings when they arrive,
  // rather than holding the first frame back or leaving a gap with nothing
  // above MaterialApp while the read is in flight.
  FeedbackSettings _feedbackSettings = FeedbackSettings.forTest();
  late PlatformFeedbackService _feedbackService = PlatformFeedbackService(
    _feedbackSettings,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadFeedbackSettings());
  }

  Future<void> _loadFeedbackSettings() async {
    final FeedbackSettings loaded;
    try {
      loaded = await FeedbackSettings.load();
    } catch (_) {
      // The placeholder settings from the field initializer keep serving:
      // a SharedPreferences failure here is never a reason to show an
      // error in place of the game.
      return;
    }
    if (!mounted) {
      return;
    }
    final PlatformFeedbackService stale = _feedbackService;
    setState(() {
      _feedbackSettings = loaded;
      _feedbackService = PlatformFeedbackService(_feedbackSettings);
    });
    stale.dispose();
  }

  @override
  void dispose() {
    _feedbackService.dispose();
    super.dispose();
  }

  void _toggleLocale() {
    setState(() {
      _locale = _locale.languageCode == 'en'
          ? const Locale('ar')
          : const Locale('en');
    });
  }

  @override
  Widget build(BuildContext context) {
    return FeedbackScope(
      settings: _feedbackSettings,
      service: _feedbackService,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
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
        home: HomeScreen(
          onToggleLocale: _toggleLocale,
          initialLinkReader: widget.initialLinkReader,
          linkStream: widget.linkStream,
        ),
      ),
    );
  }
}
