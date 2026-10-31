import 'dart:ui' show Locale;

import 'package:shared_preferences/shared_preferences.dart';

/// The player's language choice (C-516).
class LocalePreference {
  /// SharedPreferences key. Values are exactly 'en' or 'ar'.
  static const String storageKey = 'app.locale';

  /// D1 and D2. Pure: no I/O. [stored] is the raw stored string or null;
  /// anything other than 'en' or 'ar' is treated as null.
  ///
  /// A stored choice wins over the phone. Without one, the first entry of
  /// [system] whose language is English or Arabic decides, country ignored,
  /// and English is the answer when none does. Never returns a locale with a
  /// country code, so it matches [appSupportedLocales] exactly.
  static Locale startupLocale({
    required String? stored,
    required List<Locale> system,
  }) {
    if (stored == 'en' || stored == 'ar') {
      return Locale(stored!);
    }
    for (final Locale locale in system) {
      if (locale.languageCode == 'en' || locale.languageCode == 'ar') {
        return Locale(locale.languageCode);
      }
    }
    return const Locale('en');
  }

  /// The raw stored string, or null when nothing is stored. Throws what
  /// SharedPreferences throws; the caller (main) decides.
  static Future<String?> loadStored() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(storageKey);
  }

  /// Writes locale.languageCode under [storageKey]. Throws what
  /// SharedPreferences throws; the caller decides.
  static Future<void> store(Locale locale) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, locale.languageCode);
  }
}
