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
//
// Order 701: the code field and Join live in the join sheet's code entry
// (opened with a name, X226), and Create is home's primary button whatever
// the sheet holds, so the cases that once read an outlined Create now read
// an elevated one, and Create goes through the create sheet's friends tile.

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

/// C-523 D3: with an empty or short code Join is not in the tree at all
/// (absent, not disabled and not invisible), so the outlined Join of the
/// older rule has nothing to stand on; Create stays the elevated action.
void _expectCreateElevatedJoinAbsent(WidgetTester tester) {
  expect(
    _keyedButton(tester, _createKey),
    isA<ElevatedButton>(),
    reason:
        'create-room-button must be an ElevatedButton; found '
        '${_keyedButton(tester, _createKey).runtimeType}',
  );
  expect(
    find.byKey(_joinKey, skipOffstage: false),
    findsNothing,
    reason:
        'join-room-button must be absent while the code is shorter than '
        'the full length (C-523 D3)',
  );
}

/// Order 701: Join in the code entry is elevated for a code; Create on home
/// is no longer demoted by what the code entry holds.
void _expectJoinElevatedCreateStaysElevated(WidgetTester tester) {
  expect(
    _keyedButton(tester, _joinKey),
    isA<ElevatedButton>(),
    reason:
        'join-room-button must be an ElevatedButton; found '
        '${_keyedButton(tester, _joinKey).runtimeType}',
  );
  expect(
    _keyedButton(tester, _createKey),
    isA<ElevatedButton>(),
    reason:
        'create-room-button stays an ElevatedButton on home (order 701); '
        'found ${_keyedButton(tester, _createKey).runtimeType}',
  );
}

/// Order 701: a name, then the join sheet's code entry.
Future<void> _openEntry(WidgetTester tester) async {
  await enterName(tester, 'Player');
  await openCodeEntry(tester);
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

  testWidgets('empty code field uses elevated Create and no Join', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();
    await _openEntry(tester);

    expect(find.byKey(_codeKey), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(_codeKey)).controller?.text, '');

    _expectCreateElevatedJoinAbsent(tester);
  });

  testWidgets('valid code AB23CD uses elevated Join; Create stays elevated', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await _openEntry(tester);
    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
      'AB23CD',
    );
    _expectJoinElevatedCreateStaysElevated(tester);
  });

  testWidgets(
    'valid dashed code ab2-3cd uses elevated Join; Create stays elevated',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await _openEntry(tester);
      await tester.enterText(find.byKey(_codeKey), 'ab2-3cd');
      await tester.pump();

      _expectJoinElevatedCreateStaysElevated(tester);
    },
  );

  testWidgets(
    'short code ABC is a code: elevated Join; Create stays elevated',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await _openEntry(tester);
      await tester.enterText(find.byKey(_codeKey), 'ABC');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        'ABC',
      );
      _expectJoinElevatedCreateStaysElevated(tester);
    },
  );

  testWidgets('invalid code AB02#C uses elevated Create and outlined Join', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await _openEntry(tester);
    await tester.enterText(find.byKey(_codeKey), 'AB02#C');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
      'AB02#C',
    );
    _expectCreateElevatedJoinOutlined(tester);
  });

  testWidgets('Create Room still pushes create with an empty code field', (
    tester,
  ) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pumpAndSettle();

    await enterName(tester, 'Player');
    await tapCreateRoom(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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

    await _openEntry(tester);
    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();
    // Order 701: Create is on home under the join sheet; back out of the
    // sheet with the code still typed, then create.
    await backOutOfSheet(tester, joinSheetKey);
    await tapCreateRoom(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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

    await _openEntry(tester);
    await tester.enterText(find.byKey(_codeKey), 'AB23CD');
    await tester.pump();
    // Join's entry is a 200 ms AnimatedSize at most (C-523 D3).
    await tester.pump(const Duration(milliseconds: 250));

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
