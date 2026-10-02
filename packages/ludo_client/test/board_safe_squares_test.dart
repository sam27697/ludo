// Holds LudoBoard to work/ludo/orders/C-241-safe-squares.md's "What proves
// it", bullet by bullet. Written from the contract and docs/RULES.md alone;
// order 241 (lib/src/board.dart, lib/src/board_geometry.dart) is being built
// in parallel by a different worker and this file was not written against
// its content.
//
// safeTrackSquares and safeSquareCell do not exist on the base commit
// (origin/main 4bdfe9c) that order 241 has not yet landed on; this file is
// expected to fail to compile there, by the master's own design for order
// 242's acceptance.
//
// Mounting copies test/board_test.dart's _harness (a fixed SizedBox around
// a bare LudoBoard) and test/play_surface_tokens_test.dart's way of driving
// a token tap (tester.tap on the board-token-hit-S-I key) -- copied, not
// imported, per the order. Pixel checks render through a RepaintBoundary
// with tester.runAsync around toImage/toByteData (standing lesson 8: no
// pumpEventQueue() in testWidgets). Every testWidgets body here pumps
// exactly one widget tree (standing lesson 35: one mount per case).

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/theme.dart';

// docs/RULES.md section 1.3, verbatim: "Eight squares on the main track are
// safe, absolute indices: 0, 8, 13, 21, 26, 34, 39, 47. That is the four
// entry squares plus the square eight ahead of each." This literal list is
// the spec every assertion below is held to; it is written out here rather
// than read off safeTrackSquares, so a wrong implementation cannot grade
// itself.
const List<int> _rulesSafeSquares = <int>[0, 8, 13, 21, 26, 34, 39, 47];

// A board of known side, per the contract's own example: 450x450, so
// cellSize is exactly 450 / 15 = 30.
const double _boardSide = 450;
const double _cellSize = _boardSide / 15;

Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in <int>[0, 1, 2, 3]) seat: <int>[-1, -1, -1, -1],
};

Rect _cellRect(BoardCell cell) => Rect.fromLTWH(
  cell.col * _cellSize,
  cell.row * _cellSize,
  _cellSize,
  _cellSize,
);

// The default test surface (800x600 logical) is bigger than the 450x450
// board, so Scaffold's Center would otherwise offset the board away from
// (0, 0) and every absolute-pixel assertion below would be comparing
// against the wrong origin. Pinning the surface to exactly the board's own
// side makes Center's offset zero, so _cellRect's (0, 0)-anchored maths and
// the sampled image's pixels agree with what tester.getRect and the pixel
// probe actually read.
void _pinViewportToBoard(WidgetTester tester) {
  tester.view.physicalSize = const Size(_boardSide, _boardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _harness({
  required Map<int, List<int>> tokens,
  List<int> seatsInPlay = const <int>[0, 1, 2, 3],
  int? mySeat,
  Set<int> legal = const <int>{},
  void Function(int token)? onTokenTap,
  void Function(int token)? onIllegalTokenTap,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: _boardSide,
            height: _boardSide,
            child: LudoBoard(
              tokens: tokens,
              seatsInPlay: seatsInPlay,
              mySeat: mySeat,
              legal: legal,
              onTokenTap: onTokenTap,
              onIllegalTokenTap: onIllegalTokenTap,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('safeTrackSquares is the RULES.md 1.3 list, in that order (bullet 1)', () {
    test(
      'equals [0, 8, 13, 21, 26, 34, 39, 47] exactly, same order, no extras',
      () {
        expect(
          safeTrackSquares,
          _rulesSafeSquares,
          reason:
              'safeTrackSquares must equal the RULES.md 1.3 list '
              '$_rulesSafeSquares in that exact order; got $safeTrackSquares. '
              'A star on index 9 instead of 8 would first show up as a '
              'mismatch here.',
        );
      },
    );
  });

  group('safeSquareCell(n) agrees with cellFor for every seat, the same '
      'square seen from each seat (bullet 3)', () {
    test('safeSquareCell(n) == cellFor(seat: s, progress: (n - 13 * s) % 52) '
        'for every seat 0..3 and every n in the safe list', () {
      for (final int n in _rulesSafeSquares) {
        final BoardCell direct = safeSquareCell(n);
        for (int seat = 0; seat < 4; seat++) {
          final int progress = (n - 13 * seat) % 52;
          final BoardCell viaSeat = cellFor(seat: seat, progress: progress);
          expect(
            direct,
            viaSeat,
            reason:
                'safeSquareCell($n) is $direct, but cellFor(seat: $seat, '
                'progress: $progress) is $viaSeat; the same absolute '
                'square must read identically from every seat (seed: '
                'n=$n, seat=$seat)',
          );
        }
      }
    });
  });

  group('safeSquareCell rejects out-of-range absolute indices (bullet 4)', () {
    test('safeSquareCell(-1) throws ArgumentError', () {
      expect(
        () => safeSquareCell(-1),
        throwsArgumentError,
        reason:
            'safeSquareCell(-1) is outside 0..51 and must throw '
            'ArgumentError, like cellFor: reject, never repair',
      );
    });

    test('safeSquareCell(52) throws ArgumentError', () {
      expect(
        () => safeSquareCell(52),
        throwsArgumentError,
        reason:
            'safeSquareCell(52) is outside 0..51 and must throw '
            'ArgumentError, like cellFor: reject, never repair',
      );
    });
  });

  group('exactly one star widget per safe square, correctly placed, on a '
      'spectator board (bullet 2; catches a star on index 9 instead of 8, or '
      'a star missing/mislaid, and also catches stars drawn only when '
      'mySeat is set -- this board has no mySeat at all)', () {
    testWidgets('board-safe-<n> exists exactly for n in the safe list, each at '
        'safeSquareCell(n)\'s rect within 0.5px, and for no other n in 0..51', (
      WidgetTester tester,
    ) async {
      _pinViewportToBoard(tester);
      await tester.pumpWidget(_harness(tokens: _allInYard()));
      await tester.pump();

      for (int n = 0; n <= 51; n++) {
        final Finder finder = find.byKey(Key('board-safe-$n'));
        final bool shouldExist = _rulesSafeSquares.contains(n);

        expect(
          finder,
          shouldExist ? findsOneWidget : findsNothing,
          reason:
              'n=$n: expected board-safe-$n to be '
              '${shouldExist ? "present exactly once" : "absent"}; a '
              'star on the wrong index would show up here',
        );

        if (shouldExist) {
          final Rect actual = tester.getRect(finder);
          final Rect expected = _cellRect(safeSquareCell(n));
          expect(
            actual.left,
            closeTo(expected.left, 0.5),
            reason:
                'board-safe-$n left edge: expected ${expected.left}, '
                'got ${actual.left} (seed: n=$n)',
          );
          expect(
            actual.top,
            closeTo(expected.top, 0.5),
            reason:
                'board-safe-$n top edge: expected ${expected.top}, '
                'got ${actual.top} (seed: n=$n)',
          );
          expect(
            actual.width,
            closeTo(expected.width, 0.5),
            reason:
                'board-safe-$n width: expected ${expected.width}, '
                'got ${actual.width} (seed: n=$n)',
          );
          expect(
            actual.height,
            closeTo(expected.height, 0.5),
            reason:
                'board-safe-$n height: expected ${expected.height}, '
                'got ${actual.height} (seed: n=$n)',
          );
        }
      }
    });
  });

  group('the eight stars are also drawn on a board where mySeat and legal are '
      'set (bullet 2 / ruling 5; catches stars drawn only when mySeat is '
      'null, the mirror image of the spectator-board case above)', () {
    testWidgets(
      'board-safe-<n> is present for all eight safe squares when mySeat '
      'is 0 and tokens are legal and tappable',
      (WidgetTester tester) async {
        _pinViewportToBoard(tester);
        final Map<int, List<int>> tokens = _allInYard();
        tokens[0] = <int>[3, -1, -1, -1];

        await tester.pumpWidget(
          _harness(tokens: tokens, mySeat: 0, legal: const <int>{0}),
        );
        await tester.pump();

        for (final int n in _rulesSafeSquares) {
          expect(
            find.byKey(Key('board-safe-$n')),
            findsOneWidget,
            reason:
                'board-safe-$n must still be present when mySeat is set '
                'and token 0 is legal; a board that only draws stars for '
                'the spectator view would fail here (seed: n=$n)',
          );
        }
      },
    );
  });

  group('start squares are filled in the entering seat\'s colour (bullet 5; '
      'catches a start square painted in the wrong seat\'s colour, or left '
      'as plain track)', () {
    testWidgets('a point near the corner of each entry cell, outside the star, '
        'reads closer to LudoColors.seats[s] than to the plain track cell '
        'next to it, and within tolerance of the documented alpha blend', (
      WidgetTester tester,
    ) async {
      _pinViewportToBoard(tester);
      await tester.pumpWidget(_harness(tokens: _allInYard()));
      await tester.pump();

      final RenderRepaintBoundary boundary = tester.renderObject(
        find.byType(RepaintBoundary).first,
      );

      ui.Image? renderedImage;
      ByteData? pixels;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        final ByteData? data = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        renderedImage = image;
        pixels = data;
      });

      final ui.Image image = renderedImage!;
      final ByteData rgba = pixels!;
      if (rgba.lengthInBytes < image.width * image.height * 4) {
        fail(
          'rendering the board produced ${rgba.lengthInBytes} bytes, '
          'too few for a ${image.width}x${image.height} RGBA image',
        );
      }
      final double scale = image.width / _boardSide;

      Color sampleAt(double localX, double localY) {
        final int x = (localX * scale).round().clamp(0, image.width - 1);
        final int y = (localY * scale).round().clamp(0, image.height - 1);
        final int i = (y * image.width + x) * 4;
        return Color.fromARGB(
          rgba.getUint8(i + 3),
          rgba.getUint8(i),
          rgba.getUint8(i + 1),
          rgba.getUint8(i + 2),
        );
      }

      double sqDistance(Color a, Color b) {
        final double dr = a.r - b.r;
        final double dg = a.g - b.g;
        final double db = a.b - b.b;
        return dr * dr + dg * dg + db * db;
      }

      // The plain main-track fill under any non-safe cell: paperElevated
      // at alpha 0.65 over the board's dieFace background (board.dart's
      // existing, unchanged fill order for progress 0..51).
      final Color plainTrackBlend = Color.alphaBlend(
        LudoColors.paperElevated.withValues(alpha: 0.65),
        LudoColors.dieFace,
      );

      for (int seat = 0; seat < 4; seat++) {
        final int entry = 13 * seat;
        final BoardCell entryCell = safeSquareCell(entry);
        final Rect entryRect = _cellRect(entryCell);
        // 3px in from the cell's own top-left corner: clear of the
        // board's 2px outer border stroke (entry cells sit on an outer
        // edge by construction) and clear of the star, which covers
        // about 70% of the cell centred, leaving a 4.5px margin.
        final Color sampled = sampleAt(entryRect.left + 3, entryRect.top + 3);

        final BoardCell neighborCell = cellFor(
          seat: 0,
          progress: (entry + 1) % 52,
        );
        final Rect neighborRect = _cellRect(neighborCell);
        final Color plainNeighbor = sampleAt(
          neighborRect.left + _cellSize / 2,
          neighborRect.top + _cellSize / 2,
        );

        final Color seatColor = LudoColors.seats[seat];
        expect(
          sqDistance(sampled, seatColor) < sqDistance(sampled, plainNeighbor),
          isTrue,
          reason:
              'seat $seat entry square (absolute $entry, cell '
              '$entryCell): sampled colour $sampled must read closer to '
              'LudoColors.seats[$seat] ($seatColor) than to the plain '
              'track fill sampled next to it ($plainNeighbor); a start '
              'square painted in the wrong seat\'s colour, or left '
              'unpainted, fails this (seed: seat=$seat, entry=$entry)',
        );

        final Color expectedBlend = Color.alphaBlend(
          seatColor.withValues(alpha: 0.85),
          plainTrackBlend,
        );
        const double tolerance = 0.08; // about 20/255, clear of the
        // sampling margin chosen above
        final bool withinTolerance =
            (sampled.r - expectedBlend.r).abs() <= tolerance &&
            (sampled.g - expectedBlend.g).abs() <= tolerance &&
            (sampled.b - expectedBlend.b).abs() <= tolerance;
        expect(
          withinTolerance,
          isTrue,
          reason:
              'seat $seat entry square: sampled colour $sampled is not '
              'within $tolerance of Color.alphaBlend(LudoColors.seats'
              '[$seat] at alpha 0.85, <track fill under it>) = '
              '$expectedBlend (seed: seat=$seat, entry=$entry)',
        );
      }
    });
  });

  group('a tap on a legal token sitting on a safe square still sends exactly '
      'one move (bullet 6; catches a star without IgnorePointer stealing '
      'the tap)', () {
    Future<void> expectTapStillReachesToken(
      WidgetTester tester, {
      required int progress,
      required String caseName,
    }) async {
      _pinViewportToBoard(tester);
      final List<int> tapped = <int>[];
      final List<int> shaken = <int>[];
      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[progress, -1, -1, -1];

      await tester.pumpWidget(
        _harness(
          tokens: tokens,
          mySeat: 0,
          legal: const <int>{0},
          onTokenTap: tapped.add,
          onIllegalTokenTap: shaken.add,
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('board-token-hit-0-0')));
      await tester.pump();

      expect(
        tapped,
        <int>[0],
        reason:
            '$caseName (seat 0 token 0 at progress $progress, a safe '
            'square): tapping board-token-hit-0-0 must call onTokenTap '
            'exactly once with token 0; got $tapped. If the star for '
            'this square is not wrapped in IgnorePointer, it can steal '
            'the tap before it reaches the token.',
      );
      expect(
        shaken,
        isEmpty,
        reason:
            '$caseName: onIllegalTokenTap must not fire for a legal tap; '
            'got $shaken',
      );
      expect(
        find.byKey(const Key('board-token-shake-0-0')),
        findsNothing,
        reason:
            '$caseName: a legal tap must not trigger the illegal-tap '
            'shake widget',
      );
    }

    testWidgets('on an entry square (absolute 0, progress 0)', (
      WidgetTester tester,
    ) async {
      await expectTapStillReachesToken(
        tester,
        progress: 0,
        caseName: 'entry safe square',
      );
    });

    testWidgets('on a non-entry safe square (absolute 8, progress 8)', (
      WidgetTester tester,
    ) async {
      await expectTapStillReachesToken(
        tester,
        progress: 8,
        caseName: 'non-entry safe square',
      );
    });
  });
}
