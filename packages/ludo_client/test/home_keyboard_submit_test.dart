// Widget tests for HomeScreen keyboard submit: the name and room-code
// fields use TextInputAction.go, and sending that IME action submits the
// same Create / Join paths as the on-screen buttons.
//
// Create Room and Join Room build a RoomController from
// widget.controllerFactory(). The default factory opens a real WebSocket,
// so every test that submits those actions injects a factory whose connect
// function rejects before constructing a transport. Assertions on the
// pushed LobbyScreen are static constructor arguments (action, code) and
// do not need the controller to reach phase connected.
//
// LobbyScreen's connecting state shows a CircularProgressIndicator, so
// these tests never call pumpAndSettle after a Create or Join submit. A
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

const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-keyboard-submit-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_keyboard_submit_test.dart: this connector must never open a '
        'real or fake transport; RoomController only needs something to '
        'fail against without constructing one',
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

TextField _field(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget);
  return tester.widget<TextField>(find.byKey(key));
}

Future<void> _submitImeGo(WidgetTester tester, Key fieldKey) async {
  await tester.showKeyboard(find.byKey(fieldKey));
  await tester.testTextInput.receiveAction(TextInputAction.go);
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
    'name field TextInputAction.go submits Create when Create is enabled',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        '',
        reason:
            'fixture is broken: an empty room-code-field is required so '
            'Create is the enabled primary action',
      );
      expect(
        tester.widget(find.byKey(_createKey)),
        isA<ElevatedButton>(),
        reason: 'Create must be the enabled primary action',
      );
      expect(
        tester.widget<ElevatedButton>(find.byKey(_createKey)).onPressed,
        isNotNull,
        reason: 'Create must be enabled',
      );

      expect(
        _field(tester, _nameKey).textInputAction,
        TextInputAction.go,
        reason: 'home-name-field must use TextInputAction.go',
      );

      await tester.enterText(find.byKey(_nameKey), 'Priya');
      await tester.pump();
      await _submitImeGo(tester, _nameKey);

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(
        pushed.action,
        LobbyAction.create,
        reason:
            'submitting home-name-field with TextInputAction.go must '
            'trigger Create when Create is enabled',
      );
      expect(pushed.code, isNull);
      expect(pushed.playerName, 'Priya');
    },
  );

  testWidgets(
    'code field TextInputAction.go submits Join when the code is valid',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_codeKey), 'AB23CD');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        'AB23CD',
        reason: 'fixture is broken: Join requires a valid code',
      );
      expect(
        tester.widget(find.byKey(_joinKey)),
        isA<ElevatedButton>(),
        reason: 'Join must be the enabled primary action for a valid code',
      );

      final TextField codeField = _field(tester, _codeKey);
      expect(
        codeField.textInputAction,
        isNot(TextInputAction.join),
        reason:
            'room-code-field must not use TextInputAction.join, which is '
            'iOS-only and not the Android IME action this screen ships',
      );
      expect(
        codeField.textInputAction,
        TextInputAction.go,
        reason: 'room-code-field must use TextInputAction.go',
      );

      await _submitImeGo(tester, _codeKey);

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(
        pushed.action,
        LobbyAction.join,
        reason:
            'submitting room-code-field with TextInputAction.go must '
            'trigger Join when the code is valid',
      );
      expect(pushed.code, 'AB23CD');
    },
  );
}
