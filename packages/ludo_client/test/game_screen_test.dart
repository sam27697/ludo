// Conformance tests for lib/src/game_screen.dart's GameScreen, written from
// declaration H (work/ludo/orders/103-PROMPT.md, byte-identical to the copy
// carried by order 102) against no implementation of game_screen.dart the
// author of this file has read. game_screen.dart does not exist on the
// branch this file was written on -- a second worker is building it, blind,
// from the same frozen text, at the same time. This file is not expected to
// compile on this branch; that is the point of the exercise and is recorded
// in the work order.
//
// GameScreen is driven the same way test/net/room_controller_game_test.dart
// and test/lobby_screen_test.dart drive RoomController: a real RoomController
// sits over a FakeTransport (test/net/fake_transport.dart, read-only, not
// edited here) and a small connector double copied from that idiom. Every
// claim about the state the screen is rendering is reached by decoding a
// wire reply into a real RoomSnapshot through RoomController's own request
// path, never by constructing a RoomSnapshot by hand and poking it into the
// widget. Every claim about what the screen sent is checked by decoding
// FakeTransport.sentRaw.
//
// Two things this file could not resolve from declaration H alone without
// opening game_screen.dart, and the choices made instead of opening it:
//
//   1. H4 names no concrete widget type for the four token buttons (H3 does,
//      for the roll button: ElevatedButton). Rather than assume one, every
//      claim about a token button being "enabled" or "disabled" here is
//      proved behaviourally: tap it and look at the wire. A disabled button
//      that is tapped must produce no new message; an enabled one produces
//      exactly one `move`. This is strictly stronger than reading `onPressed`
//      off a guessed type, and it is the same technique H3.7/H3.8/H4.11
//      already ask for.
//   2. The exact frame type that completes a pending `roll()`/`move()`
//      request is not pinned by docs/PROTOCOL.md beyond "carries `re`"
//      (section 1) and RoomController's own doc comment ("The reply is a
//      plain frame ... not parsed as one"). Every resolution below uses the
//      real broadcast type (`rolled` for roll, `moved` for move) with `re`
//      set to the request's id, which is what the wire protocol actually
//      sends back to the acting seat, so nothing here depends on an
//      assumption about the request/reply engine beyond what section 1
//      states outright.
//
// No ambiguity in declaration H itself was found that required leaving a
// case unwritten.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'game-scr-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
  int? sixes,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'sixes': ?sixes,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from the sibling suites' idiom

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- driving a controller to a chosen room state, through real frames ------

/// Opens a controller with `createRoom`, answers it with `seat_assigned` for
/// [mySeat] (unless [sendSeatAssigned] is false) followed by a `room` reply
/// carrying the given snapshot fields, and returns the connected controller
/// and its transport. The snapshot is decoded for real by
/// `RoomSnapshot.fromJson` through `RoomConnection`'s own reply path; nothing
/// here builds a `RoomSnapshot` directly.
Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  bool sendSeatAssigned = true,
  String state = 'PLAYING',
  int players = 4,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  // Standing lesson 8: pumpEventQueue() alone relies on real Timers via
  // Future.delayed, which never fire under the fake-async clock a
  // testWidgets body runs in, and hangs forever with no diagnostic.
  // tester.runAsync() steps outside the fake zone for the duration of the
  // call so the real event loop actually advances, then tester.pump()
  // brings the widget tree's own state back in sync with what that
  // unblocked.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  if (sendSeatAssigned) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
      ),
    );
  }
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        players: players,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport);
}

// --- widget harness, mirroring test/lobby_screen_test.dart's own ----------

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

Key _tokenKey(int i) => Key('game-screen-token-$i');

const Key _boardKey = Key('game-screen-board');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _rollKey = Key('game-screen-roll-button');
const Key _dieKey = Key('game-screen-dice-value');
const Key _loadingKey = Key('game-screen-loading');
const Key _waitingKey = Key('game-screen-waiting');
const Key _winnerKey = Key('game-screen-winner');
const Key _desyncKey = Key('game-screen-desync-banner');

void main() {
  // ==========================================================================
  // H1: the board.
  // ==========================================================================
  group('H1: the board', () {
    testWidgets(
      'H1.1: a playing room of 4 seats renders exactly one LudoBoard keyed '
      'game-screen-board, whose tokens and seatsInPlay match the seats the '
      'server sent, including their list order',
      (tester) async {
        final seats = <Map<String, Object?>>[
          _seatJson(2, name: 'Cara', tokens: const <int>[-1, 0, 14, 57]),
          _seatJson(0, name: 'Sam', tokens: const <int>[3, 3, 3, 3]),
          _seatJson(3, name: 'Dee', tokens: const <int>[-1, -1, -1, -1]),
          _seatJson(1, name: 'Bob', tokens: const <int>[10, 20, 30, 40]),
        ];
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          seats: seats,
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.state,
          RoomState.playing,
          reason: 'fixture is broken',
        );

        await _mount(tester, controller);

        expect(
          find.byKey(_boardKey),
          findsOneWidget,
          reason: 'H1: expected exactly one LudoBoard keyed game-screen-board',
        );
        final board = tester.widget<LudoBoard>(find.byKey(_boardKey));
        expect(
          board.seatsInPlay,
          <int>[2, 0, 3, 1],
          reason:
              'H1: seatsInPlay must be the seat of every entry in '
              'room.seats, in the order they appear; got ${board.seatsInPlay}',
        );
        expect(
          board.tokens,
          <int, List<int>>{
            2: <int>[-1, 0, 14, 57],
            0: <int>[3, 3, 3, 3],
            3: <int>[-1, -1, -1, -1],
            1: <int>[10, 20, 30, 40],
          },
          reason:
              'H1: tokens must be a map from each seat\'s seat to that '
              'seat\'s tokens list, taken straight from room.seats; got '
              '${board.tokens}',
        );
      },
    );

    testWidgets(
      'H1.2: a playing room of 2 seats renders the board with seatsInPlay '
      'holding exactly the 2 real seats and no invented third',
      (tester) async {
        final seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(find.byKey(_boardKey), findsOneWidget);
        final board = tester.widget<LudoBoard>(find.byKey(_boardKey));
        expect(
          board.seatsInPlay,
          <int>[0, 1],
          reason:
              'H1.2: seatsInPlay must hold exactly the 2 real seats and no '
              'invented third; got ${board.seatsInPlay}',
        );
        expect(board.seatsInPlay.length, 2);
      },
    );
  });

  // ==========================================================================
  // H2: the turn banner.
  // ==========================================================================
  group('H2: the turn banner', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets('H2 branch 1: room.turn null shows loc.gameWaitingForTurn', (
      tester,
    ) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        players: 2,
        seats: seats,
        turn: null,
      );
      addTearDown(controller.dispose);
      expect(controller.room!.turn, isNull, reason: 'fixture is broken');

      await _mount(tester, controller);

      final loc = _locOf(tester);
      final banner = tester.widget<Text>(find.byKey(_bannerKey));
      expect(
        banner.data,
        loc.gameWaitingForTurn,
        reason:
            'H2 item 1: a null turn must show loc.gameWaitingForTurn '
            '("${loc.gameWaitingForTurn}"); got "${banner.data}"',
      );
    });

    testWidgets(
      'H2 branch 2: my turn awaiting a roll shows loc.gameYourTurnRoll',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final loc = _locOf(tester);
        final banner = tester.widget<Text>(find.byKey(_bannerKey));
        expect(
          banner.data,
          loc.gameYourTurnRoll,
          reason:
              'H2 item 2: my seat on turn, phase awaitRoll, must show '
              'loc.gameYourTurnRoll ("${loc.gameYourTurnRoll}"); got '
              '"${banner.data}"',
        );
      },
    );

    testWidgets(
      'H2 branch 3: my turn awaiting a move shows loc.gameYourTurnMove',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 1000,
            k: 1,
            value: 4,
            legal: const <int>[0],
          ),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final loc = _locOf(tester);
        final banner = tester.widget<Text>(find.byKey(_bannerKey));
        expect(
          banner.data,
          loc.gameYourTurnMove,
          reason:
              'H2 item 3: my seat on turn, phase awaitMove, must show '
              'loc.gameYourTurnMove ("${loc.gameYourTurnMove}"); got '
              '"${banner.data}"',
        );
      },
    );

    testWidgets('H2 branch 4: another named seat\'s turn shows '
        'loc.gameWaitingForPlayer(name)', (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        players: 2,
        seats: seats,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 1000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      final loc = _locOf(tester);
      final banner = tester.widget<Text>(find.byKey(_bannerKey));
      expect(
        banner.data,
        loc.gameWaitingForPlayer('Bob'),
        reason:
            'H2 item 4: seat 1 (Bob) on turn, not me, must show '
            'loc.gameWaitingForPlayer("Bob") '
            '("${loc.gameWaitingForPlayer('Bob')}"); got "${banner.data}"',
      );
    });

    testWidgets(
      'H2 item 4, absent-seat fallback: room.turn.seat names a seat not in '
      'room.seats -> falls back to loc.gameWaitingForTurn rather than '
      'crashing or inventing a name (declaration D3 / order 094)',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(
            seat: 2, // absent from seats above
            phase: 'await_roll',
            deadlineMs: 1000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.seats.any((s) => s.seat == 2),
          isFalse,
          reason: 'fixture is broken: seat 2 must be absent',
        );

        await _mount(tester, controller);

        final loc = _locOf(tester);
        final banner = tester.widget<Text>(find.byKey(_bannerKey));
        expect(
          banner.data,
          loc.gameWaitingForTurn,
          reason:
              'H2 item 4: turn.seat naming a seat absent from room.seats '
              'must fall back to loc.gameWaitingForTurn '
              '("${loc.gameWaitingForTurn}"), not crash and not invent a '
              'name; got "${banner.data}"',
        );
      },
    );
  });

  // ==========================================================================
  // H3: the Roll button.
  // ==========================================================================
  group('H3: the Roll button', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets(
      'H3.5: enabled (onPressed non-null) exactly when all four conditions '
      'hold: playing, turn present, my seat on turn, phase awaitRoll',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(find.byKey(_rollKey), findsOneWidget);
        final button = tester.widget<ElevatedButton>(find.byKey(_rollKey));
        expect(
          button.onPressed,
          isNotNull,
          reason:
              'H3: with state playing, turn present, my seat on turn and '
              'phase awaitRoll, the roll button must be enabled',
        );
      },
    );

    testWidgets(
      'H3.6a: disabled (present, onPressed null) when it is not my turn',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(
          find.byKey(_rollKey),
          findsOneWidget,
          reason: 'H3: the roll button must be present, not hidden, disabled',
        );
        final button = tester.widget<ElevatedButton>(find.byKey(_rollKey));
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'H3.6b: disabled (present, onPressed null) when my turn is awaiting '
      'a move, not a roll',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 1000,
            k: 1,
            value: 4,
            legal: const <int>[0],
          ),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(find.byKey(_rollKey), findsOneWidget);
        final button = tester.widget<ElevatedButton>(find.byKey(_rollKey));
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'H3.6c: disabled (present, onPressed null) when room.turn is null',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: null,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(find.byKey(_rollKey), findsOneWidget);
        final button = tester.widget<ElevatedButton>(find.byKey(_rollKey));
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'H3.7: pressing the enabled roll button puts exactly one roll request '
      'on the wire with an empty body, and changes nothing locally until a '
      'frame comes back',
      (tester) async {
        final (controller, transport) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_rollKey));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(
          newMessages,
          hasLength(1),
          reason:
              'H3.7: pressing the enabled roll button must put exactly one '
              'new message on the wire; got ${newMessages.length}',
        );
        expect(_typeOf(newMessages.single), 'roll');
        expect(
          _dataOf(newMessages.single),
          <String, Object?>{},
          reason: 'docs/PROTOCOL.md 4: roll\'s body is {}',
        );
        expect(
          controller.room!.turn!.phase,
          TurnPhase.awaitRoll,
          reason:
              'H3.7: the screen must change nothing locally; the phase '
              'must still be awaitRoll until the rolled frame comes back',
        );

        // Resolve the outstanding request so no pending timer survives past
        // the test body (standing lesson 9).
        final String rollId = _idOf(newMessages.single);
        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId,
            data: <String, Object?>{
              'seat': 0,
              'value': 4,
              'legal': <int>[0, 1],
              'deadline_ms': 1000,
              'k': 1,
              'reveal': 'b' * 64,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );

    testWidgets(
      'H3.8: pressing the disabled roll button sends nothing at all',
      (tester) async {
        final (controller, transport) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: null,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final button = tester.widget<ElevatedButton>(find.byKey(_rollKey));
        expect(
          button.onPressed,
          isNull,
          reason: 'fixture is broken: the button must be disabled here',
        );

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_rollKey));
        await tester.pump();

        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'H3.8: pressing a disabled roll button must send nothing; '
              'the wire grew by '
              '${transport.sentRaw.length - sentBefore} message(s)',
        );
      },
    );
  });

  // ==========================================================================
  // H4: the token buttons.
  // ==========================================================================
  group('H4: the token buttons', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets('H4.9: all four token buttons are present while playing', (
      tester,
    ) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        players: 2,
        seats: seats,
        turn: null,
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      for (int i = 0; i < 4; i++) {
        expect(
          find.byKey(_tokenKey(i)),
          findsOneWidget,
          reason:
              'H4: token button $i must be present while the game is '
              'playing, regardless of whether it is enabled',
        );
      }
    });

    testWidgets(
      'H4.10: with legal [1, 3] on my turn awaiting a move, buttons 1 and 3 '
      'are enabled (send a move) and buttons 0 and 2 are disabled (send '
      'nothing), proved behaviourally for each button on its own room',
      (tester) async {
        Future<void> checkButton(int index, {required bool shouldBeLegal}) {
          return () async {
            final (controller, transport) = await _connectPlaying(
              tester,
              mySeat: 0,
              players: 2,
              seats: seats,
              turn: _turnJson(
                seat: 0,
                phase: 'await_move',
                deadlineMs: 1000,
                k: 1,
                value: 4,
                legal: const <int>[1, 3],
              ),
            );
            addTearDown(controller.dispose);

            await _mount(tester, controller);

            final int sentBefore = transport.sentRaw.length;
            await tester.tap(find.byKey(_tokenKey(index)));
            await tester.pump();

            final List<String> newMessages = transport.sentRaw
                .skip(sentBefore)
                .toList();
            if (shouldBeLegal) {
              expect(
                newMessages,
                hasLength(1),
                reason:
                    'H4.10: token button $index is in legal [1, 3] and must '
                    'be enabled, sending exactly one move; got '
                    '${newMessages.length} new message(s)',
              );
              expect(_typeOf(newMessages.single), 'move');
              expect(_dataOf(newMessages.single), <String, Object?>{
                'token': index,
              });
              final String moveId = _idOf(newMessages.single);
              transport.pushText(
                _frame(
                  type: 'moved',
                  re: moveId,
                  data: <String, Object?>{
                    'seat': 0,
                    'token': index,
                    'from': 3,
                    'to': 3 + 4,
                    'captured': <Object?>[],
                    'extra_roll': false,
                    'seq': 2,
                  },
                ),
              );
              await tester.pump();
              await tester.pump();
            } else {
              expect(
                newMessages,
                isEmpty,
                reason:
                    'H4.10: token button $index is not in legal [1, 3] and '
                    'must be disabled, sending nothing; got '
                    '${newMessages.length} new message(s)',
              );
            }
          }();
        }

        await checkButton(0, shouldBeLegal: false);
        await checkButton(1, shouldBeLegal: true);
        await checkButton(2, shouldBeLegal: false);
        await checkButton(3, shouldBeLegal: true);
      },
    );

    testWidgets(
      'H4.11: pressing enabled button 3 puts exactly one move request on '
      'the wire with {"token": 3} -- a non-zero token so a hardcoded zero '
      'cannot pass',
      (tester) async {
        final (controller, transport) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 1000,
            k: 1,
            value: 4,
            legal: const <int>[3],
          ),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_tokenKey(3)));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(newMessages, hasLength(1));
        expect(_typeOf(newMessages.single), 'move');
        expect(_dataOf(newMessages.single), <String, Object?>{'token': 3});

        final String moveId = _idOf(newMessages.single);
        transport.pushText(
          _frame(
            type: 'moved',
            re: moveId,
            data: <String, Object?>{
              'seat': 0,
              'token': 3,
              'from': 10,
              'to': 14,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );

    testWidgets('H4.12: an empty legal list disables all four token buttons', (
      tester,
    ) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        mySeat: 0,
        players: 2,
        seats: seats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 1000,
          k: 1,
          value: 5,
          legal: const <int>[],
        ),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      for (int i = 0; i < 4; i++) {
        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_tokenKey(i)));
        await tester.pump();
        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'H4.12: with an empty legal list, token button $i must be '
              'disabled and send nothing',
        );
      }
    });

    testWidgets(
      'H4.13: the screen does no legality reasoning of its own -- a token '
      'whose board position the rules could not really move (already home, '
      'progress 57) but listed as legal anyway is enabled regardless, '
      'because the server is authoritative',
      (tester) async {
        final contradictorySeats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[57, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (controller, transport) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: contradictorySeats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 1000,
            k: 1,
            value: 3,
            legal: const <int>[0],
          ),
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.seats.first.tokens[0],
          57,
          reason: 'fixture is broken: token 0 must already be home',
        );

        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_tokenKey(0)));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(
          newMessages,
          hasLength(1),
          reason:
              'H4.13: the screen must trust turn.legal and enable button 0 '
              'even though the rules could not really move a token that is '
              'already home; a screen that reimplements legality would '
              'disable this button and send nothing',
        );
        expect(_typeOf(newMessages.single), 'move');
        expect(_dataOf(newMessages.single), <String, Object?>{'token': 0});

        final String moveId = _idOf(newMessages.single);
        transport.pushText(
          _frame(
            type: 'moved',
            re: moveId,
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 57,
              'to': 57,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );
  });

  // ==========================================================================
  // H5: the die.
  // ==========================================================================
  group('H5: the die', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets(
      'H5.14: absent from the tree entirely when turn.value is null',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.turn!.value,
          isNull,
          reason: 'fixture is broken',
        );

        await _mount(tester, controller);

        expect(
          find.byKey(_dieKey),
          findsNothing,
          reason:
              'H5: with turn.value null the die widget must be absent from '
              'the tree entirely, not blank',
        );
      },
    );

    testWidgets(
      'H5.15: present showing loc.gameDieValue(value) when value is not '
      'null, using a value that is neither 1 nor 6',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 1000,
            k: 1,
            value: 4,
            legal: const <int>[0],
          ),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final loc = _locOf(tester);
        expect(find.byKey(_dieKey), findsOneWidget);
        final text = tester.widget<Text>(find.byKey(_dieKey));
        expect(
          text.data,
          loc.gameDieValue(4),
          reason:
              'H5: the die must show loc.gameDieValue(4) '
              '("${loc.gameDieValue(4)}"); got "${text.data}"',
        );
      },
    );
  });

  // ==========================================================================
  // H6: the four states.
  // ==========================================================================
  group('H6: the four states', () {
    testWidgets(
      'H6.16: controller.room null shows only the loading indicator keyed '
      'game-screen-loading, and no board; pumpAndSettle is never used here '
      '(standing lesson 10)',
      (tester) async {
        final _Connector connector = _Connector();
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        addTearDown(controller.dispose);
        expect(controller.room, isNull, reason: 'fixture is broken');

        await _mount(tester, controller);

        expect(find.byKey(_loadingKey), findsOneWidget);
        expect(
          find.byKey(_boardKey),
          findsNothing,
          reason: 'H6 state 1: no board while controller.room is null',
        );
        expect(find.byKey(_waitingKey), findsNothing);
        expect(find.byKey(_bannerKey), findsNothing);
        expect(find.byKey(_rollKey), findsNothing);
        expect(find.byKey(_winnerKey), findsNothing);
      },
    );

    testWidgets('H6.17: a room in LOBBY shows the waiting text and no board', (
      tester,
    ) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        state: 'LOBBY',
        players: 4,
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        turn: null,
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.state,
        RoomState.lobby,
        reason: 'fixture is broken',
      );

      await _mount(tester, controller);

      final loc = _locOf(tester);
      expect(find.byKey(_boardKey), findsNothing);
      expect(find.byKey(_waitingKey), findsOneWidget);
      final text = tester.widget<Text>(find.byKey(_waitingKey));
      expect(text.data, loc.gameWaitingForStart);
    });

    testWidgets(
      'H6.18: a playing room with fewer than 2 seats shows the waiting text '
      'and no board, since LudoBoard asserts 2 to 4 seats',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          state: 'PLAYING',
          players: 4,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
          turn: null,
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.state,
          RoomState.playing,
          reason: 'fixture is broken',
        );
        expect(controller.room!.seats.length, 1, reason: 'fixture is broken');

        await _mount(tester, controller);

        final loc = _locOf(tester);
        expect(
          find.byKey(_boardKey),
          findsNothing,
          reason:
              'H6.18: a playing room with only 1 seat must not build '
              'LudoBoard, which asserts 2 to 4 seats',
        );
        expect(find.byKey(_waitingKey), findsOneWidget);
        final text = tester.widget<Text>(find.byKey(_waitingKey));
        expect(text.data, loc.gameWaitingForStart);
      },
    );
  });

  // ==========================================================================
  // H7: game over.
  // ==========================================================================
  group('H7: game over', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];
    final finishedTurn = _turnJson(
      seat: 0,
      phase: 'finished',
      deadlineMs: 0,
      k: 5,
    );

    testWidgets(
      'H7.19: winner is my seat shows loc.gameOverYouWin; the board is '
      'still shown; roll and all four token buttons are absent, not merely '
      'disabled',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          state: 'FINISHED',
          players: 2,
          seats: seats,
          turn: finishedTurn,
          winner: 0,
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.state,
          RoomState.finished,
          reason: 'fixture is broken',
        );

        await _mount(tester, controller);

        final loc = _locOf(tester);
        expect(find.byKey(_boardKey), findsOneWidget);
        final winnerText = tester.widget<Text>(find.byKey(_winnerKey));
        expect(winnerText.data, loc.gameOverYouWin);
        expect(find.byKey(_rollKey), findsNothing);
        for (int i = 0; i < 4; i++) {
          expect(find.byKey(_tokenKey(i)), findsNothing);
        }
      },
    );

    testWidgets('H7.20: winner is another seat present in room.seats shows '
        'loc.gameOverPlayerWins(name); roll and token buttons absent', (
      tester,
    ) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        state: 'FINISHED',
        players: 2,
        seats: seats,
        turn: finishedTurn,
        winner: 1,
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      final loc = _locOf(tester);
      final winnerText = tester.widget<Text>(find.byKey(_winnerKey));
      expect(winnerText.data, loc.gameOverPlayerWins('Bob'));
      expect(find.byKey(_rollKey), findsNothing);
      for (int i = 0; i < 4; i++) {
        expect(find.byKey(_tokenKey(i)), findsNothing);
      }
    });

    testWidgets('H7.21: winner names a seat absent from room.seats shows '
        'loc.gameOverEnded without crashing; roll and token buttons absent', (
      tester,
    ) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        state: 'FINISHED',
        players: 2,
        seats: seats,
        turn: finishedTurn,
        winner: 3, // absent from seats above
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.seats.any((s) => s.seat == 3),
        isFalse,
        reason: 'fixture is broken: seat 3 must be absent',
      );

      await _mount(tester, controller);

      final loc = _locOf(tester);
      final winnerText = tester.widget<Text>(find.byKey(_winnerKey));
      expect(winnerText.data, loc.gameOverEnded);
      expect(find.byKey(_rollKey), findsNothing);
      for (int i = 0; i < 4; i++) {
        expect(find.byKey(_tokenKey(i)), findsNothing);
      }
    });

    testWidgets(
      'H7.21b: winner null also shows loc.gameOverEnded, per H7\'s own '
      '"or names a seat not in room.seats" wording sharing the branch with '
      'null',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          state: 'FINISHED',
          players: 2,
          seats: seats,
          turn: finishedTurn,
          winner: null,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        final loc = _locOf(tester);
        final winnerText = tester.widget<Text>(find.byKey(_winnerKey));
        expect(winnerText.data, loc.gameOverEnded);
      },
    );

    testWidgets(
      'H7 bullet 1: a finished room with fewer than 2 seats omits the '
      'board, per H1',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          state: 'FINISHED',
          players: 4,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
          turn: finishedTurn,
          winner: 0,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);

        expect(
          find.byKey(_boardKey),
          findsNothing,
          reason:
              'H7: a finished room with only 1 seat must omit the board, '
              'the same as H1 requires for a non-finished room',
        );
        final loc = _locOf(tester);
        final winnerText = tester.widget<Text>(find.byKey(_winnerKey));
        expect(
          winnerText.data,
          loc.gameOverYouWin,
          reason: 'the winner text itself must still render without a board',
        );
      },
    );
  });

  // ==========================================================================
  // H8: the desync banner is additive.
  // ==========================================================================
  group('H8: the desync banner is additive', () {
    testWidgets('H8.23: with hasDesynced true on a playing room, the banner is '
        'present and the board and the buttons are still there', (
      tester,
    ) async {
      final seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ];
      // sendSeatAssigned: false so that _beginResync's own "cached seat
      // token is null" stop condition (D5 step 2, proved in
      // room_controller_game_test.dart) applies: hasDesynced is set, but
      // no resume is sent and no request timer is left outstanding for
      // this test to have to resolve.
      final (controller, transport) = await _connectPlaying(
        tester,
        sendSeatAssigned: false,
        players: 2,
        seats: seats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        seq: 1,
      );
      addTearDown(controller.dispose);
      expect(
        controller.seatToken,
        isNull,
        reason: 'fixture is broken: no seat_assigned was ever sent',
      );

      // A gap: seq 999 against room.seq 1.
      transport.pushText(
        _frame(
          type: 'presence',
          data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 999},
        ),
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(controller.hasDesynced, isTrue, reason: 'fixture is broken');
      expect(
        transport.sentRaw.where((r) => _typeOf(r) == 'resume').toList(),
        isEmpty,
        reason:
            'fixture is broken: no seat token means no resume must have '
            'been attempted, leaving no outstanding request behind',
      );

      await _mount(tester, controller);

      final loc = _locOf(tester);
      expect(
        find.byKey(_desyncKey),
        findsOneWidget,
        reason: 'H8: hasDesynced true must show the desync banner',
      );
      final banner = tester.widget<Text>(find.byKey(_desyncKey));
      expect(banner.data, loc.lobbyDesynced);
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason:
            'H8: the desync banner is additive; the board must still be '
            'showing underneath it',
      );
      expect(
        find.byKey(_rollKey),
        findsOneWidget,
        reason: 'H8: the roll button must still be showing under the banner',
      );
      for (int i = 0; i < 4; i++) {
        expect(
          find.byKey(_tokenKey(i)),
          findsOneWidget,
          reason:
              'H8: token button $i must still be showing under the '
              'banner',
        );
      }
    });
  });

  // ==========================================================================
  // H10: RTL.
  // ==========================================================================
  group('H10: Arabic and RTL', () {
    testWidgets(
      'H10.24: under an Arabic locale the screen builds, the banner and '
      'the buttons are all present, and the ambient Directionality is rtl',
      (tester) async {
        final seats = <Map<String, Object?>>[
          _seatJson(0, name: 'سام'),
          _seatJson(1, name: 'بوب'),
        ];
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller, locale: const Locale('ar'));

        final context = tester.element(find.byType(GameScreen));
        expect(
          Directionality.of(context),
          TextDirection.rtl,
          reason:
              'H10: pumping GameScreen in Locale(ar) must resolve '
              'Directionality to rtl',
        );

        final locAr = lookupAppLocalizations(const Locale('ar'));
        final locEn = lookupAppLocalizations(const Locale('en'));
        expect(
          locAr.gameYourTurnRoll,
          isNot(locEn.gameYourTurnRoll),
          reason:
              'test sanity: app_ar.arb and app_en.arb must give different '
              'strings for gameYourTurnRoll, or this test cannot tell the '
              'two locales apart',
        );

        expect(
          find.byKey(_bannerKey),
          findsOneWidget,
          reason: 'H10: the banner must be present under Locale(ar)',
        );
        final banner = tester.widget<Text>(find.byKey(_bannerKey));
        expect(
          banner.data,
          locAr.gameYourTurnRoll,
          reason:
              'H10: the banner must show the Arabic string under '
              'Locale(ar), not the English one',
        );

        expect(find.byKey(_rollKey), findsOneWidget);
        for (int i = 0; i < 4; i++) {
          expect(find.byKey(_tokenKey(i)), findsOneWidget);
        }
      },
    );
  });
}
