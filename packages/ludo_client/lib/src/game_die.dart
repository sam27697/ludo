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
    this.onTap,
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

  /// Fires on a tap while [enabled]. The widget itself still guards this:
  /// a tap while disabled never calls it, even if a caller passes one.
  final VoidCallback? onTap;

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

  void _handleTap() {
    if (!widget.enabled) {
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

    // The key sits on the Semantics widget itself, not on the SizedBox
    // beneath it: getSemantics(find.byKey('game-die')) must return this
    // node's own button, label and enabled flag, and a key further down
    // the tree does not reliably walk back up to it.
    final Widget tappable = Semantics(
      key: const Key('game-die'),
      button: true,
      label: loc.gameRollButton,
      enabled: widget.enabled,
      onTap: widget.enabled ? _handleTap : null,
      child: GestureDetector(
        // The Semantics wrapper above already states button, label, enabled
        // and the tap action on its own node; a GestureDetector's default
        // semantics would otherwise merge its own copy of that action into
        // the same node for no reason this widget needs.
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? _handleTap : null,
        child: SizedBox(width: _kDieSize, height: _kDieSize, child: die),
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
      // pip cycling and shows the blank face until the result lands.
      final int? shown = reduced ? null : _tumbleFace();
      final Widget paint = CustomPaint(
        size: const Size.square(_kDieSize),
        painter: _GameDiePainter(edgeColor: widget.seatColor, face: shown),
      );
      return reduced
          ? KeyedSubtree(key: const Key('game-die-blank'), child: paint)
          : paint;
    }
    final int? shown = widget.face;
    final Key key = shown == null
        ? const Key('game-die-blank')
        : Key('game-die-face-$shown');
    return KeyedSubtree(
      key: key,
      child: CustomPaint(
        size: const Size.square(_kDieSize),
        painter: _GameDiePainter(edgeColor: widget.seatColor, face: shown),
      ),
    );
  }
}

class _GameDiePainter extends CustomPainter {
  const _GameDiePainter({required this.edgeColor, required this.face});

  final Color edgeColor;
  final int? face;

  @override
  void paint(Canvas canvas, Size size) {
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

    final int? f = face;
    if (f == null) {
      return;
    }
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

  @override
  bool shouldRepaint(covariant _GameDiePainter oldDelegate) =>
      oldDelegate.edgeColor != edgeColor || oldDelegate.face != face;
}
