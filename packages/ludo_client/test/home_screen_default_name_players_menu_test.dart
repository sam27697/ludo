// Widget tests for the home screen's default player name and the seat
// count Create forwards: the name field shows the localised default on
// first paint, and since C-666 D1 there is no seat-count control, so
// Create Room always forwards four seats.
//
// Create Room builds a RoomController from widget.controllerFactory().
// The default factory opens a real WebSocket, so every test that taps
// Create injects a factory whose connect function rejects before
// constructing a transport. Assertions on the pushed LobbyScreen are
// static constructor arguments (players, playerName) and do not need
// the controller to reach phase connected.
//
// LobbyScreen's connecting state shows a CircularProgressIndicator, so
// these tests never call pumpAndSettle after a Create tap. A bounded
// 400ms pump covers MaterialPageRoute's default 300ms transition.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';

const Key _nameKey = Key('home-name-field');
const Key _createKey = Key('create-room-button');
const Key _localeKey = Key('locale-toggle-button');

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-screen-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_screen_default_name_players_menu_test.dart: this '
        'connector must never open a real or fake transport; '
        'RoomController only needs something to fail against without '
        'constructing one',
      );
    },
  );
}

Widget _homeScreenApp({
  RoomControllerFactory controllerFactory = _neverConnectsControllerFactory,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

String _nameFieldText(WidgetTester tester) {
  expect(find.byKey(_nameKey), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_nameKey)).controller!.text;
}

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

LobbyScreen _pushedLobbyScreen(WidgetTester tester) {
  final Finder finder = find.byType(LobbyScreen);
  expect(
    finder,
    findsOneWidget,
    reason:
        'expected exactly one LobbyScreen to have been pushed; found '
        '${finder.evaluate().length}',
  );
  return tester.widget<LobbyScreen>(finder);
}

void main() {
  testWidgets(
    'first paint name field equals the localised default in English',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final AppLocalizations loc = _loc(tester);
      expect(
        loc.homeDefaultPlayerName,
        isNotEmpty,
        reason: 'fixture is broken: homeDefaultPlayerName must not be empty',
      );
      expect(
        _nameFieldText(tester),
        loc.homeDefaultPlayerName,
        reason:
            'on first paint the name field must show the localised '
            'homeDefaultPlayerName ("${loc.homeDefaultPlayerName}"); got '
            '"${_nameFieldText(tester)}"',
      );
    },
  );

  testWidgets('first paint name field equals the localised default in Arabic', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
    await tester.pumpAndSettle();

    final AppLocalizations loc = _loc(tester);
    expect(
      loc.homeDefaultPlayerName,
      isNotEmpty,
      reason: 'fixture is broken: homeDefaultPlayerName must not be empty',
    );
    expect(
      _nameFieldText(tester),
      loc.homeDefaultPlayerName,
      reason:
          'on first paint in Arabic the name field must show the '
          'localised homeDefaultPlayerName ("${loc.homeDefaultPlayerName}"); '
          'got "${_nameFieldText(tester)}"',
    );
  });

  // C-666 D1: the closed control that read "4" and the menu behind it are
  // gone; the same first-paint situation now asserts there is nothing to
  // read or open.
  testWidgets('first paint has no players control and no menu options', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-players-button'), skipOffstage: false),
      findsNothing,
      reason:
          'home-players-button must not exist on first paint (C-666 D1: no '
          'player-count control)',
    );
    for (final int count in const <int>[2, 3, 4]) {
      expect(
        find.byKey(Key('home-players-option-$count'), skipOffstage: false),
        findsNothing,
        reason: 'home-players-option-$count must not exist on home (C-666 D1)',
      );
    }
  });

  testWidgets(
    'locale toggle rewrites a blank name field to the new locale default',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameKey), '');
      await tester.pump();
      expect(_nameFieldText(tester), isEmpty);

      await tester.tap(find.byKey(_localeKey));
      await tester.pumpAndSettle();

      final AppLocalizations loc = _loc(tester);
      expect(
        loc.homeDefaultPlayerName,
        isNotEmpty,
        reason: 'fixture is broken: homeDefaultPlayerName must not be empty',
      );
      expect(
        find.text('إنشاء غرفة'),
        findsOneWidget,
        reason: 'fixture is broken: locale toggle must have switched to Arabic',
      );
      expect(
        _nameFieldText(tester),
        loc.homeDefaultPlayerName,
        reason:
            'a blank name field must be rewritten to the new locale\'s '
            'homeDefaultPlayerName ("${loc.homeDefaultPlayerName}"); got '
            '"${_nameFieldText(tester)}"',
      );
    },
  );

  testWidgets(
    'locale toggle rewrites a name field that still equals the previous '
    'locale default',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final String previousDefault = _loc(tester).homeDefaultPlayerName;
      expect(previousDefault, isNotEmpty);

      await tester.enterText(find.byKey(_nameKey), previousDefault);
      await tester.pump();
      expect(_nameFieldText(tester), previousDefault);

      await tester.tap(find.byKey(_localeKey));
      await tester.pumpAndSettle();

      final AppLocalizations loc = _loc(tester);
      expect(
        loc.homeDefaultPlayerName,
        isNot(previousDefault),
        reason:
            'fixture is broken: English and Arabic default names must differ',
      );
      expect(
        _nameFieldText(tester),
        loc.homeDefaultPlayerName,
        reason:
            'a name field still equal to the previous locale default '
            '("$previousDefault") must be rewritten to the new locale\'s '
            'homeDefaultPlayerName ("${loc.homeDefaultPlayerName}"); got '
            '"${_nameFieldText(tester)}"',
      );
    },
  );

  testWidgets('Create forwards players 4', (tester) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await _tapAndAwaitPushedRoute(tester, _createKey);

    expect(
      _pushedLobbyScreen(tester).players,
      4,
      reason:
          'Create Room with no seat-count control must request 4 players '
          '(C-666 D1)',
    );
  });

  testWidgets('a custom typed name is not overwritten by a locale toggle', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_nameKey), 'Priya');
    await tester.pump();
    expect(_nameFieldText(tester), 'Priya');

    await tester.tap(find.byKey(_localeKey));
    await tester.pumpAndSettle();

    expect(
      find.text('إنشاء غرفة'),
      findsOneWidget,
      reason: 'fixture is broken: locale toggle must have switched to Arabic',
    );
    expect(
      _nameFieldText(tester),
      'Priya',
      reason:
          'a custom typed name must stay in the field after a locale '
          'toggle; got "${_nameFieldText(tester)}"',
    );
  });

  testWidgets('an empty name field is not sent; Create carries the non-empty '
      'localised default', (tester) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    final String defaultName = _loc(tester).homeDefaultPlayerName;
    expect(
      defaultName,
      isNotEmpty,
      reason: 'fixture is broken: homeDefaultPlayerName must not be empty',
    );

    await _tapAndAwaitPushedRoute(tester, _createKey);

    final LobbyScreen pushed = _pushedLobbyScreen(tester);
    expect(pushed.playerName, isNotEmpty);
    expect(pushed.playerName, defaultName);
  });

  testWidgets(
    'a whitespace-only name is not sent; Create carries the non-empty '
    'localised default',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      final String defaultName = _loc(tester).homeDefaultPlayerName;

      await tester.enterText(find.byKey(_nameKey), '   ');
      await _tapAndAwaitPushedRoute(tester, _createKey);

      expect(
        _pushedLobbyScreen(tester).playerName,
        defaultName,
        reason:
            'a name of only whitespace must be trimmed to empty and then '
            'fall back, the same as a genuinely empty field; got '
            '"${_pushedLobbyScreen(tester).playerName}"',
      );
    },
  );
}
