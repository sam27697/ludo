// The die as a cube. One object, two jobs: the die under the board tumbles
// as this cube while my own roll is in flight, and another seat's roll is
// the same cube thrown from that seat's corner onto the board (C-377).
//
// The cube's frame: +x right, +y down, +z toward the viewer. The viewer
// looks along -z, so a face whose rotated normal is (0, 0, 1) is square-on.
// Opposite faces sum to 7. [restingRotationFor] is a pure rotation; the
// perspective that makes the cube read as solid is applied by [DieCube],
// not baked into that rotation.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'board_geometry.dart';
import 'dead_mark.dart';
import 'theme.dart';

/// Travel and tumble of a thrown die, landing at the end of it. C-377 D5.
const Duration kThrowTumble = Duration(milliseconds: 700);

/// How long the thrown die rests on the face the server sent. C-377 D5.
const Duration kThrowRest = Duration(milliseconds: 600);

/// Fade-out after the rest. Skipped when another throw is already waiting,
/// and skipped entirely under reduced motion (C-377 D5, D8).
const Duration kThrowFade = Duration(milliseconds: 200);

/// The tumble and the rest both shrink to this when a throw is waiting
/// behind the current one, or a move arrives while this one is travelling.
/// C-377 D5.
const Duration kThrowFast = Duration(milliseconds: 250);

/// Outward unit normal of each face in the cube's own frame. The
/// viewer looks along -z: a face whose rotated normal is (0, 0, 1)
/// faces the viewer square-on. Opposite faces sum to 7.
const Map<int, (double, double, double)> kFaceNormals =
    <int, (double, double, double)>{
      1: (0, 0, 1),
      6: (0, 0, -1),
      2: (0, -1, 0),
      5: (0, 1, 0),
      3: (1, 0, 0),
      4: (-1, 0, 0),
    };

/// Right and down axes of each face, in the cube's own frame, chosen so
/// that [restingRotationFor] shows the pips the same way up as the flat
/// die (local +x to the right, local +y down) and the triple
/// (right, down, normal) stays right-handed.
const Map<
  int,
  ({(double, double, double) right, (double, double, double) down})
>
_kFaceAxes =
    <int, ({(double, double, double) right, (double, double, double) down})>{
      1: (right: (1, 0, 0), down: (0, 1, 0)),
      6: (right: (-1, 0, 0), down: (0, 1, 0)),
      2: (right: (1, 0, 0), down: (0, 0, 1)),
      5: (right: (1, 0, 0), down: (0, 0, -1)),
      3: (right: (0, 0, -1), down: (0, 1, 0)),
      4: (right: (0, 0, 1), down: (0, 1, 0)),
    };

/// Pure rotation (no perspective, no translation) that turns face
/// [face] toward the viewer: transforming kFaceNormals[face] by it
/// gives (0, 0, 1) within 1e-9. Throws ArgumentError outside 1..6.
Matrix4 restingRotationFor(int face) {
  if (face < 1 || face > 6) {
    throw ArgumentError.value(face, 'face', 'must be 1..6');
  }
  final (double nx, double ny, double nz) = kFaceNormals[face]!;
  final ({(double, double, double) right, (double, double, double) down}) axes =
      _kFaceAxes[face]!;
  return _pureRotation(axes.right, axes.down, (nx, ny, nz));
}

Matrix4 _pureRotation(
  (double, double, double) right,
  (double, double, double) down,
  (double, double, double) normal,
) {
  final Matrix4 m = Matrix4.zero();
  m.setEntry(0, 0, right.$1);
  m.setEntry(0, 1, right.$2);
  m.setEntry(0, 2, right.$3);
  m.setEntry(1, 0, down.$1);
  m.setEntry(1, 1, down.$2);
  m.setEntry(1, 2, down.$3);
  m.setEntry(2, 0, normal.$1);
  m.setEntry(2, 1, normal.$2);
  m.setEntry(2, 2, normal.$3);
  m.setEntry(3, 3, 1);
  return m;
}

/// Where a thrown die is in its life. [tumble] is the travel; [rest] and
/// [fade] both show the landed face.
enum ThrownDiePhase { tumble, rest, fade }

/// The flat numbered face: rounded square, seat-coloured border, pips.
/// [face] is 1..6. The idle cube is not this; a null face is the caller's
/// to paint. [pipOpacity] is 1 for a live face and 0.45 for a dead one
/// (C-380 D2): the face is still drawn whole, only the pips dim.
void paintNumberedDieFace(
  Canvas canvas,
  Size size, {
  required Color edgeColor,
  required int face,
  double pipOpacity = 1,
}) {
  final double s = size.shortestSide;
  final RRect faceRect = RRect.fromRectAndRadius(
    Rect.fromLTWH(s * 0.04, s * 0.04, s * 0.92, s * 0.92),
    Radius.circular(s * 0.16),
  );
  canvas.drawRRect(faceRect, Paint()..color = LudoColors.dieFace);
  canvas.drawRRect(
    faceRect,
    Paint()
      ..color = edgeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.5, s * 0.05),
  );
  _paintPips(canvas, size, face, opacity: pipOpacity);
}

/// Pips for one numbered face. Centres and radius come from [pipCentresFor]
/// and [pipRadiusFor] (C-380 D3), the same call the tray's die painter makes.
void _paintPips(Canvas canvas, Size size, int face, {double opacity = 1}) {
  if (face < 1 || face > 6) {
    return;
  }
  final Paint pipPaint = Paint()
    ..color = opacity >= 1
        ? LudoColors.ink
        : LudoColors.ink.withValues(alpha: opacity);
  final double pipR = pipRadiusFor(size);
  for (final Offset centre in pipCentresFor(face, size)) {
    canvas.drawCircle(centre, pipR, pipPaint);
  }
}

/// One die, drawn as six faces. [rotation] is a pure rotation (what
/// [restingRotationFor] returns, or a tumble built on it). Faces pointing
/// away from the viewer are not drawn; the ones that are drawn are shaded
/// by how square-on they are, so the cube reads as one lit object.
class DieCube extends StatelessWidget {
  const DieCube({
    super.key,
    required this.size,
    required this.rotation,
    required this.edgeColor,
  });

  final double size;
  final Matrix4 rotation;
  final Color edgeColor;

  @override
  Widget build(BuildContext context) {
    // The face is smaller than the box so the front face, pulled forward
    // by perspective, still sits inside [size].
    final double extent = size * 0.74;
    final double half = extent / 2;
    final List<_LitFace> faces = <_LitFace>[];
    for (final int value in kFaceNormals.keys) {
      final (double nx, double ny, double nz) = kFaceNormals[value]!;
      final double vz = _rotate(rotation, nx, ny, nz).$3;
      if (vz <= 0.02) {
        continue;
      }
      final double light = vz < 0 ? 0.0 : (vz > 1 ? 1.0 : vz);
      final Color fill = Color.alphaBlend(
        LudoColors.ink.withValues(alpha: (1 - light) * 0.5),
        LudoColors.dieFace,
      );
      final double cz = _rotate(rotation, nx * half, ny * half, nz * half).$3;
      faces.add(_LitFace(value: value, fill: fill, depth: cz));
    }
    faces.sort((_LitFace a, _LitFace b) => a.depth.compareTo(b.depth));

    // (3, 2) is the perspective term. Negative so a face at +z (toward
    // the viewer) grows and a face at -z shrinks.
    final Matrix4 view = Matrix4.identity()
      ..setEntry(3, 2, -0.42 / size)
      ..multiply(rotation);

    return SizedBox(
      key: const Key('die-cube'),
      width: size,
      height: size,
      child: Transform(
        alignment: Alignment.center,
        transform: view,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            for (final _LitFace face in faces)
              Transform(
                alignment: Alignment.center,
                transform: _facePlacement(face.value, half),
                child: CustomPaint(
                  size: Size.square(extent),
                  painter: _CubeFacePainter(
                    face: face.value,
                    fill: face.fill,
                    edgeColor: edgeColor,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LitFace {
  const _LitFace({
    required this.value,
    required this.fill,
    required this.depth,
  });

  final int value;
  final Color fill;

  /// Rotated centre z. Smaller is farther from the viewer and paints first.
  final double depth;
}

/// Direction [x, y, z] through the 3x3 of a pure rotation.
(double, double, double) _rotate(
  Matrix4 rotation,
  double x,
  double y,
  double z,
) {
  return (
    rotation.entry(0, 0) * x +
        rotation.entry(0, 1) * y +
        rotation.entry(0, 2) * z,
    rotation.entry(1, 0) * x +
        rotation.entry(1, 1) * y +
        rotation.entry(1, 2) * z,
    rotation.entry(2, 0) * x +
        rotation.entry(2, 1) * y +
        rotation.entry(2, 2) * z,
  );
}

Matrix4 _facePlacement(int face, double half) {
  final (double nx, double ny, double nz) = kFaceNormals[face]!;
  final ({(double, double, double) right, (double, double, double) down}) axes =
      _kFaceAxes[face]!;
  final (double rx, double ry, double rz) = axes.right;
  final (double dx, double dy, double dz) = axes.down;
  final Matrix4 m = Matrix4.zero();
  m.setEntry(0, 0, rx);
  m.setEntry(1, 0, ry);
  m.setEntry(2, 0, rz);
  m.setEntry(0, 1, dx);
  m.setEntry(1, 1, dy);
  m.setEntry(2, 1, dz);
  m.setEntry(0, 2, nx);
  m.setEntry(1, 2, ny);
  m.setEntry(2, 2, nz);
  m.setEntry(0, 3, nx * half);
  m.setEntry(1, 3, ny * half);
  m.setEntry(2, 3, nz * half);
  m.setEntry(3, 3, 1);
  return m;
}

class _CubeFacePainter extends CustomPainter {
  const _CubeFacePainter({
    required this.face,
    required this.fill,
    required this.edgeColor,
  });

  final int face;
  final Color fill;
  final Color edgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = fill);
    canvas.drawRect(
      rect,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, size.shortestSide * 0.045),
    );
    _paintPips(canvas, size, face);
  }

  @override
  bool shouldRepaint(covariant _CubeFacePainter oldDelegate) =>
      oldDelegate.face != face ||
      oldDelegate.fill != fill ||
      oldDelegate.edgeColor != edgeColor;
}

/// Rotation at progress [t] (0 at the throw, 1 landed) that finishes
/// exactly on [restingRotationFor]. Two axes stay in motion until the end,
/// so the flight shows two or three faces and only then the sent one.
Matrix4 throwArcRotation(int face, double t) {
  final double u = (1 - t).clamp(0.0, 1.0);
  if (u == 0) {
    return restingRotationFor(face);
  }
  final Matrix4 spin = Matrix4.identity()
    ..rotateX(u * (math.pi * 4 + math.pi / 2.5))
    ..rotateY(u * (math.pi * 2 + math.pi / 3));
  return spin.multiplied(restingRotationFor(face));
}

/// Continuous spin for my own roll, while the face is not known yet. Two
/// axes, so it never reads as a flat square turning in place.
Matrix4 ownTumbleRotation(double turns) {
  return Matrix4.identity()
    ..rotateX(turns * math.pi * 4)
    ..rotateY(turns * math.pi * 2.6)
    ..rotateZ(turns * math.pi * 0.5);
}

/// Drawn size of a die thrown onto the board. C-377 D4.
const double kThrownDieSize = 48;

/// One opponent roll, travelling from that seat's outer corner to a point
/// 60% of the way to the board centre, then resting on [face]. The widget
/// fills the board it is given; the die itself is [kThrownDieSize] and
/// ignores pointers. C-377 D4, D5, D8, D10.
class BoardThrownDie extends StatefulWidget {
  const BoardThrownDie({
    super.key,
    required this.seat,
    required this.face,
    required this.mySeat,
    required this.hurry,
    required this.successorWaiting,
    required this.onPhase,
    required this.onDone,
  });

  final int seat;
  final int face;
  final int? mySeat;

  /// Shorten the remaining tumble and the rest to [kThrowFast].
  final bool hurry;

  /// Another throw is queued. This one does not fade; it gives the board
  /// up as soon as the rest ends.
  final bool successorWaiting;

  final ValueChanged<ThrownDiePhase> onPhase;
  final VoidCallback onDone;

  @override
  State<BoardThrownDie> createState() => _BoardThrownDieState();
}

class _BoardThrownDieState extends State<BoardThrownDie>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  ThrownDiePhase _phase = ThrownDiePhase.tumble;
  Duration _phaseElapsed = Duration.zero;
  Duration _lastTick = Duration.zero;
  Duration _tumbleLimit = kThrowTumble;
  Duration _restLimit = kThrowRest;
  Duration _fadeLimit = kThrowFade;
  bool _reduced = false;
  bool _started = false;
  bool _hurryApplied = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // C-377 D8: reduced motion never travels and never tumbles. The first
    // frame is already the landed face, held for the rest, then removed.
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (_started) {
      return;
    }
    _started = true;
    _reduced = reduced;
    _hurryApplied = widget.hurry;
    if (reduced) {
      _phase = ThrownDiePhase.rest;
      _tumbleLimit = Duration.zero;
      _restLimit = widget.hurry || widget.successorWaiting
          ? kThrowFast
          : kThrowRest;
      _fadeLimit = Duration.zero;
    } else if (widget.hurry) {
      _phase = ThrownDiePhase.tumble;
      _tumbleLimit = kThrowFast;
      _restLimit = kThrowFast;
      _fadeLimit = widget.successorWaiting ? Duration.zero : kThrowFade;
    } else {
      _phase = ThrownDiePhase.tumble;
      _tumbleLimit = kThrowTumble;
      _restLimit = kThrowRest;
      _fadeLimit = widget.successorWaiting ? Duration.zero : kThrowFade;
    }
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant BoardThrownDie oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.successorWaiting) {
      _fadeLimit = Duration.zero;
      // Already fading when the next throw arrives: end after this frame.
      // onDone rebuilds the parent, which cannot happen from didUpdateWidget.
      if (_phase == ThrownDiePhase.fade && !_finished) {
        _finished = true;
        _ticker.stop();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onDone();
          }
        });
        return;
      }
    }
    if (widget.hurry && !_hurryApplied) {
      _hurryApplied = true;
      _compress();
    }
  }

  /// C-377 D5: the remaining tumble finishes within [kThrowFast], and the
  /// rest that follows (or the rest already running) is [kThrowFast] unless
  /// it was already shorter than that.
  void _compress() {
    final int fast = kThrowFast.inMicroseconds;
    if (_phase == ThrownDiePhase.tumble) {
      final int remaining = math.max(
        0,
        _tumbleLimit.inMicroseconds - _phaseElapsed.inMicroseconds,
      );
      final int compressed = math.min(remaining, fast);
      _tumbleLimit = _phaseElapsed + Duration(microseconds: compressed);
      _restLimit = kThrowFast;
    } else if (_phase == ThrownDiePhase.rest) {
      final int remaining = math.max(
        0,
        _restLimit.inMicroseconds - _phaseElapsed.inMicroseconds,
      );
      final int compressed = math.min(remaining, fast);
      _restLimit = _phaseElapsed + Duration(microseconds: compressed);
    }
  }

  void _onTick(Duration elapsed) {
    if (_finished) {
      return;
    }
    final Duration dt = elapsed - _lastTick;
    _lastTick = elapsed;
    if (dt <= Duration.zero) {
      return;
    }
    _advance(dt);
  }

  void _advance(Duration dt) {
    _phaseElapsed += dt;
    final ThrownDiePhase before = _phase;
    while (!_finished) {
      final Duration limit = _limitFor(_phase);
      if (_phaseElapsed < limit) {
        break;
      }
      _phaseElapsed -= limit;
      if (_phase == ThrownDiePhase.tumble) {
        _phase = ThrownDiePhase.rest;
        continue;
      }
      if (_phase == ThrownDiePhase.rest) {
        if (_fadeLimit <= Duration.zero) {
          _finish();
          return;
        }
        _phase = ThrownDiePhase.fade;
        continue;
      }
      _finish();
      return;
    }
    if (_finished) {
      return;
    }
    if (_phase != before) {
      widget.onPhase(_phase);
    }
    if (_phase != before ||
        _phase == ThrownDiePhase.tumble ||
        _phase == ThrownDiePhase.fade) {
      setState(() {});
    }
  }

  Duration _limitFor(ThrownDiePhase phase) {
    switch (phase) {
      case ThrownDiePhase.tumble:
        return _tumbleLimit;
      case ThrownDiePhase.rest:
        return _restLimit;
      case ThrownDiePhase.fade:
        return _fadeLimit;
    }
  }

  void _finish() {
    if (_finished) {
      return;
    }
    _finished = true;
    _ticker.stop();
    widget.onDone();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double get _tumbleT {
    if (_reduced || _phase != ThrownDiePhase.tumble) {
      return 1;
    }
    if (_tumbleLimit.inMicroseconds <= 0) {
      return 1;
    }
    return (_phaseElapsed.inMicroseconds / _tumbleLimit.inMicroseconds).clamp(
      0.0,
      1.0,
    );
  }

  double get _opacity {
    if (_phase != ThrownDiePhase.fade || _fadeLimit.inMicroseconds <= 0) {
      return 1;
    }
    final double t = _phaseElapsed.inMicroseconds / _fadeLimit.inMicroseconds;
    return (1 - t).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = constraints.maxWidth;
        final Offset corner = _outerCorner(widget.seat, widget.mySeat);
        final Offset landing = _landingPoint(corner);
        final double travel = Curves.easeOut.transform(_tumbleT);
        final Offset at = Offset.lerp(corner, landing, travel)!;
        final Offset center = Offset(at.dx * side, at.dy * side);
        final bool tumbling = !_reduced && _phase == ThrownDiePhase.tumble;
        final Matrix4 rotation = tumbling
            ? throwArcRotation(widget.face, travel)
            : restingRotationFor(widget.face);
        final Widget cube = DieCube(
          size: kThrownDieSize,
          rotation: rotation,
          edgeColor: LudoColors.seats[widget.seat.clamp(0, 3)],
        );
        final Widget phased = tumbling
            ? KeyedSubtree(
                key: Key('opponent-throw-tumbling-${widget.seat}'),
                child: cube,
              )
            : KeyedSubtree(
                key: Key('opponent-throw-landed-${widget.seat}-${widget.face}'),
                child: cube,
              );
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: center.dx - kThrownDieSize / 2,
              top: center.dy - kThrownDieSize / 2,
              width: kThrownDieSize,
              height: kThrownDieSize,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: _opacity,
                    child: KeyedSubtree(
                      key: Key('opponent-throw-${widget.seat}'),
                      child: phased,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Outer corner of [seat], in fractions of the board side, view space,
/// origin top-left. Seat 2 seen from seat 0 is the top-right corner.
Offset _outerCorner(int seat, int? mySeat) {
  const List<(double, double)> corners = <(double, double)>[
    (0, 0),
    (15, 0),
    (15, 15),
    (0, 15),
  ];
  final int index = seat.clamp(0, 3);
  double x = corners[index].$1;
  double y = corners[index].$2;
  final int quarters = viewQuarters(mySeat);
  for (int i = 0; i < quarters; i++) {
    final double nextX = 15 - y;
    final double nextY = x;
    x = nextX;
    y = nextY;
  }
  return Offset(x / 15, y / 15);
}

/// 60% of the way from [corner] to the board centre. C-377 D4.
Offset _landingPoint(Offset corner) {
  return Offset(
    corner.dx + 0.6 * (0.5 - corner.dx),
    corner.dy + 0.6 * (0.5 - corner.dy),
  );
}
