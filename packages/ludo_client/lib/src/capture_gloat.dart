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

/// Widest the line's pill gets, in cells: one yard side. A longer line
/// wraps, to two lines at most. C-662 T2'.
const double kGloatLineMaxCells = 6;

/// Side padding of the pill, in cells. C-662 T2'.
const double _linePadXCells = 0.3;

/// Top and bottom padding of the pill, in cells. C-662 T2'.
const double _linePadYCells = 0.04;

/// The line's type size before the screen's text scaler. C-662 T2'.
const double kGloatLineFontSize = 14;

/// Line height as a multiple of the type size. Two lines, the pill's
/// padding, the gap and the exit's rise have to fit the two cells that lie
/// above a corner yard's face on a 360 px board. C-662 T2'.
const double _lineHeight = 1.1;

/// Clear space between the pill and the face, in cells. C-662 T2.
const double _lineGapCells = 0.05;

/// How far the face, and the line with it, rises in the exit, in cells.
/// C-468 D5.
const double _exitRiseCells = 0.5;

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
                builder: (BuildContext context, Widget? pill) {
                  // Opacity and rise follow the face; no pop, no wobble.
                  final _GloatPose pose = _poseFor(
                    kCaptureGloatLife * _clock.value,
                    reduced: reduced,
                    cellSize: widget.cellSize,
                  );
                  return Opacity(
                    opacity: pose.opacity,
                    child: CustomSingleChildLayout(
                      delegate: _LineLayout(
                        cellSize: widget.cellSize,
                        bounds: widget.bounds,
                        rise: pose.rise,
                      ),
                      child: pill,
                    ),
                  );
                },
                // Passed as the builder's child, so the fit is measured when
                // its inputs change and not on every tick of the clock.
                child: _LinePill(
                  seat: seat,
                  cellSize: widget.cellSize,
                  text: _lineText(AppLocalizations.of(context), _line),
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
/// The text is [kGloatLineFontSize] through the screen's text scaler, in at
/// most two lines inside a pill of at most six cells. It is only made
/// smaller when two lines at that width cannot hold it in the room above
/// the face, which takes a large system text size. A line that fits at rest
/// but not with the exit's rise on top keeps its size; the layout then
/// stops its rise at the board's top. C-662 T2'.
class _LinePill extends StatelessWidget {
  const _LinePill({
    required this.seat,
    required this.cellSize,
    required this.text,
  });

  final int seat;
  final double cellSize;
  final String text;

  TextStyle _style(BuildContext context, Color ink, double factor) {
    return DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: ink,
        fontFamily: kLudoFontFamily,
        fontFamilyFallback: kLudoFontFallbacks,
        fontSize: kGloatLineFontSize * factor,
        fontWeight: FontWeight.w700,
        height: _lineHeight,
        decoration: TextDecoration.none,
      ),
    );
  }

  /// Whether [text] set in [factor] of the full size lies in two lines or
  /// fewer, no word broken, inside [width] by [height].
  bool _fits(
    BuildContext context,
    Color ink,
    double factor,
    double width,
    double height,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: _style(context, ink, factor)),
      textDirection: Directionality.of(context),
      textAlign: TextAlign.center,
      textScaler: MediaQuery.textScalerOf(context),
      textWidthBasis: TextWidthBasis.longestLine,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 2,
    )..layout(maxWidth: width);
    final bool fits =
        !painter.didExceedMaxLines &&
        painter.minIntrinsicWidth <= width + 0.01 &&
        painter.height <= height + 0.01;
    painter.dispose();
    return fits;
  }

  @override
  Widget build(BuildContext context) {
    final Color fill = LudoColors.seats[seat];
    final Color ink = contrastingInk(fill);
    final double padX = cellSize * _linePadXCells;
    final double padY = cellSize * _linePadYCells;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth - 2 * padX;
        final double height = constraints.maxHeight - 2 * padY;
        if (width <= 0 || height <= 0) {
          return const SizedBox.shrink();
        }
        double factor = 1;
        if (!_fits(context, ink, 1, width, height)) {
          // Largest factor at which two lines hold it with the rise to
          // spare. Fifteen halvings settle it far below a pixel.
          final double spare = math.max(
            height - cellSize * _exitRiseCells,
            padY,
          );
          double low = 0;
          double high = 1;
          for (int i = 0; i < 15; i++) {
            final double mid = (low + high) / 2;
            if (_fits(context, ink, mid, width, spare)) {
              low = mid;
            } else {
              high = mid;
            }
          }
          factor = low;
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(cellSize * 2),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
            child: Text(
              text,
              maxLines: 2,
              textAlign: TextAlign.center,
              textWidthBasis: TextWidthBasis.longestLine,
              style: _style(context, ink, factor),
            ),
          ),
        );
      },
    );
  }
}

/// Puts the pill centred over the face with a small gap, then shifts it
/// inward until it lies inside the board. The height it may take is what
/// lies above the face; the exit's [rise] lifts it as far as the board's
/// top allows and no further, so it never leaves the board. C-662 T2'.
class _LineLayout extends SingleChildLayoutDelegate {
  const _LineLayout({
    required this.cellSize,
    required this.bounds,
    required this.rise,
  });

  final double cellSize;
  final Rect? bounds;

  /// The face's rise now, zero or negative. C-662 T2.
  final double rise;

  double get _gap => cellSize * _lineGapCells;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    double maxWidth = cellSize * kGloatLineMaxCells;
    double maxHeight = cellSize * 4;
    final Rect? board = bounds;
    if (board != null) {
      maxWidth = math.min(maxWidth, board.width);
      maxHeight = math.max(0, -board.top - _gap);
    }
    return BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = (size.width - childSize.width) / 2;
    double y = -_gap - childSize.height + rise;
    final Rect? board = bounds;
    if (board != null) {
      x = x.clamp(
        board.left,
        math.max(board.left, board.right - childSize.width),
      );
      y = math.max(y, board.top);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _LineLayout oldDelegate) =>
      oldDelegate.cellSize != cellSize ||
      oldDelegate.bounds != bounds ||
      oldDelegate.rise != rise;
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
  return -_exitRiseCells * cellSize * u;
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
