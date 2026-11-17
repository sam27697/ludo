// The laughing face a capture draws on the capturer's yard, and the short
// line over it. GameScreen decides when one exists and for how long; this
// file only paints it. Contract C-468 D5, C-662 T1-T6.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// How long the face stays up, reduced motion included. C-468 D5.
const Duration kCaptureGloatLife = Duration(milliseconds: 1600);

/// The last part of the life, in which the face rises and fades. A rolled
/// die of the capturer's seat starts the same exit early. C-579 D2.
const Duration kCaptureGloatExit = Duration(milliseconds: 250);

/// Delay before the captured seat hears the gloat cue. C-468 D5.
const Duration kCaptureGloatSoundDelay = Duration(milliseconds: 250);

/// Seat and start serial the board's `gloat` parameter carries. A new
/// [serial] is a new gloat, including one that replaces another still
/// showing. Null on the board draws nothing. C-468 D5.
///
/// [yielding] is true once the screen has started the face's exit ahead of
/// its schedule, because its seat rolled. C-579 D2.
class BoardGloat {
  const BoardGloat({
    required this.seat,
    required this.serial,
    this.yielding = false,
  });

  final int seat;
  final int serial;
  final bool yielding;
}

/// The eight lines, in the order of `gloatLine1` to `gloatLine8`. C-662 T1.
const int kGloatLineCount = 8;

/// Widest the line's pill gets at text scale 1.0, in cells. A longer line
/// is shrunk to fit, never wrapped there. C-662 T2.
const double kGloatLineMaxCells = 2.6;

/// Clear space between the pill and the face, in cells. C-662 T2.
const double _lineGapCells = 0.15;

/// Which of the eight lines shows next: a shuffled bag that refills when
/// empty, and a refill never opens with the line that just showed. C-662 T3.
class _GloatBag {
  _GloatBag() : _random = math.Random();

  math.Random _random;
  final List<int> _left = <int>[];
  int? _last;

  int next() {
    if (_left.isEmpty) {
      _refill();
    }
    final int index = _left.removeLast();
    _last = index;
    return index;
  }

  void _refill() {
    _left
      ..addAll(List<int>.generate(kGloatLineCount, (int i) => i))
      ..shuffle(_random);
    // The bag is drawn from its end.
    if (_last != null && _left.last == _last) {
      final int swap = _random.nextInt(_left.length - 1);
      final int held = _left.last;
      _left[_left.length - 1] = _left[swap];
      _left[swap] = held;
    }
  }

  void reset(math.Random random) {
    _random = random;
    _left.clear();
    _last = null;
  }

  void force(List<int> order) {
    _left
      ..clear()
      ..addAll(order.reversed);
    _last = null;
  }
}

final _GloatBag _gloatBag = _GloatBag();

/// Test seam for C-662 T3: replaces the bag's random source with [random]
/// (a seeded one, so a run is repeatable) and empties the bag, so the next
/// gloat starts a fresh shuffle.
@visibleForTesting
void debugSeedGloatBag(math.Random random) => _gloatBag.reset(random);

/// Test seam for C-662 T3: the next gloats show exactly [order] (indices 0
/// to 7, zero based, `gloatLine1` is 0) one per serial, after which the bag
/// refills by its rule. Each index may appear once.
@visibleForTesting
void debugForceGloatOrder(List<int> order) {
  assert(
    order.toSet().length == order.length &&
        order.every((int i) => i >= 0 && i < kGloatLineCount),
    'indices 0..7, no repeats',
  );
  _gloatBag.force(order);
}

String _lineText(AppLocalizations l, int index) {
  switch (index) {
    case 0:
      return l.gloatLine1;
    case 1:
      return l.gloatLine2;
    case 2:
      return l.gloatLine3;
    case 3:
      return l.gloatLine4;
    case 4:
      return l.gloatLine5;
    case 5:
      return l.gloatLine6;
    case 6:
      return l.gloatLine7;
    default:
      return l.gloatLine8;
  }
}

/// Laughing face centred by the board on seat M's viewed yard. The root
/// key is `capture-gloat-<seat>`. C-468 D5.
///
/// The line over it is a sibling of that keyed subtree, so the key's rect
/// stays the face's two cells. It paints outside this widget's own box.
/// C-662 T2.
class CaptureGloat extends StatefulWidget {
  const CaptureGloat({
    super.key,
    required this.seat,
    required this.serial,
    required this.diameter,
    required this.cellSize,
    this.yielding = false,
    this.bounds,
  });

  final int seat;
  final int serial;

  /// The board's rect in this widget's own coordinates (origin at the
  /// face's top left). The line is held inside it. Null leaves the line
  /// unbounded. C-662 T2.
  final Rect? bounds;

  /// The exit starts now if it has not started. C-579 D2.
  final bool yielding;

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

  /// Zero based index into the pool, one per serial. C-662 T3.
  late int _line;

  @override
  void initState() {
    super.initState();
    _line = _gloatBag.next();
    _clock = AnimationController(vsync: this, duration: kCaptureGloatLife)
      ..forward();
  }

  @override
  void didUpdateWidget(covariant CaptureGloat oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same seat keeps this state (the key does not carry the serial).
    // A replacement has to start its pop over. C-468 D5.
    if (oldWidget.serial != widget.serial) {
      _line = _gloatBag.next();
      _clock.forward(from: 0);
    } else if (widget.yielding && !oldWidget.yielding) {
      // Straight into the face's own exit, which then plays out in
      // [kCaptureGloatExit]. A face already leaving keeps its place.
      // C-579 D2.
      final double exitAt =
          (kCaptureGloatLife - kCaptureGloatExit).inMicroseconds /
          kCaptureGloatLife.inMicroseconds;
      if (_clock.value < exitAt) {
        _clock.forward(from: exitAt);
      }
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
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            IgnorePointer(
              key: Key('capture-gloat-${widget.seat}'),
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _clock,
                  builder: (BuildContext context, Widget? child) {
                    final _GloatPose pose = _poseFor(
                      kCaptureGloatLife * _clock.value,
                      reduced: reduced,
                      cellSize: widget.cellSize,
                    );
                    return Opacity(
                      opacity: pose.opacity,
                      child: Transform.translate(
                        offset: Offset(0, pose.rise),
                        child: Transform.rotate(
                          angle: pose.radians,
                          child: Transform.scale(
                            scale: pose.scale,
                            child: child,
                          ),
                        ),
                      ),
                    );
                  },
                  child: SizedBox(
                    width: widget.diameter,
                    height: widget.diameter,
                    child: CustomPaint(
                      painter: _LaughingFacePainter(
                        color: LudoColors.seats[seat],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _clock,
                builder: (BuildContext context, Widget? child) {
                  // Opacity and rise follow the face; no pop, no wobble.
                  final _GloatPose pose = _poseFor(
                    kCaptureGloatLife * _clock.value,
                    reduced: reduced,
                    cellSize: widget.cellSize,
                  );
                  return Opacity(
                    opacity: pose.opacity,
                    child: Transform.translate(
                      offset: Offset(0, pose.rise),
                      child: child,
                    ),
                  );
                },
                child: CustomSingleChildLayout(
                  delegate: _LineLayout(
                    cellSize: widget.cellSize,
                    bounds: widget.bounds,
                  ),
                  child: _LinePill(
                    seat: seat,
                    cellSize: widget.cellSize,
                    text: _lineText(AppLocalizations.of(context), _line),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded pill in the seat colour, bold text in the ink that reads on it.
/// One line; a line wider than the pill may be, or a larger text scale,
/// shrinks to fit rather than wrap or clip. C-662 T2.
class _LinePill extends StatelessWidget {
  const _LinePill({
    required this.seat,
    required this.cellSize,
    required this.text,
  });

  final int seat;
  final double cellSize;
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color fill = LudoColors.seats[seat];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(cellSize * 2),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: cellSize * 0.25,
          vertical: cellSize * 0.12,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            text,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: contrastingInk(fill),
              fontSize: cellSize * 0.55,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts the pill centred over the face with a small gap, then shifts it
/// inward until it lies inside the board. The height it may take stops
/// short of the board's top by the exit's rise, so the rise cannot carry
/// it out. C-662 T2.
class _LineLayout extends SingleChildLayoutDelegate {
  const _LineLayout({required this.cellSize, required this.bounds});

  final double cellSize;
  final Rect? bounds;

  double get _gap => cellSize * _lineGapCells;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    double maxWidth = cellSize * kGloatLineMaxCells;
    double maxHeight = cellSize * 2;
    final Rect? board = bounds;
    if (board != null) {
      maxWidth = math.min(maxWidth, board.width);
      maxHeight = math.max(0, -board.top - _gap - cellSize * 0.5);
    }
    return BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = (size.width - childSize.width) / 2;
    final double y = -_gap - childSize.height;
    final Rect? board = bounds;
    if (board != null) {
      x = x.clamp(
        board.left,
        math.max(board.left, board.right - childSize.width),
      );
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _LineLayout oldDelegate) =>
      oldDelegate.cellSize != cellSize || oldDelegate.bounds != bounds;
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

final double _exitMs = kCaptureGloatExit.inMicroseconds / 1000.0;
final double _exitStartMs =
    (kCaptureGloatLife - kCaptureGloatExit).inMicroseconds / 1000.0;

/// Half a cell upward over the last 250 ms. C-468 D5.
double _riseAt(double t, double cellSize) {
  if (t < _exitStartMs) {
    return 0;
  }
  final double u = ((t - _exitStartMs) / _exitMs).clamp(0.0, 1.0);
  return -0.5 * cellSize * u;
}

double _opacityAt(double t) {
  if (t < _exitStartMs) {
    return 1;
  }
  final double u = ((t - _exitStartMs) / _exitMs).clamp(0.0, 1.0);
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
