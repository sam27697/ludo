// The board widget: draws the 15 by 15 grid and every seat's tokens on top
// of it. Every token's position comes from board_geometry.dart's cellFor;
// this file adds no coordinate logic of its own.
//
// Pure function of its arguments, same as the geometry underneath it: no
// network, no timers, no clock, no game rules beyond the coordinate mapping.
// That is what lets a room screen, a screenshot test and a plain widget test
// all render the exact same board from the exact same tokens map.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'board_geometry.dart';

export 'board_geometry.dart';

/// A Ludo board: the static grid plus every token of every seat in
/// [seatsInPlay], each placed by [cellFor].
///
/// This widget does not decide whose turn it is, does not know a game rule
/// beyond the coordinate mapping in board_geometry.dart, and renders exactly
/// what it is given, including a position the caller drew optimistically
/// that the server later contradicts.
class LudoBoard extends StatelessWidget {
  LudoBoard({
    super.key,
    required this.tokens,
    this.seatsInPlay = const [0, 1, 2, 3],
  }) : assert(
         seatsInPlay.length >= 2 && seatsInPlay.length <= 4,
         'seatsInPlay must have 2, 3 or 4 entries',
       ),
       assert(
         seatsInPlay.toSet().length == seatsInPlay.length,
         'seatsInPlay must not repeat a seat',
       ),
       assert(
         seatsInPlay.every((seat) => seat >= 0 && seat <= 3),
         'seatsInPlay entries must be 0..3',
       ),
       assert(
         seatsInPlay.every((seat) {
           final progresses = tokens[seat];
           if (progresses == null || progresses.length != 4) return false;
           return progresses.every((p) => p >= -1 && p <= 57);
         }),
         'every seat in seatsInPlay needs a tokens entry of exactly 4 '
         'progresses, each -1..57',
       );

  /// tokens[seat] is that seat's four progresses, in token index order.
  /// Every seat in [seatsInPlay] must have an entry. Length 4 each.
  final Map<int, List<int>> tokens;

  /// Which seats are playing. 2, 3 or 4 entries, each 0..3.
  final List<int> seatsInPlay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const Key('ludo-board'),
      builder: (context, constraints) {
        final side = _squareSide(constraints);
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: Stack(
              alignment: Alignment.topLeft,
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: const _BoardPainter()),
                ),
                for (final seat in seatsInPlay)
                  for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++)
                    _TokenMarker(
                      seat: seat,
                      tokenIndex: tokenIndex,
                      progress: tokens[seat]![tokenIndex],
                      boardSide: side,
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The largest square that fits the constraints this widget is given. Both
  /// axes bounded picks the smaller; one axis bounded uses that axis; both
  /// unbounded has no sensible size to fall back on and renders nothing
  /// rather than an infinite board.
  static double _squareSide(BoxConstraints constraints) {
    final hasWidth = constraints.hasBoundedWidth;
    final hasHeight = constraints.hasBoundedHeight;
    double side;
    if (hasWidth && hasHeight) {
      side = math.min(constraints.maxWidth, constraints.maxHeight);
    } else if (hasWidth) {
      side = constraints.maxWidth;
    } else if (hasHeight) {
      side = constraints.maxHeight;
    } else {
      side = 0;
    }
    if (!side.isFinite || side < 0) {
      side = 0;
    }
    return side;
  }
}

/// One token, positioned by [cellFor] and nothing else.
///
/// Carries the frozen key shape `token-<seat>-<tokenIndex>` and a
/// [Semantics] identifier of `cell-<col>-<row>` for the cell [cellFor]
/// returns, so the widget tree alone tells a test where every token landed
/// without measuring a single pixel.
class _TokenMarker extends StatelessWidget {
  const _TokenMarker({
    required this.seat,
    required this.tokenIndex,
    required this.progress,
    required this.boardSide,
  });

  final int seat;
  final int tokenIndex;
  final int progress;
  final double boardSide;

  @override
  Widget build(BuildContext context) {
    final cell = cellFor(
      seat: seat,
      progress: progress,
      tokenIndex: tokenIndex,
    );
    final cellSize = boardSide / 15;

    // Two tokens of one seat can land on the same cell on purpose (see
    // board_geometry.dart). Fan them out a little by token index rather than
    // stacking them exactly on top of each other; this is presentation only
    // and does not change the cell cellFor returned.
    final fan = cellSize * 0.12;
    final fanDx = tokenIndex.isEven ? -fan : fan;
    final fanDy = tokenIndex < 2 ? -fan : fan;

    final tokenSize = cellSize * 0.7;
    final left = cell.col * cellSize + (cellSize - tokenSize) / 2 + fanDx;
    final top = cell.row * cellSize + (cellSize - tokenSize) / 2 + fanDy;

    return Positioned(
      left: left,
      top: top,
      width: tokenSize,
      height: tokenSize,
      child: Semantics(
        key: Key('token-$seat-$tokenIndex'),
        identifier: 'cell-${cell.col}-${cell.row}',
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _seatColors[seat],
            border: Border.all(
              color: const Color(0xFF000000).withValues(alpha: 0.55),
              width: math.max(1, tokenSize * 0.06),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presentation only. Nothing in this file branches on colour; every branch
/// above is on seat, and this list is the one place seat becomes a colour.
const List<Color> _seatColors = [
  Color(0xFFD32F2F), // seat 0
  Color(0xFF388E3C), // seat 1
  Color(0xFFFBC02D), // seat 2
  Color(0xFF1976D2), // seat 3
];

/// Paints the static board: the grid, the four yards, the shared track, the
/// four home columns and the centre. None of this determines where a token
/// goes; it is drawn from the same [cellFor] a token uses, so the background
/// and the tokens can never show a track that disagrees with each other.
class _BoardPainter extends CustomPainter {
  const _BoardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = size.width / 15;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF7F3E9),
    );

    const yardCorners = [
      (0, 0), // seat 0, top-left
      (9, 0), // seat 1, top-right
      (9, 9), // seat 2, bottom-right
      (0, 9), // seat 3, bottom-left
    ];
    for (var seat = 0; seat < 4; seat++) {
      final (col, row) = yardCorners[seat];
      _fillCells(
        canvas,
        cellSize,
        col,
        row,
        6,
        6,
        _seatColors[seat].withValues(alpha: 0.16),
      );
    }

    for (var seat = 0; seat < 4; seat++) {
      for (var progress = 52; progress <= 56; progress++) {
        final cell = cellFor(seat: seat, progress: progress);
        _fillCell(
          canvas,
          cellSize,
          cell,
          _seatColors[seat].withValues(alpha: 0.32),
        );
      }
    }

    for (var progress = 0; progress < 52; progress++) {
      final cell = cellFor(seat: 0, progress: progress);
      _fillCell(
        canvas,
        cellSize,
        cell,
        const Color(0xFFFFFFFF).withValues(alpha: 0.65),
      );
    }

    _fillCells(
      canvas,
      cellSize,
      6,
      6,
      3,
      3,
      const Color(0xFFBDBDBD).withValues(alpha: 0.5),
    );

    final gridPaint = Paint()
      ..color = const Color(0xFF9E9E9E).withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 15; i++) {
      final offset = i * cellSize;
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset, size.height),
        gridPaint,
      );
      canvas.drawLine(Offset(0, offset), Offset(size.width, offset), gridPaint);
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF424242)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _fillCell(Canvas canvas, double cellSize, BoardCell cell, Color color) {
    _fillCells(canvas, cellSize, cell.col, cell.row, 1, 1, color);
  }

  void _fillCells(
    Canvas canvas,
    double cellSize,
    int col,
    int row,
    int width,
    int height,
    Color color,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(
        col * cellSize,
        row * cellSize,
        width * cellSize,
        height * cellSize,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) => false;
}
