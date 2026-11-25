// Order 721: home with an optional Google sign-in. Everything is invisible
// when the server does not offer it; when it does, the control, the chip and
// the account sheet behave, in English and Arabic, on a 360x640 phone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/account.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _signIn = Key('home-google-sign-in');
const Key _chip = Key('home-account-chip');
const Key _sheet = Key('account-sheet');
const Key _signOut = Key('account-sheet-sign-out');
const Key _delete = Key('account-sheet-delete');
const Key _confirm = Key('account-delete-confirm');
const Key _cancel = Key('account-delete-cancel');
const Key _name = Key('home-name-field');
const Key _create = Key('create-room-button');
const Key _join = Key('join-game-button');

class _Google implements GoogleIdTokenSource {
  String? token = 'tok';
  int signOuts = 0;

  @override
  Future<String?> idToken(String serverClientId) async => token;

  @override
  Future<void> signOut() async {
    signOuts += 1;
  }
}

class _Server {
  Object? clientId = 'web-id';
  int googleStatus = 200;
  int deleteStatus = 200;
  String name = 'Lina Haddad';

  Future<({int status, String body})> call(
    String method,
    Uri url, {
    String? jsonBody,
  }) async {
    switch (url.path) {
      case '/auth/config':
        return (
          status: 200,
          body: jsonEncode(<String, Object?>{'google_client_id': clientId}),
        );
      case '/auth/google':
        return (
          status: googleStatus,
          body: jsonEncode(<String, Object?>{'name': name}),
        );
      default:
        return (
          status: deleteStatus,
          body: jsonEncode(<String, Object?>{'deleted': true}),
        );
    }
  }
}

RoomController _noController() =>
    throw StateError('no room is opened in this test');

Future<AccountService> _mount(
  WidgetTester tester,
  _Server server,
  _Google google, {
  Locale locale = const Locale('en'),
  Map<String, Object> prefs = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AccountService service = AccountService(
    origin: Uri.parse('https://example.invalid'),
    google: google,
    http: server.call,
  );
  await service.load();
  debugAccountServiceOverride = service;
  addTearDown(() => debugAccountServiceOverride = null);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(onToggleLocale: () {}, controllerFactory: _noController),
    ),
  );
  await _settle(tester);
  return service;
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _nameText(WidgetTester t) =>
    t.widget<TextField>(find.byKey(_name)).controller!.text;

void main() {
  tearDown(() {
    debugGoogleSignedInOverride = null;
    debugAccountServiceOverride = null;
  });

  testWidgets('server says null: no sign-in control, no chip', (tester) async {
    final _Server server = _Server()..clientId = null;
    await _mount(tester, server, _Google());
    expect(find.byKey(_signIn), findsNothing);
    expect(find.byKey(_chip), findsNothing);
  });

  testWidgets('offered: the control shows and both main buttons stay in view', (
    tester,
  ) async {
    await _mount(tester, _Server(), _Google());
    expect(find.byKey(_signIn), findsOneWidget);
    expect(find.byKey(_chip), findsNothing);
    expect(
      tester.getSize(find.byKey(_signIn)).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.getRect(find.byKey(_create)).bottom, lessThanOrEqualTo(640));
    expect(tester.getRect(find.byKey(_join)).bottom, lessThanOrEqualTo(640));
  });

  testWidgets(
    'sign in: the name row takes the Google name and the chip shows',
    (tester) async {
      final AccountService s = await _mount(tester, _Server(), _Google());
      await tester.tap(find.byKey(_signIn));
      await _settle(tester);
      expect(s.signedIn, isTrue);
      expect(find.byKey(_signIn), findsNothing);
      expect(find.byKey(_chip), findsOneWidget);
      expect(_nameText(tester), 'Lina Haddad');
      expect(
        tester.getSize(find.byKey(_chip)).shortestSide,
        greaterThanOrEqualTo(48),
      );
    },
  );

  testWidgets('backing out says nothing and leaves the control', (
    tester,
  ) async {
    final _Google google = _Google()..token = null;
    await _mount(tester, _Server(), google);
    await tester.tap(find.byKey(_signIn));
    await _settle(tester);
    expect(find.byKey(_signIn), findsOneWidget);
    expect(find.byKey(const Key('home-account-notice')), findsNothing);
  });

  testWidgets('a refused sign-in is told in words', (tester) async {
    final _Server server = _Server()..googleStatus = 401;
    await _mount(tester, server, _Google());
    await tester.tap(find.byKey(_signIn));
    await _settle(tester);
    final Finder notice = find.byKey(const Key('home-account-notice'));
    expect(notice, findsOneWidget);
    expect(
      tester.widget<Text>(notice).data,
      'That did not work. Check your connection and try again.',
    );
    expect(find.byKey(_signIn), findsOneWidget);
  });

  testWidgets('sheet: sign out returns to the control', (tester) async {
    final _Google google = _Google();
    final AccountService s = await _mount(
      tester,
      _Server(),
      google,
      prefs: <String, Object>{
        'account.signed_in': true,
        'account.name': 'Lina Haddad',
      },
    );
    expect(s.signedIn, isTrue);
    await tester.tap(find.byKey(_chip));
    await _settle(tester);
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.text('Signed in as Lina Haddad'), findsOneWidget);
    await tester.tap(find.byKey(_signOut));
    await _settle(tester);
    expect(find.byKey(_sheet), findsNothing);
    expect(s.signedIn, isFalse);
    expect(find.byKey(_signIn), findsOneWidget);
    expect(google.signOuts, 1);
  });

  testWidgets('sheet: delete asks first, says what goes, then deletes', (
    tester,
  ) async {
    final AccountService s = await _mount(
      tester,
      _Server(),
      _Google(),
      prefs: <String, Object>{
        'account.signed_in': true,
        'account.name': 'Lina Haddad',
      },
    );
    await tester.tap(find.byKey(_chip));
    await _settle(tester);
    await tester.tap(find.byKey(_delete));
    await _settle(tester);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(
      find.textContaining('already played stay checkable'),
      findsOneWidget,
    );
    expect(s.signedIn, isTrue);
    await tester.tap(find.byKey(_cancel));
    await _settle(tester);
    expect(find.byKey(_confirm), findsNothing);
    expect(s.signedIn, isTrue);
    await tester.tap(find.byKey(_delete));
    await _settle(tester);
    await tester.tap(find.byKey(_confirm));
    await _settle(tester);
    expect(s.signedIn, isFalse);
    expect(find.byKey(_sheet), findsNothing);
    expect(find.text('Your account is deleted.'), findsOneWidget);
  });

  testWidgets('sheet: a failed delete stays in the sheet with a line', (
    tester,
  ) async {
    final _Server server = _Server()..deleteStatus = 500;
    final AccountService s = await _mount(
      tester,
      server,
      _Google(),
      prefs: <String, Object>{'account.signed_in': true},
    );
    await tester.tap(find.byKey(_chip));
    await _settle(tester);
    await tester.tap(find.byKey(_delete));
    await _settle(tester);
    await tester.tap(find.byKey(_confirm));
    await _settle(tester);
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.byKey(const Key('account-sheet-line')), findsOneWidget);
    expect(s.signedIn, isTrue);
  });

  testWidgets('Arabic: words, mirrored order, chip label', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await _mount(tester, _Server(), _Google(), locale: const Locale('ar'));
    expect(find.text('سجّل الدخول بحساب Google'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(_signIn));
    await _settle(tester);
    expect(
      find.bySemanticsLabel('مسجّل الدخول بحساب Google. افتح حسابك.'),
      findsOneWidget,
    );
    final Rect field = tester.getRect(find.byKey(_name));
    final Rect chip = tester.getRect(find.byKey(_chip));
    expect(chip.center.dx, lessThan(field.center.dx));
    handle.dispose();
  });
}
