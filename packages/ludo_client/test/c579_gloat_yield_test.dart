// Screen proof for C-579 D1-D3 (order 579t): the capture gloat yields to the
// capturer's bonus roll. Written from the contract's text alone. A real
// GameScreen over a real RoomController on FakeTransport, every state a
// decoded wire frame, the recording FeedbackService from
// support/roll_tray_harness.dart.
//
// Time is measured from the first frame the gloat is on screen; the pump
// step is 5 ms, so a moment is known to within 5 ms. The trigger of a yield
// is the clock reading right after the `rolled` frame is pushed: a frame
// push runs two bare pumps and no fake time passes in them. Every bound
// below leaves one 16 ms frame of room around the contract's 250 ms and
// 1600 ms, and no more.
//
// The exit length of C-579 D2 is written as a local constant, not by the
// name the contract adds, so this file compiles on a tree without it.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
// The scenarios hold no randomness: the name is the whole seed.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

/// C-579 D2: the exit the face plays, at the end of its life and on a yield.
const int _exitMs = 250;

/// C-468 D5: the whole life.
const int _lifeMs = 1600;

/// One frame of slack on a bound the contract states as "give or take".
const int _frameMs = 16;

const List<int> _moverTokens = <int>[3, -1, -1, -1];
const List<int> _victimTokens = <int>[-1, -1, 48, -1];

/// One capture scenario: me, the mover M and the captured seats.
class _Fix {
  _Fix(this.s, this.me, this.mover, this.captured);

  final Scn s;
  final int me;
  final int mover;
  final List<int> captured;

  Finder get gloat => find.byKey(gloatKey(mover));
}

Future<_Fix> _fixture(
  WidgetTester tester, {
  required String name,
  required int me,
  required int mover,
  int players = 2,
  bool reduced = false,
  bool snap = false,
}) async {
  phoneSurface(tester);
  final int other = me == 0 ? 2 : 0;
  final List<int> victims = <int>[
    players == 2 ? (mover == me ? other : me) : 2,
  ];
  final List<Map<String, Object?>> seats;
  if (players == 2) {
    seats = <Map<String, Object?>>[
      for (final int seat in const <int>[0, 2])
        seatJson(
          seat,
          name: seat == me ? 'Sam' : 'Bob',
          tokens: seat == mover ? (snap ? kYard : _moverTokens) : _victimTokens,
        ),
    ];
  } else {
    seats = quadSeats(
      mySeat: me,
      tokens: <int, List<int>>{
        mover: snap ? kYard : _moverTokens,
        for (final int v in victims) v: _victimTokens,
      },
    );
  }
  final RollTrayDrive drive = await mountScreen(
    tester,
    mySeat: me,
    players: players,
    disableAnimations: reduced,
    turn: awaitRollTurn(mover),
    seats: seats,
  );
  return _Fix(Scn(name, tester, drive), me, mover, victims);
}

Future<void> _pushCapture(_Fix f, {bool extraRoll = true}) => f.s.push(
  'moved',
  movedFrame(
    f.mover,
    0,
    3,
    9,
    captured: <Map<String, int>>[
      for (final int seat in f.captured)
        <String, int>{'seat': seat, 'token': 2},
    ],
    extraRoll: extraRoll,
  ),
);

/// Pushes the capture and waits for the gloat; returns the clock reading
/// (ms) of the first frame it showed on.
Future<int> _captureAndWait(_Fix f, {bool extraRoll = true}) async {
  await _pushCapture(f, extraRoll: extraRoll);
  final int? t0 = await _untilGloat(f.s);
  expect(
    t0,
    isNotNull,
    reason: f.s.why('a capturing moved starts a gloat for seat ${f.mover}'),
  );
  return t0!;
}

/// One 5 ms pump on the fake clock, kept out of the replay list.
Future<void> _tick(Scn s) async {
  await s.tester.pump(kC468Fine);
  s.clockMs += kC468Fine.inMilliseconds;
}

/// Pumps to [clockMs] in 5 ms steps and logs one replay entry.
Future<void> _pumpTo(Scn s, int clockMs) async {
  s.steps.add('pump to ${clockMs}ms');
  while (s.clockMs < clockMs) {
    await _tick(s);
  }
}

/// Like pumpUntilGloat, with one replay entry for all the pumps.
Future<int?> _untilGloat(Scn s) async {
  final int stop = s.clockMs + 4000;
  s.steps.add('pump until a gloat shows');
  while (s.clockMs <= stop) {
    if (gloatSeats(s.tester).isNotEmpty) {
      return s.clockMs;
    }
    await _tick(s);
  }
  return null;
}

/// The turn frame that follows a capture's bonus roll, then that roll.
Future<void> _rollFor(_Fix f, int seat) async {
  await f.s.push('turn', turnFrame(seat));
  await f.s.push('rolled', rolledFrame(seat, 6, 1, legal: const <int>[0]));
}

/// The opacity the face paints with: the product of every `Opacity` and
/// animated opacity (`FadeTransition`, `AnimatedOpacity`) between its paint
/// object and the board stack.
double _opacityOf(WidgetTester tester, Finder key) {
  final RenderObject? stack = boardStackOf(tester).renderObject;
  RenderObject? at = paintObjectOf(tester, key);
  double product = 1.0;
  while (at != null && !identical(at, stack)) {
    if (at is RenderOpacity) {
      product *= at.opacity;
    } else if (at is RenderAnimatedOpacity) {
      product *= at.opacity.value;
    }
    at = at.parent;
  }
  return product;
}

/// One look at the face: `age` is ms since the sampling origin.
class _Look {
  _Look(this.age, this.present, this.opacity, this.y);

  final int age;
  final bool present;
  final double opacity;
  final double y;

  @override
  String toString() =>
      '$age:${present ? '${opacity.toStringAsFixed(2)}@${y.toStringAsFixed(1)}' : 'gone'}';
}

_Look _look(_Fix f, int origin) {
  final int age = f.s.clockMs - origin;
  if (!f.s.tester.any(f.gloat)) {
    return _Look(age, false, 0, 0);
  }
  return _Look(
    age,
    true,
    _opacityOf(f.s.tester, f.gloat),
    paintCentreOf(f.s.tester, f.gloat).dy,
  );
}

/// Looks every 5 ms from now until the face is gone or the clock reads
/// [until]; the last entry is the first look without the face, if any.
Future<List<_Look>> _watch(_Fix f, {required int origin, int? until}) async {
  final int stop = until ?? origin + _lifeMs + 200;
  f.s.steps.add('watch every 5ms from ${f.s.clockMs}ms');
  final List<_Look> looks = <_Look>[];
  while (f.s.clockMs <= stop) {
    looks.add(_look(f, origin));
    if (!looks.last.present) {
      break;
    }
    await _tick(f.s);
  }
  f.s.steps.add('watched to ${f.s.clockMs}ms');
  return looks;
}

String _series(List<_Look> looks) {
  final List<String> out = <String>[];
  int next = 0;
  for (final _Look l in looks) {
    if (l.age >= next || !l.present) {
      out.add('$l');
      next = l.age + 25;
    }
  }
  return out.join(' ');
}

/// The first look without the face, as its age; null when it never went.
int? _goneAt(List<_Look> looks) {
  for (final _Look l in looks) {
    if (!l.present) {
      return l.age;
    }
  }
  return null;
}

_Look _firstAtOrAfter(List<_Look> looks, int age) =>
    looks.firstWhere((_Look l) => l.age >= age);

/// Opacity never rises and never drops by more than [maxStep] between two
/// looks 5 ms apart: a fade, not a cut.
void _expectFade(_Fix f, List<_Look> looks, String what) {
  _Look? prev;
  for (final _Look l in looks) {
    if (!l.present) {
      break;
    }
    if (prev != null) {
      expect(
        l.opacity,
        lessThanOrEqualTo(prev.opacity + 0.001),
        reason: f.s.why(
          '$what: opacity falls and never comes back; ${prev.age}ms '
          '${prev.opacity.toStringAsFixed(3)} then ${l.age}ms '
          '${l.opacity.toStringAsFixed(3)}; looks: ${_series(looks)}',
        ),
      );
      expect(
        prev.opacity - l.opacity,
        lessThan(0.25),
        reason: f.s.why(
          '$what: no single-frame cut from ${prev.age}ms '
          '${prev.opacity.toStringAsFixed(3)} to ${l.age}ms '
          '${l.opacity.toStringAsFixed(3)}; looks: ${_series(looks)}',
        ),
      );
    }
    prev = l;
  }
}

void main() {
  // -------------------------------------------------------------------
  // Item 1 (D1, D2): a rolled for the gloat's own seat starts the exit now.
  // -------------------------------------------------------------------
  for (final (int me, int mover, int players, String view)
      in const <(int, int, int, String)>[
        (0, 2, 2, 'the capturer is the other player'),
        (0, 0, 2, 'the capturer is me'),
        (1, 0, 4, 'the capturer is a third seat'),
      ]) {
    testWidgets(
      'C-579 D1/D2: $view (me $me, seat $mover, $players players): a rolled '
      'for the gloat\'s seat at age 300 ms fades and lifts the face out in '
      '250 ms',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'C-579 item 1 me=$me mover=$mover players=$players',
          me: me,
          mover: mover,
          players: players,
        );
        try {
          final int t0 = await _captureAndWait(f);
          await _pumpTo(f.s, t0 + 300);
          final _Look held = _look(f, f.s.clockMs);
          expect(
            held.present,
            isTrue,
            reason: f.s.why('fixture: the gloat is up at age 300 ms'),
          );
          expect(
            held.opacity,
            closeTo(1.0, 0.01),
            reason: f.s.why('fixture: fully opaque before the trigger'),
          );
          await _rollFor(f, mover);
          final int trigger = f.s.clockMs;
          final List<_Look> looks = await _watch(f, origin: trigger);
          final String series = _series(looks);
          final _Look mid = _firstAtOrAfter(looks, 150);
          expect(
            mid.present,
            isTrue,
            reason: f.s.why(
              'the face is still in the tree at trigger + 150 ms; $series',
            ),
          );
          expect(
            mid.opacity,
            greaterThan(0.0),
            reason: f.s.why('still visible at trigger + 150 ms; $series'),
          );
          expect(
            mid.opacity,
            lessThan(1.0),
            reason: f.s.why(
              'already fading at trigger + 150 ms (the exit started at the '
              'rolled, not at 1350 ms); $series',
            ),
          );
          final _Look early = _firstAtOrAfter(looks, 100);
          expect(
            early.opacity,
            lessThan(1.0),
            reason: f.s.why('fading by trigger + 100 ms; $series'),
          );
          final int? gone = _goneAt(looks);
          expect(
            gone,
            isNotNull,
            reason: f.s.why(
              'the face is absent 250 ms + one frame after the trigger; '
              '$series',
            ),
          );
          expect(
            gone,
            inInclusiveRange(_exitMs - _frameMs + 1, _exitMs + _frameMs),
            reason: f.s.why(
              'gone at $gone ms after the trigger, expected $_exitMs give or '
              'take one frame and not earlier; $series',
            ),
          );
          _expectFade(f, looks, 'yield');
          final double cell = cellSize(tester);
          final _Look last = looks.lastWhere((_Look l) => l.present);
          final double risen = held.y - last.y;
          expect(
            risen,
            inInclusiveRange(0.3 * cell, 0.6 * cell),
            reason: f.s.why(
              'the face rose ${risen.toStringAsFixed(1)} px by '
              '${last.age} ms; half a cell is ${(cell / 2).toStringAsFixed(1)} '
              'px; $series',
            ),
          );
          await f.s.pump(const Duration(milliseconds: 1500));
          expect(
            gloatSeats(tester),
            isEmpty,
            reason: f.s.why('it does not come back'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'C-579 D2: reduced motion keeps the same timing: present at trigger + '
    '150 ms and + 230 ms, gone 250 ms + one frame after the trigger',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'C-579 item 1 reduced',
        me: 0,
        mover: 2,
        reduced: true,
      );
      try {
        final int t0 = await _captureAndWait(f);
        await _pumpTo(f.s, t0 + 300);
        await _rollFor(f, 2);
        final int trigger = f.s.clockMs;
        final List<_Look> looks = await _watch(f, origin: trigger);
        final String series = _series(looks);
        expect(
          _firstAtOrAfter(looks, 150).present,
          isTrue,
          reason: f.s.why('present at trigger + 150 ms; $series'),
        );
        expect(
          _firstAtOrAfter(looks, _exitMs - 20).present,
          isTrue,
          reason: f.s.why('present at trigger + 230 ms; $series'),
        );
        final int? gone = _goneAt(looks);
        expect(
          gone,
          isNotNull,
          reason: f.s.why(
            'absent 250 ms + one frame after the trigger; $series',
          ),
        );
        expect(
          gone,
          inInclusiveRange(_exitMs - _frameMs + 1, _exitMs + _frameMs),
          reason: f.s.why(
            'gone at $gone ms after the trigger, expected $_exitMs give or '
            'take one frame; $series',
          ),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // Item 2 (D1): a rolled for another seat changes nothing.
  // -------------------------------------------------------------------
  for (final (int me, int mover, int roller) in const <(int, int, int)>[
    (0, 2, 0),
    (0, 0, 2),
  ]) {
    testWidgets(
      'C-579 D1: seat $roller rolls while seat $mover\'s gloat is up (I am '
      '$me): the face is untouched at 1300 ms and gone by 1600 ms + one frame',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'C-579 item 2 me=$me mover=$mover roller=$roller',
          me: me,
          mover: mover,
        );
        try {
          final int t0 = await _captureAndWait(f, extraRoll: false);
          await _pumpTo(f.s, t0 + 300);
          await _rollFor(f, roller);
          final List<_Look> looks = await _watch(f, origin: t0);
          final String series = _series(looks);
          for (final _Look l in looks.where(
            (_Look l) => l.age >= 300 && l.age <= 1300,
          )) {
            expect(
              l.present,
              isTrue,
              reason: f.s.why(
                'seat $mover\'s face is up at ${l.age} ms; $series',
              ),
            );
            expect(
              l.opacity,
              closeTo(1.0, 0.01),
              reason: f.s.why(
                'no fade before 1350 ms when another seat rolled; '
                'at ${l.age} ms; $series',
              ),
            );
          }
          final int? gone = _goneAt(looks);
          expect(
            gone,
            isNotNull,
            reason: f.s.why('gone by 1600 ms + one frame; $series'),
          );
          expect(
            gone,
            inInclusiveRange(_lifeMs - 20, _lifeMs + _frameMs),
            reason: f.s.why(
              'gone at $gone ms of age, expected $_lifeMs, as without the '
              'roll; $series',
            ),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  // -------------------------------------------------------------------
  // Item 3 (D2): a trigger inside the exit changes nothing.
  // -------------------------------------------------------------------
  testWidgets(
    'C-579 D2: a rolled for the gloat\'s seat at age 1450 ms (inside the '
    'normal exit) neither restarts nor shortens it: gone at 1600 ms + one '
    'frame, not earlier',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'C-579 item 3',
        me: 0,
        mover: 2,
      );
      try {
        final int t0 = await _captureAndWait(f);
        await _pumpTo(f.s, t0 + 1450);
        final _Look before = _look(f, t0);
        expect(
          before.present,
          isTrue,
          reason: f.s.why('fixture: the face is inside its exit at 1450 ms'),
        );
        expect(
          before.opacity,
          allOf(greaterThan(0.0), lessThan(1.0)),
          reason: f.s.why('fixture: the exit is already fading at 1450 ms'),
        );
        await _rollFor(f, 2);
        final List<_Look> looks = await _watch(f, origin: t0);
        final String series = _series(looks);
        _expectFade(
          f,
          looks.where((_Look l) => l.age >= 1450).toList(),
          'exit',
        );
        final _Look late = _firstAtOrAfter(looks, 1550);
        expect(
          late.present,
          isTrue,
          reason: f.s.why('not removed early: still up at 1550 ms; $series'),
        );
        final int? gone = _goneAt(looks);
        expect(
          gone,
          isNotNull,
          reason: f.s.why('gone by 1600 ms + one frame; $series'),
        );
        expect(
          gone,
          inInclusiveRange(_lifeMs - 20, _lifeMs + _frameMs),
          reason: f.s.why(
            'gone at $gone ms of age, expected $_lifeMs: the trigger inside '
            'the exit changes nothing; $series',
          ),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // Item 4 (D3): the sound keeps its own timer.
  // -------------------------------------------------------------------
  testWidgets(
    'C-579 D3: seat 2 captured my token and rolls at age 100 ms: exactly one '
    'gloat cue, still about 250 ms after the gloat started',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'C-579 item 4',
        me: 0,
        mover: 2,
      );
      try {
        final int t0 = await _captureAndWait(f);
        await _pumpTo(f.s, t0 + 100);
        await _rollFor(f, 2);
        expect(
          f.s.count(FeedbackCue.gloat),
          0,
          reason: f.s.why('not yet heard at age 100 ms'),
        );
        int? heardAt;
        while (f.s.clockMs <= t0 + 400) {
          if (heardAt == null && f.s.count(FeedbackCue.gloat) > 0) {
            heardAt = f.s.clockMs - t0;
          }
          await _tick(f.s);
        }
        expect(
          heardAt,
          isNotNull,
          reason: f.s.why(
            'the yield does not cancel the sound: heard by age 400 ms',
          ),
        );
        expect(
          heardAt,
          inInclusiveRange(240, 270),
          reason: f.s.why('heard at age $heardAt ms, expected 250'),
        );
        await _pumpTo(f.s, t0 + 2200);
        expect(
          f.s.count(FeedbackCue.gloat),
          1,
          reason: f.s.why('exactly one gloat cue for one capture'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D3 and D1 edges: what a rolled must not touch.
  // -------------------------------------------------------------------
  testWidgets(
    'C-579 D3: a rolled for the mover while the walk has not landed leaves '
    'the pending gloat alone: it shows later with its full life',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'C-579 D3 pending',
        me: 0,
        mover: 2,
      );
      try {
        await _pushCapture(f);
        await f.s.pump(kTokenStepDuration * 2, step: kC468Fine);
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: f.s.why('fixture: the walk has not landed, no gloat yet'),
        );
        await _rollFor(f, 2);
        final int? t0 = await _untilGloat(f.s);
        expect(
          t0,
          isNotNull,
          reason: f.s.why('the pending gloat still shows when the walk lands'),
        );
        final List<_Look> looks = await _watch(f, origin: t0!);
        final String series = _series(looks);
        for (final _Look l in looks.where(
          (_Look l) => l.age >= 300 && l.age <= 1300,
        )) {
          expect(
            l.present && (l.opacity - 1.0).abs() <= 0.01,
            isTrue,
            reason: f.s.why(
              'a roll before the face existed does not yield it; at '
              '${l.age} ms: $l; $series',
            ),
          );
        }
        final int? gone = _goneAt(looks);
        expect(
          gone,
          isNotNull,
          reason: f.s.why('gone at the end of its life; $series'),
        );
        expect(
          gone,
          inInclusiveRange(_lifeMs - 20, _lifeMs + _frameMs),
          reason: f.s.why('full 1600 ms life, gone at $gone ms; $series'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets(
    'C-579 D3: a new capture while the face is yielding replaces it with a '
    'new face on a full life',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'C-579 D3 replace',
        me: 0,
        mover: 2,
        snap: true,
      );
      try {
        final int t0 = await _captureAndWait(f);
        await _pumpTo(f.s, t0 + 300);
        await _rollFor(f, 2);
        await f.s.pump(const Duration(milliseconds: 100), step: kC468Fine);
        expect(gloatSeats(tester), <int>[
          2,
        ], reason: f.s.why('fixture: the first face is yielding, 100 ms in'));
        await f.s.push(
          'moved',
          movedFrame(
            2,
            1,
            3,
            9,
            captured: <Map<String, int>>[
              <String, int>{'seat': 0, 'token': 1},
            ],
          ),
        );
        await f.s.pump(kC468Frame * 3, step: kC468Fine);
        final int second = f.s.clockMs;
        expect(gloatSeats(tester), <int>[
          2,
        ], reason: f.s.why('the new capture shows a face at once (a snap)'));
        await _pumpTo(f.s, second + 1450);
        expect(
          gloatSeats(tester),
          <int>[2],
          reason: f.s.why(
            'the replacement runs its own life: still up 1450 ms after it '
            'started, long after the first face\'s yield would have ended',
          ),
        );
        await _pumpTo(f.s, second + _lifeMs + _frameMs);
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: f.s.why('then the replacement is gone'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );
}
