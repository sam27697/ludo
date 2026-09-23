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
// This file is proof written against code that does not exist yet. It may
// not, and does not, reference AppLocalizations.gameSeatOffline: that
// getter is not generated on this branch, and calling it here would turn
// an honest red (findsNothing where findsOneWidget is required) into a
// compile error, which is not a result this order accepts. Instead it
// asserts on the key, on the rendered Text.data, and on the relationship
// between the English and Arabic renderings, all of which compile against
// 4a49b72 whether or not lib/src/game_screen.dart has been touched.
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
// P2, P3 and P6 are expected to fail on this branch, on the offline key
// being absent (findsOneWidget finding zero widgets), because the code
// that renders it has not landed here. That red is this order's product.
// P1, P4 and P5 are expected to pass, P1 because the key is legitimately
// never rendered when the seat on turn is connected, P4 and P5 because the
// key is (for now) never rendered at all -- both become real assertions of
// the fix's own correctness the day order 163 lands next to this file.

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
/// offline key is present before returning its rendered Text.data. Shared
/// by P6's two locale mounts so both go through the identical scenario
/// P2 itself measures, differing only in which locale the MaterialApp
/// resolves.
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
        'fixture is broken: P6 ($localeLabel) needs the turn to land on '
        'seat 2 after seat 1\'s handoff, same as P2',
  );
  expect(
    controller.room!.seats[2].connected,
    isFalse,
    reason:
        'fixture is broken: P6 ($localeLabel) needs seat 2 disconnected '
        'before the turn reaches it, same as P2',
  );

  expect(
    find.byKey(_offlineKey),
    findsOneWidget,
    reason:
        'P6 ($localeLabel): game-screen-turn-seat-offline must be in the '
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
  // the line must be gone. Green on this branch, but for the wrong reason:
  // the line is never rendered at all yet, so this does not yet catch a
  // line that appeared correctly and then never left, which is the failure
  // a real player would actually report. It becomes that real assertion
  // the day order 163's fix lands next to this file.
  // ==========================================================================
  testWidgets(
    'P4: from P2\'s state, the turn moves on to seat 3, who is connected -- '
    'game-screen-turn-seat-offline must be gone again. Green on this '
    'branch, but for the wrong reason: the line is never rendered at all '
    'yet, so this case does not yet catch a line that appears correctly '
    'on a dropped seat and then never clears when the turn moves on -- '
    'the failure a real player would actually report. It becomes that '
    'real assertion once order 163\'s fix lands next to this file',
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
  // the line must be gone. Same shape and same caveat as P4: green on this
  // branch for the wrong reason, becomes a real assertion once the fix
  // lands.
  // ==========================================================================
  testWidgets(
    'P5: from P2\'s state, seat 2 returns with the turn still on seat 2 -- '
    'game-screen-turn-seat-offline must be gone. Green on this branch, '
    'but for the wrong reason, same as P4: the line is never rendered at '
    'all yet. It becomes a real assertion once order 163\'s fix lands '
    'next to this file',
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
  // P6: the locale contract. Mounts P2's exact scenario twice, once under
  // Locale('en') and once under Locale('ar'), and checks the two renderings
  // agree on containing the dropped seat's name but disagree with each
  // other -- the clause that catches a hardcoded English literal shipped
  // in place of an ARB lookup, the most likely way this change gets the
  // Arabic wrong. Red on this branch, for the same reason as P2: the key
  // is absent under both locales.
  // ==========================================================================
  testWidgets(
    'P6: the locale contract -- P2\'s scenario mounted under Locale(en) '
    'and under Locale(ar) must both show a non-empty '
    'game-screen-turn-seat-offline naming Cy, and the two renderings must '
    'not read identically to each other, which is what catches a '
    'hardcoded English literal shipped in place of an ARB lookup for the '
    'Arabic build. Red on this branch: the key is absent under both '
    'locales',
    (tester) async {
      final String? enText = await _mountP2ScenarioAndGetOfflineText(
        tester,
        locale: const Locale('en'),
        localeLabel: 'en',
      );
      final String? arText = await _mountP2ScenarioAndGetOfflineText(
        tester,
        locale: const Locale('ar'),
        localeLabel: 'ar',
      );

      expect(
        enText,
        isNotEmpty,
        reason:
            'P6 (en): game-screen-turn-seat-offline must render a '
            'non-empty string under Locale(en); got "$enText"',
      );
      expect(
        enText,
        contains('Cy'),
        reason: 'P6 (en): must name Cy, seat 2; got "$enText"',
      );

      expect(
        arText,
        isNotEmpty,
        reason:
            'P6 (ar): game-screen-turn-seat-offline must render a '
            'non-empty string under Locale(ar); got "$arText"',
      );
      expect(
        arText,
        contains('Cy'),
        reason: 'P6 (ar): must name Cy, seat 2; got "$arText"',
      );

      expect(
        arText == enText,
        isFalse,
        reason:
            'P6: the en and ar renderings must not be equal -- '
            'app_en.arb\'s gameSeatOffline reads "{name} is offline" and '
            'app_ar.arb\'s reads "انقطع اتصال {name}", two different '
            'strings for the same key, so en ("$enText") equalling ar '
            '("$arText") would mean a hardcoded English literal shipped '
            'in place of an ARB lookup, which is the most likely way '
            'this change gets the Arabic build wrong',
      );
    },
  );
}
