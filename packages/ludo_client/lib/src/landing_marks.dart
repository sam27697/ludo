// The two sight rows of the feedback contract that sit on the board itself
// (doctrine section 3), contract C-577:
//
//  * a token reaching home: [HomeBurst], a ring of gold and seat-colour rays
//    that expands outward and fades;
//  * my own token being captured: [CapturedFlashMark], a red ring that pulses
//    outward and a red tint over the disc, carried by the flight home and
//    left to fade by [CapturedFlashLinger] once the disc has landed.
//
// None of these hold the timeline: the board draws them under IgnorePointer
// and never waits on them. Each one reads `MediaQuery.disableAnimationsOf`
// and shortens under it, it is never removed (P9). Sizes come from the cell
// size the board passes in, never from fixed pixels.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// Life of a home burst, and its reduced-motion counterpart.
const Duration kHomeBurstDuration = Duration(milliseconds: 700);
const Duration kHomeBurstDurationReduced = Duration(milliseconds: 250);

/// How long the red ring stays after a captured disc has landed in its yard,
/// and its reduced-motion counterpart.
const Duration kCapturedFlashLinger = Duration(milliseconds: 300);
const Duration kCapturedFlashLingerReduced = Duration(milliseconds: 250);

/// Strength of the red tint over a captured disc while it flies.
const double _kTintAlpha = 0.45;

/// Where the ring stands at the end of the flight: its scale and its opacity.
/// The linger carries on from exactly these, so the hand-over is seamless.
const double _kRingScaleStart = 1.15;
const double _kRingScaleEnd = 1.85;
const double _kRingOpacityStart = 1.0;
const double _kRingOpacityEnd = 0.65;
const double _kRingScaleLingerEnd = 2.1;

/// A burst of short rays around a token that has just finished. [size] is the
/// side of the square it is drawn in (the board passes a multiple of its cell
/// size). Restarts, rather than stacking, when [restart] changes.
class HomeBurst extends StatefulWidget {
  const HomeBurst({
    super.key,
    required this.size,
    required this.seatColor,
    required this.restart,
    required this.onDone,
  });

  final double size;
  final Color seatColor;

  /// A counter the board bumps for a second landing of the same token.
  final int restart;

  /// Called once, the moment the burst has run its life.
  final VoidCallback onDone;

  @override
  State<HomeBurst> createState() => _HomeBurstState();
}

class _HomeBurstState extends State<HomeBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kHomeBurstDuration)
      ..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    _controller.duration = _reduced
        ? kHomeBurstDurationReduced
        : kHomeBurstDuration;
    _controller.forward();
  }

  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void didUpdateWidget(covariant HomeBurst oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restart != widget.restart) {
      _controller.duration = _reduced
          ? kHomeBurstDurationReduced
          : kHomeBurstDuration;
      _controller.forward(from: 0);
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onDone();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: HomeBurstPainter(
                t: _controller.value,
                seatColor: widget.seatColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints one frame of the burst, [t] from 0 to 1: twelve rays, gold and the
/// seat colour alternating, flying outward from the centre while a thin gold
/// ring widens and everything fades. Public so a test can read [t].
class HomeBurstPainter extends CustomPainter {
  const HomeBurstPainter({required this.t, required this.seatColor});

  static const int rays = 12;

  final double t;
  final Color seatColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double half = size.shortestSide / 2;
    final Offset c = size.center(Offset.zero);
    final double eased = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
    final double fade = 1.0 - Curves.easeIn.transform(t.clamp(0.0, 1.0));
    final double inner = half * (0.22 + 0.42 * eased);
    final double length = half * 0.30 * (1.0 - 0.5 * eased);
    final double stroke = math.max(2.0, half * 0.10);

    final Paint ring = Paint()
      ..color = LudoColors.gold.withValues(alpha: 0.7 * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, half * 0.05);
    canvas.drawCircle(c, half * (0.18 + 0.62 * eased), ring);

    for (var i = 0; i < rays; i++) {
      final double angle = 2 * math.pi * i / rays;
      final Offset dir = Offset(math.cos(angle), math.sin(angle));
      final Paint p = Paint()
        ..color = (i.isEven ? LudoColors.gold : seatColor).withValues(
          alpha: fade,
        )
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke;
      canvas.drawLine(c + dir * inner, c + dir * (inner + length), p);
    }
  }

  @override
  bool shouldRepaint(covariant HomeBurstPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.seatColor != seatColor;
}

/// The red mark a captured disc of mine wears: a tint over the disc and a ring
/// that stands outside it. It fills the box it is given (the disc's box) and
/// paints past it without clipping.
class CapturedFlashMark extends StatelessWidget {
  const CapturedFlashMark({
    super.key,
    required this.tintAlpha,
    required this.ringScale,
    required this.ringOpacity,
  });

  /// The mark at flight progress [u] from 0 (take-off) to 1 (landing).
  CapturedFlashMark.inFlight({Key? key, required double u})
    : this(
        key: key,
        tintAlpha: _kTintAlpha,
        ringScale: _lerp(_kRingScaleStart, _kRingScaleEnd, u),
        ringOpacity: _lerp(_kRingOpacityStart, _kRingOpacityEnd, u),
      );

  /// The mark [v] of the way (0 to 1) through the linger after landing.
  CapturedFlashMark.lingering({Key? key, required double v})
    : this(
        key: key,
        tintAlpha: _kTintAlpha * (1 - v),
        ringScale: _lerp(_kRingScaleEnd, _kRingScaleLingerEnd, v),
        ringOpacity: _kRingOpacityEnd * (1 - v),
      );

  final double tintAlpha;
  final double ringScale;
  final double ringOpacity;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double side = constraints.biggest.shortestSide;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: LudoColors.error.withValues(alpha: tintAlpha),
                  ),
                ),
                Transform.scale(
                  scale: ringScale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: LudoColors.error.withValues(alpha: ringOpacity),
                        width: math.max(2.0, side * 0.1),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What is left of the red mark after the disc has landed in its yard: the
/// ring fades out over [kCapturedFlashLinger] ([kCapturedFlashLingerReduced]
/// under reduced motion), then [onDone]. Fills the box it is given.
class CapturedFlashLinger extends StatefulWidget {
  const CapturedFlashLinger({
    super.key,
    required this.markKey,
    required this.onDone,
  });

  /// The key the mark inside carries, so the key the player-facing tree
  /// finds is the same one the flight's mark wore.
  final Key markKey;
  final VoidCallback onDone;

  @override
  State<CapturedFlashLinger> createState() => _CapturedFlashLingerState();
}

class _CapturedFlashLingerState extends State<CapturedFlashLinger>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kCapturedFlashLinger,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    _controller.duration = MediaQuery.disableAnimationsOf(context)
        ? kCapturedFlashLingerReduced
        : kCapturedFlashLinger;
    _controller.forward();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onDone();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CapturedFlashMark.lingering(
        key: widget.markKey,
        v: _controller.value,
      ),
    );
  }
}
