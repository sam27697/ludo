// The board widget: draws the 15 by 15 grid and every seat's tokens on top
// of it. Every token's position comes from board_geometry.dart's cellFor;
// this file adds no coordinate logic of its own.
//
// Pure function of its arguments, same as the geometry underneath it: no
// network, no timers, no clock, no game rules beyond the coordinate mapping.
// That is what lets a room screen, a screenshot test and a plain widget test
// all render the exact same board from the exact same tokens map.
//
// C-223 adds the play surface itself: my own tokens are tappable on the
// board (`mySeat`, `legal`, `autoMoveToken`, `onTokenTap`,
// `onIllegalTokenTap`). A call that passes only `tokens` and `seatsInPlay`
// still draws exactly what it always drew and nothing on it is tappable --
// that is the spectator view, and it is also what the finished-game board
// uses, since a board nobody can move on has nothing to tap.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'board_geometry.dart';
import 'theme.dart';

export 'board_geometry.dart';

/// A Ludo board: the static grid plus every token of every seat in
/// [seatsInPlay], each placed by [cellFor].
///
/// This widget does not decide whose turn it is, does not know a game rule
/// beyond the coordinate mapping in board_geometry.dart and the legality
/// [legal] itself hands it, and renders exactly what it is given, including
/// a position the caller drew optimistically that the server later
/// contradicts.
class LudoBoard extends StatefulWidget {
  LudoBoard({
    super.key,
    required this.tokens,
    this.seatsInPlay = const [0, 1, 2, 3],
    this.mySeat,
    this.legal = const <int>{},
    this.autoMoveToken,
    this.onTokenTap,
    this.onIllegalTokenTap,
  }) : assert(
         seatsInPlay.length >= 2 && seatsInPlay.length <= 4,
         'seatsInPlay must have 2, 3 or 4 entries',
       ),
       assert(
         seatsInPlay.toSet().length == seatsInPlay.length,
         'seatsInPlay must not repeat a seat',
       ),
       assert(
         seatsInPlay.every((seat) => seat >= 0 && seat <= 3),
         'seatsInPlay entries must be 0..3',
       ),
       assert(
         seatsInPlay.every((seat) {
           final progresses = tokens[seat];
           if (progresses == null || progresses.length != 4) return false;
           return progresses.every((p) => p >= -1 && p <= 57);
         }),
         'every seat in seatsInPlay needs a tokens entry of exactly 4 '
         'progresses, each -1..57',
       );

  /// tokens[seat] is that seat's four progresses, in token index order.
  /// Every seat in [seatsInPlay] must have an entry. Length 4 each.
  final Map<int, List<int>> tokens;

  /// Which seats are playing. 2, 3 or 4 entries, each 0..3.
  final List<int> seatsInPlay;

  /// The seat this board is tappable for. Null is the spectator view:
  /// nothing on the board responds to a tap.
  final int? mySeat;

  /// Token indices of [mySeat] that may move right now. Ignored for any
  /// other seat's tokens, which are never tappable regardless.
  final Set<int> legal;

  /// The token index (of [mySeat]) glowing for the unique-legal hold, or
  /// null when no hold is pending.
  final int? autoMoveToken;

  /// A legal tap, already resolved for stacks: the lowest legal index on
  /// the cell tapped.
  final void Function(int token)? onTokenTap;

  /// A tap on one of [mySeat]'s tokens that is not in [legal]. The board
  /// shakes that token itself; this is only the notification hook for
  /// whatever else wants to know (a later order's feedback service).
  final void Function(int token)? onIllegalTokenTap;

  @override
  State<LudoBoard> createState() => _LudoBoardState();
}

class _LudoBoardState extends State<LudoBoard> {
  int? _shakingToken;
  Timer? _shakeTimer;

  @override
  void dispose() {
    _shakeTimer?.cancel();
    super.dispose();
  }

  void _triggerShake(int tokenIndex) {
    _shakeTimer?.cancel();
    setState(() {
      _shakingToken = tokenIndex;
    });
    _shakeTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _shakingToken = null;
      });
    });
  }

  /// [mySeat]'s four token indices grouped by the cell they currently sit
  /// on. Two or more indices land in the same group exactly when C-223's
  /// "stacks" rule applies to them: same seat, same progress. `cellFor`
  /// already gives yard and finished tokens one cell per token index, so
  /// only main-track and home-column progresses ever produce a group of
  /// more than one.
  List<_CellGroup> _cellGroups(int mySeat, double cellSize) {
    final List<int> progresses = widget.tokens[mySeat]!;
    final Map<BoardCell, List<int>> byCell = <BoardCell, List<int>>{};
    for (var index = 0; index < 4; index++) {
      final BoardCell cell = cellFor(
        seat: mySeat,
        progress: progresses[index],
        tokenIndex: index,
      );
      byCell.putIfAbsent(cell, () => <int>[]).add(index);
    }
    return <_CellGroup>[
      for (final MapEntry<BoardCell, List<int>> entry in byCell.entries)
        _CellGroup(
          center: Offset(
            entry.key.col * cellSize + cellSize / 2,
            entry.key.row * cellSize + cellSize / 2,
          ),
          indices: entry.value..sort(),
        ),
    ];
  }

  void _handleTapUp(TapUpDetails details, double cellSize, double tokenSize) {
    final int? mySeat = widget.mySeat;
    if (mySeat == null) {
      return;
    }
    final double hitSize = math.max(48.0, tokenSize);
    final List<_CellGroup> groups = _cellGroups(mySeat, cellSize);

    _CellGroup? best;
    double bestDistance = double.infinity;
    for (final _CellGroup group in groups) {
      final double dx = (details.localPosition.dx - group.center.dx).abs();
      final double dy = (details.localPosition.dy - group.center.dy).abs();
      if (dx > hitSize / 2 || dy > hitSize / 2) {
        continue;
      }
      final double distance = (details.localPosition - group.center).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = group;
      }
    }
    if (best == null) {
      return;
    }

    final List<int> legalHere =
        best.indices.where((int index) => widget.legal.contains(index)).toList()
          ..sort();
    if (legalHere.isNotEmpty) {
      widget.onTokenTap?.call(legalHere.first);
      return;
    }

    final int shakeIndex = best.indices.first;
    widget.onIllegalTokenTap?.call(shakeIndex);
    _triggerShake(shakeIndex);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const Key('ludo-board'),
      builder: (context, constraints) {
        final side = _squareSide(constraints);
        final double cellSize = side / 15;
        final double tokenSize = cellSize * 0.7;
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handleTapUp(details, cellSize, tokenSize),
              child: Stack(
                alignment: Alignment.topLeft,
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: const _BoardPainter()),
                  ),
                  for (final seat in widget.seatsInPlay)
                    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++)
                      ..._tokenLayer(
                        seat: seat,
                        tokenIndex: tokenIndex,
                        cellSize: cellSize,
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Every widget one (seat, tokenIndex) pair contributes to the stack, in
  /// paint order: the hit-target marker (mine only), the ring or glow
  /// behind the token (mine only, when it applies), then the token itself,
  /// shake-wrapped when it is the one currently shaking.
  List<Widget> _tokenLayer({
    required int seat,
    required int tokenIndex,
    required double cellSize,
  }) {
    final int progress = widget.tokens[seat]![tokenIndex];
    final BoardCell cell = cellFor(
      seat: seat,
      progress: progress,
      tokenIndex: tokenIndex,
    );

    // Two tokens of one seat can land on the same cell on purpose (see
    // board_geometry.dart). Fan them out a little by token index rather
    // than stacking them exactly on top of each other; this is
    // presentation only and does not change the cell cellFor returned.
    final double fan = cellSize * 0.12;
    final double fanDx = tokenIndex.isEven ? -fan : fan;
    final double fanDy = tokenIndex < 2 ? -fan : fan;

    final double tokenSize = cellSize * 0.7;
    final double left =
        cell.col * cellSize + (cellSize - tokenSize) / 2 + fanDx;
    final double top = cell.row * cellSize + (cellSize - tokenSize) / 2 + fanDy;

    final bool isMine = seat == widget.mySeat;
    final bool legalHere = isMine && widget.legal.contains(tokenIndex);
    final bool autoMoveHere = isMine && widget.autoMoveToken == tokenIndex;
    final bool shakingHere = isMine && _shakingToken == tokenIndex;

    final List<Widget> layer = <Widget>[];

    if (isMine) {
      final double hitSize = math.max(48.0, tokenSize);
      layer.add(
        Positioned(
          key: Key('board-token-hit-$seat-$tokenIndex'),
          left: left + tokenSize / 2 - hitSize / 2,
          top: top + tokenSize / 2 - hitSize / 2,
          width: hitSize,
          height: hitSize,
          // A transparent ColoredBox, not a bare SizedBox: it needs to
          // actually paint (even invisibly) to register its own hit test,
          // so a test driving a tap by this key lands on it directly
          // rather than only working by way of the board's outer opaque
          // GestureDetector underneath it.
          child: const ColoredBox(color: Color(0x00000000)),
        ),
      );
    }

    if (autoMoveHere) {
      final double ringSize = tokenSize * 1.7;
      layer.add(
        Positioned(
          key: Key('board-automove-glow-$seat-$tokenIndex'),
          left: left + tokenSize / 2 - ringSize / 2,
          top: top + tokenSize / 2 - ringSize / 2,
          width: ringSize,
          height: ringSize,
          child: const _PulsingRing(period: Duration(milliseconds: 450)),
        ),
      );
    } else if (legalHere) {
      final double ringSize = tokenSize * 1.7;
      layer.add(
        Positioned(
          key: Key('board-legal-ring-$seat-$tokenIndex'),
          left: left + tokenSize / 2 - ringSize / 2,
          top: top + tokenSize / 2 - ringSize / 2,
          width: ringSize,
          height: ringSize,
          child: const _PulsingRing(period: Duration(milliseconds: 900)),
        ),
      );
    }

    final Widget token = Semantics(
      key: Key('token-$seat-$tokenIndex'),
      identifier: 'cell-${cell.col}-${cell.row}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: LudoColors.seats[seat],
          border: Border.all(
            color: LudoColors.ink.withValues(alpha: 0.55),
            width: math.max(1, tokenSize * 0.06),
          ),
        ),
      ),
    );

    if (shakingHere) {
      layer.add(
        Positioned(
          left: left,
          top: top,
          width: tokenSize,
          height: tokenSize,
          child: _ShakeOnce(
            key: Key('board-token-shake-$seat-$tokenIndex'),
            size: tokenSize,
            child: token,
          ),
        ),
      );
    } else {
      layer.add(
        Positioned(
          left: left,
          top: top,
          width: tokenSize,
          height: tokenSize,
          child: token,
        ),
      );
    }

    return layer;
  }

  /// The largest square that fits the constraints this widget is given. Both
  /// axes bounded picks the smaller; one axis bounded uses that axis; both
  /// unbounded has no sensible size to fall back on and renders nothing
  /// rather than an infinite board.
  static double _squareSide(BoxConstraints constraints) {
    final hasWidth = constraints.hasBoundedWidth;
    final hasHeight = constraints.hasBoundedHeight;
    double side;
    if (hasWidth && hasHeight) {
      side = math.min(constraints.maxWidth, constraints.maxHeight);
    } else if (hasWidth) {
      side = constraints.maxWidth;
    } else if (hasHeight) {
      side = constraints.maxHeight;
    } else {
      side = 0;
    }
    if (!side.isFinite || side < 0) {
      side = 0;
    }
    return side;
  }
}

/// One (seat, tokenIndex) group of [mySeat]'s tokens sharing a board cell,
/// used only to resolve a tap: `center` is that cell's pixel centre, and
/// `indices` is every token index of mine sitting on it, sorted ascending.
class _CellGroup {
  const _CellGroup({required this.center, required this.indices});

  final Offset center;
  final List<int> indices;
}

/// The 300ms horizontal shake an illegal tap gets. Plays once from the
/// moment it is built (this widget only exists in the tree for the
/// duration of the shake; see `board-token-shake-S-I` in C-223's key
/// table) and holds still under reduced motion, per the same rule the die
/// and the legal ring follow: meaning stays, motion goes.
class _ShakeOnce extends StatelessWidget {
  const _ShakeOnce({super.key, required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.linear,
      builder: (context, t, staticChild) {
        final double dx = math.sin(t * math.pi * 4) * size * 0.18 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: staticChild);
      },
      child: child,
    );
  }
}

/// The pulsing ring behind a legal or unique-legal-hold token: stroke width
/// and opacity breathe over [period], a full cycle. Reduced motion holds it
/// static and thicker instead of stopping it from drawing at all -- the
/// legality it marks is still true, only the motion that says so goes.
class _PulsingRing extends StatefulWidget {
  const _PulsingRing({required this.period});

  final Duration period;

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool? _reduced;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced != _reduced) {
      _reduced = reduced;
      if (reduced) {
        _controller.stop();
        _controller.value = 1;
      } else {
        _controller.repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = _reduced ?? false;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final double t = _controller.value;
          final double strokeWidth = reduced ? 3.5 : 2.0 + 2.0 * t;
          final double opacity = reduced ? 1.0 : 0.45 + 0.55 * t;
          return CustomPaint(
            painter: _RingPainter(
              color: LudoColors.success,
              strokeWidth: strokeWidth,
              opacity: opacity,
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.color,
    required this.strokeWidth,
    required this.opacity,
  });

  final Color color;
  final double strokeWidth;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(strokeWidth / 2);
    canvas.drawOval(
      rect,
      Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.strokeWidth != strokeWidth || oldDelegate.opacity != opacity;
}

/// Paints the static board: the grid, the four yards, the shared track, the
/// four home columns and the centre. None of this determines where a token
/// goes; it is drawn from the same [cellFor] a token uses, so the background
/// and the tokens can never show a track that disagrees with each other.
///
/// Seat fills and board inks come from [LudoColors]: one paintbox with theme.
class _BoardPainter extends CustomPainter {
  const _BoardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = size.width / 15;

    canvas.drawRect(Offset.zero & size, Paint()..color = LudoColors.dieFace);

    const yardCorners = [
      (0, 0), // seat 0, top-left
      (9, 0), // seat 1, top-right
      (9, 9), // seat 2, bottom-right
      (0, 9), // seat 3, bottom-left
    ];
    for (var seat = 0; seat < 4; seat++) {
      final (col, row) = yardCorners[seat];
      _fillCells(
        canvas,
        cellSize,
        col,
        row,
        6,
        6,
        LudoColors.seats[seat].withValues(alpha: 0.16),
      );
    }

    for (var seat = 0; seat < 4; seat++) {
      for (var progress = 52; progress <= 56; progress++) {
        final cell = cellFor(seat: seat, progress: progress);
        _fillCell(
          canvas,
          cellSize,
          cell,
          LudoColors.seats[seat].withValues(alpha: 0.32),
        );
      }
    }

    for (var progress = 0; progress < 52; progress++) {
      final cell = cellFor(seat: 0, progress: progress);
      _fillCell(
        canvas,
        cellSize,
        cell,
        LudoColors.paperElevated.withValues(alpha: 0.65),
      );
    }

    _fillCells(
      canvas,
      cellSize,
      6,
      6,
      3,
      3,
      LudoColors.inkMuted.withValues(alpha: 0.5),
    );

    final gridPaint = Paint()
      ..color = LudoColors.inkMuted.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 15; i++) {
      final offset = i * cellSize;
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset, size.height),
        gridPaint,
      );
      canvas.drawLine(Offset(0, offset), Offset(size.width, offset), gridPaint);
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = LudoColors.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _fillCell(Canvas canvas, double cellSize, BoardCell cell, Color color) {
    _fillCells(canvas, cellSize, cell.col, cell.row, 1, 1, color);
  }

  void _fillCells(
    Canvas canvas,
    double cellSize,
    int col,
    int row,
    int width,
    int height,
    Color color,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(
        col * cellSize,
        row * cellSize,
        width * cellSize,
        height * cellSize,
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) => false;
}
