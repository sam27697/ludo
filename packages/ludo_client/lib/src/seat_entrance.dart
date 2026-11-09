// C-599 D5(a): the entrance of a seat card that took its seat after the
// lobby first drew. It fades and scales in from 0.9 over 320 ms, and a glow
// in the seat's colour fades out over 1200 ms from the same moment. A card
// that was already there when the screen first built is wrapped the same
// way but sits at its end state, so it never animates and a later rebuild
// of the grid never changes the tree under it.
//
// Under the system's remove-animations setting there is no scale and no
// fade: the card is at its end state at once and the glow is held at full
// strength for the same 1200 ms and then removed. Shorter motion, the same
// meaning (doctrine P9).

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// How long the card takes to fade and scale into place.
const Duration kSeatEntranceDuration = Duration(milliseconds: 320);

/// How long the seat-coloured glow lasts from the card's entrance.
const Duration kSeatGlowDuration = Duration(milliseconds: 1200);

/// The scale a card starts from.
const double kSeatEntranceStartScale = 0.9;

/// The glow's strongest alpha, at the moment of entrance.
const double _glowPeakAlpha = 0.6;

class SeatEntrance extends StatefulWidget {
  const SeatEntrance({
    super.key,
    required this.seat,
    required this.entering,
    required this.child,
  });

  /// 0..3, the seat whose colour the glow carries.
  final int seat;

  /// True when this card is added after the screen first built. Read once,
  /// when the state is created; a rebuild that flips it changes nothing.
  final bool entering;

  final Widget child;

  @override
  State<SeatEntrance> createState() => _SeatEntranceState();
}

class _SeatEntranceState extends State<SeatEntrance>
    with TickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: kSeatEntranceDuration,
    value: 1,
  );
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: kSeatGlowDuration,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _enter,
    curve: Curves.easeOut,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: kSeatEntranceStartScale,
    end: 1,
  ).animate(_curve);

  Timer? _heldGlow;
  bool _heldGlowOn = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (!widget.entering) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _heldGlowOn = true;
      _heldGlow = Timer(kSeatGlowDuration, () {
        if (mounted) {
          setState(() => _heldGlowOn = false);
        }
      });
    } else {
      _enter.forward(from: 0);
      _glow.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _heldGlow?.cancel();
    _enter.dispose();
    _glow.dispose();
    super.dispose();
  }

  /// The glow's alpha now: 0 when there is none to draw.
  double _glowAlpha() {
    if (_heldGlowOn) {
      return _glowPeakAlpha;
    }
    if (_glow.isAnimating) {
      return _glowPeakAlpha * (1 - _glow.value);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final Color seatColor = LudoColors.seats[widget.seat];
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(
        key: Key('lobby-seat-${widget.seat}-entrance'),
        scale: _scale,
        child: AnimatedBuilder(
          animation: _glow,
          builder: (BuildContext context, Widget? card) {
            final double alpha = _glowAlpha();
            // passthrough: the card keeps the tight constraints its grid
            // cell hands down, so a row of two stays one height.
            return Stack(
              fit: StackFit.passthrough,
              clipBehavior: Clip.none,
              children: [
                if (alpha > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: Key('lobby-seat-${widget.seat}-glow'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(kRadiusControl),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: seatColor.withValues(alpha: alpha),
                              blurRadius: 18,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                card!,
              ],
            );
          },
          child: KeyedSubtree(
            key: const ValueKey<String>('card'),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
