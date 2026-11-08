import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'seat_mark.dart';
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
  const SeatPipStrip({
    super.key,
    this.pipSize = kSeatPipSize,
    this.seats,
    this.turnSeat,
    this.nextSeat,
  });

  final double pipSize;

  /// Which seats get a pip, in ascending order regardless of the order
  /// given. Null (the default) draws all four, same as today. C-248 rule 5.
  final List<int>? seats;

  /// The seat whose pip is drawn 1.5x the size with a 2 dp ink border and a
  /// glow in its seat colour, key `game-seat-pip-turn`. Null (the default)
  /// draws every pip the same size, same as today. C-248 rule 5.
  final int? turnSeat;

  /// C-590 D2: the seat that plays after [turnSeat]. Drawn at 1.25x with a
  /// broken ink ring, key `game-seat-pip-next`. Ignored when null, when it is
  /// not among the shown seats, or when it is the turn seat. Null (the
  /// default) draws exactly what it did before.
  final int? nextSeat;

  @override
  Widget build(BuildContext context) {
    final List<int> shown = (seats ?? const <int>[0, 1, 2, 3]).toList()..sort();
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: kSpace4,
        vertical: kSpace2,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < shown.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kSpace2),
            _pip(shown[i]),
          ],
        ],
      ),
    );
  }

  Widget _pip(int seat) {
    final bool isTurn = seat == turnSeat;
    final bool isNext = !isTurn && seat == nextSeat;
    final double size = isTurn
        ? pipSize * 1.5
        : isNext
        ? pipSize * 1.25
        : pipSize;
    final Widget dot = Container(
      key: Key('game-seat-pip-$seat'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: LudoColors.seats[seat],
        shape: BoxShape.circle,
        border: isTurn ? Border.all(color: LudoColors.ink, width: 2) : null,
        // C-595 D2: a glow in the seat's own colour. A shadow takes no
        // layout space, so the pip keeps its laid-out size.
        boxShadow: isTurn
            ? <BoxShadow>[
                BoxShadow(
                  color: LudoColors.seats[seat].withValues(alpha: 0.6),
                  blurRadius: 6,
                  spreadRadius: 1.5,
                ),
              ]
            : null,
      ),
      child: Center(
        child: SeatMark(seat: seat, size: size * 0.5),
      ),
    );
    if (isNext) {
      return KeyedSubtree(
        key: const Key('game-seat-pip-next'),
        child: CustomPaint(
          foregroundPainter: const NextSeatRingPainter(),
          // The ring is painted outside the dot's box, so the pip's layout
          // box stays the dot alone and the strip's height is unchanged.
          child: dot,
        ),
      );
    }
    if (!isTurn) {
      return dot;
    }
    return KeyedSubtree(key: const Key('game-seat-pip-turn'), child: dot);
  }
}

/// C-595 D1: the broken ring around the next seat's pip. [dashes] arcs of a
/// 1.5 dp ink stroke on a circle [gap] larger than the pip, each drawn over
/// half of its slot, the first starting at the top. Solid and lit means
/// "plays now", broken and loose means "plays next". Paints outside its box,
/// so it adds nothing to layout.
class NextSeatRingPainter extends CustomPainter {
  const NextSeatRingPainter();

  static const double gap = 2.5;
  static const double stroke = 1.5;
  static const int dashes = 8;
  static const double alpha = 0.7;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint ring = Paint()
      ..color = LudoColors.ink.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final Rect oval = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 + gap,
    );
    const double slot = 2 * math.pi / dashes;
    for (int i = 0; i < dashes; i++) {
      canvas.drawArc(oval, -math.pi / 2 + i * slot, slot / 2, false, ring);
    }
  }

  @override
  bool shouldRepaint(NextSeatRingPainter oldDelegate) => false;
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
