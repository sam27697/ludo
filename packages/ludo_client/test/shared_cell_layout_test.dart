// Pins shared-cell token layout and paint order on LudoBoard to contract
// C-386 (acceptance lines B1 to B8).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';

const double _boardSide = 360;
const double _cellSize = _boardSide / 15;
const double _epsilon = 0.5;

Key _tokenKey(int seat, int index) => Key('token-$seat-$index');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in <int>[0, 1, 2, 3]) seat: <int>[-1, -1, -1, -1],
};

Rect _viewCellRect(BoardCell boardCell, {required int? mySeat}) {
  final BoardCell viewed = toView(boardCell, viewQuarters(mySeat));
  return Rect.fromLTWH(
    viewed.col * _cellSize,
    viewed.row * _cellSize,
    _cellSize,
    _cellSize,
  );
}

bool _rectInside(Rect outer, Rect inner, [double epsilon = _epsilon]) {
  return inner.left >= outer.left - epsilon &&
      inner.top >= outer.top - epsilon &&
      inner.right <= outer.right + epsilon &&
      inner.bottom <= outer.bottom + epsilon;
}

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
  );
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Returns `(seat, tokenIndex)` pairs in the order their `token-<seat>-<index>`
/// keys appear when walking `tester.allElements`. `Stack` visits its children
/// in list order during element traversal, so this matches the board's
/// bottom-to-top paint order.
List<(int, int)> _paintOrder(WidgetTester tester, Iterable<(int, int)> tokens) {
  final Map<Key, (int, int)> byKey = <Key, (int, int)>{
    for (final (int seat, int index) in tokens)
      _tokenKey(seat, index): (seat, index),
  };
  final List<(int, int)> ordered = <(int, int)>[];
  for (final Element element in tester.allElements) {
    final Key? key = element.widget.key;
    final (int, int)? match = key == null ? null : byKey[key];
    if (match != null) {
      ordered.add(match);
    }
  }
  return ordered;
}

/// Exact area of [target] not covered by the union of [later] rects.
double _uncoveredArea(Rect target, List<Rect> later) {
  final List<Rect> clips = <Rect>[
    for (final Rect r in later)
      if (r.overlaps(target)) r.intersect(target),
  ];
  if (clips.isEmpty) {
    return target.width * target.height;
  }
  final List<double> xs = <double>{
    target.left,
    target.right,
    for (final Rect c in clips) ...<double>[c.left, c.right],
  }.toList()..sort();

  double covered = 0;
  for (int i = 0; i < xs.length - 1; i++) {
    final double x0 = xs[i];
    final double x1 = xs[i + 1];
    final double dx = x1 - x0;
    if (dx <= 0) {
      continue;
    }
    final double midX = (x0 + x1) / 2;
    final List<(double, double)> intervals = <(double, double)>[
      for (final Rect c in clips)
        if (c.left <= midX && c.right >= midX && c.top < c.bottom)
          (c.top, c.bottom),
    ]..sort(((double, double) a, (double, double) b) => a.$1.compareTo(b.$1));
    if (intervals.isEmpty) {
      continue;
    }
    double curTop = intervals.first.$1;
    double curBottom = intervals.first.$2;
    double coveredY = 0;
    for (int j = 1; j < intervals.length; j++) {
      final (double nextTop, double nextBottom) = intervals[j];
      if (nextTop <= curBottom) {
        if (nextBottom > curBottom) {
          curBottom = nextBottom;
        }
      } else {
        coveredY += curBottom - curTop;
        curTop = nextTop;
        curBottom = nextBottom;
      }
    }
    coveredY += curBottom - curTop;
    covered += dx * coveredY;
  }
  return math.max(0.0, target.width * target.height - covered);
}

/// Asserts C-386's visibility rule for [cellTokens]: no two drawn rects on the
/// cell are equal, and each token's drawn rect has at least 40% of its area
/// not covered by any token painted after it.
void _expectVisible(WidgetTester tester, List<(int, int)> cellTokens) {
  final List<(int, int)> ordered = _paintOrder(tester, cellTokens);
  expect(
    ordered.length,
    cellTokens.length,
    reason: 'expected all tokens $cellTokens in tree, found $ordered',
  );
  final List<Rect> rects = <Rect>[
    for (final (int seat, int index) in ordered)
      tester.getRect(find.byKey(_tokenKey(seat, index))),
  ];
  for (int i = 0; i < rects.length; i++) {
    for (int j = i + 1; j < rects.length; j++) {
      expect(
        rects[i] == rects[j],
        isFalse,
        reason:
            'token ${ordered[i]} and token ${ordered[j]} drawn rects must '
            'not be equal; both were ${rects[i]}',
      );
    }
    final double area = rects[i].width * rects[i].height;
    expect(
      area,
      greaterThan(0),
      reason: 'token ${ordered[i]} drawn rect must have positive area',
    );
    final double uncovered = _uncoveredArea(rects[i], rects.sublist(i + 1));
    final double fraction = uncovered / area;
    expect(
      fraction,
      greaterThanOrEqualTo(0.40),
      reason:
          'token ${ordered[i]} at ${rects[i]} has only '
          '${(fraction * 100).toStringAsFixed(1)}% uncovered by later tokens '
          '${ordered.sublist(i + 1)} (need >= 40%)',
    );
  }
}

void _expectRectClose(
  Rect actual,
  Rect expected, {
  required String label,
  double epsilon = _epsilon,
}) {
  expect(
    actual.width,
    closeTo(expected.width, epsilon),
    reason: '$label width: expected ${expected.width}, got ${actual.width}',
  );
  expect(
    actual.height,
    closeTo(expected.height, epsilon),
    reason: '$label height: expected ${expected.height}, got ${actual.height}',
  );
  expect(
    actual.center.dx,
    closeTo(expected.center.dx, epsilon),
    reason:
        '$label center.dx: expected ${expected.center.dx}, '
        'got ${actual.center.dx}',
  );
  expect(
    actual.center.dy,
    closeTo(expected.center.dy, epsilon),
    reason:
        '$label center.dy: expected ${expected.center.dy}, '
        'got ${actual.center.dy}',
  );
}

void main() {
  testWidgets(
    'B1: me seat 0 token 0 and seat 1 token 0 on one non-safe cell are both '
    'visible and mine is painted after seat 1',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      final BoardCell cell0 = cellFor(seat: 0, progress: 16, tokenIndex: 0);
      final BoardCell cell1 = cellFor(seat: 1, progress: 3, tokenIndex: 0);
      expect(
        cell0,
        cell1,
        reason:
            'fixture: seat 0 progress 16 and seat 1 progress 3 must share '
            'absolute square 16',
      );
      expect(
        cell0,
        safeSquareCell(16),
        reason: 'fixture: shared cell must be absolute main-track square 16',
      );
      expect(
        safeTrackSquares.contains(16),
        isFalse,
        reason: 'fixture: absolute square 16 must be a non-safe cell',
      );

      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[16, -1, -1, -1];
      tokens[1] = <int>[3, -1, -1, -1];

      await tester.pumpWidget(_harness(tokens: tokens, mySeat: 0));
      await tester.pump();
      try {
        const List<(int, int)> shared = <(int, int)>[(0, 0), (1, 0)];
        _expectVisible(tester, shared);

        final List<(int, int)> order = _paintOrder(tester, shared);
        expect(
          order,
          const <(int, int)>[(1, 0), (0, 0)],
          reason:
              'my token (0, 0) must be painted after seat 1 token (1, 0); '
              'got paint order $order',
        );
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'B2: seat 1 pair (tokens 0, 1) plus my token 0 on that cell are three '
    'visible at cellSize * 0.5 in L2 occupant slots',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      final BoardCell cell0 = cellFor(seat: 0, progress: 16, tokenIndex: 0);
      final BoardCell cell1a = cellFor(seat: 1, progress: 3, tokenIndex: 0);
      final BoardCell cell1b = cellFor(seat: 1, progress: 3, tokenIndex: 1);
      expect(
        cell0,
        cell1a,
        reason: 'fixture: seat 0 #0 and seat 1 #0 must share one cell',
      );
      expect(
        cell0,
        cell1b,
        reason: 'fixture: seat 0 #0 and seat 1 #1 must share one cell',
      );

      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[16, -1, -1, -1];
      tokens[1] = <int>[3, 3, -1, -1];

      await tester.pumpWidget(_harness(tokens: tokens, mySeat: 0));
      await tester.pump();
      try {
        const List<(int, int)> occupants = <(int, int)>[(1, 0), (1, 1), (0, 0)];
        _expectVisible(tester, occupants);

        final List<(int, int)> order = _paintOrder(tester, occupants);
        expect(
          order,
          occupants,
          reason:
              'occupants must paint in L2/L3 order (seat 1 #0, seat 1 #1, '
              'mine #0); got $order',
        );

        final Rect cellRect = _viewCellRect(cell0, mySeat: 0);
        final Offset cellCenter = cellRect.center;
        const double expectedSize = _cellSize * 0.5;
        const double step = _cellSize * 0.22;
        const List<(double, double)> slots = <(double, double)>[
          (-1, -1),
          (1, -1),
          (-1, 1),
        ];

        for (int i = 0; i < occupants.length; i++) {
          final (int seat, int index) = occupants[i];
          final (double dx, double dy) = slots[i];
          final Rect actual = tester.getRect(
            find.byKey(_tokenKey(seat, index)),
          );
          final Rect expected = Rect.fromCenter(
            center: cellCenter + Offset(dx * step, dy * step),
            width: expectedSize,
            height: expectedSize,
          );
          _expectRectClose(
            actual,
            expected,
            label: 'slot $i token-$seat-$index',
          );
        }
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'B3: safe square with four seats token 0 has all four visible and inside '
    'the cell',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      const int safeSquare = 8;
      expect(
        safeTrackSquares.contains(safeSquare),
        isTrue,
        reason: 'fixture: absolute square 8 must be in safeTrackSquares',
      );
      final BoardCell targetCell = safeSquareCell(safeSquare);
      const Map<int, int> progressBySeat = <int, int>{
        0: 8,
        1: 47,
        2: 34,
        3: 21,
      };
      for (final MapEntry<int, int> entry in progressBySeat.entries) {
        expect(
          cellFor(seat: entry.key, progress: entry.value, tokenIndex: 0),
          targetCell,
          reason:
              'fixture: seat ${entry.key} progress ${entry.value} must land '
              'on safe square $safeSquare ($targetCell)',
        );
      }

      final Map<int, List<int>> tokens = _allInYard();
      for (final MapEntry<int, int> entry in progressBySeat.entries) {
        tokens[entry.key] = <int>[entry.value, -1, -1, -1];
      }

      await tester.pumpWidget(
        _harness(
          tokens: tokens,
          seatsInPlay: const <int>[0, 1, 2, 3],
          mySeat: 0,
        ),
      );
      await tester.pump();
      try {
        const List<(int, int)> fourTokens = <(int, int)>[
          (1, 0),
          (2, 0),
          (3, 0),
          (0, 0),
        ];
        _expectVisible(tester, fourTokens);

        final Rect cellRect = _viewCellRect(targetCell, mySeat: 0);
        for (final (int seat, int index) in fourTokens) {
          final Rect rect = tester.getRect(find.byKey(_tokenKey(seat, index)));
          expect(
            _rectInside(cellRect, rect),
            isTrue,
            reason:
                'token-$seat-$index rect $rect must lie inside safe cell '
                'rect $cellRect',
          );
        }
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'B4: six tokens of three seats on one safe square use the 3 by 3 layout, '
    'all inside the cell and none equal',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      const int safeSquare = 8;
      expect(
        safeTrackSquares.contains(safeSquare),
        isTrue,
        reason: 'fixture: absolute square 8 must be in safeTrackSquares',
      );
      final BoardCell targetCell = safeSquareCell(safeSquare);
      const List<(int, int, int)> sixSpec = <(int, int, int)>[
        (1, 0, 47),
        (1, 1, 47),
        (2, 0, 34),
        (2, 1, 34),
        (0, 0, 8),
        (0, 1, 8),
      ];
      for (final (int seat, int index, int progress) in sixSpec) {
        expect(
          cellFor(seat: seat, progress: progress, tokenIndex: index),
          targetCell,
          reason:
              'fixture: seat $seat token $index at progress $progress must '
              'land on safe square $safeSquare ($targetCell)',
        );
      }

      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[8, 8, -1, -1];
      tokens[1] = <int>[47, 47, -1, -1];
      tokens[2] = <int>[34, 34, -1, -1];

      await tester.pumpWidget(
        _harness(
          tokens: tokens,
          seatsInPlay: const <int>[0, 1, 2, 3],
          mySeat: 0,
        ),
      );
      await tester.pump();
      try {
        const List<(int, int)> occupants = <(int, int)>[
          (1, 0),
          (1, 1),
          (2, 0),
          (2, 1),
          (0, 0),
          (0, 1),
        ];
        _expectVisible(tester, occupants);

        final Rect cellRect = _viewCellRect(targetCell, mySeat: 0);
        final Offset cellCenter = cellRect.center;
        const double expectedSize = _cellSize * 0.36;
        const double step = _cellSize * 0.3;

        for (int slot = 0; slot < occupants.length; slot++) {
          final (int seat, int index) = occupants[slot];
          final Rect actual = tester.getRect(
            find.byKey(_tokenKey(seat, index)),
          );
          expect(
            _rectInside(cellRect, actual),
            isTrue,
            reason:
                'token-$seat-$index rect $actual must lie inside safe cell '
                'rect $cellRect',
          );
          final int row = slot ~/ 3;
          final int col = slot % 3;
          final Rect expected = Rect.fromCenter(
            center: cellCenter + Offset((col - 1) * step, (row - 1) * step),
            width: expectedSize,
            height: expectedSize,
          );
          _expectRectClose(
            actual,
            expected,
            label: '3x3 slot $slot token-$seat-$index',
          );
        }
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'B5: single-seat cells keep exact 0.7 * cellSize size and 0.12 * cellSize '
    'fan offset for my pair and lone tokens of every seat',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      final BoardCell pairCell0 = cellFor(seat: 0, progress: 10, tokenIndex: 0);
      final BoardCell pairCell1 = cellFor(seat: 0, progress: 10, tokenIndex: 1);
      expect(
        pairCell0,
        pairCell1,
        reason:
            'fixture: seat 0 tokens 0 and 1 at progress 10 must share one cell',
      );

      final Map<int, (int, int)> loneTrackBySeat = <int, (int, int)>{
        0: (2, 20),
        1: (0, 5),
        2: (1, 5),
        3: (3, 5),
      };
      final Set<BoardCell> singleSeatCells = <BoardCell>{pairCell0};
      for (final MapEntry<int, (int, int)> entry in loneTrackBySeat.entries) {
        final int seat = entry.key;
        final (int tokenIndex, int progress) = entry.value;
        final BoardCell cell = cellFor(
          seat: seat,
          progress: progress,
          tokenIndex: tokenIndex,
        );
        expect(
          singleSeatCells.add(cell),
          isTrue,
          reason:
              'fixture: lone token of seat $seat at progress $progress must '
              'sit on its own unshared cell ($cell)',
        );
      }

      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[10, 10, 20, -1];
      tokens[1] = <int>[5, -1, -1, -1];
      tokens[2] = <int>[-1, 5, -1, -1];
      tokens[3] = <int>[-1, -1, -1, 5];

      await tester.pumpWidget(
        _harness(
          tokens: tokens,
          seatsInPlay: const <int>[0, 1, 2, 3],
          mySeat: 0,
        ),
      );
      await tester.pump();
      try {
        const double tokenSize = _cellSize * 0.7;
        const double fan = _cellSize * 0.12;

        void checkSingleSeatToken(int seat, int tokenIndex, int progress) {
          final BoardCell boardCell = cellFor(
            seat: seat,
            progress: progress,
            tokenIndex: tokenIndex,
          );
          final Rect cellRect = _viewCellRect(boardCell, mySeat: 0);
          final double fanDx = tokenIndex.isEven ? -fan : fan;
          final double fanDy = tokenIndex < 2 ? -fan : fan;
          final Rect expected = Rect.fromCenter(
            center: cellRect.center + Offset(fanDx, fanDy),
            width: tokenSize,
            height: tokenSize,
          );
          final Rect actual = tester.getRect(
            find.byKey(_tokenKey(seat, tokenIndex)),
          );
          _expectRectClose(
            actual,
            expected,
            label: 'single-seat token-$seat-$tokenIndex (progress $progress)',
          );
        }

        // My two tokens sharing one cell alone.
        checkSingleSeatToken(0, 0, 10);
        checkSingleSeatToken(0, 1, 10);

        // Lone track token of each seat 0..3.
        for (final MapEntry<int, (int, int)> entry in loneTrackBySeat.entries) {
          final (int tokenIndex, int progress) = entry.value;
          checkSingleSeatToken(entry.key, tokenIndex, progress);
        }
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'B6: hit box for my token in B2 is centred on its drawn rect and at '
    'least 48 by 48',
    (WidgetTester tester) async {
      _pinViewportToBoard(tester);
      final BoardCell cell0 = cellFor(seat: 0, progress: 16, tokenIndex: 0);
      final BoardCell cell1a = cellFor(seat: 1, progress: 3, tokenIndex: 0);
      final BoardCell cell1b = cellFor(seat: 1, progress: 3, tokenIndex: 1);
      expect(
        cell0,
        cell1a,
        reason: 'fixture: B2 seat 0 #0 and seat 1 #0 must share one cell',
      );
      expect(
        cell0,
        cell1b,
        reason: 'fixture: B2 seat 0 #0 and seat 1 #1 must share one cell',
      );

      final Map<int, List<int>> tokens = _allInYard();
      tokens[0] = <int>[16, -1, -1, -1];
      tokens[1] = <int>[3, 3, -1, -1];

      await tester.pumpWidget(_harness(tokens: tokens, mySeat: 0));
      await tester.pump();
      try {
        final Rect cellRect = _viewCellRect(cell0, mySeat: 0);
        final Offset expectedMixedCenter =
            cellRect.center + const Offset(-_cellSize * 0.22, _cellSize * 0.22);

        final Rect drawn0 = tester.getRect(find.byKey(_tokenKey(0, 0)));

        expect(
          drawn0.center.dx,
          closeTo(expectedMixedCenter.dx, _epsilon),
          reason:
              'token-0-0 on B2 mixed cell must sit at slot 2 center.dx '
              '${expectedMixedCenter.dx}; got ${drawn0.center.dx}',
        );
        expect(
          drawn0.center.dy,
          closeTo(expectedMixedCenter.dy, _epsilon),
          reason:
              'token-0-0 on B2 mixed cell must sit at slot 2 center.dy '
              '${expectedMixedCenter.dy}; got ${drawn0.center.dy}',
        );

        for (int index = 0; index < 4; index++) {
          final Rect drawn = tester.getRect(find.byKey(_tokenKey(0, index)));
          final Rect hit = tester.getRect(find.byKey(_hitKey(0, index)));
          expect(
            hit.center.dx,
            closeTo(drawn.center.dx, _epsilon),
            reason:
                'board-token-hit-0-$index center.dx (${hit.center.dx}) must '
                'match token-0-$index center.dx (${drawn.center.dx})',
          );
          expect(
            hit.center.dy,
            closeTo(drawn.center.dy, _epsilon),
            reason:
                'board-token-hit-0-$index center.dy (${hit.center.dy}) must '
                'match token-0-$index center.dy (${drawn.center.dy})',
          );
          expect(
            hit.width,
            greaterThanOrEqualTo(48.0),
            reason:
                'board-token-hit-0-$index width must be >= 48; got '
                '${hit.width}',
          );
          expect(
            hit.height,
            greaterThanOrEqualTo(48.0),
            reason:
                'board-token-hit-0-$index height must be >= 48; got '
                '${hit.height}',
          );
        }
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets('B7: with mySeat 1 the B1 shared cell paints seat 1 token last', (
    WidgetTester tester,
  ) async {
    _pinViewportToBoard(tester);
    final BoardCell cell0 = cellFor(seat: 0, progress: 16, tokenIndex: 0);
    final BoardCell cell1 = cellFor(seat: 1, progress: 3, tokenIndex: 0);
    expect(
      cell0,
      cell1,
      reason:
          'fixture: seat 0 progress 16 and seat 1 progress 3 must share '
          'one cell',
    );

    final Map<int, List<int>> tokens = _allInYard();
    tokens[0] = <int>[16, -1, -1, -1];
    tokens[1] = <int>[3, -1, -1, -1];

    await tester.pumpWidget(
      _harness(tokens: tokens, seatsInPlay: const <int>[0, 1, 2, 3], mySeat: 1),
    );
    await tester.pump();
    try {
      const List<(int, int)> shared = <(int, int)>[(0, 0), (1, 0)];
      _expectVisible(tester, shared);

      final List<(int, int)> cellOrder = _paintOrder(tester, shared);
      expect(
        cellOrder,
        const <(int, int)>[(0, 0), (1, 0)],
        reason:
            'with mySeat 1, seat 1 token (1, 0) must be painted after '
            'seat 0 token (0, 0) on the B1 cell; got $cellOrder',
      );

      final List<(int, int)> allTokenZeroOrder = _paintOrder(
        tester,
        const <(int, int)>[(0, 0), (1, 0), (2, 0), (3, 0)],
      );
      expect(
        allTokenZeroOrder.last,
        (1, 0),
        reason:
            'with mySeat 1, seat 1 must be moved to the end of the token '
            'paint loop across the board; got $allTokenZeroOrder',
      );
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets('B8: tap on the cell in B2 moves my legal token via onTokenTap', (
    WidgetTester tester,
  ) async {
    _pinViewportToBoard(tester);
    final BoardCell cell0 = cellFor(seat: 0, progress: 16, tokenIndex: 0);
    final BoardCell cell1a = cellFor(seat: 1, progress: 3, tokenIndex: 0);
    final BoardCell cell1b = cellFor(seat: 1, progress: 3, tokenIndex: 1);
    expect(
      cell0,
      cell1a,
      reason: 'fixture: B2 seat 0 #0 and seat 1 #0 must share one cell',
    );
    expect(
      cell0,
      cell1b,
      reason: 'fixture: B2 seat 0 #0 and seat 1 #1 must share one cell',
    );

    final List<int> tapped = <int>[];
    final List<int> shaken = <int>[];
    final Map<int, List<int>> tokens = _allInYard();
    tokens[0] = <int>[16, -1, -1, -1];
    tokens[1] = <int>[3, 3, -1, -1];

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
    try {
      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      expect(
        tapped,
        <int>[0],
        reason:
            'tapping my token hit target on the B2 shared cell must call '
            'onTokenTap with token 0; got $tapped',
      );
      expect(
        shaken,
        isEmpty,
        reason:
            'a legal tap on the B2 shared cell must not trigger '
            'onIllegalTokenTap; got $shaken',
      );
    } finally {
      await _unmount(tester);
    }
  });
}
