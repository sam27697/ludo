// The die a player rolls by tapping it. Pure presentation and one gesture:
// this widget never calls the server itself, never decides whether a roll
// is legal, and never invents a face -- `face` is always the caller's
// `turn.value`, or null when none is known yet. Everything else (the pulse
// that invites a tap, the tumble while a roll is in flight, the shake and
// the "no answer" line after a silent 4 seconds) is state the caller
// computes from RoomController and hands in as plain booleans.
//
// Drawn in the style of die_mark.dart's _DieMarkPainter: a rounded square
// face with pips, not the four-seat brand mark. The border is painted in
// the seat colour of whoever's turn it is, so the die itself carries whose
// roll this is without a separate label.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// The die's fixed footprint, face and hit target both. C-223: "at least
/// 72dp"; this is also lib/src/die_mark.dart's compact size, so the two
/// dice in this app read as the same object at two scales.
const double _kDieSize = 72;

/// Pip positions for each face, as unit offsets from the die's centre.
/// Scaled by a fraction of the face side in [_GameDiePainter]. The layout
/// matches a standard die: opposite corners for 2, all four corners for 4,
/// two columns of three for 6.
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

class GameDie extends StatefulWidget {
  const GameDie({
    super.key,
    required this.face,
    required this.seatColor,
    required this.enabled,
    required this.tumbling,
    required this.noAnswer,
    required this.noMove,
    this.onTap,
    this.onInvalidTap,
  });

  /// The last known roll, straight from `turn.value`. Null when none is
  /// known yet. Ignored while [tumbling] is true, which draws its own
  /// cosmetic, never-settling face instead.
  final int? face;

  /// `LudoColors.seats[turn.seat]`: the die's border is whoever's turn it
  /// currently is, not whoever is looking at the screen.
  final Color seatColor;

  /// True exactly when a tap would send `controller.roll()`. Also the
  /// Semantics `enabled` value C-223 requires.
  final bool enabled;

  /// True between a rolling tap and the result (or the 4s no-answer stop).
  final bool tumbling;

  /// True after 4 silent seconds following a rolling tap, until the next
  /// tap. Shows `loc.gameRollNoAnswer` under the die.
  final bool noAnswer;

  /// C-236 rule 4: true for the 1500ms the no-move beat holds, from a
  /// `rolled` for my seat with an empty `legal`. Draws the red X
  /// (`game-die-no-move-mark`, an X shape and not only a colour, doctrine
  /// P9) over whatever the die is otherwise showing, independent of
  /// [face], [enabled] or [tumbling] -- the mark is not delayed or hidden
  /// by the next seat's turn landing underneath it.
  final bool noMove;

  /// Fires on a tap while [enabled]. The widget itself still guards this:
  /// a tap while disabled never calls it, even if a caller passes one.
  final VoidCallback? onTap;

  /// C-236 rule 3: fires once on a tap that lands while [enabled] is
  /// false, instead of [onTap]. The widget never swallows a tap silently:
  /// every tap on the die either rolls or reports itself as invalid.
  final VoidCallback? onInvalidTap;

  @override
  State<GameDie> createState() => _GameDieState();
}

class _GameDieState extends State<GameDie> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _tumble;
  late final AnimationController _shake;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _tumble = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
    _syncTumble();
  }

  @override
  void didUpdateWidget(covariant GameDie oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
    _syncTumble();
    if (!oldWidget.noAnswer && widget.noAnswer) {
      _shake.forward(from: 0);
    }
  }

  bool get _reducedMotion => MediaQuery.disableAnimationsOf(context);

  void _syncPulse() {
    final bool shouldPulse =
        widget.enabled && !widget.tumbling && !_reducedMotion;
    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  void _syncTumble() {
    final bool shouldRun = widget.tumbling && !_reducedMotion;
    if (shouldRun && !_tumble.isAnimating) {
      _tumble.repeat();
    } else if (!shouldRun && _tumble.isAnimating) {
      _tumble.stop();
      _tumble.value = 0;
    }
  }

  /// C-236 rule 3: a tap that lands while the die would not roll never goes
  /// silent (doctrine P3's "illegal taps get a small shake, never
  /// silence"). The gesture is always wired to this one method; the branch
  /// on [GameDie.enabled] happens here rather than in whether the handler
  /// is attached at all, which is what used to let a disabled tap vanish
  /// with nothing to show for it.
  void _handleTap() {
    if (!widget.enabled) {
      widget.onInvalidTap?.call();
      _shake.forward(from: 0);
      return;
    }
    widget.onTap?.call();
  }

  /// A face that never settles while [widget.tumbling] is true, driven off
  /// the repeating tumble animation itself rather than a second timer or a
  /// `Random` this widget would have to own and dispose. Purely cosmetic:
  /// `turn.value` is never read from this.
  int _tumbleFace() {
    final int step = (_tumble.value * 6173).floor();
    return 1 + (step % 6);
  }

  /// C-238: wraps a painted face with `game-die-idle-art` exactly when that
  /// paint shows the cube rather than a resting or cycling value -- which,
  /// per [_GameDiePainter], is exactly when [shown] is null. Doctrine P4: a
  /// cube with three faces at once can never be read as an invented result,
  /// so it is always safe to show while no value is known.
  Widget _dieArt({required Color edgeColor, required int? shown}) {
    final Widget paint = CustomPaint(
      size: const Size.square(_kDieSize),
      painter: _GameDiePainter(edgeColor: edgeColor, face: shown),
    );
    return shown == null
        ? KeyedSubtree(key: const Key('game-die-idle-art'), child: paint)
        : paint;
  }

  @override
  void dispose() {
    _pulse.dispose();
    _tumble.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool reduced = _reducedMotion;

    Widget die = _face(reduced: reduced);

    if (widget.tumbling) {
      die = KeyedSubtree(
        key: const Key('game-die-tumbling'),
        child: AnimatedBuilder(
          animation: _tumble,
          builder: (context, child) {
            final double angle = reduced ? 0 : _tumble.value * 2 * math.pi;
            return Transform.rotate(angle: angle, child: child);
          },
          child: die,
        ),
      );
    } else if (widget.enabled && !reduced) {
      die = KeyedSubtree(
        key: const Key('game-die-pulse'),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final double scale = 1.0 + 0.08 * math.sin(_pulse.value * math.pi);
            return Transform.scale(scale: scale, child: child);
          },
          child: die,
        ),
      );
    }

    die = AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final double t = _shake.value;
        final double dx = reduced ? 0 : math.sin(t * math.pi * 4) * 6 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: die,
    );

    // C-236 rule 4: the no-move mark sits in its own stack layer, above
    // whatever `die` is doing (resting face, tumble, shake), so it is never
    // delayed or hidden by the die's own animation state.
    final Widget dieFace = widget.noMove
        ? Stack(
            alignment: Alignment.center,
            children: [
              die,
              IgnorePointer(
                key: const Key('game-die-no-move-mark'),
                child: const CustomPaint(
                  size: Size.square(_kDieSize),
                  painter: _NoMoveMarkPainter(),
                ),
              ),
            ],
          )
        : die;

    // The key sits on the Semantics widget itself, not on the SizedBox
    // beneath it: getSemantics(find.byKey('game-die')) must return this
    // node's own button, label and enabled flag, and a key further down
    // the tree does not reliably walk back up to it.
    //
    // onTap is always wired, on both nodes, whether or not the die would
    // roll: C-236 rule 3 needs every tap to reach `_handleTap`, which is the
    // one place that decides between rolling and reporting an invalid tap.
    // `enabled` still carries the advertised Semantics state.
    final Widget tappable = Semantics(
      key: const Key('game-die'),
      button: true,
      label: loc.gameRollButton,
      enabled: widget.enabled,
      onTap: _handleTap,
      child: GestureDetector(
        // The Semantics wrapper above already states button, label, enabled
        // and the tap action on its own node; a GestureDetector's default
        // semantics would otherwise merge its own copy of that action into
        // the same node for no reason this widget needs.
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SizedBox(width: _kDieSize, height: _kDieSize, child: dieFace),
      ),
    );

    if (!widget.noAnswer) {
      return tappable;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        tappable,
        const SizedBox(height: kSpace2),
        Text(
          loc.gameRollNoAnswer,
          key: const Key('game-die-no-answer'),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// C-223 clarification 1: `game-die-face-N` names only a face the die
  /// rests on, never a cosmetic one cycled mid-tumble. While tumbling under
  /// reduced motion the die shows `game-die-blank` and does not cycle at
  /// all; while tumbling with motion allowed it still cycles the pips (the
  /// contract's "rotation plus pips cycling through random faces"), but
  /// that cosmetic face carries neither a `game-die-face-N` nor a
  /// `game-die-blank` key, since it is not the blank state either -- it is
  /// not resting on anything.
  Widget _face({required bool reduced}) {
    if (widget.tumbling) {
      // Cosmetic only: never settles, never carries a resting-face key.
      // Reduced motion does not merely hold rotation off, it also stops the
      // pip cycling and shows the idle cube (C-238 rule 4) until the result
      // lands, same as the blank face it stands in for.
      final int? shown = reduced ? null : _tumbleFace();
      final Widget art = _dieArt(edgeColor: widget.seatColor, shown: shown);
      return reduced
          ? KeyedSubtree(key: const Key('game-die-blank'), child: art)
          : art;
    }
    final int? shown = widget.face;
    final Key key = shown == null
        ? const Key('game-die-blank')
        : Key('game-die-face-$shown');
    return KeyedSubtree(
      key: key,
      child: _dieArt(edgeColor: widget.seatColor, shown: shown),
    );
  }
}

/// C-236 rule 4, doctrine P9: the no-move result is never colour alone. Two
/// crossing strokes over the die's full face, static -- nothing here needs a
/// reduced-motion branch because nothing here moves; the mark's 1500ms
/// lifetime is `game_screen.dart`'s clock, not this painter's.
class _NoMoveMarkPainter extends CustomPainter {
  const _NoMoveMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = size.shortestSide * 0.22;
    final Paint paint = Paint()
      ..color = LudoColors.error
      ..strokeWidth = math.max(3, size.shortestSide * 0.09)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(inset, inset),
      Offset(size.width - inset, size.height - inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset, inset),
      Offset(inset, size.height - inset),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _NoMoveMarkPainter oldDelegate) => false;
}

class _GameDiePainter extends CustomPainter {
  const _GameDiePainter({required this.edgeColor, required this.face});

  final Color edgeColor;
  final int? face;

  // C-238: the idle cube's seven corner points, as fractions of the box's
  // shortest side, origin at its top-left. `_cubeCenterF` is the near
  // corner shared by all three visible faces; `_cubeTopF` is the far top
  // corner and `_cubeBottomF` the near bottom one. The three quads below
  // (top/left/right) each use four of these seven points and are true
  // parallelograms, which is what reads as a cube rather than a flat
  // hexagon.
  static const Offset _cubeTopF = Offset(0.50, 0.04);
  static const Offset _cubeULF = Offset(0.04, 0.28);
  static const Offset _cubeURF = Offset(0.96, 0.28);
  static const Offset _cubeCenterF = Offset(0.50, 0.52);
  static const Offset _cubeLLF = Offset(0.04, 0.72);
  static const Offset _cubeLRF = Offset(0.96, 0.72);
  static const Offset _cubeBottomF = Offset(0.50, 0.96);

  // Pip centres, same fraction convention, kept inside the face they mark
  // so a roll's three-at-once idle cube never reads as fewer or more than
  // one/two/three pips per face.
  static const Offset _cubeTopPipF = Offset(0.50, 0.28);
  static const Offset _cubeLeftPip1F = Offset(0.178, 0.484);
  static const Offset _cubeLeftPip2F = Offset(0.362, 0.756);
  static const Offset _cubeRightPip1F = Offset(0.592, 0.56);
  static const Offset _cubeRightPip2F = Offset(0.730, 0.62);
  static const Offset _cubeRightPip3F = Offset(0.868, 0.68);

  // The two side faces, darkened from the same `dieFace` token rather than
  // a new colour literal (C-238 rule 7): an opaque blend toward `ink`, the
  // right face darker than the left so the cube reads as lit from the
  // upper-left, the way the flat face's own border already reads as an
  // edge rather than a flat tint.
  static final Color _cubeLeftShade = Color.alphaBlend(
    LudoColors.ink.withValues(alpha: 0.14),
    LudoColors.dieFace,
  );
  static final Color _cubeRightShade = Color.alphaBlend(
    LudoColors.ink.withValues(alpha: 0.30),
    LudoColors.dieFace,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final int? f = face;
    if (f == null) {
      _paintIdleCube(canvas, s);
      return;
    }

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

    final List<Offset>? units = _pipUnits[f];
    if (units == null) {
      return;
    }
    final double pipR = s * 0.09;
    final Offset centre = Offset(s / 2, s / 2);
    final double off = s * 0.22;
    final Paint pipPaint = Paint()..color = LudoColors.ink;
    for (final Offset unit in units) {
      canvas.drawCircle(
        centre + Offset(unit.dx * off, unit.dy * off),
        pipR,
        pipPaint,
      );
    }
  }

  /// C-238: the die waiting to be tapped, drawn as an object (an isometric
  /// cube showing its top, left and right faces at once) rather than as a
  /// result. Doctrine P4: three faces together can never be misread as a
  /// rolled value, which is exactly why a single flat face is wrong here.
  void _paintIdleCube(Canvas canvas, double s) {
    Offset at(Offset fraction) => Offset(fraction.dx * s, fraction.dy * s);

    final Offset top = at(_cubeTopF);
    final Offset ul = at(_cubeULF);
    final Offset ur = at(_cubeURF);
    final Offset center = at(_cubeCenterF);
    final Offset ll = at(_cubeLLF);
    final Offset lr = at(_cubeLRF);
    final Offset bottom = at(_cubeBottomF);

    final Path topFace = Path()
      ..moveTo(ul.dx, ul.dy)
      ..lineTo(top.dx, top.dy)
      ..lineTo(ur.dx, ur.dy)
      ..lineTo(center.dx, center.dy)
      ..close();
    final Path leftFace = Path()
      ..moveTo(ul.dx, ul.dy)
      ..lineTo(center.dx, center.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(ll.dx, ll.dy)
      ..close();
    final Path rightFace = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(ur.dx, ur.dy)
      ..lineTo(lr.dx, lr.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..close();

    canvas.drawPath(topFace, Paint()..color = LudoColors.dieFace);
    canvas.drawPath(leftFace, Paint()..color = _cubeLeftShade);
    canvas.drawPath(rightFace, Paint()..color = _cubeRightShade);

    final Path outline = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(ur.dx, ur.dy)
      ..lineTo(lr.dx, lr.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(ll.dx, ll.dy)
      ..lineTo(ul.dx, ul.dy)
      ..close();
    canvas.drawPath(
      outline,
      Paint()
        ..color = edgeColor
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(2.5, s * 0.05),
    );

    final Paint seamPaint = Paint()
      ..color = edgeColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2, s * 0.035);
    canvas.drawLine(center, ur, seamPaint);
    canvas.drawLine(center, ul, seamPaint);
    canvas.drawLine(center, bottom, seamPaint);

    final double pipR = s * 0.065;
    final Paint pipPaint = Paint()..color = LudoColors.ink;
    canvas.drawCircle(at(_cubeTopPipF), pipR, pipPaint);
    canvas.drawCircle(at(_cubeLeftPip1F), pipR, pipPaint);
    canvas.drawCircle(at(_cubeLeftPip2F), pipR, pipPaint);
    canvas.drawCircle(at(_cubeRightPip1F), pipR, pipPaint);
    canvas.drawCircle(at(_cubeRightPip2F), pipR, pipPaint);
    canvas.drawCircle(at(_cubeRightPip3F), pipR, pipPaint);
  }

  @override
  bool shouldRepaint(covariant _GameDiePainter oldDelegate) =>
      oldDelegate.edgeColor != edgeColor || oldDelegate.face != face;
}
