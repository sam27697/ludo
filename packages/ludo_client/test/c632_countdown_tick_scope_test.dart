// C-632 (order 632t): the 1 s countdown tick rebuilds and repaints only the
// countdown.
//
// Contract (D1-D5 of order 632). The remaining whole seconds live in a
// notifier owned by the game screen's state. A tick from N > 1 to N - 1 sets
// it and does not call setState on the screen; only the block that shows the
// ring and the digits rebuilds, inside its own repaint boundary. The tick that
// reaches zero keeps today's behaviour: the screen rebuilds, because my time
// up (the die disabled, the late roll refused) flips on it. The (seat,
// deadlineMs, k) memo of _syncCountdown is untouched.
//
// The proof is a count, not a read of the source. The real GameScreen is
// mounted over a real RoomController on FakeTransport (the helpers in
// test/support, unchanged), put into each state, run for 200 ms and then
// pumped in 16 ms frames across five whole seconds so five ticks fire. A
// "tick frame" is a frame in which the digits under game-screen-turn-countdown
// changed. Two hooks are set around the counted pumps and nulled in a finally:
//
//   debugOnRebuildDirtyWidget  every Element.rebuild, counted by the widget's
//                              runtimeType;
//   debugOnProfilePaint        every paintChild entry, by render object. The
//                              RenderCustomPaint whose painter is a
//                              _BoardPainter getting an entry means the board
//                              base was re-recorded in that frame.
//
// Cases:
//   a. S1 watching and S2 my turn: in every tick frame no GameScreen element
//      is rebuilt, and at most 60 elements are rebuilt in total.
//   b. S1 and S2: in every tick frame the _BoardPainter is not painted, and
//      there are at most 40 paint entries.
//   c. S1 and S2: the countdown still counts, N, N-1 ... N-4 over the five
//      ticks, and the semantics label always equals gameTurnCountdown(n) for
//      the shown n.
//   d. S2 with a 3 s deadline: in the frame the hourglass replaces the digits
//      a GameScreen element is rebuilt, the die is disabled, and a tap on it
//      sends no roll and plays the invalid-tap cue. A control case shows the
//      same tap before zero does send the roll.
//   e. The memo: a frame repeating the same (seat, deadlineMs, k) mid
//      countdown does not restart the digits; a new k, a new deadline and a
//      new seat each do.
//
// There is no randomness: every scenario is a fixed frame script on the test
// binding's clock. The scenario name, the frames pushed and the per-tick
// numbers are in every failure message, which is the whole replay recipe:
//
//   flock /tmp/ludo-suite.lock timeout 900 \
//     flutter test test/c632_countdown_tick_scope_test.dart \
//     --plain-name "<the test name>"
//
// No pumpAndSettle anywhere: the hourglass at zero animates for good.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_die.dart' show GameDie;

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const Duration _frame = Duration(milliseconds: 16);
const Duration _warmUp = Duration(milliseconds: 200);
const Size _phone = Size(411, 891);

/// Frames of a counted run: 313 frames of 16 ms is 5008 ms.
const int _countedFrames = 313;

/// Ticks a counted run must see.
const int _ticksExpected = 5;

/// Most elements a tick frame may rebuild in total (base: 234-236).
const int _rebuildCeiling = 60;

/// Most paint entries a tick frame may have.
const int _paintCeiling = 40;

/// A deadline long enough that no counted tick reaches zero, and the last
/// seconds' warning (the last 10) is never entered either.
const int _longDeadlineMs = 30000;

const Key _digitsKey = Key('game-screen-turn-countdown');
const Key _semanticsKey = Key('game-header-countdown-semantics');

const Map<int, List<int>> _board = <int, List<int>>{
  0: <int>[10, 20, -1, -1],
  1: <int>[30, -1, -1, -1],
};

/// What one frame saw.
class _F {
  _F({
    required this.index,
    required this.ms,
    required this.before,
    required this.after,
    required this.rebuilt,
    required this.screenRebuilds,
    required this.entries,
    required this.board,
    required this.label,
  });

  final int index;
  final int ms;

  /// The digits before and after the frame's pump (null: not on screen).
  final int? before;
  final int? after;

  /// Elements rebuilt in the frame, and how many of them were a GameScreen.
  final int rebuilt;
  final int screenRebuilds;

  /// Paint entries in the frame, and whether the board base got one.
  final int entries;
  final bool board;

  /// The countdown semantics label after the frame (null: not on screen).
  final String? label;

  bool get tick => before != null && after != null && before != after;

  String get text =>
      'frame $index (${ms}ms) digits $before->$after, rebuilt $rebuilt, '
      'GameScreen rebuilds $screenRebuilds, paint entries $entries, '
      'board base painted $board';
}

String _table(List<_F> frames) =>
    frames.isEmpty ? '(none)' : frames.map((_F f) => f.text).join('; ');

bool _isBoardPainter(RenderObject ro) =>
    ro is RenderCustomPaint &&
    ro.painter.runtimeType.toString() == '_BoardPainter';

int? _digits(WidgetTester tester) {
  final Finder f = find.byKey(_digitsKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final String? data = tester.widget<Text>(f).data;
  final int? n = int.tryParse(data ?? '');
  if (n == null) {
    fail('the countdown digits "$data" are not a whole number');
  }
  return n;
}

String? _label(WidgetTester tester) {
  final Finder f = find.byKey(_semanticsKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Semantics>(f).properties.label;
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

bool _hourglassOnScreen() => find
    .byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == '_TimeUpHourglass',
    )
    .evaluate()
    .isNotEmpty;

/// Pumps up to [max] frames of 16 ms with both hooks set, nulling them in a
/// finally, and returns what every frame saw. [stopAfter] ends the run after
/// the frame it returns true for.
Future<List<_F>> _count(
  EndGame g,
  int max, {
  bool Function(_F f)? stopAfter,
  void Function(int index)? onFrame,
}) async {
  final WidgetTester tester = g.tester;
  g.s.steps.add('count up to $max frames of ${_frame.inMilliseconds}ms');
  final List<_F> out = <_F>[];
  int rebuilt = 0;
  int screen = 0;
  int entries = 0;
  bool board = false;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    rebuilt += 1;
    if (e.widget.runtimeType.toString() == 'GameScreen') {
      screen += 1;
    }
  };
  debugOnProfilePaint = (RenderObject ro) {
    entries += 1;
    if (_isBoardPainter(ro)) {
      board = true;
    }
  };
  try {
    for (int i = 0; i < max; i++) {
      rebuilt = 0;
      screen = 0;
      entries = 0;
      board = false;
      onFrame?.call(i);
      final int? before = _digits(tester);
      await tester.pump(_frame);
      g.s.clockMs += _frame.inMilliseconds;
      final _F f = _F(
        index: i,
        ms: g.s.clockMs,
        before: before,
        after: _digits(tester),
        rebuilt: rebuilt,
        screenRebuilds: screen,
        entries: entries,
        board: board,
        label: _label(tester),
      );
      out.add(f);
      if (stopAfter != null && stopAfter(f)) {
        break;
      }
    }
  } finally {
    debugOnRebuildDirtyWidget = null;
    debugOnProfilePaint = null;
  }
  return out;
}

/// Two seats (0 is mine, 1 is Bob), tokens on the board, seat [turnSeat] to
/// roll with a turn deadline of [deadlineMs].
Future<EndGame> _open(
  WidgetTester tester,
  String name, {
  required int turnSeat,
  required int deadlineMs,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = _phone;
  final List<Map<String, Object?>> seats = namedSeats(2, 0, tokens: _board);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: <String, Object?>{
      ...awaitRollTurn(turnSeat),
      'deadline_ms': deadlineMs,
    },
    seats: seats,
    mySeat: 0,
    gameId: 'c632-game-1',
  );
  await mountGame(tester, drive);
  final Scn s = Scn('$name, deadline_ms $deadlineMs', tester, drive);
  s.steps.add('turn seat $turnSeat await_roll deadline_ms $deadlineMs');
  return EndGame(s, 0, 2, seats);
}

enum _State { watching, myTurn }

String _stateName(_State s) => switch (s) {
  _State.watching => 'S1 watching',
  _State.myTurn => 'S2 my turn to roll',
};

/// Mounts the game, checks it is [state], and runs it for 200 ms more.
Future<EndGame> _reach(
  WidgetTester tester,
  _State state, {
  int deadlineMs = _longDeadlineMs,
}) async {
  final EndGame g = await _open(
    tester,
    _stateName(state),
    turnSeat: state == _State.watching ? 1 : 0,
    deadlineMs: deadlineMs,
  );
  await g.s.pump(const Duration(milliseconds: 500));
  expect(
    find.byKey(_digitsKey),
    findsOneWidget,
    reason: g.why('${_stateName(state)}: the turn countdown digits are shown'),
  );
  switch (state) {
    case _State.watching:
      expect(
        find.byKey(const Key('board-turn-yard-1')),
        findsOneWidget,
        reason: g.why('S1: board-turn-yard-1 (the glow on the other seat)'),
      );
    case _State.myTurn:
      expect(
        find.byKey(bigDieKey),
        findsOneWidget,
        reason: g.why('S2: game-die is on screen'),
      );
      expect(
        find.byKey(const Key('game-die-pulse')),
        findsOneWidget,
        reason: g.why('S2: game-die-pulse is on screen on my awaitRoll'),
      );
  }
  expect(
    find.byWidgetPredicate(
      (Widget w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_BoardPainter',
    ),
    findsOneWidget,
    reason: g.why(
      '${_stateName(state)}: a CustomPaint with a _BoardPainter is on screen '
      '(the board-base check below is not vacuous)',
    ),
  );
  await g.s.pump(_warmUp);
  return g;
}

/// A counted five-second run of [state]; checks it saw the five ticks, so a
/// case never passes on an empty list of tick frames.
Future<({EndGame g, List<_F> frames, List<_F> ticks})> _tickRun(
  WidgetTester tester,
  _State state,
) async {
  final EndGame g = await _reach(tester, state);
  final List<_F> frames = await _count(g, _countedFrames);
  final List<_F> ticks = <_F>[
    for (final _F f in frames)
      if (f.tick) f,
  ];
  expect(
    ticks.length,
    _ticksExpected,
    reason: g.why(
      '${_stateName(state)}: five whole seconds of 16 ms frames carry exactly '
      '$_ticksExpected ticks (a frame where the digits changed); saw '
      '${ticks.length}; ticks: ${_table(ticks)}',
    ),
  );
  return (g: g, frames: frames, ticks: ticks);
}

int _sentOfType(EndGame g, String type) => <String>[
  for (final String raw in g.s.drive.transport.sentRaw) frameType(raw),
].where((String t) => t == type).length;

bool _dieEnabled(WidgetTester tester) =>
    tester.widget<GameDie>(find.byType(GameDie)).enabled;

bool _digitsGaveWay(_F f) => f.before != null && f.after == null;

void main() {
  const List<_State> states = _State.values;

  group('a. a non-zero tick does not rebuild the game screen', () {
    for (final _State state in states) {
      testWidgets('${_stateName(state)}: no GameScreen element is rebuilt in a '
          'tick frame, and at most $_rebuildCeiling elements in total', (
        WidgetTester tester,
      ) async {
        final run = await _tickRun(tester, state);
        try {
          final List<_F> screen = <_F>[
            for (final _F f in run.ticks)
              if (f.screenRebuilds > 0) f,
          ];
          expect(
            screen,
            isEmpty,
            reason: run.g.why(
              '${_stateName(state)}: in every tick frame no GameScreen '
              'element is rebuilt (the tick must not call setState on the '
              'screen); GameScreen was rebuilt in ${screen.length} of '
              '${run.ticks.length} tick frames; per tick: '
              '${_table(run.ticks)}; fixed script, no seed',
            ),
          );
          final List<_F> heavy = <_F>[
            for (final _F f in run.ticks)
              if (f.rebuilt > _rebuildCeiling) f,
          ];
          expect(
            heavy,
            isEmpty,
            reason: run.g.why(
              '${_stateName(state)}: every tick frame rebuilds at most '
              '$_rebuildCeiling elements in total; ${heavy.length} of '
              '${run.ticks.length} tick frames rebuilt more; per tick: '
              '${_table(run.ticks)}; fixed script, no seed',
            ),
          );
        } finally {
          await run.g.done();
        }
      });
    }
  });

  group('b. a non-zero tick does not repaint the board', () {
    for (final _State state in states) {
      testWidgets('${_stateName(state)}: the _BoardPainter is not painted in '
          'a tick frame, and at most $_paintCeiling paint entries', (
        WidgetTester tester,
      ) async {
        final run = await _tickRun(tester, state);
        try {
          final List<_F> board = <_F>[
            for (final _F f in run.ticks)
              if (f.board) f,
          ];
          expect(
            board,
            isEmpty,
            reason: run.g.why(
              '${_stateName(state)}: in every tick frame the RenderCustomPaint '
              'of _BoardPainter is not painted; it was painted in '
              '${board.length} of ${run.ticks.length} tick frames; per tick: '
              '${_table(run.ticks)}; fixed script, no seed',
            ),
          );
          final List<_F> heavy = <_F>[
            for (final _F f in run.ticks)
              if (f.entries > _paintCeiling) f,
          ];
          expect(
            heavy,
            isEmpty,
            reason: run.g.why(
              '${_stateName(state)}: every tick frame has at most '
              '$_paintCeiling paint entries; ${heavy.length} of '
              '${run.ticks.length} tick frames had more; per tick: '
              '${_table(run.ticks)}; fixed script, no seed',
            ),
          );
        } finally {
          await run.g.done();
        }
      });
    }
  });

  group('c. the countdown still counts', () {
    for (final _State state in states) {
      testWidgets('${_stateName(state)}: the digits read N, N-1 ... N-4 and '
          'the semantics label follows them', (WidgetTester tester) async {
        final EndGame g = await _reach(tester, state);
        try {
          final AppLocalizations loc = _loc(tester);
          final int? start = _digits(tester);
          expect(
            start,
            isNotNull,
            reason: g.why('${_stateName(state)}: digits on screen at start'),
          );
          final int n = start!;
          final List<_F> frames = await _count(g, _countedFrames);
          final List<_F> ticks = <_F>[
            for (final _F f in frames)
              if (f.tick) f,
          ];
          expect(
            <int?>[for (final _F f in ticks) f.after],
            <int>[for (int i = 1; i <= _ticksExpected; i++) n - i],
            reason: g.why(
              '${_stateName(state)}: the digits read N-1 ... N-5 after the '
              'five ticks, N = $n read off the screen at the start (so '
              'N, N-1 ... N-4 are what the five seconds show); '
              'ticks: ${_table(ticks)}; fixed script, no seed',
            ),
          );
          final List<String> wrong = <String>[
            for (final _F f in frames)
              if (f.after != null && f.label != loc.gameTurnCountdown(f.after!))
                '${f.text} label "${f.label}" wanted '
                    '"${loc.gameTurnCountdown(f.after!)}"',
          ];
          expect(
            wrong,
            isEmpty,
            reason: g.why(
              '${_stateName(state)}: the game-header-countdown-semantics '
              'label equals gameTurnCountdown(n) for the shown n in every '
              'frame; ${wrong.length} frames differ: '
              '${wrong.take(5).join('; ')}; fixed script, no seed',
            ),
          );
          expect(
            _label(tester),
            loc.gameTurnCountdown(n - _ticksExpected),
            reason: g.why(
              '${_stateName(state)}: the label after the last tick names '
              '${n - _ticksExpected} seconds',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }
  });

  group('d. the zero tick still updates the screen', () {
    testWidgets('S2 my turn, deadline 3000: in the frame the hourglass '
        'replaces the digits a GameScreen element is rebuilt', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.myTurn, deadlineMs: 3000);
      try {
        expect(
          _dieEnabled(tester),
          isTrue,
          reason: g.why('S2 fixture: above zero the die is enabled'),
        );
        final List<_F> frames = await _count(g, 400, stopAfter: _digitsGaveWay);
        final _F zero = frames.last;
        expect(
          <Object?>[zero.before, zero.after, _hourglassOnScreen()],
          <Object?>[1, null, true],
          reason: g.why(
            'S2: the last counted frame is the one where the digits (at 1) '
            'give way to the hourglass; tick frames: '
            '${_table(<_F>[for (final _F f in frames)
              if (f.tick) f])}; '
            'last frame: ${zero.text}',
          ),
        );
        expect(
          zero.screenRebuilds,
          greaterThan(0),
          reason: g.why(
            'S2: in the frame the hourglass replaces the digits a GameScreen '
            'element is rebuilt (my time up flips: the die, the banner, the '
            'rings); GameScreen rebuilds in that frame: '
            '${zero.screenRebuilds}; the zero frame: ${zero.text}; '
            'fixed script, no seed',
          ),
        );
        expect(
          _dieEnabled(tester),
          isFalse,
          reason: g.why(
            'S2: after the zero frame GameDie.enabled is false (the roll is '
            'disabled at my time up); zero frame: ${zero.text}',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('S2 my turn, deadline 3000: after zero a tap on the die '
        'sends no roll and plays the invalid-tap cue', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.myTurn, deadlineMs: 3000);
      try {
        final List<_F> frames = await _count(g, 400, stopAfter: _digitsGaveWay);
        expect(
          frames.last.after,
          isNull,
          reason: g.why(
            'S2 fixture: the hourglass is up after ${frames.length} frames',
          ),
        );
        final int rollsBefore = _sentOfType(g, 'roll');
        final int invalidBefore = cueCount(
          g.s.drive.feedback,
          FeedbackCue.invalidTap,
        );
        await tester.tap(find.byKey(bigDieKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        g.s.clockMs += 100;
        expect(
          _sentOfType(g, 'roll') - rollsBefore,
          0,
          reason: g.why(
            'S2: a tap on the die at my time up sends no roll (rollEnabled '
            'is false once _myTimeUp is true); frames to zero: '
            '${frames.length}',
          ),
        );
        expect(
          cueCount(g.s.drive.feedback, FeedbackCue.invalidTap) - invalidBefore,
          1,
          reason: g.why('S2: the refused tap plays the invalid-tap cue once'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('S2 my turn, deadline 3000, control: a tap on the die '
        'before zero sends the roll', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.myTurn, deadlineMs: 3000);
      try {
        expect(
          _digits(tester),
          isNotNull,
          reason: g.why('control fixture: the digits are still up'),
        );
        final int rollsBefore = _sentOfType(g, 'roll');
        await tester.tap(find.byKey(bigDieKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        g.s.clockMs += 100;
        expect(
          _sentOfType(g, 'roll') - rollsBefore,
          1,
          reason: g.why(
            'control: before zero the same tap sends exactly one roll, so '
            'the no-roll case measures time up and not a dead tap',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('S2 my turn, deadline 3000: the hourglass stays, the digits '
        'never come back and the die stays disabled', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.myTurn, deadlineMs: 3000);
      try {
        await _count(g, 400, stopAfter: _digitsGaveWay);
        await g.s.pump(const Duration(milliseconds: 2500));
        expect(
          <Object?>[_digits(tester), _hourglassOnScreen(), _dieEnabled(tester)],
          <Object?>[null, true, false],
          reason: g.why(
            'S2: 2.5 s after zero there are no digits (no negative count), '
            'the hourglass is up and the die is disabled',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('S1 watching, deadline 3000: another seat\'s zero shows the '
        'hourglass and is not my time up', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.watching, deadlineMs: 3000);
      try {
        final List<_F> frames = await _count(g, 400, stopAfter: _digitsGaveWay);
        expect(
          <Object?>[frames.last.after, _hourglassOnScreen()],
          <Object?>[null, true],
          reason: g.why(
            'S1: the hourglass replaces the digits at zero; frames '
            'counted: ${frames.length}',
          ),
        );
        final int invalidBefore = cueCount(
          g.s.drive.feedback,
          FeedbackCue.invalidTap,
        );
        final int rollsBefore = _sentOfType(g, 'roll');
        await g.s.pump(const Duration(milliseconds: 500));
        expect(
          <Object?>[
            _sentOfType(g, 'roll') - rollsBefore,
            cueCount(g.s.drive.feedback, FeedbackCue.invalidTap) -
                invalidBefore,
          ],
          <Object?>[0, 0],
          reason: g.why('S1: nothing is sent or refused by the zero alone'),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('f. the board hook is not vacuous', () {
    testWidgets('S2 my turn: resizing the view makes the _BoardPainter paint '
        'in at least one counted frame', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.myTurn);
      try {
        final List<_F> frames = await _count(
          g,
          30,
          onFrame: (int i) {
            if (i == 5) {
              tester.view.physicalSize = const Size(380, 820);
              g.s.steps.add('resize view to 380x820 before frame 5');
            }
          },
        );
        final List<int> painted = <int>[
          for (final _F f in frames)
            if (f.board) f.index,
        ];
        expect(
          painted,
          isNotEmpty,
          reason: g.why(
            'control: a resize relayouts the board, so the RenderCustomPaint '
            'of _BoardPainter gets a paint entry in at least one of 30 '
            'frames; it got none, so the board check in case b could never '
            'fail; entries per frame: '
            '${frames.map((_F f) => f.entries).toList()}',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('e. the (seat, deadlineMs, k) memo', () {
    /// S2 with a 30 s deadline, three ticks in. Returns the digits then.
    Future<(EndGame, int)> midCountdown(WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.myTurn);
      await g.s.pump(const Duration(milliseconds: 3000));
      final int? d = _digits(tester);
      expect(
        d,
        isNotNull,
        reason: g.why('memo fixture: digits on screen mid countdown'),
      );
      expect(
        d,
        lessThan(30),
        reason: g.why('memo fixture: the countdown has ticked down from 30'),
      );
      return (g, d!);
    }

    testWidgets('a turn frame repeating the same seat, deadline_ms and k '
        'leaves the digits counting down from where they were', (
      WidgetTester tester,
    ) async {
      final (EndGame g, int d) = await midCountdown(tester);
      try {
        await g.s.push('turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': _longDeadlineMs,
          'queue': <int>[],
        });
        expect(
          _digits(tester),
          d,
          reason: g.why(
            'memo: a replayed turn (seat 0, deadline_ms $_longDeadlineMs, '
            'same k) does not restart the digits; they read $d before it',
          ),
        );
        await g.s.pump(const Duration(milliseconds: 1000));
        expect(
          _digits(tester),
          d - 1,
          reason: g.why(
            'memo: one second after the replay the digits read ${d - 1}, '
            'counting on from $d and not from 30',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a rolled frame with the same seat and deadline_ms and a new '
        'k restarts the digits', (WidgetTester tester) async {
      final (EndGame g, int d) = await midCountdown(tester);
      try {
        await g.s.push('rolled', <String, Object?>{
          ...rolledFrame(0, 3, 1, legal: <int>[0, 1]),
          'deadline_ms': _longDeadlineMs,
        });
        expect(
          _digits(tester),
          30,
          reason: g.why(
            'memo: a new k (0 to 1) with the same seat and deadline_ms '
            '$_longDeadlineMs restarts the digits at 30; they read $d before',
          ),
        );
        await g.s.pump(const Duration(milliseconds: 1000));
        expect(
          _digits(tester),
          29,
          reason: g.why(
            'memo: the restarted countdown keeps ticking, 30 to 29',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a turn frame with a new deadline_ms restarts the digits', (
      WidgetTester tester,
    ) async {
      final (EndGame g, int d) = await midCountdown(tester);
      try {
        await g.s.push('turn', <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 25000,
          'queue': <int>[],
        });
        expect(
          _digits(tester),
          25,
          reason: g.why(
            'memo: a new deadline_ms (30000 to 25000) restarts the digits '
            'at 25; they read $d before',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a turn frame for another seat restarts the digits', (
      WidgetTester tester,
    ) async {
      final (EndGame g, int d) = await midCountdown(tester);
      try {
        await g.s.push('turn', <String, Object?>{
          'seat': 1,
          'phase': 'await_roll',
          'deadline_ms': _longDeadlineMs,
          'queue': <int>[],
        });
        expect(
          _digits(tester),
          30,
          reason: g.why(
            'memo: another seat (0 to 1) with the same deadline_ms restarts '
            'the digits at 30; they read $d before',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });
}
