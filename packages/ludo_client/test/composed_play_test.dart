// Order 108: proves that the client's screens *compose*. Every other suite
// in this package mounts one screen alone (HomeScreen, RoomRoute, LobbyScreen
// or GameScreen); none of them mentions both HomeScreen and GameScreen in the
// same file. This file walks the actual route a player takes: HomeScreen ->
// RoomRoute -> LobbyScreen -> RoomRoute (latched) -> GameScreen, driven by
// real taps on the real widgets home_screen.dart:143 and home_screen.dart:182
// build, over a real RoomController sitting on a real RoomConnection sitting
// on FakeTransport (test/net/fake_transport.dart, read-only, not edited
// here). It is not a re-proof of any single screen's own rules; those are
// covered by board_test.dart, lobby_screen_test.dart and game_screen_test.dart
// already. What is new here is the seam: that the controller HomeScreen
// builds is the one RoomRoute keeps handing down, that the code LobbyScreen
// shows is the code the server actually sent, and that nothing is dropped
// crossing from one screen's widget tree into the next.
//
// LudoApp (lib/src/app.dart) has no controllerFactory parameter of its own --
// it always builds HomeScreen with the default, socket-opening factory -- so,
// exactly as test/home_screen_test.dart already does, HomeScreen is pumped
// directly inside the same MaterialApp scaffolding LudoApp assembles (same
// supportedLocales, same localizationsDelegates), with a factory of this
// file's own that hands out a fresh RoomController wired to a fresh
// FakeTransport on every call. That factory is the seam
// lib/src/server_config.dart documents as the one place a test may stand in
// for a real socket; RoomRoute is never constructed directly here, because
// tapping through HomeScreen is the entire point of the order.
//
// Every claim about state a screen renders is reached by decoding a real
// wire frame through RoomController's own path, never by constructing a
// RoomSnapshot by hand. Every claim about what a screen sent is checked by
// decoding FakeTransport.sentRaw, never by trusting that a tap must have
// produced something.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://composed-play-test.invalid/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'composed-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

/// A server push or reply, encoded exactly as Frame.decode expects.
String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot --------------

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required String code,
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  required int seq,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- the one seam this file is allowed to stand in for: server_config.dart's
// --- RoomControllerFactory. Hands out a fresh RoomController wired to a
// --- fresh FakeTransport on every call, remembering both in call order, the
// --- same idiom test/home_screen_test.dart's _LiveControllerFactory uses.

class _RecordingControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }
}

// --- widget harness, mirroring test/home_screen_test.dart's own: HomeScreen
// --- pumped the way LudoApp assembles it, but with a substitutable factory
// --- LudoApp itself has no parameter for. ----------------------------------

Widget _homeScreenApp(RoomControllerFactory controllerFactory) {
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

/// Taps the button at [buttonKey] and pumps just long enough for the pushed
/// MaterialPageRoute's transition to finish and the pushed route's first
/// screen to mount, without ever calling pumpAndSettle.
///
/// Standing lesson 2: LobbyScreen's connecting body holds a
/// CircularProgressIndicator, whose ticker reschedules a frame forever;
/// pumpAndSettle never returns once that is on screen. A fixed pump of
/// 400ms, comfortably past MaterialPageRoute's default 300ms transition, is
/// what test/home_screen_test.dart already proved sufficient for
/// LobbyScreen.initState's synchronous createRoom/joinRoom call to have put
/// its request on the wire by the time this returns.
Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  // ==========================================================================
  // C1: create, share, start, play, win.
  // ==========================================================================
  group('C1: create a room from the home screen, share it, start it, play '
      'to a winner', () {
    testWidgets(
      'HomeScreen -> RoomRoute -> LobbyScreen -> RoomRoute -> GameScreen, '
      'the code shown is the server\'s code, the share link is built from '
      'the real constant, the controller survives the route switch, and '
      'the winner shown is honest',
      (tester) async {
        final factory = _RecordingControllerFactory();
        await tester.pumpWidget(_homeScreenApp(factory.call));
        await tester.pumpAndSettle();

        // A non-default player count (3, not the selector's default of 4):
        // standing lesson 6 says a forwarding claim proved only at the
        // default value proves nothing.
        final homeContext = tester.element(find.byType(Scaffold));
        final homeLoc = AppLocalizations.of(homeContext);
        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('home-players-selector')),
            matching: find.text(homeLoc.homePlayersThree),
          ),
        );
        await tester.pump();

        await tester.enterText(
          find.byKey(const Key('home-name-field')),
          'Priya',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

        expect(
          factory.controllers,
          hasLength(1),
          reason:
              'tapping Create Room must build exactly one controller '
              'through the injected controllerFactory (home_screen.dart:140)',
        );
        final RoomController controller = factory.controllers.single;
        final FakeTransport transport = factory.transports.single;
        addTearDown(controller.dispose);

        final List<String> createMessages = transport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .toList();
        expect(
          createMessages,
          hasLength(1),
          reason:
              'expected LobbyScreen.initState (reached through RoomRoute, '
              'built by home_screen.dart:143) to have sent exactly one '
              'create_room request; sent '
              '${transport.sentRaw.map(_typeOf).toList()}',
        );
        expect(
          _dataOf(createMessages.single),
          <String, Object?>{'name': 'Priya', 'players': 3},
          reason:
              'the name typed on the home screen and the non-default '
              'player count selected there must both reach the wire '
              'unchanged, crossing HomeScreen -> RoomRoute -> LobbyScreen '
              '-> RoomController -> RoomConnection',
        );
        final String createId = _idOf(createMessages.single);

        const String roomCode = 'ZQ2X59';
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-c1-0'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: createId,
            data: _roomJson(
              code: roomCode,
              players: 3,
              hostSeat: 0,
              seats: <Map<String, Object?>>[_seatJson(0, name: 'Priya')],
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(LobbyScreen),
          findsOneWidget,
          reason:
              'a room reply answering create_room must land RoomRoute on '
              'LobbyScreen, not GameScreen, for a freshly created LOBBY room',
        );
        expect(find.byType(GameScreen), findsNothing);

        // The code the lobby displays is the code the server sent, not a
        // code this test invented and RoomRoute happened to have lying
        // around.
        final Text codeText = tester.widget<Text>(
          find.byKey(const Key('lobby-room-code')),
        );
        expect(
          codeText.data,
          roomCode,
          reason:
              'lobby-room-code (lobby_screen.dart) must show the room '
              'code the server\'s room reply carried, "$roomCode"; got '
              '"${codeText.data}"',
        );

        // The shareable link is built from the real kRoomLinkBase constant
        // (lobby_screen.dart:19), not a literal this test retyped.
        final List<String> clipboardCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              clipboardCalls.add(args['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(const Key('lobby-copy-link-button')));
        await tester.pump();
        expect(
          clipboardCalls,
          <String>[kRoomLinkBase + roomCode],
          reason:
              'lobby-copy-link-button must copy kRoomLinkBase + the '
              'server\'s own code ("${kRoomLinkBase + roomCode}"), not a '
              'link this test retyped as a literal; got $clipboardCalls',
        );

        // Two more players join, filling the 3-seat room the home screen
        // asked for.
        transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': 2},
          ),
        );
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 2, 'name': 'Cara', 'seq': 3},
          ),
        );
        await tester.pump();

        expect(
          controller.room!.seats.length,
          3,
          reason:
              'fixture is broken: the room must be full before Start '
              'is tappable',
        );

        final Finder startButton = find.byKey(const Key('lobby-start-button'));
        expect(startButton, findsOneWidget);
        final ElevatedButton startWidget = tester.widget<ElevatedButton>(
          startButton,
        );
        expect(
          startWidget.onPressed,
          isNotNull,
          reason:
              'the host, seat 0, with a full 3-seat room must see an '
              'enabled Start button',
        );

        final int sentBeforeStart = transport.sentRaw.length;
        await tester.tap(startButton);
        await tester.pump();
        final List<String> startMessages = transport.sentRaw
            .skip(sentBeforeStart)
            .where((s) => _typeOf(s) == 'start_game')
            .toList();
        expect(
          startMessages,
          hasLength(1),
          reason:
              'tapping lobby-start-button must send exactly one '
              'start_game request',
        );
        final String startId = _idOf(startMessages.single);

        transport.pushText(
          _frame(
            type: 'game_started',
            re: startId,
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 4,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason:
              'a game_started push answering start_game must switch '
              'RoomRoute from LobbyScreen to GameScreen (room_route.dart)',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'RoomRoute latches once it shows GameScreen and must never '
              'show LobbyScreen again',
        );

        // Prove behaviourally that GameScreen is rendering the very same
        // controller HomeScreen built: tap Roll and look for a real roll
        // message on this same fake transport. A route that lost the
        // controller cannot send on it.
        final int sentBeforeRoll1 = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-roll-button')));
        await tester.pump();
        final List<String> rollMessages1 = transport.sentRaw
            .skip(sentBeforeRoll1)
            .toList();
        expect(
          rollMessages1,
          hasLength(1),
          reason:
              'tapping the roll button on GameScreen must put exactly one '
              'new message on the wire of the same FakeTransport the home '
              'screen\'s controllerFactory built; a route that lost the '
              'controller during the lobby-to-game swap would send nothing '
              'here',
        );
        expect(_typeOf(rollMessages1.single), 'roll');
        final String rollId1 = _idOf(rollMessages1.single);

        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId1,
            data: <String, Object?>{
              'seat': 0,
              'value': 4,
              'legal': <int>[0, 1, 2],
              'deadline_ms': 1000,
              'k': 1,
              'reveal': 'b' * 64,
              'seq': 5,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        final int sentBeforeMove1 = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-token-0')));
        await tester.pump();
        final List<String> moveMessages1 = transport.sentRaw
            .skip(sentBeforeMove1)
            .toList();
        expect(moveMessages1, hasLength(1));
        expect(_typeOf(moveMessages1.single), 'move');
        expect(_dataOf(moveMessages1.single), <String, Object?>{'token': 0});
        final String moveId1 = _idOf(moveMessages1.single);

        transport.pushText(
          _frame(
            type: 'moved',
            re: moveId1,
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': -1,
              'to': 4,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 6,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // A second, short round: this is a seam test, not a rules test, so
        // two rounds is enough to call this an honest game rather than a
        // single lucky roll.
        final int sentBeforeRoll2 = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-roll-button')));
        await tester.pump();
        final List<String> rollMessages2 = transport.sentRaw
            .skip(sentBeforeRoll2)
            .toList();
        expect(rollMessages2, hasLength(1));
        expect(_typeOf(rollMessages2.single), 'roll');
        final String rollId2 = _idOf(rollMessages2.single);

        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId2,
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': <int>[0],
              'deadline_ms': 1000,
              'k': 2,
              'reveal': 'c' * 64,
              'seq': 7,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        final int sentBeforeMove2 = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-token-0')));
        await tester.pump();
        final List<String> moveMessages2 = transport.sentRaw
            .skip(sentBeforeMove2)
            .toList();
        expect(moveMessages2, hasLength(1));
        expect(_typeOf(moveMessages2.single), 'move');
        final String moveId2 = _idOf(moveMessages2.single);

        transport.pushText(
          _frame(
            type: 'moved',
            re: moveId2,
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 4,
              'to': 9,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 8,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // Seat 0 (this client) wins.
        transport.pushText(
          _frame(
            type: 'game_over',
            data: <String, Object?>{
              'winner': 0,
              'verify_url': 'https://composed-play-test.invalid/verify/1',
              'seq': 9,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.state,
          RoomState.finished,
          reason:
              'fixture is broken: game_over must land the room in '
              'RoomState.finished',
        );

        final gameContext = tester.element(find.byType(GameScreen));
        final gameLoc = AppLocalizations.of(gameContext);
        final Text winnerText = tester.widget<Text>(
          find.byKey(const Key('game-screen-winner')),
        );
        expect(
          winnerText.data,
          gameLoc.gameOverYouWin,
          reason:
              'this client is seat 0 and game_over named seat 0 the '
              'winner, so game-screen-winner must show loc.gameOverYouWin '
              '("${gameLoc.gameOverYouWin}"), not a message naming someone '
              'else or claiming a draw; got "${winnerText.data}"',
        );
        expect(
          find.byKey(const Key('game-screen-roll-button')),
          findsNothing,
          reason: 'a finished game must show no roll button, per H7',
        );
        for (int i = 0; i < 4; i++) {
          expect(
            find.byKey(Key('game-screen-token-$i')),
            findsNothing,
            reason: 'a finished game must show no token button $i, per H7',
          );
        }
      },
    );
  });

  // ==========================================================================
  // C2: join by code, and reach the game.
  // ==========================================================================
  group('C2: join a room by code from the home screen, and reach the game', () {
    testWidgets(
      'HomeScreen -> RoomRoute -> LobbyScreen -> RoomRoute -> GameScreen, '
      'the join_room request carries the typed code and name, and the '
      'controller survives the route switch',
      (tester) async {
        final factory = _RecordingControllerFactory();
        await tester.pumpWidget(_homeScreenApp(factory.call));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('home-name-field')),
          'Riri',
        );
        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'K7M2QP',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

        expect(factory.controllers, hasLength(1));
        final RoomController controller = factory.controllers.single;
        final FakeTransport transport = factory.transports.single;
        addTearDown(controller.dispose);

        final List<String> joinMessages = transport.sentRaw
            .where((s) => _typeOf(s) == 'join_room')
            .toList();
        expect(
          joinMessages,
          hasLength(1),
          reason:
              'expected LobbyScreen.initState, reached through RoomRoute '
              '(home_screen.dart:182), to have sent exactly one join_room '
              'request; sent ${transport.sentRaw.map(_typeOf).toList()}',
        );
        expect(
          _dataOf(joinMessages.single),
          <String, Object?>{'code': 'K7M2QP', 'name': 'Riri'},
          reason:
              'the code and name typed on the home screen must both reach '
              'the wire unchanged',
        );
        final String joinId = _idOf(joinMessages.single);

        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 1, 'seat_token': 'tok-c2-1'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: joinId,
            data: _roomJson(
              code: 'K7M2QP',
              players: 2,
              hostSeat: 0,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Riri'),
              ],
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(LobbyScreen), findsOneWidget);
        expect(find.byType(GameScreen), findsNothing);
        final Text codeText = tester.widget<Text>(
          find.byKey(const Key('lobby-room-code')),
        );
        expect(codeText.data, 'K7M2QP');

        // The host starts the game; from this client's own request stream
        // this is a bare push, `re` null.
        transport.pushText(
          _frame(
            type: 'game_started',
            data: <String, Object?>{
              'turn': 1,
              'game_id': 'b' * 16,
              'client_seeds': '1:seed',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason:
              'a game_started push must switch RoomRoute from LobbyScreen '
              'to GameScreen on the join path exactly as it does on the '
              'create path',
        );
        expect(find.byType(LobbyScreen), findsNothing);

        // Prove the controller survived the route switch, the same way C1
        // does: a real roll message on this same transport.
        final int sentBeforeRoll = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-roll-button')));
        await tester.pump();
        final List<String> rollMessages = transport.sentRaw
            .skip(sentBeforeRoll)
            .toList();
        expect(
          rollMessages,
          hasLength(1),
          reason:
              'tapping roll on GameScreen after joining by code must send '
              'exactly one message on the same FakeTransport the home '
              'screen\'s factory built for this join',
        );
        expect(_typeOf(rollMessages.single), 'roll');
        final String rollId = _idOf(rollMessages.single);

        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId,
            data: <String, Object?>{
              'seat': 1,
              'value': 3,
              'legal': <int>[],
              'deadline_ms': 1000,
              'k': 1,
              'reveal': 'd' * 64,
              'seq': 3,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );
  });

  // ==========================================================================
  // C3: game_started arrives while the lobby is on screen, before any tap.
  // ==========================================================================
  group('C3: game_started arriving unprompted switches the route with no '
      'tap, as it does for every non-host player', () {
    testWidgets(
      'a non-host client sitting in LobbyScreen, having tapped nothing, '
      'is moved to GameScreen by a game_started push alone',
      (tester) async {
        final factory = _RecordingControllerFactory();
        await tester.pumpWidget(_homeScreenApp(factory.call));
        await tester.pumpAndSettle();

        await tester.enterText(find.byKey(const Key('home-name-field')), 'Dee');
        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'AB23CD',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

        expect(factory.controllers, hasLength(1));
        final RoomController controller = factory.controllers.single;
        final FakeTransport transport = factory.transports.single;
        addTearDown(controller.dispose);

        final String joinId = _idOf(
          transport.sentRaw.singleWhere((s) => _typeOf(s) == 'join_room'),
        );
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 1, 'seat_token': 'tok-c3-1'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: joinId,
            data: _roomJson(
              code: 'AB23CD',
              players: 2,
              hostSeat: 0,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Dee'),
              ],
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(LobbyScreen),
          findsOneWidget,
          reason:
              'fixture is broken: the client must be sitting in the '
              'lobby before the unprompted game_started arrives',
        );
        expect(
          controller.isHost,
          isFalse,
          reason:
              'fixture is broken: this client is seat 1, not the host '
              'seat 0, so it is a non-host player',
        );
        expect(
          find.byKey(const Key('lobby-start-button')),
          findsNothing,
          reason:
              'fixture is broken: a non-host has no Start button to tap in '
              'the first place, which is exactly why this push must be '
              'able to move the route on its own',
        );

        // The host starts the game. This client never tapped anything.
        transport.pushText(
          _frame(
            type: 'game_started',
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'c' * 16,
              'client_seeds': '0:seed',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason:
              'a game_started push arriving while LobbyScreen is showing, '
              'with no tap of any kind from this client, must still switch '
              'RoomRoute to GameScreen; this is what happens to every '
              'non-host player in a real game',
        );
        expect(find.byType(LobbyScreen), findsNothing);
      },
    );
  });

  // ==========================================================================
  // C4: the latch. A room snapshot that puts room.state back to LOBBY after
  // game_started must neither revive LobbyScreen nor refire the network
  // intention LobbyScreen.initState only ever meant to send once.
  // ==========================================================================
  group('C4: a room push moving room.state back to LOBBY after game_started '
      'must not revive LobbyScreen or resend the join_room/create_room '
      'request', () {
    testWidgets(
      'once RoomRoute has switched to GameScreen, a further room snapshot '
      'carrying state LOBBY leaves GameScreen showing, alone, and puts no '
      'second join_room or create_room frame on the wire',
      (tester) async {
        final factory = _RecordingControllerFactory();
        await tester.pumpWidget(_homeScreenApp(factory.call));
        await tester.pumpAndSettle();

        await tester.enterText(find.byKey(const Key('home-name-field')), 'Zev');
        await tester.enterText(
          find.byKey(const Key('room-code-field')),
          'LT88MN',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

        expect(factory.controllers, hasLength(1));
        final RoomController controller = factory.controllers.single;
        final FakeTransport transport = factory.transports.single;
        addTearDown(controller.dispose);

        final String joinId = _idOf(
          transport.sentRaw.singleWhere((s) => _typeOf(s) == 'join_room'),
        );
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 1, 'seat_token': 'tok-c4-1'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: joinId,
            data: _roomJson(
              code: 'LT88MN',
              players: 2,
              hostSeat: 0,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Zev'),
              ],
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(LobbyScreen),
          findsOneWidget,
          reason:
              'fixture is broken: the client must be sitting in the lobby '
              'before game_started arrives, the same precondition C3 checks',
        );

        // The host starts the game, exactly as in C3.
        transport.pushText(
          _frame(
            type: 'game_started',
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'd' * 16,
              'client_seeds': '0:seed',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason:
              'fixture is broken: game_started must have already switched '
              'RoomRoute to GameScreen before this case can exercise the '
              'latch that keeps it there',
        );
        expect(find.byType(LobbyScreen), findsNothing);

        final int joinCountBeforeLobbyPush = transport.sentRaw
            .where((s) => _typeOf(s) == 'join_room')
            .length;
        final int createCountBeforeLobbyPush = transport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .length;

        // A further snapshot, unprompted (re null, exactly the shape
        // room_controller.dart's _reduceRoom reads for a server-initiated
        // push), puts room.state back to LOBBY. This is the situation the
        // doc comment at room_route.dart:40-56 names directly: nothing
        // about the server protocol forbids a later snapshot from carrying
        // a state other than PLAYING or FINISHED, and RoomRoute must not
        // re-derive its screen choice from it once GameScreen has shown.
        transport.pushText(
          _frame(
            type: 'room',
            data: _roomJson(
              code: 'LT88MN',
              state: 'LOBBY',
              players: 2,
              hostSeat: 0,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Zev'),
              ],
              seq: 3,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.state,
          RoomState.lobby,
          reason:
              'fixture is broken: the pushed snapshot must have actually '
              'moved the controller\'s own room.state back to '
              'RoomState.lobby, or this case is not exercising the '
              'condition it claims to; got ${controller.room!.state}',
        );

        // Symptom 1: the route must still be showing GameScreen, and only
        // GameScreen.
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason:
              'RoomRoute must keep showing GameScreen once it has shown it '
              'once, even after a later room push moves room.state back to '
              'RoomState.lobby (room_route.dart:40-56, the _showGame '
              'latch); a build that re-derives its screen choice from '
              'room.state live would flip back to LobbyScreen here',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'RoomRoute must never remount LobbyScreen once the latch has '
              'tripped, because a fresh LobbyScreen.initState would fire '
              'join_room or create_room a second time',
        );

        // Symptom 2, part one: no second controller or transport exists.
        // Named directly in the order: a remounted LobbyScreen sharing the
        // same widget.controller would not by itself create a second
        // transport, so this alone would not catch the defect; the wire
        // check right below is what does.
        expect(
          factory.transports.length,
          1,
          reason:
              'no tap and no route swap in this case ever calls the '
              'injected controllerFactory a second time; got '
              '${factory.transports.length} transports',
        );
        expect(
          factory.controllers.length,
          1,
          reason:
              'no tap and no route swap in this case ever calls the '
              'injected controllerFactory a second time; got '
              '${factory.controllers.length} controllers',
        );

        // Symptom 2, part two, the one that actually names the defect: a
        // remounted LobbyScreen sharing this same transport would send a
        // second join_room (this case joined, so create_room stays at
        // zero throughout, and is checked anyway because a latch failure
        // reusing the create path is just as much a defect).
        final int joinCountAfterLobbyPush = transport.sentRaw
            .where((s) => _typeOf(s) == 'join_room')
            .length;
        final int createCountAfterLobbyPush = transport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .length;
        expect(
          joinCountAfterLobbyPush,
          joinCountBeforeLobbyPush,
          reason:
              'a room push moving state back to LOBBY must not put a '
              'second join_room on the wire; a remounted LobbyScreen would '
              'do exactly that from its initState. before: '
              '$joinCountBeforeLobbyPush, after: $joinCountAfterLobbyPush',
        );
        expect(
          createCountAfterLobbyPush,
          createCountBeforeLobbyPush,
          reason:
              'a room push moving state back to LOBBY must not put a '
              'create_room on the wire on a route that only ever joined. '
              'before: $createCountBeforeLobbyPush, after: '
              '$createCountAfterLobbyPush',
        );
      },
    );
  });
}
