// Order 162: proves the third term of _syncCountdown's restart memo
// (lib/src/game_screen.dart:258-260 -- `turn.seat == _countdownSeat &&
// turn.deadlineMs == _countdownDeadlineMs && turn.k == _countdownK`) is what
// makes the on-screen countdown restart when a seat already on turn earns
// another roll.
//
// The mechanism this file measures, read from the source before a line of
// this file was written:
//
//   - net/room_controller.dart:689-717 (_reduceTurn), the reducer for the
//     `turn` push: line 710 builds the fresh turn with `k: room.turn?.k ??
//     0` -- it carries the previous turn's `k` forward rather than reading
//     one off the wire.
//   - packages/ludo_server/lib/src/snapshot.dart:235-241 (buildTurn), the
//     server's own encoder for that push: the payload is exactly `{seat,
//     deadline_ms, seq}`. There is no `k` key on the wire for this frame at
//     all, which is why the client has nothing to read one from and falls
//     back to carrying the old value forward.
//
// So when the seat already on turn earns an extra roll (a six or the
// capture bonus, both pinned on by _roomJson's default rules below), the
// server's `turn` push for that same seat carries a fresh `deadline_ms` and
// an unchanged `k`. `deadlineMs` is the only field of the three-term memo
// that ever differs on that path, and it is therefore the only reason
// _syncCountdown treats that push as a new segment rather than a repeat.
//
// net/room_controller.dart:841-855 (_reduceMoved) and :864-897
// (_reduceTurnPassed) both carry `seat`, `deadlineMs` and `k` forward
// unchanged from `room.turn`, by contrast -- X3 and X4 below are the other
// half of the memo's job, proving those two pushes must never restart the
// countdown.
//
// Driven the way game_screen_countdown_test.dart (the countdown assertion
// template) and composed_play_test.dart (contiguous multi-frame delivery on
// one live socket) already are: a real RoomController over a real
// FakeTransport (test/net/fake_transport.dart, read-only), every state
// reached by pushing a real wire frame and never by touching controller
// internals, the countdown read off the game-screen-turn-countdown key as
// rendered text. Every pushed frame carries `room.seq + 1`, checked after
// each push, per net/room_controller.dart's own gap check
// (`seqValue != room.seq + 1` begins a resync) -- a scenario that silently
// resynced would stop being the scenario its comments claim.
//
// Standing traps this file avoids, each one paid for on this project before:
//   - no bare `pumpEventQueue()` inside a testWidgets body (used only inside
//     `tester.runAsync`, exactly as the countdown template uses it);
//   - no `pumpAndSettle` anywhere near a live countdown timer;
//   - every controller this file creates is disposed inside its own test
//     body, never only through `addTearDown`;
//   - this file installs no `FlutterError.onError` handler at all.

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
  return 'extra-roll-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring game_screen_countdown_test.dart --------

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
// game_screen_countdown_test.dart ----------------------------------------

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
  // capture_bonus and the default 45-second turn clock are the two "pinned
  // default rules" order 162's own text names as the ways a seat already on
  // turn earns another roll.
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
// mirroring game_screen_countdown_test.dart's _connectPlaying ------------

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
  // pumpEventQueue() alone relies on real Timers via Future.delayed, which
  // never fire under the fake-async clock a testWidgets body runs in, and
  // hangs forever with no diagnostic. tester.runAsync() steps outside the
  // fake zone for the duration of the call so the real event loop actually
  // advances, then tester.pump() brings the widget tree's own state back in
  // sync with what that unblocked. Neither step advances the fake clock the
  // countdown itself is measured against below.
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

// --- widget harness, mirroring game_screen_countdown_test.dart's own ------

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

const Key _countdownKey = Key('game-screen-turn-countdown');

/// Reads whatever whole-second number the widget at [key] is showing,
/// without assuming its exact template, copied from
/// game_screen_countdown_test.dart's own helper of the same name.
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

/// One push of a wire frame followed by the standard two-pump delivery
/// idiom: FakeTransport delivers through a StreamController, which
/// schedules delivery as a microtask rather than resolving inline. The
/// first pump flushes that microtask, running the reducer and calling
/// setState, which schedules a frame too late for that same pump to draw;
/// the second pump draws it. No Duration is passed to either pump, so
/// neither call advances the fake clock the countdown timer is measured
/// against -- game_screen_countdown_test.dart's P9 uses the identical
/// two-pump idiom for the identical reason, cited in its own comment there.
Future<void> _pushAndDeliver(
  WidgetTester tester,
  FakeTransport transport,
  String frame,
) async {
  transport.pushText(frame);
  await tester.pump();
  await tester.pump();
}

void main() {
  final List<Map<String, Object?>> twoSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];

  // ==========================================================================
  // X1: the fresh segment restarts the countdown.
  // ==========================================================================
  //
  // The trap this case must not fall into (order 162's own words): if every
  // deadline_ms in the scenario were 45000, the case would pass even with
  // the deadlineMs term deleted from the memo. Here is why, worked through
  // both ways:
  //
  //   If `rolled` also carried deadline_ms 45000, the k term alone (0 -> 1)
  //   would already force a restart at the `rolled` push, under a correct
  //   memo and under a (seat, k)-only memo alike -- both would reset the
  //   display to 45 right there. `moved` then carries deadlineMs, k and seat
  //   unchanged (room_controller.dart:839-850) so neither memo restarts on
  //   it, and the display is still 45 when it reaches the final `turn`
  //   push. At that push, deadlineMs is unchanged too (45000 == 45000), so
  //   even the *correct*, full three-term memo would not restart there --
  //   the display already reads 45, coincidentally, from the earlier k-driven
  //   restart, not from anything the final push did. A reader could not tell
  //   a genuine restart from a display that was simply never disturbed.
  //
  //   Below, `rolled` instead carries deadline_ms 12000 -- distinct from the
  //   pre-roll 45000 and from the fresh segment's own 45000, and short
  //   enough that no further pumped time is needed to tell 12 apart from 45.
  //   This still restarts at `rolled` (k changed there too, 0 -> 1) and
  //   resets the display to 12; `moved` still changes nothing. But now the
  //   final `turn` push's deadlineMs (45000) genuinely differs from what the
  //   memo last recorded (12000), while seat (0) and k (1, carried forward
  //   at room_controller.dart:710) do not. A three-term memo restarts on
  //   that difference and the display becomes 45. A memo missing the
  //   deadlineMs term sees seat and k both unchanged and does not restart --
  //   the display would stay frozen at 12, since no fake seconds are pumped
  //   during the delivery of any of these three frames. 45 and 12 are far
  //   enough apart that this case cannot pass by accident either way.
  testWidgets(
    'X1: seat 0 already on turn, a six delivered as rolled/moved/turn, '
    'renders the fresh segment\'s full 45 seconds, not the value carried '
    'down from before it',
    (tester) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
        seq: 1,
      );
      await _mount(tester, controller);
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        45,
        reason:
            'X1: fixture is broken: deadline_ms 45000 with no fake time '
            'pumped yet must show 45, per game_screen.dart:271-273 '
            '((deadlineMs + 999) ~/ 1000)',
      );

      // Pump 10 seconds so the countdown has visibly moved off its starting
      // value before the extra-roll sequence runs -- 10 is used because it
      // is small next to the 12-second segment `rolled` is about to open
      // below (so the pre-roll segment's own countdown state is clearly
      // distinguishable from the mid-scenario value) and large enough that
      // "did it move at all" cannot be mistaken for rounding noise.
      await tester.pump(const Duration(seconds: 10));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        35,
        reason:
            'X1: fixture is broken: 10 pumped seconds against a 45000ms '
            'deadline must read 35 (45 - 10), per the once-a-second '
            'decrement at game_screen.dart:289-292',
      );

      // rolled: seat 0 rolls a six. deadline_ms 12000 is deliberately not
      // 45000 -- see the case header comment above for why that distinction
      // is the whole point. k moves 0 -> 1, matching docs/PROTOCOL.md
      // section 6's "rolls made so far".
      await _pushAndDeliver(
        tester,
        transport,
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
            'legal': <int>[0],
            'deadline_ms': 12000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 2,
          },
        ),
      );
      expect(
        controller.room!.turn,
        isNotNull,
        reason: 'X1: fixture is broken: the rolled push must not clear turn',
      );
      expect(
        (
          controller.room!.turn!.seat,
          controller.room!.turn!.deadlineMs,
          controller.room!.turn!.k,
        ),
        (0, 12000, 1),
        reason:
            'X1: fixture is broken: _reduceRolled (room_controller.dart:'
            '723-763) must set turn to exactly (seat 0, deadlineMs 12000, '
            'k 1) off this frame\'s own seat/deadline_ms/k fields',
      );
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        12,
        reason:
            'X1: fixture is broken: after rolled sets deadline_ms 12000, '
            'game-screen-turn-countdown must read 12 -- both the k change '
            '(0 -> 1) and the deadlineMs change (45000 -> 12000) restart '
            'the countdown here regardless of which memo is running, so '
            'this sample is a sanity check on the fixture, not yet the '
            'case\'s own assertion',
      );

      // moved: seat 0 moves the rolled token, with an extra roll because a
      // six was rolled. _reduceMoved (room_controller.dart:839-850) carries
      // seat, deadlineMs and k all forward unchanged from the turn rolled
      // just produced.
      await _pushAndDeliver(
        tester,
        transport,
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': -1,
            'to': 0,
            'captured': <Object?>[],
            'extra_roll': true,
            'seq': 3,
          },
        ),
      );
      expect(
        (
          controller.room!.turn!.seat,
          controller.room!.turn!.deadlineMs,
          controller.room!.turn!.k,
        ),
        (0, 12000, 1),
        reason:
            'X1: fixture is broken: moved must carry (seat 0, deadlineMs '
            '12000, k 1) forward unchanged, per room_controller.dart:'
            '839-850',
      );
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        12,
        reason:
            'X1: fixture is broken: moved changes none of the three memo '
            'terms, so game-screen-turn-countdown must still read 12 '
            'here -- proved directly as its own case in X3 below',
      );

      // turn: the extra roll itself. Same seat (0), a fresh deadline_ms
      // (45000, the full segment the "pinned default rules" turn_seconds:
      // 45 always opens a segment with), and no k on the wire at all --
      // packages/ludo_server/lib/src/snapshot.dart:235-241's buildTurn
      // payload is exactly {seat, deadline_ms, seq}.
      final int nextSeq = controller.room!.seq + 1;
      expect(
        nextSeq,
        4,
        reason:
            'X1: fixture is broken: three frames delivered from seq 1 '
            'must leave room.seq at 3, so the next contiguous seq is 4',
      );
      await _pushAndDeliver(
        tester,
        transport,
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 0,
            'deadline_ms': 45000,
            'seq': nextSeq,
          },
        ),
      );
      expect(
        controller.room!.turn!.k,
        1,
        reason:
            'X1: fixture is broken: _reduceTurn (room_controller.dart:710) '
            'must carry k forward as `room.turn?.k ?? 0`, i.e. 1, since '
            'this turn frame carries no k of its own at all',
      );

      final int shownAfterFreshSegment = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownAfterFreshSegment,
        45,
        reason:
            'X1: the fresh segment\'s own deadline_ms is 45000, so '
            'game-screen-turn-countdown must read 45 -- the whole-seconds '
            'formula at game_screen.dart:271-273 applied to a countdown '
            'that restarted at game_screen.dart:264-267. Got '
            '$shownAfterFreshSegment. A memo missing the deadlineMs term '
            '(game_screen.dart:258-260) would see seat 0 == 0 and k 1 == 1, '
            'both unchanged from what moved left behind, decline to '
            'restart, and leave the display frozen at 12 -- reproduced with '
            'the sequence: connect seat 0 deadlineMs 45000 k 0, pump 10s, '
            'push rolled deadline_ms 12000 k 1, push moved, push turn seat '
            '0 deadline_ms 45000',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // X2: the same fresh-segment restart, with k held constant and proved.
  // ==========================================================================
  //
  // X1's strength depends on turn.k genuinely not changing across the final
  // `turn` push. This case drives the identical sequence and asserts that
  // directly off the controller's own public snapshot, in addition to
  // repeating X1's restart assertion so this case stands on its own.
  testWidgets('X2: across the fresh-segment turn push, turn.k is the same integer '
      'before and after, and the countdown still restarts to the fresh '
      'segment\'s full 45 seconds', (tester) async {
    final (controller, transport) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      seq: 1,
    );
    await _mount(tester, controller);

    await tester.pump(const Duration(seconds: 10));

    await _pushAndDeliver(
      tester,
      transport,
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 6,
          'legal': <int>[0],
          'deadline_ms': 12000,
          'k': 1,
          'reveal': 'b' * 64,
          'seq': 2,
        },
      ),
    );

    await _pushAndDeliver(
      tester,
      transport,
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': -1,
          'to': 0,
          'captured': <Object?>[],
          'extra_roll': true,
          'seq': 3,
        },
      ),
    );

    final int kBeforeTurnFrame = controller.room!.turn!.k;
    expect(
      kBeforeTurnFrame,
      1,
      reason:
          'X2: fixture is broken: after rolled (k: 1) and moved (which '
          'carries k forward unchanged, room_controller.dart:846), '
          'turn.k must be 1 immediately before the fresh-segment turn '
          'push is sent',
    );

    final int nextSeq = controller.room!.seq + 1;
    await _pushAndDeliver(
      tester,
      transport,
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': 0,
          'deadline_ms': 45000,
          'seq': nextSeq,
        },
      ),
    );

    final int kAfterTurnFrame = controller.room!.turn!.k;
    expect(
      kAfterTurnFrame,
      kBeforeTurnFrame,
      reason:
          'X2: turn.k must be the exact same integer before ($kBeforeTurnFrame) '
          'and after ($kAfterTurnFrame) the turn frame that opens the extra '
          'roll -- the server\'s turn push carries no k at all '
          '(packages/ludo_server/lib/src/snapshot.dart:235-241) and '
          '_reduceTurn falls back to `room.turn?.k ?? 0` '
          '(room_controller.dart:710), which is a straight carry-forward, '
          'not a fresh value. If this ever differs, order 162\'s reading '
          'of _reduceTurn is wrong and the whole order needs '
          're-examining, not just this case',
    );
    expect(
      kAfterTurnFrame,
      1,
      reason:
          'X2: fixture is broken: the carried-forward k must specifically '
          'be 1, matching what rolled set it to',
    );

    expect(
      _wholeSecondsShown(tester, _countdownKey),
      45,
      reason:
          'X2: with turn.k proved unchanged across the turn push above, '
          'the countdown restarting to 45 here cannot be credited to the '
          'k term of the memo (game_screen.dart:258-260) -- only the '
          'deadlineMs term (45000, fresh, vs 12000 previously recorded) '
          'differs, so this restart is the deadlineMs term\'s doing alone',
    );

    controller.dispose();
  });

  // ==========================================================================
  // X3: moved alone does not restart the countdown.
  // ==========================================================================
  testWidgets(
    'X3: a moved push that carries seat, deadlineMs and k all forward '
    'unchanged leaves the countdown running down, it does not jump back '
    'to the segment\'s full length',
    (tester) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 20000,
          k: 2,
          value: 3,
          legal: <int>[1],
        ),
        seq: 1,
      );
      await _mount(tester, controller);
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        20,
        reason:
            'X3: fixture is broken: deadline_ms 20000 with no fake time '
            'pumped yet must show 20',
      );

      // 8 seconds: enough to be unambiguously different from both 20 (the
      // segment\'s full length) and 0 (the clamp), so a countdown that
      // wrongly reset to 20 or clamped to 0 on the moved push below is
      // equally visible.
      await tester.pump(const Duration(seconds: 8));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        12,
        reason:
            'X3: fixture is broken: 8 pumped seconds against a 20000ms '
            'deadline must read 12 (20 - 8)',
      );

      final int nextSeq = controller.room!.seq + 1;
      await _pushAndDeliver(
        tester,
        transport,
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 1,
            'from': -1,
            'to': 0,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': nextSeq,
          },
        ),
      );
      expect(
        (
          controller.room!.turn!.seat,
          controller.room!.turn!.deadlineMs,
          controller.room!.turn!.k,
        ),
        (0, 20000, 2),
        reason:
            'X3: fixture is broken: moved must carry (seat 0, deadlineMs '
            '20000, k 2) forward unchanged, per room_controller.dart:'
            '839-850',
      );

      final int shownRightAfterMoved = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownRightAfterMoved,
        12,
        reason:
            'X3: moved changes none of the three memo terms '
            '(game_screen.dart:258-260), so game-screen-turn-countdown must '
            'still read 12 right after it lands, not reset to 20. Got '
            '$shownRightAfterMoved',
      );

      // Confirm it is still the same live timer counting down, not merely
      // a display frozen at 12 by coincidence: one further pumped second
      // must take it to 11.
      await tester.pump(const Duration(seconds: 1));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        11,
        reason:
            'X3: one further pumped second after moved must read 11 (12 - '
            '1), proving the same timer kept counting down rather than '
            'being reset or replaced by the moved push',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // X4: turn_passed alone does not restart the countdown.
  // ==========================================================================
  testWidgets(
    'X4: a turn_passed push with a valid reason carries seat, deadlineMs '
    'and k all forward unchanged and does not restart the countdown',
    (tester) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 30000,
          k: 3,
          value: 1,
          legal: <int>[],
        ),
        seq: 1,
      );
      await _mount(tester, controller);
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        30,
        reason:
            'X4: fixture is broken: deadline_ms 30000 with no fake time '
            'pumped yet must show 30',
      );

      await tester.pump(const Duration(seconds: 5));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        25,
        reason:
            'X4: fixture is broken: 5 pumped seconds against a 30000ms '
            'deadline must read 25 (30 - 5)',
      );

      final int nextSeq = controller.room!.seq + 1;
      await _pushAndDeliver(
        tester,
        transport,
        _frame(
          type: 'turn_passed',
          data: <String, Object?>{
            'seat': 0,
            'reason': 'no_legal_move',
            'seq': nextSeq,
          },
        ),
      );
      expect(
        (
          controller.room!.turn!.seat,
          controller.room!.turn!.deadlineMs,
          controller.room!.turn!.k,
        ),
        (0, 30000, 3),
        reason:
            'X4: fixture is broken: turn_passed must carry (seat 0, '
            'deadlineMs 30000, k 3) forward unchanged, per '
            'room_controller.dart:882-893',
      );

      final int shownRightAfterTurnPassed = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownRightAfterTurnPassed,
        25,
        reason:
            'X4: turn_passed changes none of the three memo terms '
            '(game_screen.dart:258-260), so game-screen-turn-countdown '
            'must still read 25 right after it lands, not reset to 30. '
            'Got $shownRightAfterTurnPassed',
      );

      await tester.pump(const Duration(seconds: 1));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        24,
        reason:
            'X4: one further pumped second after turn_passed must read 24 '
            '(25 - 1), proving the same timer kept counting down rather '
            'than being reset or replaced by the turn_passed push',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // X5 (control): a turn handed to a different seat restarts the countdown.
  // ==========================================================================
  testWidgets('X5 (control): a turn push naming a different seat, with a fresh '
      'deadline_ms, restarts the countdown -- if this ever fails, something '
      'far more basic than the extra-roll path is broken', (tester) async {
    final (controller, transport) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      seq: 1,
    );
    await _mount(tester, controller);
    expect(
      _wholeSecondsShown(tester, _countdownKey),
      45,
      reason:
          'X5: fixture is broken: deadline_ms 45000 with no fake time '
          'pumped yet must show 45',
    );

    await tester.pump(const Duration(seconds: 20));
    expect(
      _wholeSecondsShown(tester, _countdownKey),
      25,
      reason:
          'X5: fixture is broken: 20 pumped seconds against a '
          '45000ms deadline must read 25 (45 - 20)',
    );

    final int nextSeq = controller.room!.seq + 1;
    await _pushAndDeliver(
      tester,
      transport,
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': 0,
          'deadline_ms': 30000,
          'seq': nextSeq,
        },
      ),
    );
    expect(
      controller.room!.turn!.seat,
      0,
      reason:
          'X5: fixture is broken: the pushed turn frame must have moved '
          'the turn to seat 0',
    );

    expect(
      _wholeSecondsShown(tester, _countdownKey),
      30,
      reason:
          'X5: a turn push naming a different seat (1 -> 0) with a fresh '
          'deadline_ms (45000 -> 30000) must restart the countdown to the '
          'fresh segment\'s own length, 30 -- the seat term of the memo '
          '(game_screen.dart:258-260) is never in question in this order, '
          'so this control must pass regardless of what happens to the '
          'deadlineMs term elsewhere in this file',
    );

    controller.dispose();
  });
}
