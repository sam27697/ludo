// Order 159: what the players who stayed are shown while a seat is gone.
//
// Order 158 measures the screen of the player who dropped and came back.
// This file measures the other three screens: a local player at seat 0
// whose own socket never breaks, while seat 2 loses its connection, the
// server's expiry sweep plays seat 2's turn for it, and seat 2 later
// returns. On seat 0's screen that whole story arrives as ordinary
// contiguous deltas on a live socket -- `presence`, `rolled`, `moved`,
// `turn` -- and RoomController reduces them incrementally, never by
// replacing the whole snapshot. That is the code path this file measures.
//
// Two facts stated by the work order and re-checked here rather than taken
// on trust, per its own instruction:
//
//   - lib/src/net/room_controller.dart:35-47 lists `presence` among the
//     frame types `_stateChangingTypes` carries, and :429-430 dispatches it
//     to `_reducePresence`, which sets that seat's `connected`. Both are
//     read directly above (see the imports and the reducer's own doc
//     comment) and are exercised, not assumed, by O1 below.
//   - `grep -ni "offline\|absent\|away\|disc\|presence\|connected"
//     lib/src/game_screen.dart` turns up nothing but a single unrelated
//     doc-comment use of the word "absent" describing buttons that vanish
//     at game-over. `GameScreen` never reads `SeatState.connected`
//     anywhere. O2 measures the consequence of that directly, by diffing
//     the rendered screen before and after seat 2 drops, rather than by
//     repeating the grep as an assertion.
//
// Driven the same way test/game_screen_connection_lost_test.dart and
// test/game_screen_test.dart drive RoomController: a real RoomController
// over a FakeTransport (test/net/fake_transport.dart, read-only, not
// edited here), every rendered state reached by pushing a wire frame
// rather than by constructing a RoomSnapshot by hand, assertions on
// find.byKey and widget structure rather than on invented literal text.
// The one place this file compares against `AppLocalizations` output
// (O3's turn banner and countdown, and O5's converged-control diff) it
// does so the same way test/game_screen_test.dart's own H2 and H5 cases
// do: against `loc.<key>(...)` computed from the same delegate the widget
// under test uses, never a hand-typed English or Arabic literal, and only
// for keys that already exist and compile on this branch.
//
// Every pushed `rolled`/`moved`/`turn` triple below matches
// docs/PROTOCOL.md section 12's shape and ordering: one `moved` per
// `rolled` that grants no extra roll and ends the turn, followed by one
// `turn` naming the next seat, three consecutive `seq` values per turn
// exactly as section 12.3 requires. `seq` is contiguous across the whole
// file: every push adds exactly 1 to the room's last `seq`, never skips,
// so none of this ever wakes the resync machinery
// test/net/room_controller_game_test.dart's D5 group already owns.
//
// Ambiguity noted rather than invented around: the order's step 3 says
// only "push whatever contiguous sequence...the protocol actually uses"
// to get the turn from wherever step 1 leaves it to seat 2. The order does
// not say whose turn step 1 should start on. This file starts the turn on
// seat 1 (not seat 0) and lets it pass through seat 1 on the way to seat
// 2, then continues the sequence past seat 2's sweep through seat 3's own
// ordinary turn and back to seat 0, so that O4's "is offered it when the
// turn does reach seat 0" is checked against an actual reach during the
// sequence, not only against the fixture's initial state. Nothing in the
// order forbids this; it is called out here because a different, equally
// defensible reading (starting the turn on seat 0 and never bringing it
// back) would have made that half of O4 untestable within the order's own
// five steps.
//
// The local seat, 0, never rolls or moves in this file: every `rolled` and
// `moved` pushed here names seat 1, seat 2 or seat 3. That is deliberate,
// not an oversight -- it keeps `_isUniqueLegalAwaitMove()`'s
// `turn.seat == controller.seat` guard false throughout, so
// game_screen.dart's own 3-second unique-legal auto-move hold (armed only
// for the local seat's own awaitMove) never arms and never needs managing
// inside these tests.

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
  return 'opp-drop-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

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
// the sibling suites -----------------------------------------------------

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
  'game_id': 'game-opponent-drop',
  'client_seeds': 'seed-opponent-drop',
  'seats': seats,
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

// --- driving a controller straight to a chosen four-seat PLAYING room,
// through real frames, mirroring the sibling suites' _connectPlaying -------

/// Connects [tester]'s controller to a room whose very first `room` push
/// already carries [seats] and [turn] -- so a case that needs a room
/// already converged to some later state (O5's control) can ask for that
/// state directly, exactly as it needs to prove convergence against a
/// controller that actually lived through the drop.
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
  // Standing lesson: pumpEventQueue() alone relies on real Timers via
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

/// The standing four-seat fixture every O-case starts from: seat 0 (Sam,
/// local), seat 1 (Bob), seat 2 (Cy, the seat that drops -- already
/// carrying one token at progress 0 so the expiry sweep in step 4 has
/// exactly one legal move to play, matching docs/RULES.md rule 15's
/// "if exactly one legal move exists it plays that move"), seat 3 (Dee).
/// Every seat's `connected` is true, per the order's step 1.
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

// --- widget harness, mirroring the sibling suites' own ----------------

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

const Key _boardKey = Key('game-screen-board');
const Key _rollKey = Key('game-screen-roll-button');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _countdownKey = Key('game-screen-turn-countdown');

Key _tokenButtonKey(int index) => Key('game-screen-token-$index');

/// Every `Text.data` under the mounted `GameScreen`, in tree order. Used to
/// diff the whole rendered screen between two moments (O2) or between two
/// controllers (O5) without guessing which individual widget might carry
/// a presence cue that does not exist yet.
List<String?> _gameScreenTexts(WidgetTester tester) {
  return tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(GameScreen),
          matching: find.byType(Text),
        ),
      )
      .map((Text w) => w.data)
      .toList();
}

bool _buttonEnabled(WidgetTester tester, Key key) =>
    tester.widget<ElevatedButton>(find.byKey(key)).onPressed != null;

/// Pushes the shared scenario's `presence`/`rolled`/`moved`/`turn` frames
/// onto [transport] a step at a time, keeping `seq` contiguous, and pumps
/// [tester] after each so RoomController's reducer has run and GameScreen
/// has rebuilt before the next push is queued. Each method name is the
/// order's own step it plays.
///
/// Two `pump()` calls, not one, per push -- measured, not guessed. The
/// round 1 return left O3 and O4 red with the turn banner one push behind
/// controller.room itself: a direct read of `controller.room!.turn!.seat`
/// taken immediately after a single `await tester.pump()` already showed
/// the correct seat while the rendered `game-screen-turn-banner` still
/// named the previous one, on some pushes and not others (verified by
/// instrumenting every push in this file with that direct read before
/// this fix, then removing the instrumentation once the cause was found).
/// That rules out both a stuck resync (`controller.hasDesynced` read false
/// at every one of those checks, and no `room` push ever answers a resync
/// in this file's own scenario for it to have recovered through) and a
/// reducer defect (the model was already right when the mismatch was
/// observed) -- what was missing was a second frame for GameScreen's own
/// `ChangeNotifier` listener to be rebuilt against state that a single
/// `pump()` had not yet painted. The order's own control had already ruled
/// out the fix being *more* pumping via `tester.runAsync(() =>
/// pumpEventQueue())` ahead of the existing single `pump()`; a second
/// plain `pump()` after it, with no event-queue draining involved, is the
/// one this file settled on because it is what the measurement above
/// showed was actually missing, and adding it makes every checkpoint in
/// this file agree with `controller.room` at the moment it is read, not
/// one push behind it.
class _ScenarioDriver {
  _ScenarioDriver(this._tester, this._transport);

  final WidgetTester _tester;
  final FakeTransport _transport;

  /// The fixture's initial `room` push is always seq 1.
  int _seq = 1;

  Future<void> _push(String type, Map<String, Object?> data) async {
    _seq += 1;
    _transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': _seq}),
    );
    await _tester.pump();
    await _tester.pump();
  }

  /// Order step 2: seat 2's socket goes quiet.
  Future<void> presenceSeat2({required bool connected}) =>
      _push('presence', <String, Object?>{'seat': 2, 'connected': connected});

  /// Order step 3: seat 1 plays an ordinary roll-then-move turn (value 6,
  /// two legal tokens so the local screen's own unique-legal hold is
  /// irrelevant even if it were seat 0's turn) and hands the turn to seat
  /// 2, which is where step 3 says the sequence must land.
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

  /// Order step 4: the expiry sweep rolls and moves for seat 2 -- the move
  /// nobody on this screen requested -- then hands the turn to seat 3.
  /// `legal: [0]` mirrors docs/RULES.md rule 15's "exactly one legal move"
  /// branch; seat 2's one on-board token (progress 0, from the fixture)
  /// is the only one a roll of 4 can move.
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

  /// Past order step 5: seat 3 plays its own ordinary turn and hands the
  /// turn back to seat 0, closing the circuit so O4's "is offered it when
  /// the turn does reach seat 0" is checked against an actual reach.
  Future<void> seat3RollsAndMovesIntoSeat0Turn() async {
    await _push('rolled', <String, Object?>{
      'seat': 3,
      'value': 6,
      'legal': <int>[0, 1],
      'deadline_ms': 45000,
      'k': 3,
      'reveal': 'c' * 64,
    });
    await _push('moved', <String, Object?>{
      'seat': 3,
      'token': 0,
      'from': -1,
      'to': 20,
      'captured': <Object?>[],
      'extra_roll': false,
    });
    await _push('turn', <String, Object?>{'seat': 0, 'deadline_ms': 45000});
  }
}

void main() {
  // ==========================================================================
  // O1: the fixture check that makes O2 meaningful.
  // ==========================================================================
  testWidgets(
    'O1: after presence {seat: 2, connected: false} at a contiguous seq, '
    "controller.room!.seats[2].connected is false",
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      expect(
        controller.room!.seats[2].connected,
        isTrue,
        reason:
            'fixture is broken: seat 2 must start connected, per the '
            "order's step 1",
      );

      await _ScenarioDriver(tester, transport).presenceSeat2(connected: false);

      expect(
        controller.room!.seats[2].connected,
        isFalse,
        reason:
            'O1: room_controller.dart\'s _reducePresence must have set '
            'seat 2\'s connected to false; if this is not false, every '
            'later case in this file is measuring nothing, because they '
            'all assume the controller itself already knows seat 2 '
            'dropped',
      );
    },
  );

  // ==========================================================================
  // O2: what the screen shows about a disconnected seat -- measured, not
  // assumed.
  // ==========================================================================
  testWidgets('O2: pushing presence {seat: 2, connected: false} changes nothing '
      'GameScreen renders -- it shows a disconnected opponent identically '
      'to a connected one, because game_screen.dart never reads '
      'SeatState.connected anywhere (see this file\'s header comment for '
      'the grep that confirmed it)', (tester) async {
    final (controller, transport, _) = await _connectFourSeatGame(
      tester,
      initialTurnSeat: 1,
    );
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    expect(
      find.byKey(_boardKey),
      findsOneWidget,
      reason: 'fixture is broken: the board must be showing before the drop',
    );

    final List<String?> textsBefore = _gameScreenTexts(tester);
    final LudoBoard boardBefore = tester.widget<LudoBoard>(
      find.byKey(_boardKey),
    );
    final Map<int, List<int>> tokensBefore = Map<int, List<int>>.from(
      boardBefore.tokens,
    );
    final List<int> seatsInPlayBefore = List<int>.from(boardBefore.seatsInPlay);
    final bool rollEnabledBefore = _buttonEnabled(tester, _rollKey);
    final List<bool> tokenButtonsBefore = <bool>[
      for (int i = 0; i < 4; i++) _buttonEnabled(tester, _tokenButtonKey(i)),
    ];

    await _ScenarioDriver(tester, transport).presenceSeat2(connected: false);
    expect(
      controller.room!.seats[2].connected,
      isFalse,
      reason:
          'fixture is broken: seat 2 must have dropped for O2 to mean anything',
    );

    final List<String?> textsAfter = _gameScreenTexts(tester);
    expect(
      textsAfter,
      textsBefore,
      reason:
          'O2: the master\'s reading is that game_screen.dart renders a '
          'disconnected opponent identically to a connected one, which '
          'this asserts directly: every Text under GameScreen must read '
          'exactly the same before and after seat 2 drops. Before: '
          '$textsBefore. After: $textsAfter. If these differ, some '
          'widget does distinguish connected from disconnected and the '
          "master's grep was wrong -- say which widget and how, because "
          'that overturns this comment, not just this assertion',
    );

    final LudoBoard boardAfter = tester.widget<LudoBoard>(
      find.byKey(_boardKey),
    );
    for (final int seat in seatsInPlayBefore) {
      expect(
        boardAfter.tokens[seat],
        tokensBefore[seat],
        reason:
            'O2: seat $seat\'s tokens on the board must be unaffected by '
            'seat 2\'s presence flipping',
      );
    }
    expect(
      boardAfter.seatsInPlay,
      seatsInPlayBefore,
      reason: 'O2: which seats the board draws must be unaffected by presence',
    );
    expect(
      _buttonEnabled(tester, _rollKey),
      rollEnabledBefore,
      reason:
          'O2: the roll button\'s enabled state must be unaffected by presence',
    );
    for (int i = 0; i < 4; i++) {
      expect(
        _buttonEnabled(tester, _tokenButtonKey(i)),
        tokenButtonsBefore[i],
        reason:
            'O2: token button $i\'s enabled state must be unaffected by presence',
      );
    }

    // This is the current, honestly-stated contract: GameScreen carries
    // no presence affordance at all, so a player watching the countdown
    // run down on seat 2 is given no visual reason for it. Revisit this
    // whole test the day a presence affordance is added to
    // game_screen.dart -- at that point every assertion above should
    // start failing, on purpose, and should be replaced with assertions
    // on whatever that affordance is.
  });

  // ==========================================================================
  // O3: the swept move lands, the turn and the countdown move to seat 3.
  // ==========================================================================
  testWidgets(
    "O3: the expiry sweep's moved frame for seat 2 renders on the board at "
    'its new square, and the turn banner and countdown move to seat 3',
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
        controller.room!.turn!.seat,
        3,
        reason:
            'fixture is broken: the final turn frame in this sequence '
            'names seat 3; it must have landed',
      );
      expect(
        controller.room!.seats[2].tokens[0],
        4,
        reason:
            'fixture is broken: the sweep\'s moved frame (from: 0, to: 4) '
            'must have put seat 2\'s token 0 at progress 4',
      );

      final SemanticsHandle handle = tester.ensureSemantics();
      final BoardCell expectedCell = cellFor(
        seat: 2,
        progress: 4,
        tokenIndex: 0,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('token-2-0')),
          matching: find.bySemanticsIdentifier(
            'cell-${expectedCell.col}-${expectedCell.row}',
          ),
          matchRoot: true,
        ),
        findsOneWidget,
        reason:
            'O3: token-2-0, the token nobody on this screen requested, '
            'must render at cellFor(seat: 2, progress: 4, tokenIndex: 0) '
            '(cell-${expectedCell.col}-${expectedCell.row}); an '
            'incremental reducer that dropped the sweep\'s moved delta '
            'would leave it at its old cell (cell-${cellFor(seat: 2, progress: 0, tokenIndex: 0).col}-${cellFor(seat: 2, progress: 0, tokenIndex: 0).row}) instead',
      );
      // Disposed explicitly, in the body, not left to addTearDown: the
      // binding's end-of-test checks run before addTearDown callbacks, so
      // a handle only ever released there is still open when that check
      // runs and fails the test on a handle this case itself no longer
      // needs (test/board_test.dart's own semantics cases use the same
      // idiom).
      handle.dispose();

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final Text banner = tester.widget<Text>(find.byKey(_bannerKey));
      expect(
        banner.data,
        loc.gameWaitingForPlayer('Dee'),
        reason:
            'O3: the turn banner must name seat 3 (Dee) once the turn '
            'frame naming seat 3 has landed; got "${banner.data}", '
            'expected "${loc.gameWaitingForPlayer('Dee')}"',
      );
      final Text countdown = tester.widget<Text>(find.byKey(_countdownKey));
      expect(
        countdown.data,
        loc.gameTurnCountdown(45),
        reason:
            'O3: seat 3\'s turn frame carries a fresh deadline_ms of '
            '45000; because the seat half of the (seat, deadlineMs) pair '
            'changed (seat 2 to seat 3) this must have restarted the '
            'countdown at 45 seconds, not left seat 2\'s stale reading '
            'in place; got "${countdown.data}"',
      );
      expect(
        _buttonEnabled(tester, _rollKey),
        isFalse,
        reason:
            'O3: with the turn at seat 3, seat 0\'s roll button must stay '
            'disabled',
      );
    },
  );

  // ==========================================================================
  // O4: the local seat is offered the roll affordance exactly when the
  // turn is its own, checked after every single frame of the sequence.
  // ==========================================================================
  testWidgets(
    'O4: seat 0 is never offered the roll affordance for a turn that is '
    'not its own, and is offered it once the turn reaches seat 0 -- '
    'checked after every frame of the whole drop-sweep-return-and-back '
    'sequence',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      int seq = 1;
      Future<void> pushAndCheck(
        String type,
        Map<String, Object?> data,
        String checkpoint,
      ) async {
        seq += 1;
        transport.pushText(
          _frame(type: type, data: <String, Object?>{...data, 'seq': seq}),
        );
        // Two pumps, not one -- see _ScenarioDriver's doc comment above
        // for the measurement that found a single pump leaves
        // game-screen-roll-button one push behind controller.room.
        await tester.pump();
        await tester.pump();
        final TurnState turn = controller.room!.turn!;
        final bool expected =
            turn.seat == controller.seat && turn.phase == TurnPhase.awaitRoll;
        expect(
          _buttonEnabled(tester, _rollKey),
          expected,
          reason:
              'O4 after $checkpoint: controller.room!.turn is seat '
              '${turn.seat} phase ${turn.phase}, controller.seat is '
              '${controller.seat}, so game-screen-roll-button.onPressed '
              'must be ${expected ? "non-null (enabled)" : "null (disabled)"}',
        );
      }

      final TurnState initialTurn = controller.room!.turn!;
      expect(
        _buttonEnabled(tester, _rollKey),
        initialTurn.seat == controller.seat &&
            initialTurn.phase == TurnPhase.awaitRoll,
        reason:
            'O4 at fixture connect (turn seat ${initialTurn.seat}, phase '
            '${initialTurn.phase}, controller.seat ${controller.seat}): '
            'the roll button\'s initial enabled state must already match '
            'whose turn it is',
      );

      await pushAndCheck('presence', <String, Object?>{
        'seat': 2,
        'connected': false,
      }, 'step 2 (presence seat 2 false)');
      await pushAndCheck('rolled', <String, Object?>{
        'seat': 1,
        'value': 6,
        'legal': <int>[0, 1],
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'a' * 64,
      }, 'seat 1 rolled');
      await pushAndCheck('moved', <String, Object?>{
        'seat': 1,
        'token': 0,
        'from': -1,
        'to': 13,
        'captured': <Object?>[],
        'extra_roll': false,
      }, 'seat 1 moved');
      await pushAndCheck('turn', <String, Object?>{
        'seat': 2,
        'deadline_ms': 45000,
      }, 'turn passed to seat 2 (order step 3 complete)');
      await pushAndCheck('rolled', <String, Object?>{
        'seat': 2,
        'value': 4,
        'legal': <int>[0],
        'deadline_ms': 45000,
        'k': 2,
        'reveal': 'b' * 64,
      }, 'the expiry sweep rolled for seat 2');
      await pushAndCheck('moved', <String, Object?>{
        'seat': 2,
        'token': 0,
        'from': 0,
        'to': 4,
        'captured': <Object?>[],
        'extra_roll': false,
      }, 'the expiry sweep moved for seat 2');
      await pushAndCheck('turn', <String, Object?>{
        'seat': 3,
        'deadline_ms': 45000,
      }, 'turn passed to seat 3 (order step 4 complete)');
      await pushAndCheck('presence', <String, Object?>{
        'seat': 2,
        'connected': true,
      }, 'step 5 (presence seat 2 true)');
      await pushAndCheck('rolled', <String, Object?>{
        'seat': 3,
        'value': 6,
        'legal': <int>[0, 1],
        'deadline_ms': 45000,
        'k': 3,
        'reveal': 'c' * 64,
      }, 'seat 3 rolled');
      await pushAndCheck('moved', <String, Object?>{
        'seat': 3,
        'token': 0,
        'from': -1,
        'to': 20,
        'captured': <Object?>[],
        'extra_roll': false,
      }, 'seat 3 moved');
      await pushAndCheck('turn', <String, Object?>{
        'seat': 0,
        'deadline_ms': 45000,
      }, 'the turn has come full circle back to seat 0');
    },
  );

  // ==========================================================================
  // O5: seat 2 reads connected again, and the screen is exactly as
  // coherent as a controller that never saw the drop at all.
  // ==========================================================================
  testWidgets(
    'O5: once seat 2 returns, the controller reads it connected again, and '
    'GameScreen renders exactly what a controller told about the same '
    'final state directly -- with no drop ever mentioned -- renders too',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      // No addTearDown registration for this controller: it is disposed
      // explicitly below, once, the moment its job in this test is done.
      // Registering addTearDown as well would dispose it a second time
      // when tear-down runs, tripping
      // ChangeNotifier.debugAssertNotDisposed on a controller this body
      // already retired.
      await _mount(tester, controller);

      final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
      await driver.presenceSeat2(connected: false);
      await driver.seat1RollsAndMovesIntoSeat2Turn();
      await driver.expirySweepsSeat2IntoSeat3Turn();
      await driver.presenceSeat2(connected: true);

      expect(
        controller.room!.seats[2].connected,
        isTrue,
        reason:
            'O5: presence {seat: 2, connected: true} at a contiguous seq '
            'must flip seat 2 back to connected in the controller\'s own '
            'state',
      );

      // O2 found no rendered state at all that distinguishes a connected
      // seat from a disconnected one, so there is no stale "absent" cue
      // to check for here. What is checked instead is convergence: a
      // controller that actually lived through the drop and the return
      // must render identically to a controller whose one and only room
      // snapshot already encodes the same final state, seat 2 connected,
      // with no drop ever mentioned to it.
      final List<String?> scenarioTexts = _gameScreenTexts(tester);
      final LudoBoard scenarioBoard = tester.widget<LudoBoard>(
        find.byKey(_boardKey),
      );
      final Map<int, List<int>> scenarioTokens = Map<int, List<int>>.from(
        scenarioBoard.tokens,
      );
      final List<int> scenarioSeatsInPlay = List<int>.from(
        scenarioBoard.seatsInPlay,
      );
      final bool scenarioRollEnabled = _buttonEnabled(tester, _rollKey);
      // Explicit, not left to addTearDown alone: this controller's job in
      // this test is done and a second, independent controller is about
      // to be built and mounted in its place.
      controller.dispose();

      final (RoomController control, _, _) = await _connectRoomDirect(
        tester,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob', tokens: const <int>[13, -1, -1, -1]),
          _seatJson(2, name: 'Cy', tokens: const <int>[4, -1, -1, -1]),
          _seatJson(3, name: 'Dee'),
        ],
        turn: _turnJson(seat: 3, phase: 'await_roll', deadlineMs: 45000, k: 2),
      );
      addTearDown(control.dispose);
      await _mount(tester, control);

      expect(
        _gameScreenTexts(tester),
        scenarioTexts,
        reason:
            'O5: a controller that lived through the drop and the return '
            'must render the same text as a controller given the same '
            'final state directly with no drop ever mentioned; a '
            'difference here is stale state the drop-return sequence left '
            'behind. Scenario: $scenarioTexts',
      );
      final LudoBoard controlBoard = tester.widget<LudoBoard>(
        find.byKey(_boardKey),
      );
      for (final int seat in scenarioSeatsInPlay) {
        expect(
          controlBoard.tokens[seat],
          scenarioTokens[seat],
          reason:
              'O5: seat $seat\'s tokens after the drop-return sequence '
              'must match the converged control\'s tokens for that seat',
        );
      }
      expect(
        controlBoard.seatsInPlay,
        scenarioSeatsInPlay,
        reason:
            'O5: which seats the board draws must match the converged control',
      );
      expect(
        _buttonEnabled(tester, _rollKey),
        scenarioRollEnabled,
        reason:
            'O5: the roll button\'s enabled state after the drop-return '
            'sequence must match the converged control\'s',
      );
    },
  );

  // ==========================================================================
  // O6, a control, and it must pass.
  // ==========================================================================
  testWidgets(
    'O6 (control): the same rolled/moved/turn frames, with seat 2 never '
    'marked disconnected, produce the same board and the same turn '
    'progression O3 found',
    (tester) async {
      final (controller, transport, _) = await _connectFourSeatGame(
        tester,
        initialTurnSeat: 1,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final _ScenarioDriver driver = _ScenarioDriver(tester, transport);
      // No presence frame at all: seat 2 is never told to be disconnected.
      await driver.seat1RollsAndMovesIntoSeat2Turn();
      await driver.expirySweepsSeat2IntoSeat3Turn();

      expect(
        controller.room!.seats[2].connected,
        isTrue,
        reason: 'fixture is broken: this control never drops seat 2',
      );
      expect(
        controller.room!.turn!.seat,
        3,
        reason:
            'O6: the turn must reach seat 3 the same way O3 found, even '
            'with no presence frame ever pushed; a red O6 means this '
            'file\'s rig is not reaching the behaviour it claims to test, '
            'not that the disconnect path is broken',
      );
      expect(
        controller.room!.seats[2].tokens[0],
        4,
        reason:
            'O6: seat 2\'s own move must put token 0 at progress 4, same '
            'as O3\'s swept move, whether or not seat 2 was ever marked '
            'disconnected',
      );

      final SemanticsHandle handle = tester.ensureSemantics();
      final BoardCell expectedCell = cellFor(
        seat: 2,
        progress: 4,
        tokenIndex: 0,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('token-2-0')),
          matching: find.bySemanticsIdentifier(
            'cell-${expectedCell.col}-${expectedCell.row}',
          ),
          matchRoot: true,
        ),
        findsOneWidget,
        reason:
            'O6: without any disconnect, seat 2\'s own turn still lands '
            'token-2-0 at the same cell O3 found; if this is not found '
            'the rig itself, not the disconnect path, is broken',
      );
      // Disposed explicitly, in the body, not left to addTearDown: the
      // binding's end-of-test checks run before addTearDown callbacks, so
      // a handle only ever released there is still open when that check
      // runs and fails the test on a handle this case itself no longer
      // needs (test/board_test.dart's own semantics cases use the same
      // idiom).
      handle.dispose();
      expect(
        _buttonEnabled(tester, _rollKey),
        isFalse,
        reason:
            'O6: with the turn at seat 3, seat 0\'s roll button must stay '
            'disabled, same as O3',
      );
    },
  );
}
