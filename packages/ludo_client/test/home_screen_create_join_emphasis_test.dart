// Widget tests for HomeScreen Create Room / Join Room emphasis: the
// primary action is an ElevatedButton and the other is an OutlinedButton,
// switching with the room-code-field contents. Taps still push the same
// LobbyAction they do today.
//
// Create Room and Join Room build a RoomController from
// widget.controllerFactory(). The default factory opens a real WebSocket,
// so every test that taps those buttons injects a factory whose connect
// function rejects before constructing a transport. Assertions on the
// pushed LobbyScreen are static constructor arguments (action, code) and
// do not need the controller to reach phase connected.
//
// LobbyScreen's connecting state shows a CircularProgressIndicator, so
// these tests never call pumpAndSettle after a Create or Join tap. A
// bounded 400ms pump covers MaterialPageRoute's default 300ms transition.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';

const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-screen-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_screen_create_join_emphasis_test.dart: this connector must '
        'never open a real or fake transport; RoomController only needs '
        'something to fail against without constructing one',
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

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
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

Widget _keyedButton(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget);
  return tester.widget(find.byKey(key));
}

void _expectCreateElevatedJoinOutlined(WidgetTester tester) {
  expect(
    _keyedButton(tester, _createKey),
    isA<ElevatedButton>(),
    reason:
        'create-room-button must be an ElevatedButton; found '
        '${_keyedButton(tester, _createKey).runtimeType}',
  );
  expect(
    _keyedButton(tester, _joinKey),
    isA<OutlinedButton>(),
    reason:
        'join-room-button must be an OutlinedButton; found '
        '${_keyedButton(tester, _joinKey).runtimeType}',
  );
}

void _expectJoinElevatedCreateOutlined(WidgetTester tester) {
  expect(
    _keyedButton(tester, _joinKey),
    isA<ElevatedButton>(),
    reason:
        'join-room-button must be an ElevatedButton; found '
        '${_keyedButton(tester, _joinKey).runtimeType}',
  );
  expect(
    _keyedButton(tester, _createKey),
    isA<OutlinedButton>(),
    reason:
        'create-room-button must be an OutlinedButton; found '
        '${_keyedButton(tester, _createKey).runtimeType}',
  );
}

void main() {
  testWidgets('empty code field uses elevated Create and outlined Join', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    expect(find.byKey(_codeKey), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(_codeKey)).controller?.text, '');

    _expectCreateElevatedJoinOutlined(tester);
  });

  testWidgets('valid code AB23CD uses elevated Join and outlined Create', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
      'AB23CD',
    );
    _expectJoinElevatedCreateOutlined(tester);
  });

  testWidgets(
    'valid dashed code ab2-3cd uses elevated Join and outlined Create',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_codeKey), 'ab2-3cd');
      await tester.pump();

      _expectJoinElevatedCreateOutlined(tester);
    },
  );

  testWidgets('invalid short code ABC uses elevated Create and outlined Join', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_codeKey), 'ABC');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
      'ABC',
    );
    _expectCreateElevatedJoinOutlined(tester);
  });

  testWidgets(
    'invalid banned-zero code AB023C uses elevated Create and outlined Join',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_codeKey), 'AB023C');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        'AB023C',
      );
      _expectCreateElevatedJoinOutlined(tester);
    },
  );

  testWidgets('Create Room still pushes create with an empty code field', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await _tapAndAwaitPushedRoute(tester, _createKey);

    final LobbyScreen pushed = _pushedLobbyScreen(tester);
    expect(
      pushed.action,
      LobbyAction.create,
      reason: 'Create Room must push LobbyAction.create',
    );
    expect(pushed.code, isNull);
  });

  testWidgets('Create Room still pushes create when the field holds AB23CD', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();

    await _tapAndAwaitPushedRoute(tester, _createKey);

    final LobbyScreen pushed = _pushedLobbyScreen(tester);
    expect(
      pushed.action,
      LobbyAction.create,
      reason:
          'Create Room must still push LobbyAction.create when the '
          'room-code-field holds a valid code, including once Create is '
          'the outlined control',
    );
    expect(pushed.code, isNull);
  });

  testWidgets('Join Room still pushes join with a valid code AB23CD', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();

    await _tapAndAwaitPushedRoute(tester, _joinKey);

    final LobbyScreen pushed = _pushedLobbyScreen(tester);
    expect(
      pushed.action,
      LobbyAction.join,
      reason: 'Join Room with a valid code must push LobbyAction.join',
    );
    expect(pushed.code, 'AB23CD');
  });
}
