// Conformance tests for the turn-countdown contract work order 141 pins
// against lib/src/game_screen.dart's GameScreen, written from the frozen
// contract text in work/ludo/orders/141-turn-countdown-proof.md alone. On
// this base commit (754fa37) GameScreen builds no widget keyed
// game-screen-turn-countdown and no widget keyed game-screen-waiting-for-
// seat anywhere: a second worker is adding both, blind, from the identical
// frozen contract, in a different worktree, and this file has not read that
// worker's change.
//
// P1, P2, P3, P4 and P7 are therefore expected to FAIL on this base commit --
// the countdown key the contract names does not exist. P5 and P6 are
// controls and are expected to PASS: they exercise paths the contract does
// not add anything new to (an absent key staying absent, a healthy own-turn
// board), so a red P5 or P6 would mean this file is not reaching the
// behaviour it claims to test, not that the contract is unmet.
//
// GameScreen is driven the same way test/game_screen_test.dart and
// test/game_screen_connection_lost_test.dart drive RoomController: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// idiom. Every claim about the state the screen is rendering is reached by
// decoding a wire reply into a real RoomSnapshot through RoomController's
// own request path, never by constructing a RoomSnapshot by hand. Assertions
// are made on find.byKey, widget types and rendered numbers only, never on
// localized strings: the counterpart order adds new l10n keys that do not
// exist on this base commit, and referencing them would not compile.
//
// Where the countdown text sits inside whatever widget carries the
// game-screen-turn-countdown key is not pinned by the contract (only the key
// and "shows the whole seconds remaining" are). _wholeSecondsShown below
// reads the key's own widget if it is a Text, or else the first Text
// descendant under it, and pulls the first run of digits out of whatever
// string that Text carries -- so a rendered "45", "00:45" or "45s" are all
// read as 45 without this file assuming the exact template the other worker
// chose.
//
// Ambiguity found while writing this file, reported rather than invented
// around:
//
//   P6 asks for "a playing room whose turn carries no deadline_ms at all".
//   On this base commit, TurnState.deadlineMs (lib/src/net/snapshot.dart) is
//   a required, non-nullable int: SnapshotFormatException is thrown by
//   TurnState.fromJson whenever a decoded turn object's deadline_ms key is
//   missing or JSON null, and RoomConnection._asRoomSnapshot
//   (lib/src/net/connection.dart) does not catch that exception on the
//   `room` reply that completes createRoom/joinRoom/resume/setPlayers -- it
//   would fail this file's own fixture setup, not exercise GameScreen at
//   all. There is no way to drive a real, decoded RoomSnapshot into a state
//   where room.turn is a TurnState with no deadline_ms while turn itself is
//   present; the only way "the turn carries no deadline_ms at all" is
//   reachable through the real model is room.turn being null outright, since
//   then there is no TurnState object to carry any deadline at all. That
//   also matches the contract's own rule 1 phrasing literally:
//   `room.turn?.deadlineMs` on a null `room.turn` evaluates to null under
//   Dart's null-aware operator regardless of whether TurnState.deadlineMs
//   itself is nullable, so "is non-null" is false exactly when turn is null,
//   which is what rule 1 requires for the countdown to be absent. P6 below is
//   therefore driven with turn: null, the same "no turn at all" state
//   test/game_screen_test.dart's H2 branch 1 and H3.6c already reach, but
//   checked here for a different key. This should be checked against
//   whatever the implementer also concluded about deadline_ms's nullability.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom ----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'countdown-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
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
  // unblocked. Neither step advances the fake clock the countdown itself
  // will be measured against below.
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
  return (controller, transport);
}

// --- widget harness, mirroring game_screen_test.dart's own ----------------

Widget _harness(Widget child) {
  return MaterialApp(
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

const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _waitingForSeatKey = Key('game-screen-waiting-for-seat');
const Key _boardKey = Key('game-screen-board');
const Key _rollKey = Key('game-screen-roll-button');

/// Reads whatever whole-second number the widget at [key] is showing,
/// without assuming its exact template. If the keyed widget is itself a
/// [Text], its data is used; otherwise the first [Text] descendant under it
/// is used. The first run of digits (with an optional leading '-', so a
/// clamp bug that slips out a negative number is still readable rather than
/// silently failing the parse) is parsed out and returned.
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
  final List<Map<String, Object?>> twoSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];

  // ==========================================================================
  // P1: the countdown renders.
  // ==========================================================================
  testWidgets('P1: a playing room whose turn carries deadline_ms 45000 renders '
      'game-screen-turn-countdown showing 45 whole seconds, checked against '
      'the deadline put on the wire, not a number the widget also computed', (
    tester,
  ) async {
    final (controller, _) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
    );
    addTearDown(controller.dispose);
    expect(
      controller.room!.turn!.deadlineMs,
      45000,
      reason: 'fixture is broken: deadline_ms must be 45000 on the wire',
    );

    await _mount(tester, controller);

    expect(
      find.byKey(_countdownKey),
      findsOneWidget,
      reason:
          'P1: a playing room whose turn carries deadline_ms non-null '
          'must render exactly one widget keyed '
          'game-screen-turn-countdown; none was found',
    );
    final int shown = _wholeSecondsShown(tester, _countdownKey);
    expect(
      shown,
      45,
      reason:
          'P1: deadline_ms 45000 was put on the wire with no fake time '
          'advanced since; game-screen-turn-countdown must show 45 whole '
          'seconds, got $shown',
    );
  });

  // ==========================================================================
  // P2: it counts down.
  // ==========================================================================
  testWidgets('P2: from a 45000ms deadline, each further second of pumped time '
      'strictly decreases the rendered value', (tester) async {
    final (controller, _) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
    );
    addTearDown(controller.dispose);

    await _mount(tester, controller);
    expect(
      find.byKey(_countdownKey),
      findsOneWidget,
      reason:
          'P2: game-screen-turn-countdown must be present before this '
          'case can measure it counting down',
    );

    int previous = _wholeSecondsShown(tester, _countdownKey);
    for (int elapsedSeconds = 1; elapsedSeconds <= 5; elapsedSeconds++) {
      await tester.pump(const Duration(seconds: 1));
      final int shown = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shown,
        lessThan(previous),
        reason:
            'P2: after $elapsedSeconds second(s) of pumped time past a '
            '45000ms deadline, game-screen-turn-countdown must show a '
            'smaller value than the previous $previous; got $shown, which '
            'did not decrease',
      );
      previous = shown;
    }
  });

  // ==========================================================================
  // P3: the clamp.
  // ==========================================================================
  testWidgets(
    'P3: past the deadline the rendered value is zero and never negative at '
    'any second sampled across the boundary, and stays zero once reached',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);
      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'P3: game-screen-turn-countdown must be present before this '
            'case can measure the clamp at its deadline',
      );

      // Sample every second from 1 through 50 seconds of pumped time,
      // crossing the 45000ms deadline partway through, and require that no
      // sample is ever negative -- the case requirement 2 in the contract
      // exists for.
      for (int elapsedSeconds = 1; elapsedSeconds <= 50; elapsedSeconds++) {
        await tester.pump(const Duration(seconds: 1));
        final int shown = _wholeSecondsShown(tester, _countdownKey);
        expect(
          shown,
          greaterThanOrEqualTo(0),
          reason:
              'P3: game-screen-turn-countdown must never show a negative '
              'number; at $elapsedSeconds second(s) of pumped time past a '
              '45000ms deadline, got $shown',
        );
      }
      final int shownAtFifty = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shownAtFifty,
        0,
        reason:
            'P3: with 50 seconds of pumped time against a 45000ms deadline, '
            'game-screen-turn-countdown must show exactly 0; got '
            '$shownAtFifty',
      );

      // Advance further and confirm the clamp holds rather than the
      // countdown wrapping, resetting or otherwise moving off zero.
      await tester.pump(const Duration(seconds: 10));
      final int shownAfterMore = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shownAfterMore,
        0,
        reason:
            'P3: 10 further seconds of pumped time past an already-expired '
            '45000ms deadline must still show 0, not drift away from the '
            'clamp; got $shownAfterMore',
      );
    },
  );

  // ==========================================================================
  // P4: waiting for another seat.
  // ==========================================================================
  testWidgets(
    'P4: in a playing room where the turn belongs to a seat that is not '
    'this player\'s, game-screen-waiting-for-seat is present and names the '
    'seat on turn, proved by varying which seat is named and requiring the '
    'rendered text to differ rather than asserting exact wording',
    (tester) async {
      final (controllerBob, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controllerBob.dispose);
      expect(
        controllerBob.room!.turn!.seat,
        isNot(controllerBob.seat),
        reason: 'fixture is broken: the turn must not belong to my seat',
      );

      await _mount(tester, controllerBob);

      expect(
        find.byKey(_waitingForSeatKey),
        findsOneWidget,
        reason:
            'P4: with the turn on seat 1 and my own seat 0, '
            'game-screen-waiting-for-seat must be present; none was found',
      );
      final String textForBob = _renderedTextAt(tester, _waitingForSeatKey);
      expect(
        textForBob,
        isNotEmpty,
        reason:
            'P4: game-screen-waiting-for-seat must name the seat on turn, '
            'not render an empty string',
      );
    },
  );

  // ==========================================================================
  // P5: the control, my own turn.
  // ==========================================================================
  testWidgets(
    'P5 (control): in a playing room where the turn belongs to this player, '
    'game-screen-waiting-for-seat is absent; the board and the roll button '
    'are present',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.turn!.seat,
        controller.seat,
        reason: 'fixture is broken: the turn must belong to my own seat',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_waitingForSeatKey),
        findsNothing,
        reason:
            'P5: with the turn on my own seat, game-screen-waiting-for-seat '
            'must be absent',
      );
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'P5: the board must be present on my own turn',
      );
      expect(
        find.byKey(_rollKey),
        findsOneWidget,
        reason: 'P5: the roll button must be present on my own turn',
      );
    },
  );

  // ==========================================================================
  // P6: the control, no deadline.
  // ==========================================================================
  testWidgets(
    'P6 (control): in a playing room whose turn is null -- so there is no '
    'deadline_ms at all to show, per this file\'s header comment -- '
    'game-screen-turn-countdown is absent and nothing throws',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: null,
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.turn,
        isNull,
        reason: 'fixture is broken: room.turn must be null',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_countdownKey),
        findsNothing,
        reason:
            'P6: a playing room whose turn is null must never render '
            'game-screen-turn-countdown',
      );
    },
  );

  // ==========================================================================
  // P7: no timer survives the widget.
  // ==========================================================================
  testWidgets(
    'P7: mounting a playing room with a deadline and then pumping the '
    'widget tree away must leave no periodic timer behind for '
    'flutter_test\'s own pending-timer check to catch; asserting the '
    'countdown is present first stops this case passing vacuously on a '
    'base with no countdown at all',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'P7: game-screen-turn-countdown must be present while mounted '
            'for this case to prove anything about its timer surviving '
            'disposal; a base with no countdown at all must fail here '
            'rather than pass this case for having no timer to catch',
      );

      // Pump the tree away: GameScreen (and whatever State owns the
      // countdown's Timer) is disposed. If dispose does not cancel that
      // Timer, flutter_test's own binding fails this test on its own with
      // "A Timer is still pending even after the widget tree was disposed"
      // once this body returns -- nothing here asserts on that timer
      // directly.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

/// Reads the rendered text at [key] the same way [_wholeSecondsShown] locates
/// its Text, but returns the raw string rather than parsing a number out of
/// it. Used by P4, which only needs to know the rendered text is non-empty
/// and present, not what number (there is none) it carries.
String _renderedTextAt(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  if (widget is Text) {
    return widget.data ?? '';
  }
  final Finder descendant = find.descendant(
    of: finder,
    matching: find.byType(Text),
  );
  expect(
    descendant,
    findsAtLeastNWidgets(1),
    reason:
        'the widget keyed $key is a ${widget.runtimeType}, not a '
        'Text, and carries no Text descendant to read rendered text from',
  );
  final Text text = tester.widget<Text>(descendant.first);
  return text.data ?? '';
}
