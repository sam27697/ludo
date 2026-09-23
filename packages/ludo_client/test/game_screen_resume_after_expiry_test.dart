// Conformance tests for work order 158: what a returning player's screen
// shows after the server's expiry sweep has already played that seat's turn
// while the socket was dead. Run 49 proved this at the server wire; nothing
// before this file measured it through GameScreen and a real
// RoomController. Written from work/ludo/orders/158-client-resume-after-
// expiry-render.md alone, on base commit dd310e6.
//
// This is a measurement order, not a fix order. R6 guards against a
// regression in lib/src/game_screen.dart's _syncCountdown: a resumed turn
// that shares the pre-drop turn's exact deadline_ms but carries a different
// turn.k must still reset the on-screen countdown to that turn's own full
// segment, not carry the dead-socket seconds forward. (The master once
// measured a defect here -- a countdown memo that compared only (seat,
// deadlineMs) and never turn.k, leaving the old countdown running across the
// resume -- and that defect has since been fixed.) Every number this file's
// R6 case asserts is derived and explained in that case's own comment,
// checked against the actual reducer code in lib/src/net/room_controller.dart
// and lib/src/game_screen.dart, not guessed.
//
// GameScreen is driven the same way test/game_screen_connection_lost_test.dart
// and test/game_screen_countdown_test.dart drive RoomController: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// idiom. Every claim about the state the screen is rendering is reached by
// decoding a wire reply into a real RoomSnapshot through RoomController's own
// request path, never by constructing a RoomSnapshot by hand and poking it
// into the widget. Assertions are made on find.byKey, widget types/fields and
// rendered numbers only, never on localized strings.
//
// Ambiguities found while writing this file, reported rather than invented
// around:
//
//   1. The order's scenario step 2 asks to "record what the countdown is
//      doing at this moment" (right after the far end vanishes) as part of
//      the measurement, but does not give that observation its own R-letter
//      the way R1 through R7 each get one. This file folds that observation
//      into dropAndReconnect's shared setup (a light assertion that
//      game-screen-turn-countdown is absent while the connection-lost body
//      is showing, with a reason noting that absence from the tree does not
//      by itself prove the countdown's own Timer has stopped) and leaves the
//      deeper measurement of that Timer's actual behaviour to R6, which is
//      the only case whose outcome depends on it. This was a judgement call,
//      not a finding, and is reported as one.
//   2. The scenario text gives freedom to choose the exact stated deadline_ms
//      and turn.k values ("a stated deadline_ms", "a stated turn.k"); the
//      literal integers below (42000ms / k: 2 pre-drop, and so on) are this
//      file's own fixture choices, picked so R6's arithmetic is exact and
//      auditable, not values pinned by the order itself.

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

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'resume-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites ----------------------

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
// the sibling suites ---------------------------------------------------

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
// mirroring the sibling suites' _connectPlaying ----------------------------

Future<(RoomController, FakeTransport, _Connector)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  int players = 4,
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
  // Standing lesson: pumpEventQueue() alone relies on real Timers via
  // Future.delayed, which never fire under the fake-async clock a
  // testWidgets body runs in, and hangs forever with no diagnostic.
  // tester.runAsync() steps outside the fake zone for the duration of the
  // call so the real event loop actually advances, then tester.pump() brings
  // the widget tree's own state back in sync with what that unblocked.
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
      data: _roomJson(players: players, seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport, connector);
}

// --- widget harness, mirroring the sibling suites' own ---------------------

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
const Key _boardKey = Key('game-screen-board');
const Key _rollKey = Key('game-screen-roll-button');
const Key _countdownKey = Key('game-screen-turn-countdown');

/// Reads whatever whole-second number the widget at [key] is showing,
/// without assuming its exact template, copied from
/// test/game_screen_countdown_test.dart's own helper of the same name so
/// this file reads the countdown exactly the way that file's own proof of
/// the countdown contract does.
int _wholeSecondsShown(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  final Text text;
  if (widget is Text) {
    text = widget;
  } else {
    final Finder descendant = find.descendant(
      of: finder,
      matching: find.byType(Text),
    );
    expect(
      descendant,
      findsAtLeastNWidgets(1),
      reason:
          'the widget keyed $key is a ${widget.runtimeType}, not a '
          'Text, and carries no Text descendant to read a rendered number '
          'from',
    );
    text = tester.widget<Text>(descendant.first);
  }
  final String rendered = text.data ?? '';
  final RegExpMatch? match = RegExp(r'-?\d+').firstMatch(rendered);
  if (match == null) {
    fail(
      'the widget keyed $key rendered "$rendered", which contains '
      'no whole number to read a countdown value from',
    );
  }
  return int.parse(match.group(0)!);
}

void main() {
  // A four-seat room, mid-game, every seat's tokens all in the yard to
  // start. Seat 0 is the local player throughout this file.
  final List<Map<String, Object?>> fourSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
    _seatJson(2, name: 'Cid'),
    _seatJson(3, name: 'Deb'),
  ];

  // The scenario's step 1: seat 0 is on turn, awaiting a roll, with a
  // stated deadline_ms and a stated turn.k, seat 0's tokens all in the
  // yard (fourSeats above already gives every seat all-yard tokens).
  Map<String, Object?> preDropTurn() =>
      _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 42000, k: 2);

  // The scenario's step 5 world for R1, R2, R3, R4 and R5: the server's
  // expiry sweep played seat 0's pre-drop turn (seat 0's token 0 is now out
  // of the yard, at square 10) and the turn has moved on to seat 1, with a
  // fresh full 45-second segment and a higher turn.k and seq.
  List<Map<String, Object?>> postSweepSeats() => <Map<String, Object?>>[
    _seatJson(0, name: 'Sam', tokens: const <int>[10, -1, -1, -1]),
    _seatJson(1, name: 'Bob'),
    _seatJson(2, name: 'Cid'),
    _seatJson(3, name: 'Deb'),
  ];
  Map<String, Object?> postSweepTurn() =>
      _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 5);

  /// Reaches PLAYING with [initialTurn], mounts GameScreen, drops the far
  /// end, lets [disconnectWaitSeconds] of fake time pass with the socket
  /// dead (the scenario's step 3: nothing is pushed on the dead socket
  /// during this wait; the server's expiry sweep is modelled purely by what
  /// the eventual resume reply carries, never by anything pushed here), then
  /// taps game-screen-reconnect-button and drives the connect+request chain
  /// through to the point where a resume request has actually reached
  /// [resumeTransport].sentRaw. The caller answers that request itself, on
  /// whichever payload the case under test needs.
  ///
  /// Also records the scenario's step 2 observation, ambiguity 1 in this
  /// file's header: game-screen-turn-countdown is absent while the
  /// connection-lost body is showing. That absence is expected from R1's
  /// own claim about the connection-lost body replacing the playing body
  /// outright; it is not, by itself, proof that the countdown's Timer has
  /// stopped ticking underneath. R6 measures that Timer's actual behaviour.
  Future<(RoomController, FakeTransport, FakeTransport)> dropAndReconnect(
    WidgetTester tester, {
    required Map<String, Object?> initialTurn,
    required List<Map<String, Object?>> seats,
    int disconnectWaitSeconds = 5,
  }) async {
    final (controller, transport, connector) = await _connectPlaying(
      tester,
      mySeat: 0,
      players: 4,
      seats: seats,
      turn: initialTurn,
    );
    await _mount(tester, controller);
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture is broken: the room must start out connected',
    );

    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.closed,
      reason: 'fixture is broken: the far side vanishing must close phase',
    );
    expect(
      find.byKey(_connectionLostKey),
      findsOneWidget,
      reason:
          'fixture is broken: the connection-lost body must be showing '
          'before game-screen-reconnect-button can be tapped',
    );
    expect(
      find.byKey(_countdownKey),
      findsNothing,
      reason:
          'scenario step 2 observation: game-screen-turn-countdown must be '
          'absent while the connection-lost body is showing -- see this '
          "file's header ambiguity 1 for why this is recorded here rather "
          'than under its own R-letter, and R6 for what this absence does '
          'and does not prove about the countdown Timer underneath',
    );

    if (disconnectWaitSeconds > 0) {
      await tester.pump(Duration(seconds: disconnectWaitSeconds));
    }

    final FakeTransport resumeTransport = FakeTransport();
    connector.enqueue(resumeTransport);
    expect(
      find.byKey(_reconnectButtonKey),
      findsOneWidget,
      reason: 'fixture is broken: the reconnect button must be present to tap',
    );
    await tester.tap(find.byKey(_reconnectButtonKey));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();

    expect(
      resumeTransport.sentRaw,
      isNotEmpty,
      reason:
          'fixture is broken: tapping game-screen-reconnect-button must '
          'have sent a request on the newly opened transport by now',
    );

    return (controller, transport, resumeTransport);
  }

  /// Answers the outstanding resume request on [resumeTransport] with a
  /// `room` snapshot built from [roomJson], and pumps twice: the pushed
  /// frame is delivered to RoomController through FakeTransport's
  /// StreamController, which schedules delivery as a microtask rather than
  /// resolving inline, and the first pump only flushes that microtask; the
  /// second draws the frame the resulting setState scheduled. The sibling
  /// suites' own push-then-pump-twice sites use the identical idiom for the
  /// identical reason.
  Future<void> answerResume(
    WidgetTester tester,
    FakeTransport resumeTransport,
    Map<String, Object?> roomJson,
  ) async {
    final String id = _idOf(resumeTransport.sentRaw.last);
    resumeTransport.pushText(_frame(type: 'room', re: id, data: roomJson));
    await tester.pump();
    await tester.pump();
  }

  /// The shared post-sweep world R1, R2 and R3 all measure: drop, reconnect,
  /// and answer resume with postSweepSeats()/postSweepTurn().
  Future<RoomController> reachPostSweep(WidgetTester tester) async {
    final (controller, _, resumeTransport) = await dropAndReconnect(
      tester,
      initialTurn: preDropTurn(),
      seats: fourSeats,
    );
    await answerResume(
      tester,
      resumeTransport,
      _roomJson(seats: postSweepSeats(), turn: postSweepTurn(), seq: 4),
    );
    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'fixture is broken: the resume reply must land the controller '
          'back in RoomPhase.connected',
    );
    expect(
      controller.room!.state,
      RoomState.playing,
      reason: 'fixture is broken: the resumed room must still be PLAYING',
    );
    return controller;
  }

  // ==========================================================================
  // R1: the connection-lost body is gone and the playing body is back.
  // ==========================================================================
  testWidgets(
    'R1: after a resume answered post-sweep, game-screen-connection-lost '
    'and game-screen-reconnect-button are both absent and the board is '
    'present',
    (tester) async {
      final RoomController controller = await reachPostSweep(tester);
      addTearDown(controller.dispose);

      expect(
        find.byKey(_connectionLostKey),
        findsNothing,
        reason:
            'R1: once the resume reply has landed and the phase is '
            'connected again, game-screen-connection-lost must be gone; '
            'finding it would mean the returning player is still being '
            'shown the connection-lost screen over a healthy socket',
      );
      expect(
        find.byKey(_reconnectButtonKey),
        findsNothing,
        reason:
            'R1: with the connection-lost body gone, its reconnect button '
            'must be gone with it',
      );
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason:
            'R1: the board must be back; a returning player with no board '
            'has nothing to play on',
      );
    },
  );

  // ==========================================================================
  // R2: the board renders seat 0's swept token at the resumed square.
  // ==========================================================================
  testWidgets(
    'R2: the board renders seat 0\'s token 0 at the square the resume '
    'snapshot put it on (progress 10), not in the yard, proved against '
    'board.dart\'s own Semantics(identifier:) contract from cellFor, not '
    'against a pixel position',
    (tester) async {
      final RoomController controller = await reachPostSweep(tester);
      addTearDown(controller.dispose);
      expect(
        controller.room!.seats
            .firstWhere((SeatState s) => s.seat == 0)
            .tokens[0],
        10,
        reason:
            'fixture is broken: the resumed snapshot must carry seat 0 '
            'token 0 at progress 10',
      );

      final SemanticsHandle handle = tester.ensureSemantics();
      final BoardCell expectedCell = cellFor(
        seat: 0,
        progress: 10,
        tokenIndex: 0,
      );
      final String expectedId = 'cell-${expectedCell.col}-${expectedCell.row}';
      expect(
        find.descendant(
          of: find.byKey(const Key('token-0-0')),
          matching: find.bySemanticsIdentifier(expectedId),
          matchRoot: true,
        ),
        findsOneWidget,
        reason:
            'R2: token-0-0 must carry Semantics(identifier: "$expectedId") '
            'per cellFor(seat: 0, progress: 10, tokenIndex: 0) -- the '
            'square the resume snapshot actually put this token on. Not '
            'finding it here means the returning player\'s board is not '
            'showing the swept token where the server says it landed '
            '(reproduce with: mySeat 0, four seats, pre-drop turn seat 0 '
            'deadline_ms 42000 k 2, endFromFarSide, reconnect, resume '
            'reply carrying seat 0 tokens [10, -1, -1, -1])',
      );
      handle.dispose();
    },
  );

  // ==========================================================================
  // R3: it is seat 1's turn, so the roll affordance is not offered.
  // ==========================================================================
  testWidgets('R3: with the resumed turn on seat 1, game-screen-roll-button is '
      'present but disabled (onPressed null), not offered as pressable and '
      'not hidden outright', (tester) async {
    final RoomController controller = await reachPostSweep(tester);
    addTearDown(controller.dispose);
    expect(
      controller.room!.turn!.seat,
      1,
      reason: 'fixture is broken: the resumed turn must belong to seat 1',
    );
    expect(
      controller.seat,
      0,
      reason: 'fixture is broken: the local player must still be seat 0',
    );

    expect(
      find.byKey(_rollKey),
      findsOneWidget,
      reason:
          'R3: game-screen-roll-button must be present (this screen '
          'always builds it, disabled rather than hidden, per '
          'lib/src/game_screen.dart\'s _playingBody), not absent',
    );
    final ElevatedButton button = tester.widget<ElevatedButton>(
      find.byKey(_rollKey),
    );
    expect(
      button.onPressed,
      isNull,
      reason:
          'R3: with the resumed turn on seat 1, not the local player\'s '
          'own seat 0, game-screen-roll-button must be disabled '
          '(onPressed null); a non-null onPressed here would let the '
          'returning player send a roll out of turn',
    );
  });

  // ==========================================================================
  // R4: reconnect opens a second transport and sends resume.
  // ==========================================================================
  testWidgets(
    'R4: tapping game-screen-reconnect-button sends exactly one resume '
    'request on the new transport, carrying the cached room code and the '
    'cached seat token from the original seat_assigned',
    (tester) async {
      final (controller, _, resumeTransport) = await dropAndReconnect(
        tester,
        initialTurn: preDropTurn(),
        seats: fourSeats,
      );
      addTearDown(controller.dispose);

      expect(
        resumeTransport.sentRaw.length,
        1,
        reason:
            'R4: exactly one request must have been sent on the newly '
            'opened transport by the time this case checks it; got '
            '${resumeTransport.sentRaw.length}',
      );
      final Map<String, Object?> sent = _decode(resumeTransport.sentRaw.single);
      expect(
        sent['t'],
        'resume',
        reason:
            'R4: the request sent on the new transport after tapping '
            'game-screen-reconnect-button must be a resume request; got '
            't=${sent['t']}',
      );
      final Map<String, Object?> data = sent['d']! as Map<String, Object?>;
      expect(
        data['code'],
        'K7M2QP',
        reason: 'R4: resume must carry the cached room code',
      );
      expect(
        data['seat_token'],
        'tok-0',
        reason:
            'R4: resume must carry the cached seat token from the '
            'original seat_assigned (tok-0)',
      );

      // Resolve the outstanding request so no pending requestTimeout Timer
      // survives past this test body.
      await answerResume(
        tester,
        resumeTransport,
        _roomJson(seats: postSweepSeats(), turn: postSweepTurn(), seq: 4),
      );
    },
  );

  // ==========================================================================
  // R5: controller.seat survives a resume that carries no seat_assigned.
  // ==========================================================================
  testWidgets(
    'R5: controller.seat is still 0 after a resume completes, even though '
    'the server sends no seat_assigned on resume and the new '
    'RoomConnection._seat is therefore null',
    (tester) async {
      final (controller, _, resumeTransport) = await dropAndReconnect(
        tester,
        initialTurn: preDropTurn(),
        seats: fourSeats,
      );
      addTearDown(controller.dispose);
      expect(
        controller.seat,
        0,
        reason:
            'fixture is broken: going into the resume, controller.seat '
            'must still read 0 from the original seat_assigned',
      );

      await answerResume(
        tester,
        resumeTransport,
        _roomJson(seats: postSweepSeats(), turn: postSweepTurn(), seq: 4),
      );

      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken: the resume reply must land connected',
      );
      expect(
        controller.seat,
        0,
        reason:
            'R5: RoomConnection._seat is null for a connection that only '
            'ever resumes, because the server sends no seat_assigned on '
            'resume; RoomController._syncSeatCache is documented to '
            'overwrite only on a non-null value. This asserts the cached '
            'seat actually survives rather than trusting the comment that '
            'says it does; a defect here would show controller.seat as '
            'null once this resume completes',
      );
    },
  );

  // ==========================================================================
  // R6: the turn comes back around to seat 0 with the same integer
  // deadline_ms as the pre-drop turn but a different turn.k. This guards
  // against a regression the master once measured here: a countdown memo
  // that ignored turn.k could mistake this resumed turn for the pre-drop
  // one already on screen and leave a stale countdown running across the
  // resume.
  // ==========================================================================
  //
  // lib/src/game_screen.dart's _syncCountdown restarts the on-screen
  // countdown whenever the resumed turn is a different turn from the one it
  // last synced against, and two turns that share seat and deadline_ms but
  // carry different turn.k values are still different turns. Here the
  // resumed turn is (seat: 0, deadlineMs: 42000, k: 7) against the pre-drop
  // turn's (seat: 0, deadlineMs: 42000, k: 2); the difference in k is what
  // marks this as a fresh turn (a capture bonus or a six granting seat 0 a
  // fresh turn after the sweep played its way around the table), not a
  // re-delivery of the one already ticking down. Because the restart guard
  // compares turn.k, the countdown is reset to the resumed turn's own full
  // segment: the 15 seconds spent with the socket dead are not carried
  // forward into that reset.
  //
  // The arithmetic this case's exact-value assertions depend on: the
  // countdown starts at ceil(42000 / 1000) = 42 (confirmed by this case's
  // own first assertion, and matching test/game_screen_countdown_test.dart
  // P1's identical finding for a fresh deadline). 15 seconds of fake time
  // are then pumped while the phase is closed (modelling the scenario's
  // step 3, "time passes"), but because the resumed turn's different
  // turn.k resets the countdown rather than carrying that elapsed time
  // forward, none of those 15 seconds show up in what the resumed countdown
  // reads. Tapping reconnect and running the connect+request chain to
  // actually send the resume request (via tester.runAsync(() =>
  // pumpEventQueue())) drains only microtasks, not fake seconds -- this is
  // the same idiom _connectPlaying already uses for the identical step, and
  // test/game_screen_countdown_test.dart's P1 confirms empirically that
  // idiom does not itself perturb the countdown -- so no further ticks are
  // spent getting the resume request sent. The rendered value right after
  // the resume lands must therefore be a fresh 42, the resumed turn's own
  // full segment, not 27 (42 - 15): a reading of 27 here would mean the 15
  // dead-socket seconds were carried forward instead of reset, which is
  // exactly the regression this case exists to catch. A further 3 seconds
  // of fake time pumped afterwards, with nothing else touching the
  // controller, then distinguishes a Timer genuinely restarted at the
  // resume (42 - 3 = 39) from one that merely never stopped (27 - 3 = 24,
  // the defective reading this case used to assert before the fix).
  testWidgets(
    'R6: a resumed turn back on seat 0 sharing the pre-drop turn\'s exact '
    'integer deadline_ms but carrying a different turn.k -- measured, not '
    'assumed; see this case\'s own header comment for the arithmetic',
    (tester) async {
      final (controller, transport, connector) = await _connectPlaying(
        tester,
        mySeat: 0,
        players: 4,
        seats: fourSeats,
        turn: preDropTurn(),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      expect(
        _wholeSecondsShown(tester, _countdownKey),
        42,
        reason:
            'fixture is broken: deadline_ms 42000 must render as 42 whole '
            'seconds with no fake time advanced yet',
      );

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the far side vanishing must close phase',
      );
      expect(
        find.byKey(_countdownKey),
        findsNothing,
        reason:
            'fixture is broken: the connection-lost body must be showing, '
            'per R1, so game-screen-turn-countdown must be absent from '
            'the tree here -- its absence from the tree is not itself '
            'proof its Timer has stopped, which is what the rest of this '
            'case measures',
      );

      // 15 seconds of fake time pass with the socket dead. Nothing is
      // pushed on the dead socket; the expiry sweep is modelled purely by
      // what the resume reply below carries.
      await tester.pump(const Duration(seconds: 15));

      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);
      expect(
        find.byKey(_reconnectButtonKey),
        findsOneWidget,
        reason:
            'fixture is broken: the reconnect button must be present to tap',
      );
      await tester.tap(find.byKey(_reconnectButtonKey));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: reconnect must have sent resume by now',
      );

      final String id = _idOf(resumeTransport.sentRaw.last);
      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Sam', tokens: const <int>[10, -1, -1, -1]),
              _seatJson(1, name: 'Bob'),
              _seatJson(2, name: 'Cid'),
              _seatJson(3, name: 'Deb'),
            ],
            turn: _turnJson(
              seat: 0,
              phase: 'await_roll',
              deadlineMs: 42000,
              k: 7,
            ),
            seq: 4,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture is broken: the resume reply must land the controller '
            'back in RoomPhase.connected',
      );
      expect(
        controller.room!.turn!.seat,
        0,
        reason: 'fixture is broken: the resumed turn must be back on seat 0',
      );
      expect(
        controller.room!.turn!.k,
        7,
        reason:
            'fixture is broken: the resumed turn must carry turn.k 7, '
            'different from the pre-drop turn\'s k 2',
      );
      expect(
        controller.room!.turn!.deadlineMs,
        42000,
        reason:
            'fixture is broken: the resumed turn must carry the same '
            'integer deadline_ms (42000) as the pre-drop turn',
      );
      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'fixture is broken: with the phase connected again and the '
            'room PLAYING, game-screen-turn-countdown must be present',
      );

      final int shownRightAfterResume = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownRightAfterResume,
        42,
        reason:
            'R6: immediately after this resume lands, game-screen-turn-'
            'countdown reads $shownRightAfterResume; this case\'s own '
            'header comment expects and explains exactly 42, the resumed '
            'turn\'s own full segment (ceil(42000 / 1000)), because '
            'turn.k has moved from 2 to 7 and the countdown\'s restart '
            'guard treats that as a different turn, resetting the '
            'countdown rather than carrying forward the 15 seconds of '
            'fake time pumped while the socket was dead. A reading of 27 '
            'here would mean those 15 dead-socket seconds were carried '
            'forward instead -- the regression this case guards against. '
            'Reproduce with: mySeat 0, four seats, pre-drop turn (seat 0, '
            'await_roll, deadline_ms 42000, k 2), endFromFarSide, pump 15s '
            'while closed, tap reconnect, answer resume with turn (seat 0, '
            'await_roll, deadline_ms 42000, k 7)',
      );

      // Distinguishes a Timer genuinely restarted at the resume from any
      // other explanation for 42: a further 3 seconds of fake time, with
      // nothing else touching the controller, takes a freshly restarted
      // Timer from 42 to 39. A Timer that had merely never stopped from
      // before the resume would instead still read 27 minus these same 3
      // seconds, 24, not 39.
      await tester.pump(const Duration(seconds: 3));
      final int shownAfterFurtherAdvance = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownAfterFurtherAdvance,
        39,
        reason:
            'R6: 3 further seconds of fake time after the resume landed '
            'must read $shownAfterFurtherAdvance. The header comment '
            'above expects and explains exactly 39: a fresh 42 (the '
            'resumed turn\'s own full segment) minus these same 3 '
            'seconds, proving the countdown\'s Timer was genuinely '
            'restarted at the resume rather than merely left running. A '
            'reading of 24 here would mean the pre-drop Timer was still '
            'running, never reset (27 - 3); a reading of 27, unchanged, '
            'would mean the Timer had somehow stopped rather than been '
            'reset. Neither is what a correct reset produces; 39 is, '
            'which is why this case asserts 39 and not a looser bound',
      );
    },
  );

  // ==========================================================================
  // R7 (control): the resumed turn is seat 0's own, in await_roll, with a
  // plainly different deadline_ms. A red result here means this rig is not
  // reaching the scenario R6 depends on, not that the product is broken.
  // ==========================================================================
  testWidgets(
    'R7 (control): a resumed turn on seat 0 in await_roll with a plainly '
    'different deadline_ms (30000, against the pre-drop turn\'s 42000) '
    'offers the roll affordance and the countdown shows the new segment',
    (tester) async {
      final (controller, _, resumeTransport) = await dropAndReconnect(
        tester,
        initialTurn: preDropTurn(),
        seats: fourSeats,
      );
      addTearDown(controller.dispose);

      await answerResume(
        tester,
        resumeTransport,
        _roomJson(
          seats: fourSeats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 30000,
            k: 6,
          ),
          seq: 4,
        ),
      );

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'R7 control: fixture is broken: the resume reply must land '
            'the controller back in RoomPhase.connected',
      );
      expect(
        controller.room!.turn!.seat,
        0,
        reason:
            'R7 control: fixture is broken: the resumed turn must be on '
            'seat 0',
      );
      expect(
        controller.room!.turn!.deadlineMs,
        30000,
        reason:
            'R7 control: fixture is broken: the resumed turn must carry '
            'deadline_ms 30000',
      );
      expect(
        find.byKey(_connectionLostKey),
        findsNothing,
        reason:
            'R7 control: with the resume landed, game-screen-connection-'
            'lost must be gone; a red result here is a rig failure, not a '
            'product finding',
      );

      expect(
        find.byKey(_rollKey),
        findsOneWidget,
        reason:
            'R7 control: game-screen-roll-button must be present; a red '
            'result here is a rig failure, not a product finding',
      );
      final ElevatedButton button = tester.widget<ElevatedButton>(
        find.byKey(_rollKey),
      );
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'R7 control: with the resumed turn on the local player\'s own '
            'seat 0 in await_roll, game-screen-roll-button must be '
            'enabled; a red result here means this rig is not reaching '
            'the scenario R6 depends on, not that the product is broken',
      );

      final int shown = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shown,
        30,
        reason:
            'R7 control: deadline_ms 30000, plainly different from the '
            'pre-drop turn\'s 42000, must render as a fresh 30-second '
            'countdown; got $shown. A red result here is a rig failure, '
            'not a product finding',
      );
    },
  );
}
