import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The product mark: a rounded die with one pip per seat colour. Matches the
/// store icon language (die, not the four-quadrant board grid) so the home
/// screen and the launcher read as the same brand.
class DieMark extends StatelessWidget {
  const DieMark({
    super.key,
    this.size = 160,
    this.rotation = -0.12,
    this.semanticsLabel,
  });

  final double size;

  /// Radians. Slightly off-square so it reads as an object, not a UI tile.
  final double rotation;

  /// Optional accessibility label; callers should pass [appTitle].
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final Widget paint = Transform.rotate(
      angle: rotation,
      child: CustomPaint(
        size: Size.square(size),
        painter: const _DieMarkPainter(),
      ),
    );
    if (semanticsLabel == null) {
      return paint;
    }
    return Semantics(label: semanticsLabel, child: paint);
  }
}

class _DieMarkPainter extends CustomPainter {
  const _DieMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final RRect face = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.06, s * 0.06, s * 0.88, s * 0.88),
      Radius.circular(s * 0.18),
    );

    final Paint shadow = Paint()
      ..color = LudoColors.feltDeep.withValues(alpha: 0.18)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.04);
    canvas.drawRRect(face.shift(Offset(0, s * 0.035)), shadow);

    canvas.drawRRect(face, Paint()..color = LudoColors.dieFace);
    canvas.drawRRect(
      face,
      Paint()
        ..color = LudoColors.dieEdge
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, s * 0.028),
    );

    final double pipR = s * 0.095;
    final Offset c = Offset(s / 2, s / 2);
    final double off = s * 0.22;
    final List<Offset> spots = <Offset>[
      c + Offset(-off, -off),
      c + Offset(off, -off),
      c + Offset(-off, off),
      c + Offset(off, off),
    ];

    for (int i = 0; i < 4; i++) {
      final Offset p = spots[i];
      canvas.drawCircle(p, pipR, Paint()..color = LudoColors.seats[i]);
      canvas.drawCircle(
        p,
        pipR,
        Paint()
          ..color = LudoColors.dieEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, s * 0.014),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
