// C-630 (order 630t): the board is not repainted for every frame of a pulse
// or a glow.
//
// Contract. Each always-running animation (the turn glow on a yard, the
// legal-move ring, the die pulse) paints in its own layer, and the static
// board base is in a layer of its own, so a pulse frame re-records only the
// pulse. The proof is a count, not a look at the code: the real GameScreen is
// mounted over a real RoomController on FakeTransport (the helpers in
// test/support, unchanged), put into each in-game state, run for 200 ms, and
// then pumped for 60 frames of 16 ms with debugOnProfilePaint counting every
// paintChild entry by render object.
//
// What the hook measures: it fires inside PaintingContext.paintChild, once for
// every child a painting parent paints, including a repaint boundary child
// that is only composited from its cached layer. A RenderCustomPaint that
// sits inside a boundary gets an entry only in a frame where that boundary
// re-records. So "the RenderCustomPaint of _BoardPainter had an entry in this
// frame" means the board base was re-recorded, and "the total entry count"
// bounds the painted work from above.
//
// Cases (frames are counted after the state is reached and has run 200 ms):
//   a. S1 watching, S2 my turn, S3 choosing, S4 walking: the board base is
//      painted in at most 2 of the 60 frames (one for the 1 s countdown tick,
//      one for a walking step that relayouts the board).
//   b. S1, S2, S3: at least 56 of 60 frames have at most 40 paint entries
//      (without the boundaries it is 295-300 in every frame).
//   c. S3: each legal ring still paints in at least 50 of 60 frames, and S1's
//      turn glow likewise, so the animation was not frozen to pass (a).
//   d. S2: the die pulse still changes the scale of the Transform under
//      game-die-pulse between frame 0 and frame 15.
//   e. The keys keep the widget types they find today.
//   Round 2 adds two cases:
//   b2. S4 walking: at least 50 of 60 frames have at most 150 paint entries
//      (without the boundaries around the die band and the board it is 298).
//   f. S2: the CustomPaint that draws the die face (_GameDiePainter, under
//      game-die-pulse) is painted in at most 2 of 60 frames, so the scale
//      animation reuses the face's recorded picture.
//
// There is no randomness: every scenario is a fixed frame script on the test
// binding's clock. The scenario name, the frames pushed and the per-frame
// numbers are in every failure message, which is the whole replay recipe:
//
//   flock /tmp/ludo-suite.lock timeout 900 \
//     flutter test test/c630_repaint_isolation_test.dart \
//     --plain-name "<the test name>"

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const int _frames = 60;
const Duration _frame = Duration(milliseconds: 16);
const Duration _warmUp = Duration(milliseconds: 200);
const Size _phone = Size(411, 891);

/// Most frames in which the board base may be painted (a countdown tick, a
/// walking step).
const int _boardBaseAllowance = 2;

/// Most paint entries a frame may have to count as cheap.
const int _cheapEntries = 40;

/// Fewest cheap frames out of [_frames].
const int _cheapFramesNeeded = 56;

/// Most paint entries a walking frame may have to count as cheap (a token
/// step relayouts the board, so its own layer repaints; the rest must not).
const int _walkCheapEntries = 150;

/// Fewest cheap walking frames out of [_frames].
const int _walkCheapFramesNeeded = 50;

/// Most frames in which the die face's own CustomPaint may be painted (a
/// countdown tick, one relayout).
const int _dieFaceAllowance = 2;

/// Fewest frames out of [_frames] in which an animation must still paint.
const int _aliveFramesNeeded = 50;

const Map<int, List<int>> _board = <int, List<int>>{
  0: <int>[10, 20, -1, -1],
  1: <int>[30, -1, -1, -1],
};

/// What one run of [_frames] frames saw.
class _Run {
  _Run(this.name);

  final String name;

  /// Paint entries per frame.
  final List<int> entries = <int>[];

  /// Per frame: did the render object of the board base get an entry.
  final List<bool> boardBase = <bool>[];

  /// Per frame: the tracked render objects that got an entry.
  final List<Set<RenderObject>> tracked = <Set<RenderObject>>[];

  int get boardFrames => boardBase.where((bool b) => b).length;

  int get cheapFrames => entries.where((int n) => n <= _cheapEntries).length;

  int framesAtMost(int limit) => entries.where((int n) => n <= limit).length;

  int framesPainted(RenderObject ro) =>
      tracked.where((Set<RenderObject> s) => s.contains(ro)).length;

  String get entriesText => '[${entries.join(' ')}]';

  String get boardText =>
      '[${<String>[for (int i = 0; i < boardBase.length; i++)
        if (boardBase[i]) '$i'].join(' ')}]';
}

bool _isBoardPainter(RenderObject ro) =>
    ro is RenderCustomPaint &&
    ro.painter.runtimeType.toString() == '_BoardPainter';

/// Pumps [_frames] frames with the paint hook set, restoring it in a finally.
/// [track] are render objects whose per-frame paint entries are recorded.
/// [onFrame] runs before each frame's pump.
Future<_Run> _count(
  Scn s,
  String name, {
  List<RenderObject> track = const <RenderObject>[],
  void Function(int index)? onFrame,
}) async {
  final _Run run = _Run(name);
  s.steps.add('count $_frames frames of ${_frame.inMilliseconds}ms');
  int entries = 0;
  bool board = false;
  Set<RenderObject> seen = <RenderObject>{};
  debugOnProfilePaint = (RenderObject ro) {
    entries += 1;
    if (_isBoardPainter(ro)) {
      board = true;
    }
    if (track.contains(ro)) {
      seen.add(ro);
    }
  };
  try {
    for (int i = 0; i < _frames; i++) {
      entries = 0;
      board = false;
      seen = <RenderObject>{};
      onFrame?.call(i);
      await s.tester.pump(_frame);
      s.clockMs += _frame.inMilliseconds;
      run.entries.add(entries);
      run.boardBase.add(board);
      run.tracked.add(seen);
    }
  } finally {
    debugOnProfilePaint = null;
  }
  return run;
}

/// Two seats (0 is mine, 1 is Bob), tokens on the board, the given turn.
Future<EndGame> _open(
  WidgetTester tester,
  String name,
  Map<String, Object?> turn,
) async {
  phoneSurface(tester);
  tester.view.physicalSize = _phone;
  final List<Map<String, Object?>> seats = namedSeats(2, 0, tokens: _board);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: 0,
    gameId: 'c630-game-1',
  );
  await mountGame(tester, drive);
  return EndGame(Scn(name, tester, drive), 0, 2, seats);
}

/// My roll of [value] lands with tokens 0 and 1 legal; pumps until both legal
/// rings are on screen.
Future<void> _rollAndRing(EndGame g, int value) async {
  await g.s.push('rolled', rolledFrame(0, value, 1, legal: <int>[0, 1]));
  int guard = 0;
  while (ringedTokens(g.tester).length < 2 && guard < 400) {
    await g.s.pump(_frame);
    guard += 1;
  }
  expect(
    ringedTokens(g.tester),
    <int>[0, 1],
    reason: g.why(
      'fixture: board-legal-ring-0-0 and board-legal-ring-0-1 on screen '
      'after the roll of $value landed (waited ${guard * 16} ms)',
    ),
  );
}

enum _State { watching, myTurn, choosing, walking }

String _stateName(_State s) => switch (s) {
  _State.watching => 'S1 watching',
  _State.myTurn => 'S2 my turn to roll',
  _State.choosing => 'S3 choosing',
  _State.walking => 'S4 walking',
};

/// Mounts the game, reaches [state], runs it for 200 ms, and checks the
/// fixture really is that state.
Future<EndGame> _reach(WidgetTester tester, _State state) async {
  final String name = _stateName(state);
  final EndGame g = await _open(
    tester,
    name,
    awaitRollTurn(state == _State.watching ? 1 : 0),
  );
  switch (state) {
    case _State.watching:
      await g.s.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(const Key('game-screen-turn-countdown')),
        findsOneWidget,
        reason: g.why('S1: the turn countdown is on screen, seat 1 to roll'),
      );
      expect(
        find.byKey(const Key('board-turn-yard-1')),
        findsOneWidget,
        reason: g.why('S1: board-turn-yard-1 (the glow on the other seat)'),
      );
    case _State.myTurn:
      await g.s.pump(const Duration(milliseconds: 500));
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
    case _State.choosing:
      await _rollAndRing(g, 3);
    case _State.walking:
      await _rollAndRing(g, 5);
      await g.s.push('moved', movedFrame(0, 0, 10, 15));
  }
  await g.s.pump(_warmUp);
  return g;
}

/// The [RenderCustomPaint] of the first widget under [key] whose painter has
/// the runtime type name [painter].
RenderCustomPaint _customPaintUnder(
  WidgetTester tester,
  EndGame g,
  Key key,
  String painter,
) {
  final Finder found = find.descendant(
    of: find.byKey(key),
    matching: find.byWidgetPredicate(
      (Widget w) =>
          w is CustomPaint && w.painter.runtimeType.toString() == painter,
    ),
  );
  expect(
    found,
    findsWidgets,
    reason: g.why('fixture: a CustomPaint with $painter under $key'),
  );
  return tester.renderObject<RenderCustomPaint>(found.first);
}

void main() {
  const List<_State> inGame = _State.values;

  group('a. the board base is not repainted for a pulse or a glow', () {
    for (final _State state in inGame) {
      testWidgets('${_stateName(state)}: _BoardPainter paints in at most '
          '$_boardBaseAllowance of $_frames frames', (
        WidgetTester tester,
      ) async {
        final EndGame g = await _reach(tester, state);
        try {
          final Finder token = find.byKey(const Key('token-0-0'));
          final List<Offset> centres = <Offset>[];
          final _Run run = await _count(
            g.s,
            _stateName(state),
            onFrame: (int i) {
              if (state == _State.walking && (i == 0 || i == 20)) {
                centres.add(tester.getCenter(token));
              }
            },
          );
          if (state == _State.walking) {
            expect(
              centres[1],
              isNot(centres[0]),
              reason: g.why(
                'S4 fixture: token-0-0 is walking (frame 0 ${centres[0]}, '
                'frame 20 ${centres[1]})',
              ),
            );
          }
          expect(
            run.boardFrames,
            lessThanOrEqualTo(_boardBaseAllowance),
            reason: g.why(
              '${_stateName(state)}: the _BoardPainter RenderCustomPaint is '
              'painted in at most $_boardBaseAllowance of $_frames frames '
              '(a countdown tick, a walking step); it was painted in '
              '${run.boardFrames}, at frames ${run.boardText}; '
              'scenario ${_stateName(state)}, fixed script, no seed',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }
  });

  group('b. a steady frame paints few render objects', () {
    for (final _State state in <_State>[
      _State.watching,
      _State.myTurn,
      _State.choosing,
    ]) {
      testWidgets('${_stateName(state)}: at least $_cheapFramesNeeded of '
          '$_frames frames have at most $_cheapEntries paint entries', (
        WidgetTester tester,
      ) async {
        final EndGame g = await _reach(tester, state);
        try {
          final _Run run = await _count(g.s, _stateName(state));
          expect(
            run.cheapFrames,
            greaterThanOrEqualTo(_cheapFramesNeeded),
            reason: g.why(
              '${_stateName(state)}: at least $_cheapFramesNeeded of '
              '$_frames frames with at most $_cheapEntries paint entries; '
              'only ${run.cheapFrames} were; entries per frame '
              '${run.entriesText}; scenario ${_stateName(state)}, fixed '
              'script, no seed',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('S4 walking: at least $_walkCheapFramesNeeded of $_frames '
        'frames have at most $_walkCheapEntries paint entries', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.walking);
      try {
        final Finder token = find.byKey(const Key('token-0-0'));
        final List<Offset> centres = <Offset>[];
        final _Run run = await _count(
          g.s,
          'S4 walking',
          onFrame: (int i) {
            if (i == 0 || i == 20) {
              centres.add(tester.getCenter(token));
            }
          },
        );
        expect(
          centres[1],
          isNot(centres[0]),
          reason: g.why(
            'S4 fixture: token-0-0 is walking (frame 0 ${centres[0]}, '
            'frame 20 ${centres[1]})',
          ),
        );
        final int cheap = run.framesAtMost(_walkCheapEntries);
        expect(
          cheap,
          greaterThanOrEqualTo(_walkCheapFramesNeeded),
          reason: g.why(
            'S4 walking: at least $_walkCheapFramesNeeded of $_frames frames '
            'with at most $_walkCheapEntries paint entries; only $cheap '
            'were; entries per frame ${run.entriesText}; scenario S4 '
            'walking, fixed script, no seed',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('c. the animations still run', () {
    testWidgets('S3 choosing: each legal ring paints in at least '
        '$_aliveFramesNeeded of $_frames frames', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.choosing);
      try {
        final List<RenderCustomPaint> rings = <RenderCustomPaint>[
          _customPaintUnder(tester, g, legalRingKey(0, 0), '_RingPainter'),
          _customPaintUnder(tester, g, legalRingKey(0, 1), '_RingPainter'),
        ];
        expect(
          rings[0],
          isNot(same(rings[1])),
          reason: g.why('fixture: two distinct ring render objects'),
        );
        final _Run run = await _count(g.s, 'S3 choosing', track: rings);
        for (int t = 0; t < rings.length; t++) {
          final int painted = run.framesPainted(rings[t]);
          expect(
            painted,
            greaterThanOrEqualTo(_aliveFramesNeeded),
            reason: g.why(
              'S3: the _RingPainter under board-legal-ring-0-$t is painted '
              'in at least $_aliveFramesNeeded of $_frames frames (the pulse '
              'still animates); it was painted in $painted; scenario '
              'S3 choosing, fixed script, no seed',
            ),
          );
        }
      } finally {
        await g.done();
      }
    });

    testWidgets('S1 watching: the turn glow paints in at least '
        '$_aliveFramesNeeded of $_frames frames', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.watching);
      try {
        final RenderCustomPaint glow = _customPaintUnder(
          tester,
          g,
          const Key('board-turn-yard-1'),
          '_GlowPainter',
        );
        final _Run run = await _count(
          g.s,
          'S1 watching',
          track: <RenderObject>[glow],
        );
        final int painted = run.framesPainted(glow);
        expect(
          painted,
          greaterThanOrEqualTo(_aliveFramesNeeded),
          reason: g.why(
            'S1: the _GlowPainter under board-turn-yard-1 is painted in at '
            'least $_aliveFramesNeeded of $_frames frames (the glow still '
            'animates); it was painted in $painted; scenario S1 watching, '
            'fixed script, no seed',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('d. the die pulse still scales', () {
    testWidgets('S2 my turn: the Transform under game-die-pulse has a '
        'different scale at frame 15 than at frame 0', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.myTurn);
      try {
        final Finder transform = find
            .descendant(
              of: find.byKey(const Key('game-die-pulse')),
              matching: find.byType(Transform),
            )
            .first;
        expect(
          transform,
          findsOneWidget,
          reason: g.why('fixture: a Transform under game-die-pulse'),
        );
        final List<double> scales = <double>[];
        await _count(
          g.s,
          'S2 my turn',
          onFrame: (int i) {
            scales.add(
              tester.widget<Transform>(transform).transform.getMaxScaleOnAxis(),
            );
          },
        );
        expect(
          (scales[15] - scales[0]).abs(),
          greaterThan(1e-4),
          reason: g.why(
            'S2: the die pulse changes the scale between frame 0 and frame '
            '15; scale at frame 0 ${scales[0]}, at frame 15 ${scales[15]}; '
            'all 60 scales $scales; scenario S2 my turn, fixed script, no '
            'seed',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('f. the die face is recorded once, not per pulse frame', () {
    testWidgets('S2 my turn: the die face CustomPaint paints in at most '
        '$_dieFaceAllowance of $_frames frames', (WidgetTester tester) async {
      final EndGame g = await _reach(tester, _State.myTurn);
      try {
        final RenderCustomPaint face = _customPaintUnder(
          tester,
          g,
          const Key('game-die-pulse'),
          '_GameDiePainter',
        );
        final Finder transform = find
            .descendant(
              of: find.byKey(const Key('game-die-pulse')),
              matching: find.byType(Transform),
            )
            .first;
        final List<double> scales = <double>[];
        final _Run run = await _count(
          g.s,
          'S2 my turn',
          track: <RenderObject>[face],
          onFrame: (int i) {
            scales.add(
              tester.widget<Transform>(transform).transform.getMaxScaleOnAxis(),
            );
          },
        );
        expect(
          (scales[15] - scales[0]).abs(),
          greaterThan(1e-4),
          reason: g.why(
            'S2 fixture: the pulse is running while the face is counted '
            '(scale at frame 0 ${scales[0]}, at frame 15 ${scales[15]})',
          ),
        );
        final int painted = run.framesPainted(face);
        expect(
          painted,
          lessThanOrEqualTo(_dieFaceAllowance),
          reason: g.why(
            'S2: the _GameDiePainter CustomPaint under game-die-pulse is '
            'painted in at most $_dieFaceAllowance of $_frames frames (the '
            'face is its own layer, the scale animation reuses its '
            'picture); it was painted in $painted; scenario S2 my turn, '
            'fixed script, no seed',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('e. keys keep the widget types they find today', () {
    testWidgets('S3 choosing: board-legal-ring-0-0 and -0-1 are Positioned', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.choosing);
      try {
        for (final int t in <int>[0, 1]) {
          final Finder f = find.byKey(legalRingKey(0, t));
          expect(
            f,
            findsOneWidget,
            reason: g.why('S3: board-legal-ring-0-$t is on screen once'),
          );
          expect(
            tester.widget(f).runtimeType,
            Positioned,
            reason: g.why('S3: board-legal-ring-0-$t is a Positioned'),
          );
        }
      } finally {
        await g.done();
      }
    });

    testWidgets('S2 my turn: game-die-pulse is a KeyedSubtree', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.myTurn);
      try {
        final Finder f = find.byKey(const Key('game-die-pulse'));
        expect(
          f,
          findsOneWidget,
          reason: g.why('S2: game-die-pulse is on screen once'),
        );
        expect(
          tester.widget(f).runtimeType,
          KeyedSubtree,
          reason: g.why('S2: game-die-pulse is a KeyedSubtree'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('S1 watching: board-turn-yard-1 is a KeyedSubtree', (
      WidgetTester tester,
    ) async {
      final EndGame g = await _reach(tester, _State.watching);
      try {
        final Finder f = find.byKey(const Key('board-turn-yard-1'));
        expect(
          f,
          findsOneWidget,
          reason: g.why('S1: board-turn-yard-1 is on screen once'),
        );
        expect(
          tester.widget(f).runtimeType,
          KeyedSubtree,
          reason: g.why('S1: board-turn-yard-1 is a KeyedSubtree'),
        );
      } finally {
        await g.done();
      }
    });
  });
}
