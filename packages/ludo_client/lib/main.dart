import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/deep_link.dart';
import 'src/locale_preference.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? stored;
  try {
    stored = await LocalePreference.loadStored();
  } catch (_) {
    // Unreadable storage reads as "no stored choice", so the phone's
    // language decides rather than the app failing to start.
    stored = null;
  }
  runApp(
    LudoApp(
      initialLocale: LocalePreference.startupLocale(
        stored: stored,
        system: WidgetsBinding.instance.platformDispatcher.locales,
      ),
      persistLocale: true,
      initialLinkReader: appLinksInitialLink,
      linkStream: appLinksLinkStream,
    ),
  );
}
