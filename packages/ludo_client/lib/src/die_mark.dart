import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Face size for [DieMark] on short vs tall viewports. Home and lobby share
/// this so compact and shoutable layouts stay locked together.
double dieMarkSize(bool compact) => compact ? 72 : 148;

/// Pip diameter on the compact game-chrome seat strip (space-2 on the 4/8 scale).
const double kSeatPipSize = 8;

/// Felt-edge thickness on game chrome (space-1 on the 4/8 scale).
const double kFeltEdgeThickness = 4;

/// Compact seat-identity strip: one solid pip per [LudoColors.seats] entry, in
/// seat order. Shared by game chrome so waiting, playing, and game-over all
/// carry the same brand cue without duplicating layout.
class SeatPipStrip extends StatelessWidget {
  const SeatPipStrip({super.key, this.pipSize = kSeatPipSize});

  final double pipSize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: kSpace4,
        vertical: kSpace2,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < LudoColors.seats.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kSpace2),
            Container(
              key: Key('game-seat-pip-$i'),
              width: pipSize,
              height: pipSize,
              decoration: BoxDecoration(
                color: LudoColors.seats[i],
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Thin felt-coloured bar that frames the game seat-pip strip. Colour is
/// [LudoColors.feltMid] (also accepted as [LudoBrand.felt] when those match).
class FeltEdge extends StatelessWidget {
  const FeltEdge({super.key, this.thickness = kFeltEdgeThickness});

  final double thickness;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: LudoColors.feltMid,
      child: SizedBox(height: thickness, width: double.infinity),
    );
  }
}

/// The product mark: a rounded die with one pip per seat colour. Matches the
/// store icon language (die, not the four-quadrant board grid) so the home
/// screen and the launcher read as the same brand.
class DieMark extends StatelessWidget {
  const DieMark({
    super.key,
    this.size = 160,
    this.rotation = -0.12,
    this.semanticsLabel,
    this.child,
  });

  final double size;

  /// Radians. Slightly off-square so it reads as an object, not a UI tile.
  final double rotation;

  /// Optional accessibility label; callers should pass [appTitle].
  final String? semanticsLabel;

  /// Optional overlay on the die face (for example a room code). Painted
  /// after the face and pips, inset so it stays inside the rounded square.
  /// Existing callers that omit this keep the pip-only mark.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final Widget paint = Transform.rotate(
      angle: rotation,
      child: CustomPaint(
        size: Size.square(size),
        painter: const _DieMarkPainter(),
        child: child == null
            ? null
            : SizedBox.square(
                dimension: size,
                child: Padding(
                  padding: EdgeInsets.all(size * 0.22),
                  child: Center(child: child),
                ),
              ),
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
