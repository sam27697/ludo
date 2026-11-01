// The die a player rolls by tapping it. Pure presentation and one gesture:
// this widget never calls the server itself, never decides whether a roll
// is legal, and never invents a face -- `face` is always the caller's
// `turn.value`, or null when none is known yet. Everything else (the pulse
// that invites a tap, the tumble while a roll is in flight, the shake and
// the "no answer" line after a silent 4 seconds) is state the caller
// computes from RoomController and hands in as plain booleans.
//
// Drawn in the style of die_mark.dart's _DieMarkPainter: a rounded square
// face with pips, not the four-seat brand mark. The border is the seat
// colour the caller passes. With a seat of one's own that is always that
// seat's colour (C-465 D1). With none it is the turn seat's colour, so a
// spectator still sees whose roll it is. While my own roll is in flight
// the same pips are on a cube (die_cube.dart) instead of this flat face.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'dead_mark.dart';
import 'die_cube.dart';
import 'refusal_mark.dart';
import 'theme.dart';

/// The die's fixed footprint, face and hit target both. C-223: "at least
/// 72dp"; this is also lib/src/die_mark.dart's compact size, so the two
/// dice in this app read as the same object at two scales.
const double _kDieSize = 72;

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
    this.badgeHeadroom = double.infinity,
    this.idleOpacity = 1,
  });

  /// The last known roll, straight from `turn.value`. Null when none is
  /// known yet. Ignored while [tumbling] is true, which draws its own
  /// cosmetic, never-settling face instead.
  final int? face;

  /// Border colour. With a seat of one's own the caller passes that
  /// seat's colour in every phase (C-465 D1). With no seat it is
  /// `LudoColors.seats[turn.seat]`, whoever's turn it currently is.
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
  /// `rolled` for my seat with an empty `legal`. Draws the dead badge
  /// (`game-die-no-move-mark`, a white X on a red disc, not colour alone,
  /// doctrine P9) on the die's top-right corner, over whatever the die is
  /// otherwise showing, independent of [face], [enabled] or [tumbling].
  /// The mark is not delayed or hidden by the next seat's turn landing
  /// underneath it. The face under it stays whole, pips at 0.45 (C-380).
  final bool noMove;

  /// C-404: the space between the board's painted bottom edge and this
  /// die's own top, the way the caller's column has it laid out this
  /// build (`_PlayColumnMetrics.boardGap`). The no-move badge hangs
  /// [deadBadgeRect] above the die by 0.21 of its side; where this is at
  /// least that much the badge sits exactly where [deadBadgeRect] puts
  /// it (today's rect, unmoved). Where it is shorter, [_noMoveBadge]
  /// brings the badge down by exactly the shortfall, never more, so it
  /// never paints over the board. The default leaves it alone: a die
  /// mounted outside the play column gets today's placement.
  final double badgeHeadroom;

  /// C-468 D7: how strongly the die (face, cube and badge) paints. The idle
  /// die of a seat that is not rolling passes 0.45. It lives here, below the
  /// `game-die` key, so C-520 A2's refusal mark can sit outside it at full
  /// strength.
  final double idleOpacity;

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

  // C-520 D3: a refused tap under reduced motion wears a mark for 300 ms.
  Timer? _markTimer;
  bool _marked = false;

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
      if (_reducedMotion) {
        _showRefusalMark();
      }
      return;
    }
    widget.onTap?.call();
  }

  /// C-520 D3. The 300 ms mark; a second refused tap inside it restarts the
  /// 300 ms.
  void _showRefusalMark() {
    _markTimer?.cancel();
    setState(() {
      _marked = true;
    });
    _markTimer = Timer(kRefusalMarkLife, () {
      _markTimer = null;
      if (!mounted) {
        return;
      }
      setState(() {
        _marked = false;
      });
    });
  }

  /// C-238: wraps a painted face with `game-die-idle-art` exactly when that
  /// paint shows the cube rather than a resting or cycling value -- which,
  /// per [_GameDiePainter], is exactly when [shown] is null. Doctrine P4: a
  /// cube with three faces at once can never be read as an invented result,
  /// so it is always safe to show while no value is known.
  Widget _dieArt({required Color edgeColor, required int? shown}) {
    final Widget paint = CustomPaint(
      size: const Size.square(_kDieSize),
      painter: _GameDiePainter(
        edgeColor: edgeColor,
        face: shown,
        // C-380 D2: a no-move face keeps every pip, dimmed. The idle cube
        // (shown == null) has no numbered face to dim.
        pipOpacity: widget.noMove && shown != null ? 0.45 : 1,
      ),
    );
    return shown == null
        ? KeyedSubtree(key: const Key('game-die-idle-art'), child: paint)
        : paint;
  }

  @override
  void dispose() {
    _markTimer?.cancel();
    _pulse.dispose();
    _tumble.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool reduced = _reducedMotion;

    // C-377 D7: while a roll of mine is in flight the tumble is the cube,
    // not a flat face spinning in place. Reduced motion keeps the idle
    // cube with no tumble, the same as before (D8).
    final Widget dieBody = widget.tumbling && !reduced
        ? AnimatedBuilder(
            animation: _tumble,
            builder: (BuildContext context, Widget? child) {
              return DieCube(
                size: _kDieSize,
                rotation: ownTumbleRotation(_tumble.value),
                edgeColor: widget.seatColor,
              );
            },
          )
        : _face();

    Widget die = dieBody;

    if (widget.tumbling) {
      die = KeyedSubtree(key: const Key('game-die-tumbling'), child: die);
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

    // C-236 rule 4: the no-move badge sits in its own stack layer, above
    // whatever `die` is doing (resting face, tumble, shake), so it is never
    // delayed or hidden by the die's own animation state. It hangs off the
    // top-right corner (C-380 D1). Clip.none keeps the overhang; the badge
    // is positioned, so the die's 72dp box does not grow.
    // The stacks are always built and `die` is always their first child, so
    // the die's element keeps its slot when the badge or the mark comes and
    // goes. Passthrough hands `die` the same tight box it had before.
    final Widget dieArt = Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[die, if (widget.noMove) _noMoveBadge()],
    );
    // C-468 D7: the Opacity is an ancestor of the die's art. C-520 A2: the
    // refusal mark is a sibling of it, never under it.
    final Widget dieFace = Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        Opacity(opacity: widget.idleOpacity, child: dieArt),
        if (_marked)
          const Positioned.fill(
            child: RefusalMark(
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.all(Radius.circular(_kDieSize * 0.16)),
            ),
          ),
      ],
    );

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

  /// C-380 D4: `game-die-no-move-mark` sits on the badge, not on the face.
  /// Physical top-right, not [PositionedDirectional], so Arabic does not
  /// mirror it.
  ///
  /// C-404 decision 2: the badge overhangs the die's top edge by
  /// `-badge.top`. Where [badgeHeadroom] already covers that, the badge
  /// stays exactly where [deadBadgeRect] put it (decision 3: nothing
  /// moves at rest). Where it falls short, the badge comes straight down
  /// by that shortfall and no more -- its size and its centre's x on the
  /// die's right edge are untouched, only the y moves.
  Widget _noMoveBadge() {
    final Rect badge = deadBadgeRect(const Size.square(_kDieSize));
    final double overhang = -badge.top;
    final double shortfall = math.max(0, overhang - widget.badgeHeadroom);
    final Rect rect = shortfall == 0 ? badge : badge.translate(0, shortfall);
    return Positioned.fromRect(
      rect: rect,
      child: const IgnorePointer(
        child: CustomPaint(
          key: Key('game-die-no-move-mark'),
          painter: DeadMarkPainter(),
        ),
      ),
    );
  }

  /// C-223 clarification 1: `game-die-face-N` names only a face the die
  /// rests on. Motion tumble is [DieCube] and never reaches here. Reduced
  /// motion tumble shows `game-die-blank` and the idle cube (C-238 rule 4,
  /// C-377 D8): no pip cycling, no invented face.
  Widget _face() {
    if (widget.tumbling) {
      final Widget art = _dieArt(edgeColor: widget.seatColor, shown: null);
      return KeyedSubtree(key: const Key('game-die-blank'), child: art);
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

class _GameDiePainter extends CustomPainter {
  const _GameDiePainter({
    required this.edgeColor,
    required this.face,
    required this.pipOpacity,
  });

  final Color edgeColor;
  final int? face;

  /// 1 for a live face, 0.45 while [GameDie.noMove] holds a numbered face.
  final double pipOpacity;

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
    paintNumberedDieFace(
      canvas,
      size,
      edgeColor: edgeColor,
      face: f,
      pipOpacity: pipOpacity,
    );
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
      oldDelegate.edgeColor != edgeColor ||
      oldDelegate.face != face ||
      oldDelegate.pipOpacity != pipOpacity;
}
