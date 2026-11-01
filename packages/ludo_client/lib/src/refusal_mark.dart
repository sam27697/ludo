// The halo a refused tap shows when the system asks for no animation
// (C-520 D3, A4). The shakes carry the refusal with motion on; with motion
// off they hold still, so the object wears this for 300 ms instead. It is in
// the tree or it is not: no fade, no scale, no move. Doctrine P9.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// How long a [RefusalMark] stays up after the refused tap (C-520 D3).
const Duration kRefusalMarkLife = Duration(milliseconds: 300);

/// C-520 D3, A4. The halo a refused tap shows when animations are off.
///
/// It paints outside its own box and does not clip, so the layout box is the
/// object's and the sites do not change. From the box edge outward: a gap
/// left unpainted, a pale stroke that parts the red from any red fill or
/// frame under it (seat 0 is every host), then the red stroke.
class RefusalMark extends StatelessWidget {
  const RefusalMark({super.key, required this.shape, this.borderRadius});

  /// BoxShape.circle or BoxShape.rectangle.
  final BoxShape shape;

  /// Used when [shape] is rectangle.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _HaloPainter(
            shape: shape,
            borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
          ),
        ),
      ),
    );
  }
}

const double _kHaloGap = 2;
const double _kHaloPale = 2;
const double _kHaloRed = 3;

class _HaloPainter extends CustomPainter {
  const _HaloPainter({required this.shape, required this.borderRadius});

  final BoxShape shape;
  final BorderRadius? borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Offset.zero & size;
    // Each stroke is centred half its width past its inner edge.
    _stroke(
      canvas,
      box,
      _kHaloGap + _kHaloPale / 2,
      _kHaloPale,
      LudoColors.paper,
    );
    _stroke(
      canvas,
      box,
      _kHaloGap + _kHaloPale + _kHaloRed / 2,
      _kHaloRed,
      LudoColors.error,
    );
  }

  /// One stroke whose centre line sits [out] dp from the box edge.
  void _stroke(Canvas canvas, Rect box, double out, double width, Color color) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..isAntiAlias = true
      ..color = color;
    if (shape == BoxShape.circle) {
      canvas.drawCircle(
        box.center,
        math.min(box.width, box.height) / 2 + out,
        paint,
      );
      return;
    }
    final BorderRadius r = borderRadius ?? BorderRadius.zero;
    Radius grown(Radius c) => Radius.elliptical(c.x + out, c.y + out);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        box.inflate(out),
        topLeft: grown(r.topLeft),
        topRight: grown(r.topRight),
        bottomLeft: grown(r.bottomLeft),
        bottomRight: grown(r.bottomRight),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.shape != shape || old.borderRadius != borderRadius;
}
