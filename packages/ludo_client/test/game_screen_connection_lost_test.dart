// Conformance tests for the connection-lost contract work order 138 pins
// against lib/src/game_screen.dart's GameScreen: on this base commit
// (c79fba1) GameScreen.build() branches only on controller.room and
// room.state, never on controller.phase, so a dead socket mid-game leaves
// the board frozen with no error, no reconnect and no in-game leave. A
// second worker is adding that behaviour, blind, from the identical frozen
// contract, in a different worktree; this file is written from that
// contract text alone and has not read the other worker's change.
//
// Cases C1 through C5 are therefore expected to FAIL on this base commit --
// the keys the contract names (game-screen-connection-lost,
// game-screen-reconnect-button, game-screen-appbar-leave,
// game-screen-leave-button) do not exist anywhere in game_screen.dart yet.
// C6 and C7 are controls and are expected to PASS: they exercise the
// healthy, already-working path the contract does not change, so a red C6
// or C7 would mean this file is not reaching the behaviour it claims to
// test, not that the contract is unmet.
//
// GameScreen is driven the same way test/game_screen_test.dart and
// test/lobby_screen_test.dart drive RoomController: a real RoomController
// sits over a FakeTransport (test/net/fake_transport.dart, read-only, not
// edited here) and a small connector double copied from that idiom. Every
// claim about the state the screen is rendering is reached by decoding a
// wire reply into a real RoomSnapshot through RoomController's own request
// path, never by constructing a RoomSnapshot by hand and poking it into the
// widget. Assertions are made on find.byKey and widget types/structure only,
// never on localized strings: the counterpart order adds new l10n keys that
// do not exist on this base commit, and referencing them would not compile.
//
// Ambiguity found while writing this file, reported rather than invented
// around:
//
//   The contract's C7 names "the failed state" for the errorMessage-null
//   case. Reading lib/src/net/room_controller.dart's actual _fail method
//   (the only place that ever sets phase to RoomPhase.failed), errorMessage
//   is unconditionally assigned a String there -- possibly empty, but never
//   null -- on every path that reaches RoomPhase.failed
//   (_failFromRequest / _fail, room_controller.dart lines ~1021-1064). There
//   is no way to drive a real RoomController, behaviourally, into
//   RoomPhase.failed while controller.errorMessage stays null: every road
//   into "failed" sets it. The one road that leaves errorMessage at its
//   initial null and lands in a connection-lost phase is the ordinary
//   socket-death path (RoomConnection.done firing on its own), which the
//   contract's own frozen text puts in RoomPhase.closed, not
//   RoomPhase.failed (see C2). Since the contract's "game-screen-error-
//   message" key is specified once, for whichever of the two connection-
//   lost phases GameScreen is in, C7 below is written against
//   RoomPhase.closed with errorMessage genuinely null -- the only phase in
//   which that combination is reachable by driving the real controller --
//   rather than against a "RoomPhase.failed with errorMessage null"
//   combination that does not exist on the other side of any button this
//   controller exposes. This should be checked against whatever the
//   implementer also concluded.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'conn-lost-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring game_screen_test.dart --------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot, mirroring
// game_screen_test.dart -------------------------------------------------

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
  int players = 2,
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

// --- a TransportConnector test double, copied from the sibling suites'
// idiom -------------------------------------------------------------------

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

// --- driving a controller to a chosen room state, through real frames,
// mirroring game_screen_test.dart's _connectPlaying -----------------------

Future<(RoomController, FakeTransport, _Connector)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  String state = 'PLAYING',
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
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
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        players: players,
        seats: seats,
        turn: turn,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport, connector);
}

// --- widget harness, mirroring game_screen_test.dart's own ----------------

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

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');
const Key _leaveButtonKey = Key('game-screen-leave-button');
const Key _appbarLeaveKey = Key('game-screen-appbar-leave');
const Key _errorMessageKey = Key('game-screen-error-message');
const Key _boardKey = Key('game-screen-board');
const Key _rollKey = Key('game-screen-roll-button');

void main() {
  // A mid-game seats/turn fixture shared by every case that needs a
  // healthy, in-progress game to start from.
  final List<Map<String, Object?>> midGameSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];
  Map<String, Object?> midGameTurn() =>
      _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0);

  // ==========================================================================
  // C1: failed, mid-game.
  // ==========================================================================
  testWidgets(
    'C1: a controller driven to RoomPhase.failed while holding a '
    'RoomState.playing snapshot renders game-screen-connection-lost and '
    'game-screen-reconnect-button; the board and the roll button are absent',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.state,
        RoomState.playing,
        reason: 'fixture is broken: the room must be mid-game',
      );

      // Drive phase to failed via a real, outstanding request answered with
      // an `error` frame -- the same mechanism lobby_screen_test.dart's
      // _resolveFailed uses -- rather than by poking a private field.
      unawaited(controller.roll());
      await tester.pump();
      final String rollId = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: rollId,
          data: <String, Object?>{'code': 'SERVER_GONE', 'message': ''},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason: 'fixture is broken: the error reply must have failed roll()',
      );
      expect(
        controller.room!.state,
        RoomState.playing,
        reason:
            'fixture is broken: the last room snapshot must still say '
            'playing -- C1 tests that phase, not room, decides the body',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_connectionLostKey),
        findsOneWidget,
        reason:
            'C1: RoomPhase.failed while room.state is playing must render '
            'game-screen-connection-lost, whatever the last room snapshot '
            'said',
      );
      expect(
        find.byKey(_reconnectButtonKey),
        findsOneWidget,
        reason: 'C1: the connection-lost state must carry a reconnect button',
      );
      expect(
        find.byKey(_boardKey),
        findsNothing,
        reason: 'C1: the board must be absent once the phase has failed',
      );
      expect(
        find.byKey(_rollKey),
        findsNothing,
        reason: 'C1: the roll button must be absent once the phase has failed',
      );
    },
  );

  // ==========================================================================
  // C2: closed, mid-game.
  // ==========================================================================
  testWidgets(
    'C2: a controller driven to RoomPhase.closed while holding a '
    'RoomState.playing snapshot renders game-screen-connection-lost and '
    'game-screen-reconnect-button; the board and the roll button are absent',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.state,
        RoomState.playing,
        reason: 'fixture is broken: the room must be mid-game',
      );

      // The far end vanishes on its own: RoomConnection.done fires and
      // RoomController's own lifecycle (not a request failure) sets
      // RoomPhase.closed, per room_controller.dart's _openAndAttach.
      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'fixture is broken: the far side vanishing must close the phase',
      );
      expect(
        controller.room!.state,
        RoomState.playing,
        reason:
            'fixture is broken: the last room snapshot must still say '
            'playing -- C2 tests that phase, not room, decides the body',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_connectionLostKey),
        findsOneWidget,
        reason:
            'C2: RoomPhase.closed while room.state is playing must render '
            'game-screen-connection-lost, whatever the last room snapshot '
            'said',
      );
      expect(
        find.byKey(_reconnectButtonKey),
        findsOneWidget,
        reason: 'C2: the connection-lost state must carry a reconnect button',
      );
      expect(
        find.byKey(_boardKey),
        findsNothing,
        reason: 'C2: the board must be absent once the phase has closed',
      );
      expect(
        find.byKey(_rollKey),
        findsNothing,
        reason: 'C2: the roll button must be absent once the phase has closed',
      );
    },
  );

  // ==========================================================================
  // C3: reconnect is wired.
  // ==========================================================================
  testWidgets('C3: tapping game-screen-reconnect-button causes exactly one new '
      'connect() attempt at the transport -- proved behaviourally, not by '
      'reading onPressed off the widget', (tester) async {
    final (controller, transport, connector) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: midGameSeats,
      turn: midGameTurn(),
    );
    addTearDown(controller.dispose);

    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.closed,
      reason: 'fixture is broken: the far side vanishing must close phase',
    );
    expect(
      controller.seatToken,
      isNotNull,
      reason:
          'fixture is broken: a cached seat token is required for '
          'reconnect() to be legal from RoomPhase.closed',
    );

    await _mount(tester, controller);

    final int callsBefore = connector.calls.length;
    final FakeTransport resumeTransport = FakeTransport();
    connector.enqueue(resumeTransport);

    expect(
      find.byKey(_reconnectButtonKey),
      findsOneWidget,
      reason: 'C3: the reconnect button must be present to tap',
    );
    final ElevatedButton button = tester.widget<ElevatedButton>(
      find.byKey(_reconnectButtonKey),
    );
    expect(
      button,
      isA<ElevatedButton>(),
      reason: 'C3: game-screen-reconnect-button must be an ElevatedButton',
    );

    await tester.tap(find.byKey(_reconnectButtonKey));
    await tester.pump();

    expect(
      connector.calls.length,
      callsBefore + 1,
      reason:
          'C3: tapping game-screen-reconnect-button must call '
          'controller.reconnect(), which opens exactly one new transport; '
          'expected ${callsBefore + 1} total connect() calls, got '
          '${connector.calls.length}',
    );

    // Resolve the resume request the tap armed so no outstanding timer
    // survives past the test body (standing lesson 9).
    if (resumeTransport.sentRaw.isNotEmpty) {
      final String resumeId = _idOf(resumeTransport.sentRaw.last);
      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(seats: midGameSeats, turn: midGameTurn(), seq: 1),
        ),
      );
      await tester.pump();
      await tester.pump();
    }
  });

  // ==========================================================================
  // C4: an in-game exit exists.
  // ==========================================================================
  testWidgets(
    'C4: with RoomPhase.connected and a healthy RoomState.playing room, '
    'game-screen-appbar-leave is present in the AppBar actions',
    (tester) async {
      final (controller, _, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken',
      );

      await _mount(tester, controller);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byKey(_appbarLeaveKey),
        ),
        findsOneWidget,
        reason:
            'C4: game-screen-appbar-leave must be present inside the '
            'AppBar, even for a healthy, connected, playing game',
      );
    },
  );

  // ==========================================================================
  // C5: leaving does not hang on a dead server.
  // ==========================================================================
  testWidgets(
    'C5: tapping game-screen-appbar-leave removes GameScreen from the '
    'navigator within one second of pumped time, even when the server '
    'never answers leave_room',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken',
      );

      final int sentBefore = transport.sentRaw.length;

      await tester.pumpWidget(
        _harness(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                key: const Key('previous-route'),
                body: Builder(
                  builder: (innerContext) => ElevatedButton(
                    key: const Key('open-game-screen'),
                    onPressed: () {
                      Navigator.of(innerContext).push(
                        MaterialPageRoute<void>(
                          builder: (_) => GameScreen(controller: controller),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('open-game-screen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'fixture is broken: GameScreen must have been pushed',
      );

      // The server never answers leave_room: no reply is ever pushed on
      // transport for whatever request tapping the leave affordance sends.
      // The transport not growing at all is not asserted here -- the
      // contract only pins that the route goes away promptly, not how it
      // got there.
      expect(
        find.byKey(_appbarLeaveKey),
        findsOneWidget,
        reason: 'C5: game-screen-appbar-leave must be present to tap',
      );
      await tester.tap(find.byKey(_appbarLeaveKey));

      // One second of pumped time, total, to let any pop transition finish,
      // bounded well under the 10-second requestTimeout this must not sit
      // on.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'C5: GameScreen must be gone from the navigator within one '
            'second of pumped time after tapping game-screen-appbar-leave, '
            'even though transport.sentRaw grew by only '
            '${transport.sentRaw.length - sentBefore} message(s) and none '
            'was ever answered',
      );
    },
  );

  // ==========================================================================
  // C6: the control.
  // ==========================================================================
  testWidgets(
    'C6 (control): with RoomPhase.connected and a healthy RoomState.playing '
    'room, game-screen-connection-lost is absent and the board is present',
    (tester) async {
      final (controller, _, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken',
      );
      expect(
        controller.room!.state,
        RoomState.playing,
        reason: 'fixture is broken',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_connectionLostKey),
        findsNothing,
        reason:
            'C6: a healthy, connected, playing game must not render '
            'game-screen-connection-lost',
      );
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'C6: a healthy, connected, playing game must render the board',
      );
    },
  );

  // ==========================================================================
  // C7: the error message is conditional.
  // ==========================================================================
  testWidgets(
    'C7 (control): in a connection-lost state with controller.errorMessage '
    'null, game-screen-error-message is absent (see this file\'s header '
    'comment for why this is driven through RoomPhase.closed rather than '
    'RoomPhase.failed)',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the far side vanishing must close phase',
      );
      expect(
        controller.errorMessage,
        isNull,
        reason:
            'fixture is broken: an ordinary socket death must never set '
            'errorMessage -- only _fail does, and this path never calls it',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_errorMessageKey),
        findsNothing,
        reason:
            'C7: with controller.errorMessage null, game-screen-error-'
            'message must be absent from the tree entirely, not blank',
      );
    },
  );

  // ==========================================================================
  // game-screen-leave-button: the leave affordance the connection-lost state
  // itself carries, distinct from game-screen-appbar-leave. Covered here
  // because the contract names it as one of the four keys the connection-
  // lost state carries, alongside game-screen-connection-lost and
  // game-screen-reconnect-button, which C1/C2 above already check for.
  // ==========================================================================
  testWidgets(
    'the connection-lost state (reached the same way as C2) also carries '
    'game-screen-leave-button, which pops the route promptly even when the '
    'server never answers',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      addTearDown(controller.dispose);

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the far side vanishing must close phase',
      );

      await tester.pumpWidget(
        _harness(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (_) => GameScreen(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(_leaveButtonKey),
        findsOneWidget,
        reason: 'the connection-lost state must carry game-screen-leave-button',
      );
      await tester.tap(find.byKey(_leaveButtonKey));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'tapping game-screen-leave-button must remove GameScreen from '
            'the navigator within one second of pumped time',
      );
    },
  );
}
