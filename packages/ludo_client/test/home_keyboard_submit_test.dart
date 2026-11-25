// Widget tests for HomeScreen keyboard submit. Since order 701 the name
// field's keyboard action no longer creates a room: with no room link
// waiting for a name it opens nothing, and Create goes through the create
// sheet. The room-code field, now in the join sheet's code entry, keeps
// TextInputAction.go, and that IME action submits the same Join path as
// the on-screen button.
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
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_flow.dart';

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
  // A code join waits for the install id (PROTOCOL 32 item 6). Make it once,
  // and give every test a store holding only that id, so a record saved by an
  // earlier test cannot turn the next join into a resume and the join never
  // depends on how the platform-channel failure path resolves under fake async.
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  testWidgets(
    'name field keyboard action opens nothing; Create through its sheet '
    'pushes the create lobby with the typed name',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      // Order 701: home has no room-code-field, so nothing can make Join
      // the primary action on home.
      expect(
        find.byKey(_codeKey, skipOffstage: false),
        findsNothing,
        reason:
            'fixture is broken: no room-code-field may be on home, so '
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

      await tester.enterText(find.byKey(_nameKey), 'Priya');
      await tester.pump();
      // The action the field declares, as the keyboard's action key sends
      // it. Order 701 removed Go-creates from the name field.
      final TextInputAction nameAction =
          _field(tester, _nameKey).textInputAction ?? TextInputAction.done;
      await tester.showKeyboard(find.byKey(_nameKey));
      await tester.testTextInput.receiveAction(nameAction);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        <Object?>[
          find.byType(LobbyScreen).evaluate().length,
          find.byKey(createRoomSheetKey).evaluate().length,
          find.byKey(joinSheetKey).evaluate().length,
        ],
        <Object?>[0, 0, 0],
        reason:
            'submitting home-name-field ($nameAction) with no room link '
            'waiting must open nothing: expected [LobbyScreen, '
            'create-room-sheet, join-sheet] all 0',
      );
      expect(
        _field(tester, _nameKey).controller?.text,
        'Priya',
        reason: 'the name action must leave the typed name in the field',
      );

      await tapCreateRoom(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(
        pushed.action,
        LobbyAction.create,
        reason: 'Create, then the friends-only tile, must push a create lobby',
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

      // Order 701: a name (X226), then the code entry in the join sheet.
      await enterName(tester, 'Player');
      await openCodeEntry(tester);
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
