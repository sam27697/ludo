import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_build.dart';
import 'src/deep_link.dart';
import 'src/locale_preference.dart';
import 'src/server_config.dart' as server_config;

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
  // Section 27 rule 1: read once, before any socket can open. An unreadable
  // build is null and the upgrade then carries no header.
  server_config.clientBuild = await readAppBuild();
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
