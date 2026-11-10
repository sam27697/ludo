// Proof of C-614 D1: every place the app opens a verify URL adds ?lang= set
// to the language the app is showing at that moment, not the phone's.
//
// Group (a) is the pure helper, verifyUriFor in lib/src/verify_link.dart. On
// the base that file does not exist, so this file fails to compile and the
// only reason is that one missing import. Group (b) (the end card) and group
// (c) (home's recent game) are kept in their own group so a copy of this file
// without the import and without group (a) compiles on the base and shows
// their red on its own.
//
// The app's own language is MaterialApp.locale, which is what the running app
// feeds from LocalePreference; the phone's language is set apart from it with
// the test platform dispatcher's locales, so a client that read the phone
// instead of the app would fail the cases where the two disagree.
//
// The end card is mounted the way test/verify_door_wiring_test.dart does it:
// a real RoomController over a FakeTransport whose first reply is a FINISHED
// room carrying verify_url. Home is mounted from a seeded LastGame. The
// launcher is spied on its method channels, as test/end_card_test.dart does,
// and every URL the plugin was asked to open is read back as a Uri.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/verify_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _verifyKey = Key('game-screen-verify-button');
const Key _homeLastGameCheckKey = Key('home-last-game-check');

const String _testUrl = 'wss://c614-verify-link-test.invalid/ws';

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

// --- url_launcher spy -------------------------------------------------------

/// Every url the plugin was asked to open, in call order, as the string the
/// platform side received.
List<String> _listenUrlLaunches(WidgetTester tester) {
  final List<String> urls = <String>[];
  Future<Object?> handler(MethodCall call) async {
    final Object? args = call.arguments;
    if (args is Map && args['url'] is String) {
      urls.add(args['url'] as String);
    } else if (args is String) {
      urls.add(args);
    }
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return urls;
}

/// The phone says [platform] while the app (MaterialApp.locale) says
/// something else; cleared at tear-down.
void _setPhoneLocale(WidgetTester tester, Locale platform) {
  tester.platformDispatcher.localesTestValue = <Locale>[platform];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
}

/// Reads the launched urls back and checks the one the scenario owes.
void _expectOneLaunchWithLang(
  List<String> launched, {
  required String scenario,
  required String lang,
  required String path,
  Map<String, String> keptParams = const <String, String>{},
}) {
  expect(
    launched,
    hasLength(1),
    reason:
        'scenario "$scenario": expected exactly one url_launcher call, got '
        '${launched.length}: $launched',
  );
  final Uri uri = Uri.parse(launched.single);
  expect(
    uri.path,
    path,
    reason:
        'scenario "$scenario": the launched path must stay $path; got '
        '"${uri.path}" in ${launched.single}',
  );
  expect(
    uri.queryParametersAll['lang'],
    <String>[lang],
    reason:
        'scenario "$scenario": expected the launched url to carry exactly '
        'one lang=$lang; got ${uri.queryParametersAll['lang']} in '
        '${launched.single}',
  );
  keptParams.forEach((String key, String value) {
    expect(
      uri.queryParametersAll[key],
      <String>[value],
      reason:
          'scenario "$scenario": the existing parameter $key=$value must '
          'survive; got ${uri.queryParametersAll[key]} in ${launched.single}',
    );
  });
}

// --- end card fixture: a real RoomController landing on FINISHED ------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c614-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _finishedRoomJson({required String verifyUrl}) =>
    <String, Object?>{
      'code': 'C614XX',
      'state': 'FINISHED',
      'host_seat': 0,
      'players': 2,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'a' * 64,
      'chain_index': 0,
      'game_id': 'c614-game',
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ],
      'turn': null,
      'winner': 0,
      'verify_url': verifyUrl,
      'seq': 1,
    };

Future<void> _mountFinishedEndCard(
  WidgetTester tester, {
  required Locale appLocale,
  required String verifyUrl,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  addTearDown(controller.dispose);

  final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _finishedRoomJson(verifyUrl: verifyUrl),
    ),
  );
  await created;

  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(appLocale, GameScreen(controller: controller)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
  // Landing on FINISHED fires the game_log fetch; this transport never
  // answers it, so its request timeout is flushed rather than left pending.
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

Widget _app(Locale locale, Widget home) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

RoomController _unusedControllerFactory() => RoomController(
  serverUrl: Uri.parse(_testUrl),
  connect: (Uri url) async {
    throw UnimplementedError(
      'c614 test: the recent-game check never taps Create or Join, so '
      'controllerFactory must never be called',
    );
  },
);

// --- home fixture: a seeded LastGame ----------------------------------------

Future<void> _mountHomeWithLastGame(
  WidgetTester tester, {
  required Locale appLocale,
  required String verifyUrl,
}) async {
  final DateTime fixedNow = DateTime.utc(2026, 11, 10, 12, 0, 0);
  await SessionMemory.recordLastGame(
    LastGame(
      gameId: 'c614-home-game',
      verifyUrl: verifyUrl,
      finishedAt: fixedNow.subtract(const Duration(days: 1)),
      won: true,
    ),
  );
  await tester.pumpWidget(
    _app(
      appLocale,
      HomeScreen(
        onToggleLocale: () {},
        controllerFactory: _unusedControllerFactory,
        clock: () => fixedNow,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key, String scenario) async {
  final Finder finder = find.byKey(key);
  expect(
    finder,
    findsOneWidget,
    reason: 'scenario "$scenario": fixture is broken, $key must mount once',
  );
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('a: verifyUriFor builds the link', () {
    final Uri base = Uri.parse('https://provefair.app/v/abc');

    test('ar adds lang=ar', () {
      final Uri got = verifyUriFor(base, const Locale('ar'));
      expect(
        got.toString(),
        'https://provefair.app/v/abc?lang=ar',
        reason: 'expected lang=ar added to $base; got $got',
      );
    });

    test('en adds lang=en', () {
      final Uri got = verifyUriFor(base, const Locale('en'));
      expect(
        got.toString(),
        'https://provefair.app/v/abc?lang=en',
        reason: 'expected lang=en added to $base; got $got',
      );
    });

    test('a language that is not ar or en leaves the uri unchanged', () {
      for (final String code in const <String>['fr', 'de', 'es', 'zh']) {
        final Uri got = verifyUriFor(base, Locale(code));
        expect(
          got.toString(),
          base.toString(),
          reason: 'expected no lang for "$code"; got $got',
        );
      }
    });

    test('a country code does not change the language that is sent', () {
      final Uri got = verifyUriFor(base, const Locale('ar', 'AE'));
      expect(got.queryParametersAll['lang'], <String>[
        'ar',
      ], reason: 'expected lang=ar for ar_AE; got $got');
    });

    test('an existing lang is replaced, never duplicated', () {
      final Uri got = verifyUriFor(
        Uri.parse('https://provefair.app/v/abc?lang=en'),
        const Locale('ar'),
      );
      expect(got.queryParametersAll['lang'], <String>[
        'ar',
      ], reason: 'expected exactly one lang=ar; got $got');
      expect(
        got.toString().split('lang=').length - 1,
        1,
        reason: 'expected the text "lang=" once in the link; got $got',
      );
    });

    test('several existing lang values collapse to the one the app shows', () {
      final Uri got = verifyUriFor(
        Uri.parse('https://provefair.app/v/abc?lang=en&lang=fr'),
        const Locale('ar'),
      );
      expect(got.queryParametersAll['lang'], <String>[
        'ar',
      ], reason: 'expected exactly one lang=ar from a double lang; got $got');
    });

    test('another parameter is kept next to lang', () {
      final Uri got = verifyUriFor(
        Uri.parse('https://provefair.app/v/abc?ref=card&n=2'),
        const Locale('en'),
      );
      expect(got.queryParametersAll, <String, List<String>>{
        'ref': <String>['card'],
        'n': <String>['2'],
        'lang': <String>['en'],
      }, reason: 'expected ref, n and lang=en together; got $got');
    });

    test('scheme, host, port, path and fragment are untouched', () {
      final Uri got = verifyUriFor(
        Uri.parse('http://127.0.0.1:8080/v/abc/def#rolls'),
        const Locale('ar'),
      );
      expect(got.scheme, 'http', reason: 'scheme changed in $got');
      expect(got.host, '127.0.0.1', reason: 'host changed in $got');
      expect(got.port, 8080, reason: 'port changed in $got');
      expect(got.path, '/v/abc/def', reason: 'path changed in $got');
      expect(got.fragment, 'rolls', reason: 'fragment changed in $got');
      expect(got.queryParametersAll['lang'], <String>['ar']);
    });

    test('the input uri is not modified', () {
      final Uri input = Uri.parse('https://provefair.app/v/abc?lang=en');
      verifyUriFor(input, const Locale('ar'));
      expect(
        input.toString(),
        'https://provefair.app/v/abc?lang=en',
        reason: 'verifyUriFor must return a new Uri; the input became $input',
      );
    });
  });

  group('b and c: the buttons open the link in the app language', () {
    testWidgets('end card, app ar on an en phone, opens lang=ar', (
      tester,
    ) async {
      const String scenario = 'end card, app ar, phone en';
      _setPhoneLocale(tester, const Locale('en', 'US'));
      await _mountFinishedEndCard(
        tester,
        appLocale: const Locale('ar'),
        verifyUrl: 'https://provefair.app/v/endcard?ref=card',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _verifyKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'ar',
        path: '/v/endcard',
        keptParams: const <String, String>{'ref': 'card'},
      );
    });

    testWidgets('end card, app en on an ar phone, opens lang=en', (
      tester,
    ) async {
      const String scenario = 'end card, app en, phone ar';
      _setPhoneLocale(tester, const Locale('ar', 'AE'));
      await _mountFinishedEndCard(
        tester,
        appLocale: const Locale('en'),
        verifyUrl: 'https://provefair.app/v/endcard?ref=card',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _verifyKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'en',
        path: '/v/endcard',
        keptParams: const <String, String>{'ref': 'card'},
      );
    });

    testWidgets('end card, server link already says lang=en, app ar wins', (
      tester,
    ) async {
      const String scenario = 'end card, link lang=en, app ar, phone en';
      _setPhoneLocale(tester, const Locale('en'));
      await _mountFinishedEndCard(
        tester,
        appLocale: const Locale('ar'),
        verifyUrl: 'https://provefair.app/v/endcard?lang=en',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _verifyKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'ar',
        path: '/v/endcard',
      );
    });

    testWidgets('home recent game, app ar on an en phone, opens lang=ar', (
      tester,
    ) async {
      const String scenario = 'home recent game, app ar, phone en';
      _setPhoneLocale(tester, const Locale('en', 'US'));
      await _mountHomeWithLastGame(
        tester,
        appLocale: const Locale('ar'),
        verifyUrl: 'https://provefair.app/v/home?ref=home',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _homeLastGameCheckKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'ar',
        path: '/v/home',
        keptParams: const <String, String>{'ref': 'home'},
      );
    });

    testWidgets('home recent game, app en on an ar phone, opens lang=en', (
      tester,
    ) async {
      const String scenario = 'home recent game, app en, phone ar';
      _setPhoneLocale(tester, const Locale('ar', 'AE'));
      await _mountHomeWithLastGame(
        tester,
        appLocale: const Locale('en'),
        verifyUrl: 'https://provefair.app/v/home?ref=home',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _homeLastGameCheckKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'en',
        path: '/v/home',
        keptParams: const <String, String>{'ref': 'home'},
      );
    });

    testWidgets('home recent game, stored link says lang=en, app ar wins', (
      tester,
    ) async {
      const String scenario = 'home recent game, link lang=en, app ar';
      _setPhoneLocale(tester, const Locale('en'));
      await _mountHomeWithLastGame(
        tester,
        appLocale: const Locale('ar'),
        verifyUrl: 'https://provefair.app/v/home?lang=en',
      );
      final List<String> launched = _listenUrlLaunches(tester);
      await _tap(tester, _homeLastGameCheckKey, scenario);
      _expectOneLaunchWithLang(
        launched,
        scenario: scenario,
        lang: 'ar',
        path: '/v/home',
      );
    });
  });
}
