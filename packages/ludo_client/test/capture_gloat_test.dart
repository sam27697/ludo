// Screen proof for C-468 D5 (order 469): the capture gloat. Written from
// the contract's text alone. A real GameScreen over a real RoomController
// on FakeTransport, every state a decoded wire frame, the recording
// FeedbackService from support/roll_tray_harness.dart.
//
// Time is measured from the first frame the gloat is on screen. The pump
// step is 5 ms, so a moment is known to within 5 ms; every bound below
// leaves that much room and no more. The surface is 360x800 at pixel ratio
// 1, so a logical pixel is a device pixel.
//
// This file does not compile on a tree without FeedbackCue.gloat, which is
// the expected failing arm on the base.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

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
  List<int>? captured,
  int players = 2,
  Locale locale = const Locale('en'),
  bool reduced = false,
  bool snap = false,
  Map<String, Object?>? turn,
}) async {
  phoneSurface(tester);
  final int other = me == 0 ? 2 : 0;
  final List<int> victims =
      captured ?? <int>[players == 2 ? (mover == me ? other : me) : 2];
  final List<Map<String, Object?>> seats;
  if (players == 2) {
    final int moverSeat = mover;
    seats = <Map<String, Object?>>[
      for (final int seat in const <int>[0, 2])
        seatJson(
          seat,
          name: seat == me ? 'Sam' : 'Bob',
          tokens: seat == moverSeat
              ? (snap ? kYard : _moverTokens)
              : _victimTokens,
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
    locale: locale,
    disableAnimations: reduced,
    turn: turn ?? awaitRollTurn(mover),
    seats: seats,
  );
  return _Fix(Scn(name, tester, drive), me, mover, victims);
}

Future<void> _pushCapture(_Fix f, {bool extraRoll = false}) => f.s.push(
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
Future<int> _captureAndWait(_Fix f) async {
  await _pushCapture(f);
  final int? t0 = await pumpUntilGloat(f.s);
  expect(
    t0,
    isNotNull,
    reason: f.s.why('a capturing moved starts a gloat for seat ${f.mover}'),
  );
  return t0!;
}

Future<void> _pumpTo(Scn s, int clockMs) async {
  if (clockMs > s.clockMs) {
    await s.pump(Duration(milliseconds: clockMs - s.clockMs), step: kC468Fine);
  }
}

String _gloatList(WidgetTester tester) => '${gloatSeats(tester)}';

/// The colour at [global] in the nearest repaint boundary above [key].
Future<Color> _pixel(WidgetTester tester, Finder key, Offset global) async {
  RenderObject boundary = tester.renderObject(key);
  while (!boundary.isRepaintBoundary) {
    boundary = boundary.parent!;
  }
  final RenderBox box = boundary as RenderBox;
  final Offset local = box.globalToLocal(global);
  final ui.Image? image = await tester.runAsync<ui.Image>(
    () => (box.debugLayer! as OffsetLayer).toImage(box.paintBounds),
  );
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final int x = local.dx.round();
  final int y = local.dy.round();
  final int at = (y * image!.width + x) * 4;
  return Color.fromARGB(
    data!.getUint8(at + 3),
    data.getUint8(at),
    data.getUint8(at + 1),
    data.getUint8(at + 2),
  );
}

bool _near(Color a, Color b, int tolerance) =>
    ((a.r - b.r).abs() * 255) <= tolerance &&
    ((a.g - b.g).abs() * 255) <= tolerance &&
    ((a.b - b.b).abs() * 255) <= tolerance;

double _luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

void main() {
  // -------------------------------------------------------------------
  // D5.1: trigger and moment.
  // -------------------------------------------------------------------
  for (final (int me, int mover) in const <(int, int)>[(0, 0), (0, 2)]) {
    testWidgets(
      'D5.1: a capturing moved by seat $mover (I am $me) shows the gloat '
      'when the mover lands, not before',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'D5.1 landing me=$me mover=$mover',
          me: me,
          mover: mover,
        );
        try {
          await _pushCapture(f);
          expect(
            gloatSeats(tester),
            isEmpty,
            reason: f.s.why('no gloat on the frame itself'),
          );
          for (int square = 1; square <= 5; square++) {
            await f.s.pump(kTokenStepDuration);
            expect(
              gloatSeats(tester),
              isEmpty,
              reason: f.s.why(
                'the token has walked $square of 6 squares, no gloat yet '
                '(on screen: ${_gloatList(tester)})',
              ),
            );
          }
          await f.s.pump(kTokenStepDuration);
          await f.s.pump(kC468Frame * 2);
          expect(
            gloatSeats(tester),
            <int>[mover],
            reason: f.s.why(
              'the sixth square landed: exactly capture-gloat-$mover',
            ),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'D5.1: when the board snaps to truth instead of walking the gloat '
    'starts at once',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.1 snap',
        me: 0,
        mover: 2,
        snap: true,
      );
      try {
        await _pushCapture(f);
        await f.s.pump(kC468Frame * 3);
        expect(
          gloatSeats(tester),
          <int>[2],
          reason: f.s.why(
            'the mover\'s token jumped from the yard (a snap, no walk), so '
            'the gloat starts within a few frames',
          ),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets('D5.1: a moved with an empty captured list shows no gloat', (
    tester,
  ) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.1 empty captured',
      me: 0,
      mover: 2,
    );
    try {
      await f.s.push('moved', movedFrame(2, 0, 3, 9));
      await f.s.pump(const Duration(milliseconds: 2500));
      expect(
        gloatSeats(tester),
        isEmpty,
        reason: f.s.why('a plain move never gloats'),
      );
      expect(
        f.s.count(FeedbackCue.gloat),
        0,
        reason: f.s.why('and plays no gloat sound'),
      );
    } finally {
      await releaseGame(tester, f.s.drive);
    }
  });

  testWidgets(
    'D5.1: a room snapshot that moves tokens as a capture would (a snap) '
    'shows no gloat and plays no gloat sound',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.1 snapshot',
        me: 0,
        mover: 2,
        snap: true,
      );
      try {
        await f.s.push(
          'room',
          roomData(
            seats: <Map<String, Object?>>[
              seatJson(0, name: 'Sam', tokens: kYard),
              seatJson(2, name: 'Bob', tokens: const <int>[9, -1, -1, -1]),
            ],
            turn: awaitRollTurn(2, k: 3),
          ),
        );
        await f.s.pump(const Duration(milliseconds: 2500));
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: f.s.why('a snapshot never starts a gloat'),
        );
        expect(f.s.count(FeedbackCue.gloat), 0, reason: f.s.why('no sound'));
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets(
    'D5.1: a resync after a roll (recent rolls not an append) shows no '
    'gloat',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.1 resync',
        me: 0,
        mover: 2,
      );
      try {
        await f.s.push('rolled', rolledFrame(2, 6, 1, legal: const <int>[0]));
        await f.s.pump(const Duration(milliseconds: 1800));
        await f.s.push(
          'room',
          roomData(
            seats: <Map<String, Object?>>[
              seatJson(0, name: 'Sam', tokens: kYard),
              seatJson(2, name: 'Bob', tokens: const <int>[9, -1, -1, -1]),
            ],
            turn: awaitRollTurn(2, k: 4),
          ),
        );
        await f.s.pump(const Duration(milliseconds: 2500));
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: f.s.why('a resync never starts a gloat'),
        );
        expect(f.s.count(FeedbackCue.gloat), 0, reason: f.s.why('no sound'));
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D5.2: place, size, art.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final (int me, int mover) in const <(int, int)>[(0, 0), (0, 2)]) {
      testWidgets(
        'D5.2: ${locale.languageCode}, seat $mover\'s gloat (I am $me) is '
        'centred on its viewed yard and is 2 cells wide',
        (tester) async {
          final _Fix f = await _fixture(
            tester,
            name: 'D5.2 place ${locale.languageCode} me=$me mover=$mover',
            me: me,
            mover: mover,
            locale: locale,
          );
          try {
            final int t0 = await _captureAndWait(f);
            await _pumpTo(f.s, t0 + 1000);
            expect(gloatSeats(tester), <int>[
              mover,
            ], reason: f.s.why('fixture: the gloat is on screen in its hold'));
            final Rect quadrant = yardQuadrantViewRect(
              boardSquare(tester),
              mover,
              me,
            );
            final Rect yardToken = tester.getRect(
              find.byKey(Key('token-$mover-1')),
            );
            expect(
              quadrant.inflate(1).contains(yardToken.center),
              isTrue,
              reason: f.s.why(
                'fixture: seat $mover\'s yard token ${yardToken.center} is in '
                'the quadrant $quadrant this test measures against',
              ),
            );
            final Rect rect = tester.getRect(f.gloat);
            final double cell = cellSize(tester);
            expect(
              (rect.center - quadrant.center).distance,
              lessThanOrEqualTo(1.0),
              reason: f.s.why(
                'gloat centre ${rect.center} on the yard centre '
                '${quadrant.center}',
              ),
            );
            expect(
              rect.width,
              closeTo(2 * cell, 1.0),
              reason: f.s.why('gloat width $rect is 2 cells = ${2 * cell}'),
            );
            expect(
              rect.height,
              closeTo(2 * cell, 1.0),
              reason: f.s.why('gloat height $rect is 2 cells = ${2 * cell}'),
            );
          } finally {
            await releaseGame(tester, f.s.drive);
          }
        },
      );
    }
  }

  for (final (int me, int mover) in const <(int, int)>[(0, 0), (0, 2)]) {
    testWidgets(
      'D5.2: seat $mover\'s gloat (I am $me) is a disc in seat $mover\'s '
      'colour with a darker rim, drawn with no text',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'D5.2 colour me=$me mover=$mover',
          me: me,
          mover: mover,
        );
        try {
          final int t0 = await _captureAndWait(f);
          await _pumpTo(f.s, t0 + 1000);
          final Rect rect = tester.getRect(f.gloat);
          final double radius = rect.width / 2;
          final Color fill = LudoColors.seats[mover];
          final Color forehead = await _pixel(
            tester,
            f.gloat,
            rect.center + Offset(0, -0.7 * radius),
          );
          expect(
            _near(forehead, fill, 4),
            isTrue,
            reason: f.s.why(
              'the disc is filled with seat $mover\'s colour $fill; the '
              'pixel above the eyes is $forehead',
            ),
          );
          final Color rim = await _pixel(
            tester,
            f.gloat,
            rect.center + Offset(0, -(radius - 1.0)),
          );
          expect(
            _luma(rim),
            lessThan(_luma(fill) - 0.03),
            reason: f.s.why(
              'the 2 dp rim is darker than the fill: rim $rim fill $fill',
            ),
          );
          final Finder text = find.descendant(
            of: f.gloat,
            matching: find.byWidgetPredicate(
              (Widget w) => w is Text || w is RichText || w is Icon,
            ),
          );
          expect(
            text,
            findsNothing,
            reason: f.s.why('painted, with no font glyph or icon in it'),
          );
          expect(
            find.descendant(of: f.gloat, matching: find.byType(CustomPaint)),
            findsWidgets,
            reason: f.s.why('painted by a CustomPaint'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'D5.2: layers: above the tokens and the seat die, below the thrown die; '
    'above the seat record',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.2 layers',
        me: 0,
        mover: 0,
      );
      try {
        final int t0 = await _captureAndWait(f);
        final Element stack = boardStackOf(tester);
        final int gloatSlot = stackSlot(tester, stack, f.gloat);
        for (final Key key in const <Key>[
          Key('token-0-0'),
          Key('token-0-1'),
          Key('token-2-0'),
          Key('board-seat-die-2'),
        ]) {
          expect(
            stackSlot(tester, stack, find.byKey(key)),
            lessThan(gloatSlot),
            reason: f.s.why('$key paints under the gloat'),
          );
        }
        await f.s.push('turn', turnFrame(2));
        await f.s.push(
          'rolled',
          rolledFrame(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
        );
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: f.s.why('fixture: the gloat is still up'));
        expect(
          find.byKey(opponentThrowKey(2)),
          findsOneWidget,
          reason: f.s.why('fixture: seat 2\'s thrown die is up'),
        );
        expect(
          stackSlot(tester, stack, find.byKey(opponentThrowKey(2))),
          greaterThan(stackSlot(tester, stack, f.gloat)),
          reason: f.s.why('the thrown die paints over the gloat'),
        );
        final int stop = t0 + 1400;
        while (!tester.any(find.byKey(seatRecordKey(2))) &&
            f.s.clockMs < stop) {
          await f.s.pump(kC468Fine, step: kC468Fine);
        }
        expect(
          find.byKey(seatRecordKey(2)),
          findsOneWidget,
          reason: f.s.why('fixture: seat 2\'s roll record is on the board'),
        );
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: f.s.why('fixture: the gloat is still up beside the record'));
        expect(
          stackSlot(tester, stack, find.byKey(seatRecordKey(2))),
          lessThan(stackSlot(tester, stack, f.gloat)),
          reason: f.s.why('the seat record paints under the gloat'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets('D5.2: the gloat takes no tap: a legal token under it still '
      'sends its move', (tester) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.2 tap through',
      me: 0,
      mover: 0,
    );
    try {
      await _captureAndWait(f);
      await f.s.push('turn', turnFrame(0));
      await f.s.push(
        'rolled',
        rolledFrame(
          0,
          6,
          1,
          legal: const <int>[1],
          queue: const <int>[6],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[1]),
          ],
        ),
      );
      expect(gloatSeats(tester), <int>[
        0,
      ], reason: f.s.why('fixture: the gloat is up over my yard'));
      // The token's 48dp hit area only partly overlaps the gloat, so the
      // tap point is the centre of the overlap, inside both (order 469
      // RETURN 1).
      final Rect hit = tester.getRect(find.byKey(tokenHitKey(0, 1)));
      final Rect gloatRect = tester.getRect(f.gloat);
      final Rect overlap = hit.intersect(gloatRect);
      expect(
        overlap.width > 0 && overlap.height > 0,
        isTrue,
        reason: f.s.why(
          'fixture: token 1\'s hit area $hit overlaps the gloat $gloatRect',
        ),
      );
      final Offset point = overlap.center;
      expect(
        hit.contains(point) && gloatRect.contains(point),
        isTrue,
        reason: f.s.why(
          'fixture: the tap point $point is inside the token hit area $hit '
          'and the gloat $gloatRect',
        ),
      );
      final int sentBefore = f.s.drive.transport.sentRaw.length;
      await tester.tapAt(point);
      await tester.pump();
      f.s.steps.add('tap token-0-1 at $point');
      final List<Map<String, Object?>> moves = movesSince(
        f.s.drive.transport,
        sentBefore,
      );
      expect(
        moves,
        hasLength(1),
        reason: f.s.why('the tap went through to the token'),
      );
      expect(moves.single['token'], 1, reason: f.s.why('and named token 1'));
    } finally {
      await releaseGame(tester, f.s.drive);
    }
  });

  for (final bool mine in const <bool>[true, false]) {
    testWidgets(
      'D5.2: the gloat adds no semantics node (${mine ? 'my' : 'their'} '
      'gloat)',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final _Fix f = await _fixture(
          tester,
          name: 'D5.2 semantics mine=$mine',
          me: 0,
          mover: mine ? 0 : 2,
        );
        try {
          final int t0 = await _captureAndWait(f);
          await _pumpTo(f.s, t0 + 600);
          final List<String> owners = <String>[];
          void visit(RenderObject object) {
            if (object.debugSemantics != null) {
              owners.add('${object.runtimeType}');
            }
            object.visitChildren(visit);
          }

          visit(paintObjectOf(tester, f.gloat));
          final RenderObject root = tester.renderObject(f.gloat);
          visit(root);
          expect(
            owners,
            isEmpty,
            reason: f.s.why(
              'no render object under capture-gloat-${f.mover} owns a '
              'semantics node; found $owners',
            ),
          );
        } finally {
          handle.dispose();
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  // -------------------------------------------------------------------
  // D5.2: motion.
  // -------------------------------------------------------------------
  testWidgets(
    'D5.2: motion: pops from 0.4 to 1.15 and 1.0 by 300 ms, wobbles plus and '
    'minus 8 degrees to 800 ms, holds, rises half a cell from 1350 ms, gone '
    'at 1600 ms',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.2 motion',
        me: 0,
        mover: 2,
      );
      try {
        final int t0 = await _captureAndWait(f);
        final List<({int t, double scale, double deg, Offset centre})> trace =
            <({int t, double scale, double deg, Offset centre})>[];
        while (f.s.clockMs <= t0 + 1590) {
          final ({double scale, double degrees}) pose = poseOf(tester, f.gloat);
          trace.add((
            t: f.s.clockMs - t0,
            scale: pose.scale,
            deg: pose.degrees,
            centre: paintCentreOf(tester, f.gloat),
          ));
          await f.s.pump(kC468Fine, step: kC468Fine);
          if (gloatSeats(tester).isEmpty) {
            break;
          }
        }
        final String summary =
            'first ${trace.first}, last ${trace.last}, ${trace.length} samples';
        expect(
          trace.first.scale,
          inInclusiveRange(0.35, 0.65),
          reason: f.s.why('pop starts near 0.4 scale; $summary'),
        );
        final pop = trace.where((e) => e.t <= 300).toList();
        final peak = pop.reduce((a, b) => a.scale >= b.scale ? a : b);
        expect(
          peak.scale,
          inInclusiveRange(1.12, 1.18),
          reason: f.s.why('pop overshoots to 1.15; peak $peak'),
        );
        expect(
          peak.t,
          inInclusiveRange(140, 230),
          reason: f.s.why('the overshoot lands near 180 ms; peak $peak'),
        );
        for (final e in trace.where((e) => e.t >= 320 && e.t <= 1340)) {
          expect(
            e.scale,
            closeTo(1.0, 0.02),
            reason: f.s.why('settled at scale 1.0 from 300 ms; sample $e'),
          );
        }
        final wobble = trace.where((e) => e.t >= 320 && e.t <= 780).toList();
        final double high = wobble.map((e) => e.deg).reduce(math.max);
        final double low = wobble.map((e) => e.deg).reduce(math.min);
        expect(
          high,
          inInclusiveRange(7.0, 9.0),
          reason: f.s.why('wobble reaches +8 degrees; max $high min $low'),
        );
        expect(
          low,
          inInclusiveRange(-9.0, -7.0),
          reason: f.s.why('wobble reaches -8 degrees; max $high min $low'),
        );
        final holdAt = trace.firstWhere((e) => e.t >= 900);
        for (final e in trace.where((e) => e.t >= 860 && e.t <= 1340)) {
          expect(
            e.deg.abs(),
            lessThan(0.5),
            reason: f.s.why('upright while holding; sample $e'),
          );
          expect(
            (e.centre - holdAt.centre).distance,
            lessThan(1.0),
            reason: f.s.why('still while holding; sample $e'),
          );
        }
        final double cell = cellSize(tester);
        final late = trace.where((e) => e.t >= 1570).toList();
        expect(late, isNotEmpty, reason: f.s.why('still up at 1570 ms'));
        final double risen = holdAt.centre.dy - late.last.centre.dy;
        expect(
          risen,
          inInclusiveRange(0.35 * cell, 0.55 * cell),
          reason: f.s.why(
            'rose ${risen.toStringAsFixed(1)} px by ${late.last.t} ms; half '
            'a cell is ${(cell / 2).toStringAsFixed(1)} px',
          ),
        );
        expect(
          late.last.centre.dx,
          closeTo(holdAt.centre.dx, 1.0),
          reason: f.s.why('it rises straight up'),
        );
        await _pumpTo(f.s, t0 + 1610);
        expect(
          gloatSeats(tester),
          isEmpty,
          reason: f.s.why('gone at 1600 ms (on screen: ${_gloatList(tester)})'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    testWidgets(
      'D5.2: reduced motion (${locale.languageCode}): full size and upright '
      'on the first frame, no scale, wobble or rise, removed at 1600 ms',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'D5.2 reduced ${locale.languageCode}',
          me: 0,
          mover: 2,
          locale: locale,
          reduced: true,
        );
        try {
          final int t0 = await _captureAndWait(f);
          final Rect quadrant = yardQuadrantViewRect(boardSquare(tester), 2, 0);
          final double cell = cellSize(tester);
          final Rect first = tester.getRect(f.gloat);
          expect(
            first.width,
            closeTo(2 * cell, 1.0),
            reason: f.s.why('first frame is 2 cells wide: $first'),
          );
          expect(
            (first.center - quadrant.center).distance,
            lessThanOrEqualTo(1.0),
            reason: f.s.why('first frame is on the yard centre'),
          );
          final Offset start = paintCentreOf(tester, f.gloat);
          while (f.s.clockMs <= t0 + 1500) {
            final ({double scale, double degrees}) pose = poseOf(
              tester,
              f.gloat,
            );
            final String at = '${f.s.clockMs - t0}ms';
            expect(
              pose.scale,
              closeTo(1.0, 0.005),
              reason: f.s.why('no ancestor scales it, at $at'),
            );
            expect(
              pose.degrees.abs(),
              lessThan(0.1),
              reason: f.s.why('no ancestor rotates it, at $at'),
            );
            expect(
              (paintCentreOf(tester, f.gloat) - start).distance,
              lessThan(0.5),
              reason: f.s.why('it does not rise, at $at'),
            );
            await f.s.pump(const Duration(milliseconds: 20), step: kC468Fine);
          }
          expect(gloatSeats(tester), <int>[
            2,
          ], reason: f.s.why('present at 1500 ms'));
          await _pumpTo(f.s, t0 + 1610);
          expect(
            gloatSeats(tester),
            isEmpty,
            reason: f.s.why('removed at 1600 ms'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets(
    'D5.2: with motion it is present at 1500 ms and gone at 1600 ms',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.2 lifetime',
        me: 0,
        mover: 0,
      );
      try {
        final int t0 = await _captureAndWait(f);
        await _pumpTo(f.s, t0 + 1500);
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: f.s.why('present at 1500 ms'));
        await _pumpTo(f.s, t0 + 1610);
        expect(gloatSeats(tester), isEmpty, reason: f.s.why('gone at 1600 ms'));
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

  testWidgets(
    'D5.1: a second capture while one shows replaces it: one gloat, the new '
    'seat, with its own full lifetime',
    (tester) async {
      phoneSurface(tester);
      final RollTrayDrive drive = await mountScreen(
        tester,
        turn: awaitRollTurn(2),
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: const <int>[3, 48, -1, -1]),
          seatJson(2, name: 'Bob', tokens: const <int>[3, 30, -1, -1]),
        ],
      );
      final Scn s = Scn('D5.1 replace', tester, drive);
      try {
        await s.push(
          'moved',
          movedFrame(
            2,
            0,
            3,
            9,
            captured: <Map<String, int>>[
              <String, int>{'seat': 0, 'token': 1},
            ],
          ),
        );
        final int? first = await pumpUntilGloat(s);
        expect(first, isNotNull, reason: s.why('seat 2\'s capture gloats'));
        expect(gloatSeats(tester), <int>[2], reason: s.why('fixture'));
        await s.push('turn', turnFrame(0));
        await s.push(
          'moved',
          movedFrame(
            0,
            0,
            3,
            9,
            captured: <Map<String, int>>[
              <String, int>{'seat': 2, 'token': 1},
            ],
          ),
        );
        int guard = 0;
        while (!gloatSeats(tester).contains(0)) {
          expect(
            gloatSeats(tester).length,
            lessThanOrEqualTo(1),
            reason: s.why('never two gloats at once: ${_gloatList(tester)}'),
          );
          await s.pump(kC468Fine, step: kC468Fine);
          guard += 1;
          expect(
            guard,
            lessThan(400),
            reason: s.why('seat 0\'s capture gloats within 2 s'),
          );
        }
        final int second = s.clockMs;
        expect(
          second - first!,
          lessThan(1500),
          reason: s.why('fixture: the first gloat was still up'),
        );
        expect(gloatSeats(tester), <int>[
          0,
        ], reason: s.why('the new gloat replaced the old: only seat 0\'s'));
        await _pumpTo(s, second + 1500);
        expect(
          gloatSeats(tester),
          <int>[0],
          reason: s.why(
            'the replacement runs its own 1600 ms, still up at 1500 ms',
          ),
        );
        await _pumpTo(s, second + 1610);
        expect(gloatSeats(tester), isEmpty, reason: s.why('then it is gone'));
      } finally {
        await releaseGame(tester, drive);
      }
    },
  );

  // -------------------------------------------------------------------
  // D5.3: who hears it.
  // -------------------------------------------------------------------
  testWidgets(
    'D5.3: the captured seat records gloat 250 ms after the gloat starts '
    '(absent at 200, present by 300), once',
    (tester) async {
      final _Fix f = await _fixture(
        tester,
        name: 'D5.3 timing',
        me: 0,
        mover: 2,
      );
      try {
        final int t0 = await _captureAndWait(f);
        expect(
          f.s.count(FeedbackCue.gloat),
          0,
          reason: f.s.why('not on the first frame of the gloat'),
        );
        int? heardAt;
        while (f.s.clockMs <= t0 + 400) {
          if (heardAt == null && f.s.count(FeedbackCue.gloat) > 0) {
            heardAt = f.s.clockMs - t0;
          }
          if (f.s.clockMs - t0 == 200) {
            expect(
              f.s.count(FeedbackCue.gloat),
              0,
              reason: f.s.why('absent at 200 ms'),
            );
          }
          await f.s.pump(kC468Fine, step: kC468Fine);
        }
        expect(
          heardAt,
          isNotNull,
          reason: f.s.why('present by 300 ms after the gloat starts'),
        );
        expect(
          heardAt,
          inInclusiveRange(240, 270),
          reason: f.s.why('heard ${heardAt}ms after the gloat started, 250'),
        );
        await _pumpTo(f.s, t0 + 2200);
        expect(
          f.s.count(FeedbackCue.gloat),
          1,
          reason: f.s.why('exactly once for one capture'),
        );
      } finally {
        await releaseGame(tester, f.s.drive);
      }
    },
  );

  testWidgets('D5.3: two of my tokens captured in one move sound one gloat', (
    tester,
  ) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.3 two tokens',
      me: 0,
      mover: 2,
    );
    try {
      await f.s.push(
        'moved',
        movedFrame(
          2,
          0,
          3,
          9,
          captured: <Map<String, int>>[
            <String, int>{'seat': 0, 'token': 2},
            <String, int>{'seat': 0, 'token': 1},
          ],
        ),
      );
      await f.s.pump(const Duration(milliseconds: 2800));
      expect(
        f.s.count(FeedbackCue.gloat),
        1,
        reason: f.s.why('one move, one gloat sound'),
      );
    } finally {
      await releaseGame(tester, f.s.drive);
    }
  });

  for (final (int me, int expected, String role) in const <(int, int, String)>[
    (0, 0, 'the capturer'),
    (1, 0, 'a third seat'),
    (2, 1, 'the captured seat'),
    (3, 0, 'a third seat'),
  ]) {
    testWidgets(
      'D5.3: four seats, seat 0 captures seat 2: I am seat $me, $role: the '
      'gloat is shown and gloat is heard $expected time(s)',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'D5.3 four seats me=$me',
          me: me,
          mover: 0,
          captured: const <int>[2],
          players: 4,
        );
        try {
          final int t0 = await _captureAndWait(f);
          expect(gloatSeats(tester), <int>[
            0,
          ], reason: f.s.why('every seat sees the capturer\'s gloat'));
          await _pumpTo(f.s, t0 + 2200);
          expect(
            f.s.count(FeedbackCue.gloat),
            expected,
            reason: f.s.why('seat $me ($role) hears gloat $expected time(s)'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  for (final (int me, int expected) in const <(int, int)>[
    (1, 1),
    (2, 1),
    (3, 0),
  ]) {
    testWidgets(
      'D5.3: four seats, seat 0 captures seats 1 and 2 in one move: seat '
      '$me hears gloat $expected time(s)',
      (tester) async {
        final _Fix f = await _fixture(
          tester,
          name: 'D5.3 two victims me=$me',
          me: me,
          mover: 0,
          captured: const <int>[1, 2],
          players: 4,
        );
        try {
          final int t0 = await _captureAndWait(f);
          await _pumpTo(f.s, t0 + 2200);
          expect(
            f.s.count(FeedbackCue.gloat),
            expected,
            reason: f.s.why('seat $me hears gloat $expected time(s)'),
          );
        } finally {
          await releaseGame(tester, f.s.drive);
        }
      },
    );
  }

  testWidgets('D5.3: a game_over inside the 250 ms cancels the gloat sound', (
    tester,
  ) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.3 game over',
      me: 0,
      mover: 2,
    );
    try {
      final int t0 = await _captureAndWait(f);
      await _pumpTo(f.s, t0 + 100);
      await f.s.push('game_over', gameOverFrame(2));
      await f.s.pump(const Duration(milliseconds: 900));
      expect(
        f.s.count(FeedbackCue.gloat),
        0,
        reason: f.s.why('game over at ~100 ms: the 250 ms sound never plays'),
      );
    } finally {
      await releaseGame(tester, f.s.drive);
    }
  });

  testWidgets('D5.3: disposing the screen inside the 250 ms cancels the '
      'gloat sound', (tester) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.3 dispose',
      me: 0,
      mover: 2,
    );
    final int t0 = await _captureAndWait(f);
    await _pumpTo(f.s, t0 + 100);
    await releaseGame(tester, f.s.drive);
    await f.s.pump(const Duration(milliseconds: 900));
    expect(
      f.s.count(FeedbackCue.gloat),
      0,
      reason: f.s.why('unmounted at ~100 ms: the 250 ms sound never plays'),
    );
  });

  testWidgets('D5.3: a resync inside the 250 ms cancels the gloat sound', (
    tester,
  ) async {
    final _Fix f = await _fixture(
      tester,
      name: 'D5.3 resync',
      me: 0,
      mover: 2,
      turn: awaitRollTurn(2),
    );
    try {
      await f.s.push('rolled', rolledFrame(2, 5, 1, legal: const <int>[0]));
      await _pushCapture(f);
      final int? t0 = await pumpUntilGloat(f.s);
      expect(t0, isNotNull, reason: f.s.why('the capture gloats'));
      await _pumpTo(f.s, t0! + 100);
      await f.s.push(
        'room',
        roomData(
          seats: <Map<String, Object?>>[
            seatJson(0, name: 'Sam', tokens: kYard),
            seatJson(2, name: 'Bob', tokens: const <int>[9, -1, -1, -1]),
          ],
          turn: awaitRollTurn(2, k: 4),
        ),
      );
      await f.s.pump(const Duration(milliseconds: 900));
      expect(
        f.s.count(FeedbackCue.gloat),
        0,
        reason: f.s.why('a resync at ~100 ms removes the pending sound'),
      );
    } finally {
      await releaseGame(tester, f.s.drive);
    }
  });
}
