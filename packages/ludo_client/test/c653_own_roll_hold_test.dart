// Screen proofs for contract C-653 (work/ludo/orders/653-own-roll-readable.md),
// decisions D1 to D4, written from the contract alone. The implementation is
// built in parallel in a tree this file's author has not read.
//
// A real GameScreen over a real RoomController on FakeTransport, driven
// through test/support/roll_tray_harness.dart with the frames the server
// sends under the roll queue (`rolled`, then for a six that owes a roll a
// same-seat `turn` in await_roll, docs/PROTOCOL.md 21.3). Nothing is mocked
// but the socket and the feedback service.
//
// How the die's shown face is read: the same way play_surface_die_test.dart
// and idle_die_face_test.dart read it. GameDie keys the resting face
// `game-die-face-N` and the idle cube `game-die-idle-art` / `game-die-blank`;
// this file looks for those keys as descendants of the big die (`game-die`),
// so a face drawn elsewhere (the tray, a yard die) never counts. "Shows 6"
// means exactly `game-die-face-6` is present under `game-die` and no other
// face key is, and the idle cube is not.
//
// Time is fake and never settled: every wait is an explicit pump, in steps of
// at most 50 ms, counted from the arrival of the `rolled` frame under test.
// There is no seed. Each case is a fixed list of frames, and a failure line
// names the case, locale, motion mode, the step in ms since the `rolled`
// frame, what was expected, what the die showed, the roll count and the
// cues, and every frame pushed so far, which is the whole reproduction.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/dead_mark.dart'
    show pipCentresFor, pipRadiusFor;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;

import 'support/roll_tray_harness.dart';

// --- the contract's constants, verbatim -----------------------------------------

/// D1: the hold, from the arrival of my `rolled` frame.
const int _holdMs = 900;

/// D3: the mark's key and its two texts.
const Key _markKey = Key('own-die-roll-again');
const String _rollAgainEn = 'Roll again';
const String _rollAgainAr = 'ارمِ مرة أخرى';

/// D3: at least 20 dp.
const double _markMinDp = 20;

/// D4: 1.0 -> 1.2 -> 1.0 over 300 ms.
const double _popPeak = 1.2;
const int _popMs = 300;

const Key _shotKey = Key('c653-shot');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

// Two tokens on the track, two in the yard: a 4 moves either of the first
// two, a 6 moves any of the four, so no single-legal auto-move hold arms.
const List<int> _openTokens = <int>[10, 20, -1, -1];

// Seat 0 near home: no 6 is playable (need-exact), the roll voids the turn.
const List<int> _nearHomeTokens = <int>[55, 57, 57, 57];

// --- frames ---------------------------------------------------------------------

Map<String, Object?> _rolledData(
  int seat,
  int value, {
  required List<int> queue,
  List<int> legal = const <int>[],
  List<Map<String, Object?>>? legalByFace,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _awaitRollTurn(int seat, List<int> queue) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

Map<String, Object?> _myRollTurn() =>
    turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]);

Map<String, Object?> _theirRollTurn() =>
    turnJson(seat: 1, phase: 'await_roll', k: 0, queue: const <int>[]);

// --- the play ---------------------------------------------------------------------

/// One mounted GameScreen, the fake clock, and the log that makes a failure
/// reproducible.
class _Game {
  _Game(this.tester, this.drive, this.item, this.locale, this.reduced);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String item;
  final Locale locale;
  final bool reduced;
  final List<String> frames = <String>[];

  /// Fake milliseconds pumped since the mount, and the value of that clock
  /// when the `rolled` frame under test arrived.
  int _now = 0;
  int _arrival = 0;

  /// Milliseconds since the arrival of the `rolled` frame under test.
  int get rel => _now - _arrival;

  String get motion => reduced ? 'reduced-motion' : 'full-motion';

  Finder get _die => find.byKey(bigDieKey);

  Future<void> push(String type, Map<String, Object?> data) async {
    final String body = jsonEncode(data);
    final String shown = body.length > 200
        ? '${body.substring(0, 200)}...'
        : body;
    frames.add('$type $shown@${rel}ms');
    await drive.push(tester, type, data);
  }

  /// A `rolled` frame: it is the arrival the hold counts from.
  Future<void> pushRolled(Map<String, Object?> data) async {
    _arrival = _now;
    await push('rolled', data);
  }

  /// Pumps until [ms] after the `rolled` frame under test, 50 ms at a time.
  Future<void> advanceTo(int ms) async {
    while (rel < ms) {
      final int step = ms - rel < 50 ? ms - rel : 50;
      await tester.pump(Duration(milliseconds: step));
      _now += step;
    }
  }

  // --- what the die shows -----------------------------------------------------

  List<int> get faces => <int>[
    for (int v = 1; v <= 6; v++)
      if (find
          .descendant(of: _die, matching: find.byKey(bigFaceKey(v)))
          .evaluate()
          .isNotEmpty)
        v,
  ];

  bool get idleArt => find
      .descendant(of: _die, matching: find.byKey(idleArtKey))
      .evaluate()
      .isNotEmpty;

  bool get pulsing => find
      .descendant(of: _die, matching: find.byKey(const Key('game-die-pulse')))
      .evaluate()
      .isNotEmpty;

  int get marks => find.byKey(_markKey).evaluate().length;

  int get rolls =>
      sentTypesSince(drive.transport, 0).where((t) => t == 'roll').length;

  int cues(FeedbackCue cue) => cueCount(drive.feedback, cue);

  String get observed =>
      'die faces $faces, idle cube $idleArt, pulse $pulsing, roll-again marks '
      '$marks, rolls sent $rolls, invalid-tap cues ${cues(FeedbackCue.invalidTap)}, '
      'tap cues ${cues(FeedbackCue.tap)}';

  String why(String step, String expected) =>
      'C-653t $item [${locale.languageCode}, $motion] at +${rel}ms ($step): '
      'expected $expected; observed $observed. Frames pushed in order '
      '(@ms since the latest rolled): '
      '${frames.isEmpty ? '<none>' : frames.join(' -> ')}. Fixed frames, no '
      'seed: replay them on a GameScreen over a RoomController on '
      'FakeTransport, pumping 50 ms at a time.';

  // --- assertions -----------------------------------------------------------

  /// The die rests on [face] and, when [mark] is set, shows the roll-again
  /// mark; when it is not, no mark exists anywhere.
  void expectFace(String step, int face, {required bool mark}) {
    expect(faces, <int>[
      face,
    ], reason: why(step, 'the die to show exactly game-die-face-$face'));
    expect(
      idleArt,
      isFalse,
      reason: why(step, 'no idle cube while the die shows its landed face'),
    );
    expect(
      marks,
      mark ? 1 : 0,
      reason: why(
        step,
        mark
            ? 'exactly one own-die-roll-again on the die'
            : 'no own-die-roll-again anywhere',
      ),
    );
  }

  /// The normal idle die: the cube, no face, no mark, pulsing unless motion
  /// is reduced.
  void expectIdle(String step) {
    expect(
      faces,
      isEmpty,
      reason: why(step, 'no face on the die once the hold is over'),
    );
    expect(
      idleArt,
      isTrue,
      reason: why(step, 'the idle cube (game-die-idle-art) on the die'),
    );
    expect(
      marks,
      0,
      reason: why(step, 'the roll-again mark gone once the hold is over'),
    );
    expect(
      pulsing,
      !reduced,
      reason: why(
        step,
        reduced
            ? 'no pulse under reduced motion'
            : 'the normal idle pulsing die (game-die-pulse)',
      ),
    );
  }

  /// A tap on the die at the current time. Returns the number of `roll`
  /// envelopes it put on the wire.
  Future<int> tapDie() async {
    final int before = rolls;
    await tester.tap(_die, warnIfMissed: false);
    await tester.pump();
    return rolls - before;
  }

  /// A tap on one of my tokens; returns the `move` envelopes it sent.
  Future<int> tapToken(int token) async {
    final int before = movesSince(drive.transport, 0).length;
    await tester.tap(find.byKey(tokenHitKey(0, token)), warnIfMissed: false);
    await tester.pump();
    return movesSince(drive.transport, 0).length - before;
  }

  /// D2: a tap during the hold sends nothing and gets the invalid-tap
  /// feedback a disabled die already gives, and no roll-start cue.
  Future<void> expectTapRefused(String step) async {
    final int invalidBefore = cues(FeedbackCue.invalidTap);
    final int tapBefore = cues(FeedbackCue.tap);
    final int sent = await tapDie();
    expect(
      sent,
      0,
      reason: why(step, 'a tap during the hold to send no roll, sent $sent'),
    );
    expect(
      cues(FeedbackCue.invalidTap) - invalidBefore,
      1,
      reason: why(
        step,
        'the existing invalid-tap feedback once for the refused tap',
      ),
    );
    expect(
      cues(FeedbackCue.tap) - tapBefore,
      0,
      reason: why(step, 'no tap (roll-start) cue for a refused tap'),
    );
  }

  /// After the hold: a tap rolls, exactly once.
  Future<void> expectTapRolls(String step) async {
    final int sent = await tapDie();
    expect(
      sent,
      1,
      reason: why(step, 'a tap after the hold to send exactly one roll'),
    );
  }
}

typedef _Body = Future<void> Function(_Game g);

/// Mounts GameScreen for seat 0 on [turn] over [seats] inside a keyed
/// RepaintBoundary (for the pixel case) and runs [body]; the screen and the
/// controller are released whatever [body] does.
Future<void> _run(
  WidgetTester tester, {
  required String item,
  Locale locale = _en,
  bool reduced = false,
  List<int> mine = _openTokens,
  List<int> other = const <int>[-1, -1, -1, -1],
  Map<String, Object?>? turn,
  required _Body body,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn ?? _myRollTurn(),
    seats: twoSeats(mine: mine, other: other),
  );
  await tester.pumpWidget(
    rollTrayHarness(
      RepaintBoundary(
        key: _shotKey,
        child: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: drive.feedback,
          child: GameScreen(controller: drive.controller),
        ),
      ),
      locale: locale,
      disableAnimations: reduced,
    ),
  );
  await tester.pump();
  await tester.pump();
  final _Game g = _Game(tester, drive, item, locale, reduced);
  try {
    await body(g);
  } finally {
    await releaseGame(tester, drive);
  }
}

/// My six that owes a roll, as the server sends it: `rolled` 6 with queue
/// [6] and no legal token, then my own `turn` in await_roll.
Future<void> _mySixOwesRoll(
  _Game g, {
  int k = 1,
  List<int> queue = const <int>[6],
}) async {
  await g.pushRolled(_rolledData(0, 6, queue: queue, k: k));
  await g.push('turn', _awaitRollTurn(0, queue));
}

/// The D1/D2/D3 timeline of one six that owes a roll, counted from its
/// arrival: faces and mark at 100, 500 and 850 ms, a refused tap at 500, the
/// idle die at 950 and a tap that rolls once.
Future<void> _expectSixTimeline(_Game g, {required String label}) async {
  await g.advanceTo(100);
  g.expectFace('$label 100 ms', 6, mark: true);
  await g.advanceTo(500);
  g.expectFace('$label 500 ms', 6, mark: true);
  await g.expectTapRefused('$label tap at 500 ms');
  g.expectFace('$label 500 ms after the refused tap', 6, mark: true);
  await g.advanceTo(850);
  g.expectFace('$label 850 ms', 6, mark: true);
  await g.advanceTo(_holdMs + 50);
  g.expectIdle('$label 950 ms');
  await g.expectTapRolls('$label tap at 950 ms');
}

// --- geometry and pixels --------------------------------------------------------

/// True when [rect] touches the disc of radius [r] at [c].
bool _rectTouchesDisc(Rect rect, Offset c, double r) {
  final double nx = c.dx.clamp(rect.left, rect.right);
  final double ny = c.dy.clamp(rect.top, rect.bottom);
  return (Offset(nx, ny) - c).distance < r;
}

/// Opaque pixels of [rgba] (a [width] px wide RGBA buffer) inside [rect] that
/// sit within [tolerance] of [colour], and the rect's pixel area.
(int, int) _colourPixels(
  ByteData rgba,
  int width,
  int height,
  Rect rect,
  Color colour, {
  int tolerance = 40,
}) {
  final Uint8List bytes = rgba.buffer.asUint8List(
    rgba.offsetInBytes,
    rgba.lengthInBytes,
  );
  final int r = (colour.r * 255).round();
  final int gr = (colour.g * 255).round();
  final int b = (colour.b * 255).round();
  final int x0 = rect.left.floor().clamp(0, width);
  final int x1 = rect.right.ceil().clamp(0, width);
  final int y0 = rect.top.floor().clamp(0, height);
  final int y1 = rect.bottom.ceil().clamp(0, height);
  int hits = 0;
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      final int i = (y * width + x) * 4;
      if (bytes[i + 3] < 250) {
        continue;
      }
      if ((bytes[i] - r).abs() <= tolerance &&
          (bytes[i + 1] - gr).abs() <= tolerance &&
          (bytes[i + 2] - b).abs() <= tolerance) {
        hits++;
      }
    }
  }
  return (hits, (x1 - x0) * (y1 - y0));
}

/// The width the face's own painter is drawn at, through every ancestor
/// transform, so a scale applied anywhere above the painter shows up.
double _faceDrawnWidth(WidgetTester tester, int face) {
  final Finder painter = find
      .descendant(
        of: find.byKey(bigFaceKey(face)),
        matching: find.byType(CustomPaint),
      )
      .first;
  return tester.getRect(painter).width;
}

void main() {
  // ===========================================================================
  // 1 and 2. My six that owes a roll, full and reduced motion (D1, D2, D3).
  // ===========================================================================
  for (final bool reduced in <bool>[false, true]) {
    final String mode = reduced ? 'reduced motion' : 'full motion';

    testWidgets('C-653t ${reduced ? 2 : 1}: my six then a same-seat '
        'await_roll turn, $mode: face 6 and the mark at 100/500/850 ms, a '
        'tap at 500 sends no roll, at 950 the idle die rolls once', (
      tester,
    ) async {
      await _run(
        tester,
        item: reduced ? '2' : '1',
        reduced: reduced,
        body: (_Game g) async {
          g.expectIdle('fixture: before any roll');
          await _mySixOwesRoll(g);
          await _expectSixTimeline(g, label: 'six');
        },
      );
    });
  }

  testWidgets('C-653t 1b: the hold counts from the rolled frame, not from the '
      'turn frame that follows it 200 ms later', (tester) async {
    await _run(
      tester,
      item: '1b',
      body: (_Game g) async {
        await g.pushRolled(_rolledData(0, 6, queue: const <int>[6], k: 1));
        await g.advanceTo(200);
        await g.push('turn', _awaitRollTurn(0, const <int>[6]));
        g.expectFace('turn just arrived', 6, mark: true);
        await g.advanceTo(850);
        g.expectFace('850 ms after the rolled frame', 6, mark: true);
        await g.expectTapRefused('tap at 850 ms');
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('950 ms after the rolled frame, 750 after the turn');
        await g.expectTapRolls('tap at 950 ms');
      },
    );
  });

  testWidgets('C-653t 1c: a room snapshot in the middle of the hold does not '
      'cut it short', (tester) async {
    await _run(
      tester,
      item: '1c',
      body: (_Game g) async {
        await _mySixOwesRoll(g);
        await g.advanceTo(300);
        await g.push(
          'room',
          roomData(
            seats: twoSeats(mine: _openTokens),
            turn: turnJson(
              seat: 0,
              phase: 'await_roll',
              k: 1,
              queue: const <int>[6],
            ),
          ),
        );
        await g.advanceTo(850);
        expect(
          g.faces,
          <int>[6],
          reason: g.why(
            'room snapshot at 300 ms',
            'the die still on face 6 at 850 ms, whatever frames follow (D1)',
          ),
        );
        await g.expectTapRefused('tap at 850 ms');
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('950 ms');
        await g.expectTapRolls('tap at 950 ms');
      },
    );
  });

  // ===========================================================================
  // 3. A non-6 with a legal move: the face, never the mark (D3).
  // ===========================================================================
  testWidgets('C-653t 3: my 4 with legal moves (await_move): face 4 shown, '
      'no mark, at every sampled time', (tester) async {
    await _run(
      tester,
      item: '3',
      body: (_Game g) async {
        await g.pushRolled(
          _rolledData(
            0,
            4,
            queue: const <int>[4],
            legal: const <int>[0, 1],
            legalByFace: <Map<String, Object?>>[
              faceLegal(4, const <int>[0, 1]),
            ],
            k: 1,
          ),
        );
        for (final int ms in <int>[0, 100, 500, 850, 950, 1500]) {
          await g.advanceTo(ms);
          g.expectFace('4 with legal moves, $ms ms', 4, mark: false);
        }
      },
    );
  });

  // ===========================================================================
  // 4. Another seat's six: nothing on my die (D3).
  // ===========================================================================
  testWidgets('C-653t 4: another seat rolls a 6 and owes a roll: no mark '
      'anywhere and my die is unchanged', (tester) async {
    await _run(
      tester,
      item: '4',
      turn: _theirRollTurn(),
      body: (_Game g) async {
        final List<int> facesBefore = g.faces;
        final bool idleBefore = g.idleArt;
        await g.pushRolled(_rolledData(1, 6, queue: const <int>[6], k: 1));
        await g.push('turn', _awaitRollTurn(1, const <int>[6]));
        for (final int ms in <int>[0, 100, 500, 850, 950, 1500]) {
          await g.advanceTo(ms);
          expect(
            g.marks,
            0,
            reason: g.why(
              'seat 1 rolled a 6',
              'no own-die-roll-again for another seat\'s six',
            ),
          );
          expect(
            g.faces,
            facesBefore,
            reason: g.why(
              'seat 1 rolled a 6',
              'my die to keep showing $facesBefore, as before the roll',
            ),
          );
          expect(
            g.idleArt,
            idleBefore,
            reason: g.why(
              'seat 1 rolled a 6',
              'my die\'s idle cube state unchanged ($idleBefore)',
            ),
          );
        }
      },
    );
  });

  // ===========================================================================
  // 5. Two sixes in a row: each rolled restarts the hold (D1).
  // ===========================================================================
  testWidgets('C-653t 5a: a second six after the first hold: its own 900 ms '
      'starts at its own arrival', (tester) async {
    await _run(
      tester,
      item: '5a',
      body: (_Game g) async {
        await _mySixOwesRoll(g, k: 1, queue: const <int>[6]);
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('first six, 950 ms');
        await g.expectTapRolls('first six, tap at 950 ms');
        await g.advanceTo(1050);
        await _mySixOwesRoll(g, k: 2, queue: const <int>[6, 6]);
        g.expectFace('second six arrival', 6, mark: true);
        await g.advanceTo(100);
        g.expectFace('second six 100 ms', 6, mark: true);
        await g.advanceTo(500);
        g.expectFace('second six 500 ms', 6, mark: true);
        final int before = g.rolls;
        await g.expectTapRefused('second six tap at 500 ms');
        expect(
          g.rolls,
          before,
          reason: g.why('second six', 'no extra roll from the refused tap'),
        );
        await g.advanceTo(850);
        g.expectFace('second six 850 ms', 6, mark: true);
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('second six 950 ms');
        await g.expectTapRolls('second six tap at 950 ms');
        expect(
          g.rolls,
          before + 1,
          reason: g.why('second six', 'two rolls in all, one per hold'),
        );
      },
    );
  });

  testWidgets('C-653t 5b: a second six that arrives 500 ms into the first '
      'hold restarts it: still held 850 ms after the second, gone at 950', (
    tester,
  ) async {
    await _run(
      tester,
      item: '5b',
      body: (_Game g) async {
        await _mySixOwesRoll(g, k: 1, queue: const <int>[6]);
        await g.advanceTo(500);
        g.expectFace('first six 500 ms', 6, mark: true);
        await _mySixOwesRoll(g, k: 2, queue: const <int>[6, 6]);
        // The first hold would end at 900 ms after the first arrival, which
        // is 400 ms after the second; the die must still be held there.
        await g.advanceTo(400);
        g.expectFace(
          'second six 400 ms (the first hold ran out here)',
          6,
          mark: true,
        );
        await g.advanceTo(850);
        g.expectFace('second six 850 ms', 6, mark: true);
        await g.expectTapRefused('second six tap at 850 ms');
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('second six 950 ms');
        await g.expectTapRolls('second six tap at 950 ms');
      },
    );
  });

  // ===========================================================================
  // 6. The mark's label, both locales (D3).
  // ===========================================================================
  for (final Locale locale in <Locale>[_en, _ar]) {
    final bool ar = locale.languageCode == 'ar';
    testWidgets('C-653t 6: ${locale.languageCode}: the mark carries the '
        'Semantics label "${ar ? _rollAgainAr : _rollAgainEn}"', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        await _run(
          tester,
          item: '6',
          locale: locale,
          body: (_Game g) async {
            await _mySixOwesRoll(g);
            await g.advanceTo(500);
            expect(
              g.marks,
              1,
              reason: g.why('label', 'the mark present before reading it'),
            );
            final SemanticsNode node = tester.getSemantics(
              find.byKey(_markKey),
            );
            final String want = ar ? _rollAgainAr : _rollAgainEn;
            expect(
              node.label,
              contains(want),
              reason: g.why(
                'semantics of own-die-roll-again',
                'a label containing "$want", read "${node.label}"',
              ),
            );
            if (ar) {
              expect(
                node.label,
                isNot(contains(_rollAgainEn)),
                reason: g.why(
                  'semantics of own-die-roll-again',
                  'no English label in the Arabic locale, read "${node.label}"',
                ),
              );
            }
          },
        );
      } finally {
        handle.dispose();
      }
    });
  }

  // ===========================================================================
  // 7. A 6 then a 3 (queue [6, 3], await_move): the 3's hold, no mark.
  // ===========================================================================
  testWidgets('C-653t 7: a 6 then a 3 (queue [6, 3], await_move): during '
      'the 3\'s hold the face is 3 and there is no mark', (tester) async {
    await _run(
      tester,
      item: '7',
      body: (_Game g) async {
        await _mySixOwesRoll(g, k: 1, queue: const <int>[6]);
        await g.advanceTo(500);
        g.expectFace('the six, 500 ms', 6, mark: true);
        await g.advanceTo(_holdMs + 50);
        g.expectIdle('the six, 950 ms');
        await g.expectTapRolls('tap at 950 ms for the second roll');
        await g.advanceTo(1100);
        await g.pushRolled(
          _rolledData(
            0,
            3,
            queue: const <int>[6, 3],
            legal: const <int>[0, 1, 2, 3],
            legalByFace: <Map<String, Object?>>[
              faceLegal(6, const <int>[0, 1, 2, 3]),
              faceLegal(3, const <int>[0, 1]),
            ],
            k: 2,
          ),
        );
        for (final int ms in <int>[0, 100, 500, 850]) {
          await g.advanceTo(ms);
          g.expectFace('the 3, $ms ms', 3, mark: false);
        }
        await g.advanceTo(_holdMs + 50);
        expect(
          g.marks,
          0,
          reason: g.why('the 3, after its hold', 'no mark at any time'),
        );
        await g.advanceTo(1500);
        expect(
          g.marks,
          0,
          reason: g.why('the 3, long after', 'no mark at any time'),
        );
      },
    );
  });

  // ===========================================================================
  // 3b. A 6 that passes the turn owes no roll: no mark (D3).
  // ===========================================================================
  testWidgets('C-653t 3b: a 6 with no legal move that passes the turn '
      '(no_legal_move): no mark', (tester) async {
    await _run(
      tester,
      item: '3b',
      mine: _nearHomeTokens,
      body: (_Game g) async {
        await g.pushRolled(_rolledData(0, 6, queue: const <int>[], k: 1));
        await g.push('turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'no_legal_move',
        });
        await g.push('turn', _awaitRollTurn(1, const <int>[]));
        for (final int ms in <int>[0, 100, 500, 850, 950]) {
          await g.advanceTo(ms);
          expect(
            g.marks,
            0,
            reason: g.why(
              'a 6 that voids the turn',
              'no own-die-roll-again: the roll is not owed',
            ),
          );
        }
      },
    );
  });

  testWidgets('C-653t 3c: a third six (three_sixes) hands the turn on: no '
      'mark', (tester) async {
    await _run(
      tester,
      item: '3c',
      body: (_Game g) async {
        await g.pushRolled(_rolledData(0, 6, queue: const <int>[], k: 3));
        await g.push('turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'three_sixes',
        });
        await g.push('turn', _awaitRollTurn(1, const <int>[]));
        for (final int ms in <int>[0, 100, 500, 850, 950]) {
          await g.advanceTo(ms);
          expect(
            g.marks,
            0,
            reason: g.why(
              'a third six that voids the turn',
              'no own-die-roll-again: the roll is not owed',
            ),
          );
        }
      },
    );
  });

  // ===========================================================================
  // 8. The mark's geometry and colour (D3).
  // ===========================================================================
  testWidgets('C-653t 8: the mark is at least 20 dp, sits on a corner of the '
      'die without covering a pip, and is drawn in the legal-ring green', (
    tester,
  ) async {
    await _run(
      tester,
      item: '8',
      body: (_Game g) async {
        await _mySixOwesRoll(g);
        await g.advanceTo(500);
        expect(
          g.marks,
          1,
          reason: g.why('geometry', 'the mark present before measuring it'),
        );
        final Rect die = tester.getRect(find.byKey(bigDieKey));
        final Rect mark = tester.getRect(find.byKey(_markKey));
        expect(
          mark.width >= _markMinDp && mark.height >= _markMinDp,
          isTrue,
          reason: g.why(
            'geometry',
            'a mark of at least $_markMinDp x $_markMinDp dp, measured '
                '${mark.width} x ${mark.height} (die $die, mark $mark)',
          ),
        );
        expect(
          mark.overlaps(die),
          isTrue,
          reason: g.why(
            'geometry',
            'the mark on the die (die $die, mark $mark)',
          ),
        );
        final Offset dc = die.center;
        final Offset mc = mark.center;
        expect(
          (mc.dx - dc.dx).abs() >= die.width * 0.25 &&
              (mc.dy - dc.dy).abs() >= die.height * 0.25,
          isTrue,
          reason: g.why(
            'geometry',
            'the mark centred on a corner region of the die (centre at least '
                'a quarter of the die away from the die centre on both axes); '
                'die $die, mark $mark',
          ),
        );
        final Size dieSize = die.size;
        final double pipR = pipRadiusFor(dieSize);
        for (final Offset pip in pipCentresFor(6, dieSize)) {
          final Offset at = die.topLeft + pip;
          expect(
            _rectTouchesDisc(mark, at, pipR),
            isFalse,
            reason: g.why(
              'geometry',
              'the mark clear of every pip of the 6; it covers the pip at '
                  '$at (radius $pipR), mark $mark',
            ),
          );
        }

        // Colour: the legal-ring green, as pixels, whatever widget draws it.
        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(_shotKey),
        );
        late ByteData rgba;
        late int width;
        late int height;
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
          width = image.width;
          height = image.height;
          final ByteData? bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          if (bytes == null) {
            fail('toByteData produced no pixel data for the play surface');
          }
          rgba = bytes;
        });
        final Offset origin = tester.getTopLeft(find.byKey(_shotKey));
        final (int green, int area) = _colourPixels(
          rgba,
          width,
          height,
          mark.shift(-origin),
          LudoColors.success,
        );
        expect(
          green >= 30,
          isTrue,
          reason: g.why(
            'colour',
            'at least 30 px of LudoColors.success (the legal-ring green) '
                'inside the mark, found $green of $area px in $mark',
          ),
        );
        expect(
          green <= area * 0.7,
          isTrue,
          reason: g.why(
            'shape',
            'a glyph (an arrow with open space), not a solid green block: '
                '$green of $area px are green in $mark',
          ),
        );
      },
    );
  });

  // ===========================================================================
  // 9. The pop (D4).
  // ===========================================================================
  testWidgets('C-653t 9a: full motion: the landed face scales 1.0 -> 1.2 -> '
      '1.0 over 300 ms', (tester) async {
    await _run(
      tester,
      item: '9a',
      body: (_Game g) async {
        await _mySixOwesRoll(g);
        final Map<int, double> width = <int, double>{};
        for (int ms = 0; ms <= 500; ms += 50) {
          await g.advanceTo(ms);
          expect(g.faces, <int>[
            6,
          ], reason: g.why('pop sampling', 'face 6 at every sample'));
          width[ms] = _faceDrawnWidth(tester, 6);
        }
        final double base = width[500]!;
        final String samples = width.entries
            .map((e) => '${e.key}ms=${(e.value / base).toStringAsFixed(3)}')
            .join(' ');
        expect(
          width[0]! / base <= 1.05,
          isTrue,
          reason: g.why('pop start', 'scale 1.0 at the start; $samples'),
        );
        double peak = 0;
        for (int ms = 50; ms <= 250; ms += 50) {
          if (width[ms]! > peak) {
            peak = width[ms]!;
          }
        }
        expect(
          peak / base >= _popPeak - 0.05 && peak / base <= _popPeak + 0.05,
          isTrue,
          reason: g.why(
            'pop peak',
            'a peak scale of about $_popPeak between 50 and 250 ms; $samples',
          ),
        );
        expect(
          width[50]! / base > 1.02,
          isTrue,
          reason: g.why(
            'pop rise',
            'the scale already rising at 50 ms; $samples',
          ),
        );
        expect(
          (width[_popMs]! / base - 1).abs() <= 0.02,
          isTrue,
          reason: g.why('pop end', 'back to scale 1.0 by $_popMs ms; $samples'),
        );
        for (int ms = _popMs; ms <= 500; ms += 50) {
          expect(
            (width[ms]! / base - 1).abs() <= 0.01,
            isTrue,
            reason: g.why(
              'pop settled',
              'scale 1.0 from $_popMs ms on; $samples',
            ),
          );
        }
      },
    );
  });

  testWidgets('C-653t 9b: reduced motion: no scale at any time in the hold', (
    tester,
  ) async {
    await _run(
      tester,
      item: '9b',
      reduced: true,
      body: (_Game g) async {
        await _mySixOwesRoll(g);
        final Map<int, double> width = <int, double>{};
        for (int ms = 0; ms <= 500; ms += 50) {
          await g.advanceTo(ms);
          expect(g.faces, <int>[
            6,
          ], reason: g.why('no-pop sampling', 'face 6 at every sample'));
          width[ms] = _faceDrawnWidth(tester, 6);
        }
        final double base = width[500]!;
        final String samples = width.entries
            .map((e) => '${e.key}ms=${(e.value / base).toStringAsFixed(3)}')
            .join(' ');
        for (final MapEntry<int, double> e in width.entries) {
          expect(
            (e.value / base - 1).abs() <= 0.005,
            isTrue,
            reason: g.why(
              'no scale',
              'the face never scaled under reduced motion; $samples',
            ),
          );
        }
      },
    );
  });

  // ===========================================================================
  // 17. Another seat's rolled ends my hold at once (rule 4a over D1).
  // ===========================================================================
  testWidgets('C-653t 17: another seat\'s rolled 300 ms into my hold clears my '
      'held face and my mark in the same frame, and neither comes back', (
    tester,
  ) async {
    await _run(
      tester,
      item: '17',
      body: (_Game g) async {
        await _mySixOwesRoll(g);
        await g.advanceTo(300);
        g.expectFace('my six, just before the other seat rolls', 6, mark: true);
        await g.push(
          'rolled',
          _rolledData(
            1,
            5,
            queue: const <int>[5],
            legal: const <int>[0],
            legalByFace: <Map<String, Object?>>[
              faceLegal(5, const <int>[0]),
            ],
            k: 1,
          ),
        );
        expect(
          g.faces,
          isEmpty,
          reason: g.why(
            'seat 1 rolled 5 at +300 ms, same frame',
            'my die to drop the held face 6 at once and never show seat 1\'s '
                'face 5',
          ),
        );
        expect(
          g.marks,
          0,
          reason: g.why(
            'seat 1 rolled 5 at +300 ms, same frame',
            'own-die-roll-again gone at once with the held face',
          ),
        );
        for (final int ms in <int>[350, 500, 850, 950, 1500]) {
          await g.advanceTo(ms);
          expect(
            g.faces,
            isEmpty,
            reason: g.why(
              'after seat 1\'s rolled',
              'no face on my die (not the stale 6, not seat 1\'s 5)',
            ),
          );
          expect(
            g.marks,
            0,
            reason: g.why(
              'after seat 1\'s rolled',
              'the mark does not come back while the old hold would have run',
            ),
          );
        }
        expect(
          g.idleArt,
          isTrue,
          reason: g.why(
            'long after seat 1\'s rolled',
            'my die on the idle cube',
          ),
        );
      },
    );
  });

  // ===========================================================================
  // 18 and 19. My own moved ends my hold at once (D1 as amended in return 2).
  // ===========================================================================
  for (final bool reduced in <bool>[false, true]) {
    final String mode = reduced ? 'reduced motion' : 'full motion';

    testWidgets('C-653t 18: my 4, token tap at 200 ms, then a home arrival '
        '(moved extra_roll true) and a same-seat await_roll turn, $mode: no '
        'held face and no mark after the moved, one roll for a tap at 250 ms', (
      tester,
    ) async {
      await _run(
        tester,
        item: '18',
        reduced: reduced,
        // Token 0 is four squares from home: the 4 takes it there.
        mine: const <int>[53, 20, -1, -1],
        body: (_Game g) async {
          await g.pushRolled(
            _rolledData(
              0,
              4,
              queue: const <int>[4],
              legal: const <int>[0, 1],
              legalByFace: <Map<String, Object?>>[
                faceLegal(4, const <int>[0, 1]),
              ],
              k: 1,
            ),
          );
          await g.advanceTo(100);
          g.expectFace('my 4 held, before the token tap', 4, mark: false);
          await g.advanceTo(200);
          final int moves = await g.tapToken(0);
          expect(
            moves,
            1,
            reason: g.why(
              'token tap at 200 ms',
              'exactly one move, sent $moves',
            ),
          );
          await g.push('moved', <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 53,
            'to': 57,
            'captured': <Object?>[],
            'extra_roll': true,
            'face': 4,
          });
          await g.push('turn', _awaitRollTurn(0, const <int>[]));
          expect(
            g.faces,
            isEmpty,
            reason: g.why(
              'the frame after my home moved',
              'no held face 4: the face is spent, the hold ends with my moved',
            ),
          );
          expect(
            g.marks,
            0,
            reason: g.why(
              'the frame after my home moved',
              'no own-die-roll-again',
            ),
          );
          await g.advanceTo(250);
          g.expectIdle('50 ms after the moved, inside the old 900 ms hold');
          await g.expectTapRolls('die tap at 250 ms, bonus roll owed');
          await g.advanceTo(_holdMs + 50);
          expect(
            g.marks,
            0,
            reason: g.why('old hold would be over', 'no mark at any time'),
          );
        },
      );
    });

    testWidgets('C-653t 19: my 4, token tap at 200 ms, then a capture '
        '(moved extra_roll true, captured seat 1) and a same-seat await_roll '
        'turn, $mode: no held face and no mark after the moved, one roll for '
        'a tap at 250 ms', (tester) async {
      await _run(
        tester,
        item: '19',
        reduced: reduced,
        mine: const <int>[10, 20, -1, -1],
        other: const <int>[14, -1, -1, -1],
        body: (_Game g) async {
          await g.pushRolled(
            _rolledData(
              0,
              4,
              queue: const <int>[4],
              legal: const <int>[0, 1],
              legalByFace: <Map<String, Object?>>[
                faceLegal(4, const <int>[0, 1]),
              ],
              k: 1,
            ),
          );
          await g.advanceTo(100);
          g.expectFace('my 4 held, before the token tap', 4, mark: false);
          await g.advanceTo(200);
          final int moves = await g.tapToken(0);
          expect(
            moves,
            1,
            reason: g.why(
              'token tap at 200 ms',
              'exactly one move, sent $moves',
            ),
          );
          await g.push('moved', <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 10,
            'to': 14,
            'captured': <Map<String, int>>[
              <String, int>{'seat': 1, 'token': 0},
            ],
            'extra_roll': true,
            'face': 4,
          });
          await g.push('turn', _awaitRollTurn(0, const <int>[]));
          expect(
            g.faces,
            isEmpty,
            reason: g.why(
              'the frame after my capture moved',
              'no held face 4: the face is spent, the hold ends with my moved',
            ),
          );
          expect(
            g.marks,
            0,
            reason: g.why(
              'the frame after my capture moved',
              'no own-die-roll-again',
            ),
          );
          await g.advanceTo(250);
          g.expectIdle('50 ms after the moved, inside the old 900 ms hold');
          await g.expectTapRolls('die tap at 250 ms, bonus roll owed');
          await g.advanceTo(_holdMs + 50);
          expect(
            g.marks,
            0,
            reason: g.why('old hold would be over', 'no mark at any time'),
          );
        },
      );
    });
  }
}
