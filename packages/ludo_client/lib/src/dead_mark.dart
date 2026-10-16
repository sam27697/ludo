// The dead mark for a die that cannot be spent (C-380). One badge for the
// big die and the tray, centred on the die's top-right corner in every
// locale: a die is an object, not text, so the corner does not follow the
// reading direction. The face under the badge stays whole. Pip centres and
// radius live here so the flat face, the cube and the tray draw one geometry.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Fraction of the die's shortest side from the face centre out to a corner
/// pip. Shared with the radius below; C-380 keeps the proportions the flat
/// face already used.
const double _kPipFromCentre = 0.22;

/// Pip radius as a fraction of the die's shortest side.
const double _kPipRadiusOfSide = 0.09;

/// Badge side as a fraction of the die's shortest side (C-380 D1).
const double _kBadgeOfSide = 0.42;

/// Pip positions, unit offsets from the face centre. 1 is the middle, and
/// the pairs sit on the diagonals and the mid-edges the way a die does.
const Map<int, List<Offset>> _pipUnits = <int, List<Offset>>{
  1: <Offset>[Offset(0, 0)],
  2: <Offset>[Offset(-1, -1), Offset(1, 1)],
  3: <Offset>[Offset(-1, -1), Offset(0, 0), Offset(1, 1)],
  4: <Offset>[Offset(-1, -1), Offset(1, -1), Offset(-1, 1), Offset(1, 1)],
  5: <Offset>[
    Offset(-1, -1),
    Offset(1, -1),
    Offset(0, 0),
    Offset(-1, 1),
    Offset(1, 1),
  ],
  6: <Offset>[
    Offset(-1, -1),
    Offset(1, -1),
    Offset(-1, 0),
    Offset(1, 0),
    Offset(-1, 1),
    Offset(1, 1),
  ],
};

/// The badge's bounding square for a die of [dieSize]: centred on the
/// die's top-right corner, side 0.42 * dieSize.shortestSide.
Rect deadBadgeRect(Size dieSize) {
  final double side = _kBadgeOfSide * dieSize.shortestSide;
  return Rect.fromCenter(
    center: Offset(dieSize.width, 0),
    width: side,
    height: side,
  );
}

/// Pip centres of [face] (1..6) on a die face of [dieSize], origin at
/// the face's top-left. ArgumentError outside 1..6.
List<Offset> pipCentresFor(int face, Size dieSize) {
  if (face < 1 || face > 6) {
    throw ArgumentError.value(face, 'face', 'must be 1..6');
  }
  final double side = dieSize.shortestSide;
  final Offset centre = Offset(side / 2, side / 2);
  final double off = side * _kPipFromCentre;
  return <Offset>[
    for (final Offset unit in _pipUnits[face]!)
      centre + Offset(unit.dx * off, unit.dy * off),
  ];
}

/// Pip radius on a die face of [dieSize].
double pipRadiusFor(Size dieSize) => dieSize.shortestSide * _kPipRadiusOfSide;

/// Ring thickness and the X inside it, as fractions of the badge side.
/// The ring stays inside the disc. The X stops short of the ring.
const double _kRingOfBadge = 0.065;
const double _kXStrokeOfBadge = 0.13;
const double _kXArmOfBadge = 0.20;

/// The one dead mark (C-380 D1): a red disc, a thin white ring, and a
/// white X. [Colors.white], not a new hex, so the distinct-hex ratchet
/// does not move. Nothing here reads the locale.
class DeadMarkPainter extends CustomPainter {
  const DeadMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = side / 2;

    canvas.drawCircle(center, radius, Paint()..color = LudoColors.error);

    final double ring = math.max(1, side * _kRingOfBadge);
    canvas.drawCircle(
      center,
      radius - ring / 2,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring,
    );

    final double reach = side * _kXArmOfBadge;
    final Paint x = Paint()
      ..color = Colors.white
      ..strokeWidth = math.max(1.4, side * _kXStrokeOfBadge)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      center + Offset(-reach, -reach),
      center + Offset(reach, reach),
      x,
    );
    canvas.drawLine(
      center + Offset(reach, -reach),
      center + Offset(-reach, reach),
      x,
    );
  }

  @override
  bool shouldRepaint(covariant DeadMarkPainter oldDelegate) => false;
}
