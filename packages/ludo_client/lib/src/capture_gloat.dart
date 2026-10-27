// The laughing face a capture draws on the capturer's yard. GameScreen
// decides when one exists and for how long; this file only paints it.
// Contract C-468 D5.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// How long the face stays up, reduced motion included. C-468 D5.
const Duration kCaptureGloatLife = Duration(milliseconds: 1600);

/// Delay before the captured seat hears the gloat cue. C-468 D5.
const Duration kCaptureGloatSoundDelay = Duration(milliseconds: 250);

/// Seat and start serial the board's `gloat` parameter carries. A new
/// [serial] is a new gloat, including one that replaces another still
/// showing. Null on the board draws nothing. C-468 D5.
class BoardGloat {
  const BoardGloat({required this.seat, required this.serial});

  final int seat;
  final int serial;
}

/// Laughing face centred by the board on seat M's viewed yard. The root
/// key is `capture-gloat-<seat>`. C-468 D5.
class CaptureGloat extends StatefulWidget {
  const CaptureGloat({
    super.key,
    required this.seat,
    required this.serial,
    required this.diameter,
    required this.cellSize,
  });

  final int seat;
  final int serial;

  /// Two cells. C-468 D5.
  final double diameter;

  /// One board cell, so the exit can rise by half of one. C-468 D5.
  final double cellSize;

  @override
  State<CaptureGloat> createState() => _CaptureGloatState();
}

class _CaptureGloatState extends State<CaptureGloat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: kCaptureGloatLife)
      ..forward();
  }

  @override
  void didUpdateWidget(covariant CaptureGloat oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same seat keeps this state (the key does not carry the serial).
    // A replacement has to start its pop over. C-468 D5.
    if (oldWidget.serial != widget.serial) {
      _clock.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final int seat = widget.seat.clamp(0, 3);
    return IgnorePointer(
      key: Key('capture-gloat-${widget.seat}'),
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _clock,
          builder: (BuildContext context, Widget? child) {
            final _GloatPose pose = _poseFor(
              _clock.lastElapsedDuration ?? Duration.zero,
              reduced: reduced,
              cellSize: widget.cellSize,
            );
            return Opacity(
              opacity: pose.opacity,
              child: Transform.translate(
                offset: Offset(0, pose.rise),
                child: Transform.rotate(
                  angle: pose.radians,
                  child: Transform.scale(scale: pose.scale, child: child),
                ),
              ),
            );
          },
          child: SizedBox(
            width: widget.diameter,
            height: widget.diameter,
            child: CustomPaint(
              painter: _LaughingFacePainter(color: LudoColors.seats[seat]),
            ),
          ),
        ),
      ),
    );
  }
}

class _GloatPose {
  const _GloatPose({
    required this.scale,
    required this.radians,
    required this.rise,
    required this.opacity,
  });

  final double scale;
  final double radians;
  final double rise;
  final double opacity;
}

/// Pop, two wobbles, hold, then rise and fade. Reduced motion holds the
/// full face still until the screen takes it down. C-468 D5.
_GloatPose _poseFor(
  Duration elapsed, {
  required bool reduced,
  required double cellSize,
}) {
  if (reduced) {
    return const _GloatPose(scale: 1, radians: 0, rise: 0, opacity: 1);
  }
  final double t = elapsed.inMicroseconds / 1000.0;
  return _GloatPose(
    scale: _scaleAt(t),
    radians: _wobbleAt(t),
    rise: _riseAt(t, cellSize),
    opacity: _opacityAt(t),
  );
}

/// 0.4 to 1.15 over 180 ms, then to 1.0 over 120 ms. Linear, the contract
/// names no curve. C-468 D5.
double _scaleAt(double t) {
  if (t <= 0) {
    return 0.4;
  }
  if (t < 180) {
    return 0.4 + 0.75 * (t / 180);
  }
  if (t < 300) {
    return 1.15 - 0.15 * ((t - 180) / 120);
  }
  return 1;
}

/// Two full cycles of plus and minus 8 degrees across 500 ms, starting
/// once the pop has settled (300 ms). C-468 D5.
double _wobbleAt(double t) {
  if (t < 300 || t >= 800) {
    return 0;
  }
  final double u = (t - 300) / 500;
  return 8 * math.pi / 180 * math.sin(u * 2 * math.pi * 2);
}

/// Half a cell upward over the last 250 ms. C-468 D5.
double _riseAt(double t, double cellSize) {
  if (t < 1350) {
    return 0;
  }
  final double u = ((t - 1350) / 250).clamp(0.0, 1.0);
  return -0.5 * cellSize * u;
}

double _opacityAt(double t) {
  if (t < 1350) {
    return 1;
  }
  final double u = ((t - 1350) / 250).clamp(0.0, 1.0);
  return 1 - u;
}

/// Disc in the seat colour, darker rim, closed eyes, open grin, tongue,
/// one tear. Painted, never a glyph. C-468 D5.
class _LaughingFacePainter extends CustomPainter {
  const _LaughingFacePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset center = Offset(s / 2, s / 2);
    const double rimWidth = 2;
    final double fillRadius = s / 2 - rimWidth / 2;
    canvas.drawCircle(center, fillRadius, Paint()..color = color);
    canvas.drawCircle(
      center,
      fillRadius,
      Paint()
        ..color = _darker(color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = rimWidth,
    );

    final Paint ink = Paint()
      ..color = LudoColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, s * 0.045)
      ..strokeCap = StrokeCap.round;
    _eye(canvas, s, 0.28, 0.44, ink);
    _eye(canvas, s, 0.56, 0.72, ink);
    _tear(canvas, s);
    _mouth(canvas, s);
  }

  /// Upward arc: the bow sits above the two corners. C-468 D5.
  void _eye(Canvas canvas, double s, double left, double right, Paint ink) {
    final double y = s * 0.40;
    final Path path = Path()
      ..moveTo(s * left, y)
      ..quadraticBezierTo(s * (left + right) / 2, y - s * 0.08, s * right, y);
    canvas.drawPath(path, ink);
  }

  /// One drop at the right eye's outer corner. C-468 D5.
  void _tear(Canvas canvas, double s) {
    final Offset top = Offset(s * 0.74, s * 0.42);
    final Offset tip = Offset(s * 0.78, s * 0.54);
    final Path drop = Path()
      ..moveTo(top.dx, top.dy)
      ..quadraticBezierTo(top.dx + s * 0.07, top.dy + s * 0.05, tip.dx, tip.dy)
      ..quadraticBezierTo(top.dx - s * 0.015, top.dy + s * 0.07, top.dx, top.dy)
      ..close();
    canvas.drawPath(drop, Paint()..color = LudoColors.paperElevated);
    canvas.drawPath(
      drop,
      Paint()
        ..color = LudoColors.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, s * 0.02),
    );
  }

  void _mouth(Canvas canvas, double s) {
    final Path mouth = Path()
      ..moveTo(s * 0.22, s * 0.58)
      ..quadraticBezierTo(s * 0.50, s * 0.90, s * 0.78, s * 0.58)
      ..quadraticBezierTo(s * 0.50, s * 0.68, s * 0.22, s * 0.58)
      ..close();
    canvas.drawPath(mouth, Paint()..color = LudoColors.ink);
    final Path tongue = Path()
      ..moveTo(s * 0.36, s * 0.70)
      ..quadraticBezierTo(s * 0.50, s * 0.84, s * 0.64, s * 0.70)
      ..quadraticBezierTo(s * 0.50, s * 0.74, s * 0.36, s * 0.70)
      ..close();
    canvas.drawPath(tongue, Paint()..color = _lighter(color));
  }

  @override
  bool shouldRepaint(covariant _LaughingFacePainter oldDelegate) =>
      oldDelegate.color != color;
}

Color _darker(Color color) {
  final HSLColor hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness * 0.55).clamp(0.0, 1.0)).toColor();
}

Color _lighter(Color color) {
  final HSLColor hsl = HSLColor.fromColor(color);
  return hsl.withLightness((hsl.lightness + 0.40).clamp(0.0, 0.95)).toColor();
}
