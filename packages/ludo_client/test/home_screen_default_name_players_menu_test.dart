// Widget tests for the home screen's player name and the seat count Create
// forwards. Since order 701 (X226) the name field starts empty with its label
// as the hint and an empty name opens nothing; since C-666 D1 there is no
// seat-count control, so Create Room always forwards four seats.
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

import 'support/home_flow.dart';

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

/// Order 701: Create opens a sheet; the friends-only tile creates the room.
Future<void> _createAndAwaitPushedRoute(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tapCreateRoom(tester);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// X226: the empty field carries its label as the hint. Read either the
/// decoration's hint or its label: the design names the text, not which slot
/// of the decoration carries it.
void _expectEmptyWithLabelHint(WidgetTester tester, String locale) {
  final AppLocalizations loc = _loc(tester);
  expect(
    _nameFieldText(tester),
    isEmpty,
    reason:
        'X226 ($locale): on first paint the name field must be empty; got '
        '"${_nameFieldText(tester)}"',
  );
  final InputDecoration? decoration = tester
      .widget<TextField>(find.byKey(_nameKey))
      .decoration;
  expect(
    decoration?.hintText == loc.homeNameFieldLabel ||
        decoration?.labelText == loc.homeNameFieldLabel,
    isTrue,
    reason:
        'X226 ($locale): the empty field shows its label '
        '"${loc.homeNameFieldLabel}" as the hint; hintText '
        '"${decoration?.hintText}", labelText "${decoration?.labelText}"',
  );
}

/// Taps Create on an empty or blank name and asserts nothing opened.
Future<void> _expectCreateRefused(WidgetTester tester, String scenario) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tester.tap(find.byKey(_createKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    find.byKey(createRoomSheetKey),
    findsNothing,
    reason: 'X226 ($scenario): Create must not open the create sheet',
  );
  expect(
    find.byType(LobbyScreen),
    findsNothing,
    reason: 'X226 ($scenario): no lobby may be pushed without a name',
  );
  expect(
    find.byKey(homeNameRequiredKey),
    findsOneWidget,
    reason: 'X226 ($scenario): home-name-required must show under the field',
  );
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
    'first paint name field is empty with its label as the hint in English',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      _expectEmptyWithLabelHint(tester, 'en');
    },
  );

  testWidgets(
    'first paint name field is empty with its label as the hint in Arabic',
    (tester) async {
      await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
      await tester.pumpAndSettle();

      _expectEmptyWithLabelHint(tester, 'ar');
    },
  );

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

  // X226: a blank field is no longer filled with a default name, so a locale
  // toggle leaves it blank.
  testWidgets(
    'locale toggle leaves a blank name field blank',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameKey), '');
      await tester.pump();
      expect(_nameFieldText(tester), isEmpty);

      await tester.tap(find.byKey(_localeKey));
      await tester.pumpAndSettle();

      expect(
        find.text('إنشاء غرفة'),
        findsOneWidget,
        reason: 'fixture is broken: locale toggle must have switched to Arabic',
      );
      expect(
        _nameFieldText(tester),
        isEmpty,
        reason:
            'X226: a blank name field must stay blank across a locale '
            'toggle; got "${_nameFieldText(tester)}"',
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

    await enterName(tester, 'Player');
    await _createAndAwaitPushedRoute(tester);

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

  testWidgets('an empty name field is not sent: Create opens nothing and '
      'asks for a name', (tester) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await _expectCreateRefused(tester, 'empty name');
  });

  testWidgets(
    'a whitespace-only name is empty after trim: Create opens nothing and '
    'asks for a name',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameKey), '   ');
      await _expectCreateRefused(tester, 'whitespace-only name');
    },
  );
}
