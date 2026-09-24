// Order 164: the proof, written before the fix, that GameScreen tells a
// player watching a 45-second countdown run down on a dropped opponent why
// it is running.
//
// Order 159 measured (test/game_screen_opponent_drop_test.dart, O2) that
// game_screen.dart renders a disconnected seat identically to a connected
// one: the whole rendered screen diffs equal before and after seat 2's
// presence flips to false. The master re-measured that on 4a49b72
// (`grep -rn "\.connected" lib/` returns only `RoomPhase.connected` hits,
// a different thing entirely) and confirmed it again by prototype. Order
// 163 is implementing the fix, in a worktree this file cannot see, against
// the pinned contract reproduced in this order: immediately after the
// game-screen-turn-banner Text and before the existing dice-value block, a
// SizedBox and a Text keyed game-screen-turn-seat-offline render, and
// nothing else does, exactly when room.turn is not null, some seat entry
// matches room.turn!.seat, and that entry's connected is false. When any of
// those three fail, neither widget is in the tree at all -- not an empty
// string, not a zero-height box, absent -- which is why every negative case
// below asserts findsNothing rather than an empty Text.data.
//
// This file was first written as proof against code that did not exist yet,
// on a branch cut from 4a49b72 before order 163's fix, where it could not
// reference AppLocalizations.gameSeatOffline at all: that getter was not
// generated there, and calling it would have turned an honest red
// (findsNothing where findsOneWidget is required) into a compile error,
// which that order did not accept. This branch is cut instead from
// integrate/run52-offline, which carries order 163's fix, so
// AppLocalizations.gameSeatOffline is generated and P6en/P6ar assert
// against it directly, per the master's own return on this order's first
// round (see that round's VERDICT for the measurement): each locale's
// rendered Text.data must equal that same widget tree's own
// loc.gameSeatOffline('Cy'), which is strictly stronger than only checking
// the two locales differ from each other.
//
// The harness below is copied from test/game_screen_opponent_drop_test.dart
// rather than reinvented, per the order's instruction to mirror it: the
// same _connectFourSeatGame four-seat PLAYING fixture (seat 0 Sam, local;
// seat 1 Bob; seat 2 Cy; seat 3 Dee), the same _harness (already taking a
// Locale), the same _ScenarioDriver pushing real wire frames through a real
// RoomController over a FakeTransport and pumping twice per push (see that
// file's own header on _ScenarioDriver for the measurement behind the
// second pump -- one pump leaves a rendered frame one push stale). Nothing
// is imported from that file; everything reused is copied, per the order's
// instruction not to import private helpers across test files and not to
// edit the file being copied from.
//
// All six cases are expected to pass on this branch: order 163's fix has
// already landed on integrate/run52-offline, so P1's control, P2 and P3's
// two arrival orders, P4 and P5's clearing cases, and P6en/P6ar's locale
// contract are all real assertions of the fix's own correctness here, not
// merely structural checks against an offline key that never renders.

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

// --- server-side id generation for pushed frames, copied from
// test/game_screen_opponent_drop_test.dart's own idiom -----------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'seat-offline-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied from the sibling suite ----------------

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot, copied
// from the sibling suite -------------------------------------------------

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
  'game_id': 'game-seat-offline',
  'client_seeds': 'seed-seat-offline',
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from the sibling suite's
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

// --- driving a controller straight to a chosen four-seat PLAYING room,
// through real frames, copied from the sibling suite's _connectRoomDirect --

Future<(RoomController, FakeTransport, _Connector)> _connectRoomDirect(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 4);
  // Standing lesson, copied along with the rig: pumpEventQueue() alone
  // relies on real Timers via Future.delayed, which never fire under the
  // fake-async clock a testWidgets body runs in, and hangs forever with no
  // diagnostic. tester.runAsync() steps outside the fake zone for the
  // duration of the call so the real event loop actually advances, then
  // tester.pump() brings the widget tree's own state back in sync with
  // what that unblocked.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(players: 4, seats: seats, turn: turn, seq: 1),
    ),
  );
  await future;
  return (controller, transport, connector);
}

/// The standing four-seat fixture every P-case starts from: seat 0 (Sam,
/// local), seat 1 (Bob), seat 2 (Cy, the seat that drops -- already
/// carrying one token at progress 0 so a pushed expiry-sweep sequence has
/// exactly one legal move to play, matching docs/RULES.md rule 15's
/// "if exactly one legal move exists it plays that move"), seat 3 (Dee).
/// Every seat's connected is true unless the case's own driver flips it.
Future<(RoomController, FakeTransport, _Connector)> _connectFourSeatGame(
  WidgetTester tester, {
  required int initialTurnSeat,
}) {
  return _connectRoomDirect(
    tester,
    seats: <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
      _seatJson(2, name: 'Cy', tokens: const <int>[0, -1, -1, -1]),
      _seatJson(3, name: 'Dee'),
    ],
    turn: _turnJson(
      seat: initialTurnSeat,
      phase: 'await_roll',
      deadlineMs: 45000,
      k: 0,
    ),
  );
}

// --- widget harness, copied from the sibling suite ----------------------

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

const Key _offlineKey = Key('game-screen-turn-seat-offline');

/// Pushes the shared scenario's presence/rolled/moved/turn frames onto
/// [transport] a step at a time, keeping seq contiguous, and pumps [tester]
/// twice after each -- copied verbatim from
/// test/game_screen_opponent_drop_test.dart's own _ScenarioDriver, whose
/// header comment there records the measurement behind the second pump:
/// one pump alone leaves a rendered frame (there, the turn banner; here,
/// the offline line once it exists) one push stale against
/// controller.room, which a fix landing next to this file would otherwise
/// make P2 and P3 flaky against.
class _ScenarioDriver {
  _ScenarioDriver(this._tester, this._transport);

  final WidgetTester _tester;
  final FakeTransport _transport;

  /// The fixture's initial room push is always seq 1.
  int _seq = 1;

  Future<void> _push(String type, Map<String, Object?> data) async {
    _seq += 1;
    _transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': _seq}),
    );
    await _tester.pump();
    await _tester.pump();
  }

  /// Seat 2's socket goes quiet, or comes back, depending on [connected].
  Future<void> presenceSeat2({required bool connected}) =>
      _push('presence', <String, Object?>{'seat': 2, 'connected': connected});

  /// Seat 1 plays an ordinary roll-then-move turn (value 6, two legal
  /// tokens so the local screen's own unique-legal hold is irrelevant even
  /// if it were seat 0's turn) and hands the turn to seat 2.
  Future<void> seat1RollsAndMovesIntoSeat2Turn() async {
    await _push('rolled', <String, Object?>{
      'seat': 1,
      'value': 6,
      'legal': <int>[0, 1],
      'deadline_ms': 45000,
      'k': 1,
      'reveal': 'a' * 64,
    });
    await _push('moved', <String, Object?>{
      'seat': 1,
      'token': 0,
      'from': -1,
      'to': 13,
      'captured': <Object?>[],
      'extra_roll': false,
    });
    await _push('turn', <String, Object?>{'seat': 2, 'deadline_ms': 45000});
  }

  /// The expiry sweep rolls and moves for seat 2 -- the move nobody on
  /// this screen requested -- then hands the turn to seat 3. legal: [0]
  /// mirrors docs/RULES.md rule 15's "exactly one legal move" branch;
  /// seat 2's one on-board token (progress 0, from the fixture) is the
  /// only one a roll of 4 can move.
  Future<void> expirySweepsSeat2IntoSeat3Turn() async {
    await _push('rolled', <String, Object?>{
      'seat': 2,
      'value': 4,
      'legal': <int>[0],
      'deadline_ms': 45000,
      'k': 2,
      'reveal': 'b' * 64,
    });
    await _push('moved', <String, Object?>{
      'seat': 2,
      'token': 0,
      'from': 0,
      'to': 4,
      'captured': <Object?>[],
      'extra_roll': false,
    });
    await _push('turn', <String, Object?>{'seat': 3, 'deadline_ms': 45000});
  }
}

/// Mounts a fresh controller on the four-seat fixture (turn starting on
/// seat 1), drives it through P2's exact sequence -- seat 2 drops, then
/// seat 1's turn hands off into seat 2 -- under [locale], and asserts the
/// offline key is present before returning its rendered Text.data. Called
/// once per case by P6en and P6ar, each from its own fresh `testWidgets`
/// body and therefore its own fresh widget tree: GameScreen has no
/// `didUpdateWidget`, so a second `tester.pumpWidget` inside one body
/// updates the existing element instead of creating a new one, and
/// `_GameScreenState.initState` (where the RoomController's listener gets
/// attached) never runs a second time. A prior version of this file mounted
/// both locales inside a single case and measured, by instrumenting the
/// rig, that the second mount's listener stayed attached to the first
/// mount's controller, so the second mount rendered one push stale --
/// naming Bob's turn banner while controller.room.turn.seat had already
/// moved to seat 2 -- and its offline-key assertion passed for the wrong
/// reason (the frame it painted genuinely had no offline seat on turn, but
/// only because it was the wrong frame). Two separate cases, two separate
/// elements, is the only honest way to measure both locales.
Future<String?> _mountP2ScenarioAndGetOfflineText(
  WidgetTester tester, {
  required Locale locale,
  required String localeLabel,
}) async {
  final (controller, transport, _) = await _connectFourSeatGame(
    tester,
    initialTurnSeat: 1,
  );
  addTearDown(controller.dispose);
  await _mount(tester, controller, locale: locale);

  final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
  await driver.presenceSeat2(connected: false);
  await driver.seat1RollsAndMovesIntoSeat2Turn();

  expect(
    controller.room!.turn?.seat,
    2,
    reason:
        'fixture is broken: P6$localeLabel needs the turn to land on '
        'seat 2 after seat 1\'s handoff, same as P2',
  );
  expect(
    controller.room!.seats[2].connected,
    isFalse,
    reason:
        'fixture is broken: P6$localeLabel needs seat 2 disconnected '
        'before the turn reaches it, same as P2',
  );

  expect(
    find.byKey(_offlineKey),
    findsOneWidget,
    reason:
        'P6$localeLabel: game-screen-turn-seat-offline must be in the '
        'tree once seat 2 has dropped and the turn is on it -- this is '
        'P2\'s own end state, mounted under Locale($localeLabel) instead '
        'of the default',
  );
  return tester.widget<Text>(find.byKey(_offlineKey)).data;
}

void main() {
  // ==========================================================================
  // P1: the turn is on seat 2 and seat 2 is connected -- the control that
  // proves the key is not simply unfindable for a trivial reason (a typo in
  // the key string, a widget that never builds at all, and so on). Must be
  // green on this branch, and stays green once the fix lands.
  // ==========================================================================
  testWidgets('P1: the turn is on seat 2 and seat 2 is connected -- '
      'game-screen-turn-seat-offline must not be in the tree, and this case '
      'is the control that proves the key is not simply unfindable for a '
      'trivial reason', (tester) async {
    final (controller, _, _) = await _connectFourSeatGame(
      tester,
      initialTurnSeat: 2,
    );
    addTearDown(controller.dispose);
    await _mount(tester, controller);

    expect(
      controller.room!.turn?.seat,
      2,
      reason:
          'fixture is broken: P1 needs the very first room snapshot to '
          'already carry the turn on seat 2',
    );
    expect(
      controller.room!.seats[2].connected,
      isTrue,
      reason:
          'fixture is broken: P1 needs seat 2 connected, per the '
          'fixture\'s own default',
    );

    expect(
      find.byKey(_offlineKey),
      findsNothing,
      reason:
          'P1: seat 2 is on turn and connected, so '
          'game-screen-turn-seat-offline must not be in the tree at '
          'all; if it is, the offline line is firing for a connected '
          'seat, which would falsely tell every player at the table '
          'that Cy has dropped when Cy has not',
    );
  });

  // ==========================================================================
  // P2: seat 2 drops, then the turn arrives at seat 2 -- the turn reducer
  // landing on a seat that is already absent. Red on this branch: the
  // offline line does not exist yet.
  // ==========================================================================
  testWidgets('P2: seat 2 drops and then the turn arrives at seat 2 -- '
      'game-screen-turn-seat-offline must appear naming Cy, so a player '
      'watching the countdown run down on seat 2 is told why. Red on this '
      'branch: the turn reducer is landing on an already-absent seat, and '
      'order 163\'s fix has not landed in this worktree', (tester) async {
    final (controller, transport, _) = await _connectFourSeatGame(
      tester,
      initialTurnSeat: 1,
    );
    addTearDown(controller.dispose);
    await _mount(tester, controller);

    final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
    await driver.presenceSeat2(connected: false);
    await driver.seat1RollsAndMovesIntoSeat2Turn();

    expect(
      controller.room!.turn?.seat,
      2,
      reason:
          'fixture is broken: P2 needs the turn to land on seat 2 '
          'after seat 1\'s handoff',
    );
    expect(
      controller.room!.seats[2].connected,
      isFalse,
      reason:
          'fixture is broken: P2 needs seat 2 already disconnected '
          'before the turn reaches it',
    );

    expect(
      find.byKey(_offlineKey),
      findsOneWidget,
      reason:
          'P2: the turn reducer just landed the turn on seat 2, which '
          'is already disconnected; a player watching the countdown '
          'run down on Cy is owed the reason for it and, with this '
          'widget absent, is told nothing',
    );
    final Text offline = tester.widget<Text>(find.byKey(_offlineKey));
    expect(
      offline.data,
      isNotNull,
      reason:
          'P2: game-screen-turn-seat-offline must carry rendered text, '
          'not a null Text.data',
    );
    expect(
      offline.data,
      isNotEmpty,
      reason:
          'P2: game-screen-turn-seat-offline must not render an empty '
          'string; got "${offline.data}"',
    );
    expect(
      offline.data,
      contains('Cy'),
      reason:
          'P2: the offline line must name the seat that dropped (Cy, '
          'seat 2), so a player knows exactly who the table is waiting '
          'on; got "${offline.data}"',
    );
  });

  // ==========================================================================
  // P3: the turn is already on seat 2, then seat 2 drops -- the presence
  // reducer landing under a live turn, the other order from P2. Red on
  // this branch, for the same reason as P2, but an implementation can
  // plausibly get one of these two orderings right and the other wrong,
  // which is why both are measured separately rather than treated as
  // duplicates.
  // ==========================================================================
  testWidgets(
    'P3: the turn is already on seat 2 and then seat 2 drops -- the same '
    'end state as P2, reached in the other order; game-screen-turn-seat-'
    'offline must appear naming Cy here too. Red on this branch: the '
    'presence reducer is landing under a live turn, and order 163\'s fix '
    'has not landed in this worktree',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 2,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
      await driver.presenceSeat2(connected: false);

      expect(
        controller.room!.turn?.seat,
        2,
        reason:
            'fixture is broken: P3 needs the turn already sitting on '
            'seat 2 before the presence frame lands',
      );
      expect(
        controller.room!.seats[2].connected,
        isFalse,
        reason:
            'fixture is broken: P3 needs seat 2 to have dropped under a '
            'turn that was already its own',
      );

      expect(
        find.byKey(_offlineKey),
        findsOneWidget,
        reason:
            'P3: presence {seat: 2, connected: false} just landed under '
            'a turn that was already sitting on seat 2; the offline line '
            'must appear here exactly as it does when the turn reducer '
            'arrives at an already-absent seat (P2) -- a fix that only '
            'checks connected inside the turn reducer, and never on a '
            'bare presence delta, would leave this case with the widget '
            'absent while P2 passes',
      );
      final Text offline = tester.widget<Text>(find.byKey(_offlineKey));
      expect(
        offline.data,
        isNotNull,
        reason:
            'P3: game-screen-turn-seat-offline must carry rendered text, '
            'not a null Text.data',
      );
      expect(
        offline.data,
        isNotEmpty,
        reason:
            'P3: game-screen-turn-seat-offline must not render an empty '
            'string; got "${offline.data}"',
      );
      expect(
        offline.data,
        contains('Cy'),
        reason:
            'P3: the offline line must name Cy, seat 2, whichever order '
            'the drop and the turn arrived in; got "${offline.data}"',
      );
    },
  );

  // ==========================================================================
  // P4: from P2's state, the turn moves on to seat 3, who is connected --
  // the line must be gone. This is the case that catches a line which
  // appeared correctly on a dropped seat and then never left, which is the
  // failure a real player would actually report. Proved to bite: deleting
  // the connected check in _offlineTurnSeat, so the line shows whenever the
  // turn names a seat, reddens P1, P4 and P5 and nothing else.
  // ==========================================================================
  testWidgets(
    'P4: from P2\'s state, the turn moves on to seat 3, who is connected -- '
    'game-screen-turn-seat-offline must be gone again. This catches a line '
    'that appears correctly on a dropped seat and then never clears when '
    'the turn moves on, which is the failure a real player would actually '
    'report',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
      await driver.presenceSeat2(connected: false);
      await driver.seat1RollsAndMovesIntoSeat2Turn();
      await driver.expirySweepsSeat2IntoSeat3Turn();

      expect(
        controller.room!.turn?.seat,
        3,
        reason:
            'fixture is broken: P4 needs the expiry sweep to have handed '
            'the turn to seat 3',
      );
      expect(
        controller.room!.seats[3].connected,
        isTrue,
        reason:
            'fixture is broken: P4 needs seat 3 connected, so a '
            'lingering offline line would have no live cause left to '
            'point at',
      );

      expect(
        find.byKey(_offlineKey),
        findsNothing,
        reason:
            'P4: the turn has moved on from seat 2 to seat 3, who is '
            'connected; game-screen-turn-seat-offline must be gone. A '
            'line that appeared correctly while the turn sat on seat 2 '
            'and then stayed on screen after the turn moved to a '
            'connected seat is the failure a real player would actually '
            'report',
      );
    },
  );

  // ==========================================================================
  // P5: from P2's state, seat 2 returns with the turn still on seat 2 --
  // the line must be gone. Same shape as P4 and proved to bite by the same
  // mutation: the line must clear when the seat comes back, not only when
  // the turn moves away from it.
  // ==========================================================================
  testWidgets(
    'P5: from P2\'s state, seat 2 returns with the turn still on seat 2 -- '
    'game-screen-turn-seat-offline must be gone. Same shape as P4: the '
    'line must clear when the seat comes back, not only when the turn '
    'moves away from it',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
      await driver.presenceSeat2(connected: false);
      await driver.seat1RollsAndMovesIntoSeat2Turn();
      await driver.presenceSeat2(connected: true);

      expect(
        controller.room!.turn?.seat,
        2,
        reason:
            'fixture is broken: P5 needs the turn to still be on seat 2 '
            'when seat 2 returns',
      );
      expect(
        controller.room!.seats[2].connected,
        isTrue,
        reason: 'fixture is broken: P5 needs seat 2 back to connected',
      );

      expect(
        find.byKey(_offlineKey),
        findsNothing,
        reason:
            'P5: seat 2 is back and the turn is still sitting on it; '
            'game-screen-turn-seat-offline must be gone. A line that '
            'stays on screen after the seat it names has reconnected is '
            'the same class of failure P4 catches, on the opposite side '
            'of the fix',
      );
    },
  );

  // ==========================================================================
  // P6en / P6ar: the locale contract, split into two cases each with its
  // own fresh widget tree. P2's exact scenario is mounted once under
  // Locale('en') and, separately, once under Locale('ar'); each case reads
  // AppLocalizations off its own tree's own BuildContext (the same tree it
  // just mounted, via tester.element(find.byType(GameScreen))) and asserts
  // the rendered Text.data equals that tree's own
  // loc.gameSeatOffline('Cy') exactly. That is strictly stronger than a
  // not-equal-to-the-other-locale check: it does not just prove the two
  // renderings differ from each other, it proves each one is the string
  // its own locale's ARB entry actually specifies. A hardcoded English
  // literal shipped in place of an ARB lookup would still render
  // "Cy is offline" under Locale('ar') while that tree's own
  // loc.gameSeatOffline('Cy') resolves app_ar.arb's "انقطع اتصال {name}"
  // to "انقطع اتصال Cy", and P6ar's equality assertion fails on exactly
  // that mismatch. Split into two cases (rather than the single
  // two-mount case this order returned once) because GameScreen has no
  // didUpdateWidget: a second tester.pumpWidget inside one body updates
  // the existing element instead of creating a fresh one, so the second
  // mount's controller listener never gets attached and the second mount
  // renders a whole turn stale -- see _mountP2ScenarioAndGetOfflineText's
  // own header comment for the measurement behind this. On this branch
  // order 163's fix has landed, so both cases are expected to pass.
  // ==========================================================================
  testWidgets(
    'P6en: P2\'s scenario mounted under Locale(en) must show a non-empty '
    'game-screen-turn-seat-offline naming Cy whose Text.data equals this '
    'tree\'s own AppLocalizations.gameSeatOffline(\'Cy\') exactly -- the '
    'en half of the locale contract, in its own fresh widget tree so a '
    'second mount elsewhere in this file cannot leave this one\'s '
    'controller listener unattached',
    (tester) async {
      final String? enText = await _mountP2ScenarioAndGetOfflineText(
        tester,
        locale: const Locale('en'),
        localeLabel: 'en',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );

      expect(
        enText,
        isNotEmpty,
        reason:
            'P6en: game-screen-turn-seat-offline must render a non-empty '
            'string under Locale(en); got "$enText"',
      );
      expect(
        enText,
        contains('Cy'),
        reason: 'P6en: must name Cy, seat 2; got "$enText"',
      );
      expect(
        enText,
        loc.gameSeatOffline('Cy'),
        reason:
            'P6en: game-screen-turn-seat-offline\'s Text.data must equal '
            'this tree\'s own loc.gameSeatOffline(\'Cy\') exactly, not '
            'merely differ from the Arabic rendering elsewhere in this '
            'file; got "$enText", expected '
            '"${loc.gameSeatOffline('Cy')}"',
      );
    },
  );

  testWidgets(
    'P6ar: P2\'s scenario mounted under Locale(ar) must show a non-empty '
    'game-screen-turn-seat-offline naming Cy whose Text.data equals this '
    'tree\'s own AppLocalizations.gameSeatOffline(\'Cy\') exactly -- the '
    'ar half of the locale contract, in its own fresh widget tree so a '
    'second mount elsewhere in this file cannot leave this one\'s '
    'controller listener unattached. A hardcoded English literal shipped '
    'in place of an ARB lookup would still render "Cy is offline" here '
    'and fail this exact assertion, which is the case this order exists '
    'to prove',
    (tester) async {
      final String? arText = await _mountP2ScenarioAndGetOfflineText(
        tester,
        locale: const Locale('ar'),
        localeLabel: 'ar',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );

      expect(
        arText,
        isNotEmpty,
        reason:
            'P6ar: game-screen-turn-seat-offline must render a non-empty '
            'string under Locale(ar); got "$arText"',
      );
      expect(
        arText,
        contains('Cy'),
        reason: 'P6ar: must name Cy, seat 2; got "$arText"',
      );
      expect(
        arText,
        loc.gameSeatOffline('Cy'),
        reason:
            'P6ar: game-screen-turn-seat-offline\'s Text.data must equal '
            'this tree\'s own loc.gameSeatOffline(\'Cy\') exactly; a '
            'hardcoded English literal shipped in place of an ARB lookup '
            'would render "Cy is offline" here while this tree\'s own '
            'loc.gameSeatOffline(\'Cy\') resolves app_ar.arb\'s '
            '"انقطع اتصال {name}" to "${loc.gameSeatOffline('Cy')}", so '
            'this is exactly the mismatch that catches it; got "$arText"',
      );
    },
  );
}
