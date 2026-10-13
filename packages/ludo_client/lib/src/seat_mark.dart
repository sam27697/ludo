// C-331: every seat gets a fixed shape, not only a colour (doctrine P9 --
// "colour is never the only signal" -- a seat-colour disc alone reads the
// same to a colour-blind player as the seat next to it). One widget, drawn
// with a CustomPainter, used everywhere a seat is shown as a disc: the
// board token itself, the lobby/game seat card, the seat pip strip and the
// board's seat-name chip.

import 'dart:math' as math;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/widgets.dart';

import 'theme.dart';

/// The fixed shape each seat carries, forever: seat 0 a circle, seat 1 a
/// triangle (point up), seat 2 a square, seat 3 a diamond.
enum SeatShape { circle, triangle, square, diamond }

/// The one place that maps a seat to its [SeatShape]. Fixed order, never
/// reassigned once a game has shipped (rule 1).
SeatShape seatShapeOf(int seat) {
  switch (seat) {
    case 0:
      return SeatShape.circle;
    case 1:
      return SeatShape.triangle;
    case 2:
      return SeatShape.square;
    case 3:
      return SeatShape.diamond;
    default:
      throw ArgumentError.value(seat, 'seat', 'must be 0..3');
  }
}

/// The fill colour [SeatMark] paints in, chosen to contrast with the seat
/// colour it sits on: [LudoColors.ink] on seat 2 (the yellow seat), plain
/// white ([Colors.white] rather than a new hex literal, so the lib-wide
/// distinct-hex ratchet does not move) on seats 0, 1 and 3.
Color seatMarkInkOf(int seat) {
  return seat == 2 ? LudoColors.ink : Colors.white;
}

/// A seat's shape, centred in a [size] by [size] box. Purely a visual aid --
/// wrapped in [ExcludeSemantics] so the spoken label stays whatever the
/// widget this mark sits inside already carries. Below 6 logical pixels
/// (rule 4) it paints nothing: a mark that small is noise, not a signal.
class SeatMark extends StatelessWidget {
  const SeatMark({super.key, required this.seat, required this.size});

  /// 0..3.
  final int seat;

  /// Logical pixels, the mark's own bounding box (not the disc it sits on).
  final double size;

  @override
  Widget build(BuildContext context) {
    if (size < 6) {
      return ExcludeSemantics(child: SizedBox.square(dimension: size));
    }
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _SeatMarkPainter(
            shape: seatShapeOf(seat),
            color: seatMarkInkOf(seat),
          ),
        ),
      ),
    );
  }
}

class _SeatMarkPainter extends CustomPainter {
  const _SeatMarkPainter({required this.shape, required this.color});

  final SeatShape shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double side = size.shortestSide;
    final double half = side / 2;

    switch (shape) {
      case SeatShape.circle:
        canvas.drawCircle(center, half, paint);
        break;
      case SeatShape.triangle:
        final Path path = Path()
          ..moveTo(center.dx, center.dy - half)
          ..lineTo(center.dx + half, center.dy + half)
          ..lineTo(center.dx - half, center.dy + half)
          ..close();
        canvas.drawPath(path, paint);
        break;
      case SeatShape.square:
        canvas.drawRect(
          Rect.fromCenter(center: center, width: side, height: side),
          paint,
        );
        break;
      case SeatShape.diamond:
        // A square rotated 45 degrees, its own side shrunk by sqrt(2) first
        // so the rotated shape's diagonal -- its real bounding box once
        // tilted -- lands back on `side`, the same bounding box every other
        // shape fills.
        final double rotatedSide = side / math.sqrt2;
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(
          Rect.fromCenter(
            center: Offset.zero,
            width: rotatedSide,
            height: rotatedSide,
          ),
          paint,
        );
        canvas.restore();
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SeatMarkPainter oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}
