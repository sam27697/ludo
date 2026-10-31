// Tests for work/ludo/orders/C-516-app-language.md, rules D1, D2, D3 and
// D5: lib/src/locale_preference.dart (LocalePreference) and the
// persistLocale parameter of LudoApp, built in parallel by order 517.
// Neither exists on the branch this file was written on; every expectation
// is read off C-516's own text. D4 (the catch sites in main) is proven by
// the device-matrix run, not here.
//
// Every failure message names its scenario (the stored value, the system
// list, or the widget flow) so a red row can be replayed by hand. There is
// no randomness and no seed.
//
// The widget cases follow test/locale_rtl_test.dart: LudoApp is pumped
// whole and the toggle is tapped by key. The write behind a tap is not
// awaited by the app (C-516), so the cases pump and then read the prefs
// until the expected value shows up, bounded, rather than sleeping.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations_ar.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/locale_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _toggleKey = Key('locale-toggle-button');

class _Row {
  const _Row(this.stored, this.system, this.expected);

  final String? stored;
  final List<Locale> system;
  final String expected;
}

const List<_Row> _rows = <_Row>[
  // D2: no stored choice, the first en or ar locale of the list wins.
  _Row(null, [Locale('ar', 'AE')], 'ar'),
  _Row(null, [Locale('ar')], 'ar'),
  _Row(null, [Locale('en', 'US')], 'en'),
  _Row(null, [Locale('fr', 'FR')], 'en'),
  _Row(null, [], 'en'),
  _Row(null, [Locale('fr', 'FR'), Locale('ar', 'SA')], 'ar'),
  _Row(null, [
    Locale('fr', 'FR'),
    Locale('en', 'GB'),
    Locale('ar', 'SA'),
  ], 'en'),
  _Row(null, [
    Locale('de', 'DE'),
    Locale('ar', 'EG'),
    Locale('en', 'US'),
  ], 'ar'),
  // D1: a stored en or ar beats the phone.
  _Row('en', [Locale('ar', 'AE')], 'en'),
  _Row('ar', [Locale('en', 'US')], 'ar'),
  // Anything stored that is not en or ar counts as nothing stored.
  _Row('xx', [Locale('ar', 'AE')], 'ar'),
  _Row('', [Locale('en', 'US')], 'en'),
];

String _describe(_Row row) =>
    'stored=${row.stored == null ? 'null' : "'${row.stored}'"} '
    'system=${row.system}';

/// Pumps and re-reads the stored value until [want] shows up, at most 20
/// rounds. Returns whatever was read last, so a failure shows the real value.
Future<String?> _readUntil(WidgetTester tester, String? want) async {
  String? raw;
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    raw = prefs.getString(LocalePreference.storageKey);
    if (raw == want) return raw;
  }
  return raw;
}

/// For the "nothing is written" cases: lets the frame and every pending
/// microtask run for a few rounds, then reads once.
Future<String?> _readAfterQuiet(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await SharedPreferences.getInstance();
  }
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(LocalePreference.storageKey);
}

TextDirection _homeDirection(WidgetTester tester) =>
    Directionality.of(tester.element(find.byType(HomeScreen)));

void main() {
  group('startupLocale (D1, D2)', () {
    for (final row in _rows) {
      test(_describe(row), () {
        final got = LocalePreference.startupLocale(
          stored: row.stored,
          system: row.system,
        );
        expect(
          got.languageCode,
          row.expected,
          reason:
              'expected language ${row.expected}, got ${got.languageCode} '
              'for ${_describe(row)}',
        );
        expect(
          got.countryCode,
          isNull,
          reason:
              'expected a null countryCode, got ${got.countryCode} '
              'for ${_describe(row)}',
        );
      });
    }
  });

  group('loadStored and store', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('the storage key is exactly app.locale', () {
      expect(LocalePreference.storageKey, 'app.locale');
    });

    test('loadStored is null when nothing is stored', () async {
      expect(
        await LocalePreference.loadStored(),
        isNull,
        reason: 'expected null with empty prefs',
      );
    });

    test('store writes the language code only, loadStored reads it', () async {
      await LocalePreference.store(const Locale('ar', 'AE'));

      expect(
        await LocalePreference.loadStored(),
        'ar',
        reason: "expected loadStored 'ar' after store(Locale('ar','AE'))",
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(LocalePreference.storageKey),
        'ar',
        reason: "expected raw 'ar' under app.locale after store(ar_AE)",
      );
    });

    test('the last store wins', () async {
      await LocalePreference.store(const Locale('ar'));
      await LocalePreference.store(const Locale('en'));

      expect(
        await LocalePreference.loadStored(),
        'en',
        reason: "expected 'en' after store(ar) then store(en)",
      );
    });

    test(
      'loadStored returns a value that was in the prefs at launch',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          LocalePreference.storageKey: 'ar',
        });

        expect(
          await LocalePreference.loadStored(),
          'ar',
          reason: "expected 'ar' from initial prefs {app.locale: ar}",
        );
      },
    );
  });

  group('LudoApp(persistLocale: true) (D3)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('each tap stores the new language and flips the direction', (
      tester,
    ) async {
      await tester.pumpWidget(const LudoApp(persistLocale: true));
      await tester.pumpAndSettle();
      expect(
        _homeDirection(tester),
        TextDirection.ltr,
        reason: 'expected ltr before any tap with prefs {}',
      );

      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();
      expect(
        _homeDirection(tester),
        TextDirection.rtl,
        reason: 'expected rtl after the first tap with persistLocale: true',
      );
      expect(
        await _readUntil(tester, 'ar'),
        'ar',
        reason: "expected raw 'ar' under app.locale after the first tap",
      );

      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();
      expect(
        _homeDirection(tester),
        TextDirection.ltr,
        reason: 'expected ltr after the second tap with persistLocale: true',
      );
      expect(
        await _readUntil(tester, 'en'),
        'en',
        reason: "expected raw 'en' under app.locale after the second tap",
      );
    });

    testWidgets('a tap from an Arabic start stores en', (tester) async {
      await tester.pumpWidget(
        const LudoApp(initialLocale: Locale('ar'), persistLocale: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();

      expect(
        _homeDirection(tester),
        TextDirection.ltr,
        reason: 'expected ltr after one tap from initialLocale ar',
      );
      expect(
        await _readUntil(tester, 'en'),
        'en',
        reason: "expected raw 'en' after one tap from initialLocale ar",
      );
    });

    testWidgets('starting and never tapping leaves the key absent', (
      tester,
    ) async {
      await tester.pumpWidget(const LudoApp(persistLocale: true));
      await tester.pumpAndSettle();

      expect(
        await _readAfterQuiet(tester),
        isNull,
        reason: 'expected no app.locale after launch without a tap',
      );
    });

    testWidgets('starting in Arabic and never tapping leaves the key absent', (
      tester,
    ) async {
      await tester.pumpWidget(
        const LudoApp(initialLocale: Locale('ar'), persistLocale: true),
      );
      await tester.pumpAndSettle();

      expect(
        await _readAfterQuiet(tester),
        isNull,
        reason:
            'expected no app.locale after launch in ar without a tap '
            '(a launch must not write the phone language back)',
      );
    });
  });

  group('LudoApp() with no new arguments (D5)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('a tap flips the direction and stores nothing', (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();
      expect(
        _homeDirection(tester),
        TextDirection.ltr,
        reason: 'expected ltr from LudoApp() before any tap',
      );

      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();

      expect(
        _homeDirection(tester),
        TextDirection.rtl,
        reason: 'expected rtl after one tap on LudoApp()',
      );
      expect(
        await _readAfterQuiet(tester),
        isNull,
        reason: 'expected no app.locale after a tap on LudoApp() (D5)',
      );
    });

    testWidgets('two taps still store nothing', (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_toggleKey));
      await tester.pumpAndSettle();

      expect(
        _homeDirection(tester),
        TextDirection.ltr,
        reason: 'expected ltr after two taps on LudoApp()',
      );
      expect(
        await _readAfterQuiet(tester),
        isNull,
        reason: 'expected no app.locale after two taps on LudoApp() (D5)',
      );
    });
  });

  group('stored choice to first frame (D1)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('stored ar over an English phone renders Arabic, rtl', (
      tester,
    ) async {
      final locale = LocalePreference.startupLocale(
        stored: 'ar',
        system: const [Locale('en', 'US')],
      );
      await tester.pumpWidget(LudoApp(initialLocale: locale));
      await tester.pumpAndSettle();

      expect(
        _homeDirection(tester),
        TextDirection.rtl,
        reason: "expected rtl for stored 'ar' with system [en_US]",
      );
      final ar = AppLocalizationsAr();
      expect(
        tester.widget<Title>(find.byType(Title)).title,
        ar.appTitle,
        reason: "expected the ar app title for stored 'ar' with system [en_US]",
      );
      // appTitle is the same string in en and ar, so the tagline is what
      // actually shows which language the screen is in.
      expect(
        find.text(ar.homeTagline),
        findsOneWidget,
        reason:
            "expected the ar home tagline '${ar.homeTagline}' on screen for "
            "stored 'ar' with system [en_US]",
      );
    });
  });
}
