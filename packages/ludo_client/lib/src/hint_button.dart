// The one-hint bulb under the board (C-471 D3). A drawn disc in the
// seat colour, not a labelled button. The screen decides the state and
// plays the cue; this widget only draws, shakes, and reports the tap.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// C-471 D3. [ready] can be spent. [waiting] still has its one use.
/// [used] is spent for this game.
enum HintControlState { ready, waiting, used }

/// Visual disc is 40 dp. The hit box is 48 dp (C-471 D3).
const double _kHintVisual = 40;
const double _kHintHit = 48;

/// One gentle glow, not a loop. The die's own pulse is what says the
/// turn is yours (C-471 D3).
const Duration _kHintGlow = Duration(milliseconds: 800);

class HintButton extends StatefulWidget {
  const HintButton({
    super.key,
    required this.state,
    required this.seatColor,
    required this.onTap,
  });

  final HintControlState state;
  final Color seatColor;

  /// Called for every tap. True when the tap spent the hint. False is
  /// the invalid tap, and the bulb shakes (C-471 D3).
  final bool Function() onTap;

  @override
  State<HintButton> createState() => _HintButtonState();
}

class _HintButtonState extends State<HintButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow;
  bool _glowArmed = false;
  int _shakeSerial = 0;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(vsync: this, duration: _kHintGlow);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncGlow();
  }

  @override
  void didUpdateWidget(HintButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGlow();
  }

  /// Pulse once each time the control enters [HintControlState.ready].
  /// Reduced motion keeps the full-colour disc and skips the glow
  /// (C-471 D3).
  void _syncGlow() {
    final bool ready = widget.state == HintControlState.ready;
    final bool enter = ready && !_glowArmed;
    _glowArmed = ready;
    if (!ready) {
      _glow.stop();
      _glow.value = 0;
      return;
    }
    if (!enter || MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    _glow.forward(from: 0);
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  void _handleTap() {
    final bool spent = widget.onTap();
    if (spent || !mounted) {
      return;
    }
    setState(() {
      _shakeSerial += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final HintControlState state = widget.state;
    final String label;
    final String stateKey;
    switch (state) {
      case HintControlState.ready:
        label = loc.hintReady;
        stateKey = 'game-hint-ready';
      case HintControlState.waiting:
        label = loc.hintWaiting;
        stateKey = 'game-hint-waiting';
      case HintControlState.used:
        label = loc.hintUsed;
        stateKey = 'game-hint-used';
    }
    final bool ready = state == HintControlState.ready;
    Widget art = _HintArt(
      state: state,
      seatColor: widget.seatColor,
      glow: _glow,
    );
    if (_shakeSerial > 0) {
      art = _HintShake(key: ValueKey<int>(_shakeSerial), child: art);
    }
    return Semantics(
      key: const Key('game-hint-button'),
      container: true,
      button: true,
      enabled: ready,
      label: label,
      onTap: ready ? _handleTap : null,
      child: GestureDetector(
        key: Key(stateKey),
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SizedBox(
          width: _kHintHit,
          height: _kHintHit,
          child: ExcludeSemantics(
            child: Opacity(opacity: ready ? 1 : 0.45, child: art),
          ),
        ),
      ),
    );
  }
}

class _HintArt extends StatelessWidget {
  const _HintArt({
    required this.state,
    required this.seatColor,
    required this.glow,
  });

  final HintControlState state;
  final Color seatColor;
  final Animation<double> glow;

  @override
  Widget build(BuildContext context) {
    final bool used = state == HintControlState.used;
    final bool lightDisc = seatColor.computeLuminance() > 0.6;
    // A filled disc needs a glyph that reads on the seat colour. The
    // spent bulb is an outline on the page, so it takes the seat colour
    // itself (C-471 D3).
    final Color glyph = used
        ? seatColor
        : (lightDisc ? LudoColors.ink : LudoColors.paper);
    // Depth on the disc uses the paintbox near-white and ink (C-471 D3).
    final Color highlight = Color.lerp(seatColor, LudoColors.actionOn, 0.30)!;
    final Color shade = Color.lerp(seatColor, LudoColors.ink, 0.22)!;
    return AnimatedBuilder(
      animation: glow,
      builder: (BuildContext context, Widget? child) {
        final double bump = math.sin(glow.value * math.pi);
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: bump == 0
                ? const <BoxShadow>[]
                : <BoxShadow>[
                    BoxShadow(
                      color: seatColor.withValues(alpha: 0.50 * bump),
                      blurRadius: 12 * bump,
                      spreadRadius: 1.5 * bump,
                    ),
                  ],
          ),
          child: child,
        );
      },
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: used ? Colors.transparent : null,
              gradient: used
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[highlight, seatColor, shade],
                    ),
              border: used ? Border.all(color: seatColor, width: 2) : null,
              boxShadow: used
                  ? const <BoxShadow>[]
                  : <BoxShadow>[
                      BoxShadow(
                        color: LudoColors.ink.withValues(alpha: 0.32),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: SizedBox(
              width: _kHintVisual,
              height: _kHintVisual,
              child: Icon(
                used ? Icons.lightbulb_outline : Icons.lightbulb,
                size: 22,
                color: glyph,
              ),
            ),
          ),
          if (!used)
            const PositionedDirectional(top: 1, end: 1, child: _HintBadge()),
        ],
      ),
    );
  }
}

/// The unused-hint numeral. Not a word label (C-471 D3).
class _HintBadge extends StatelessWidget {
  const _HintBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: LudoColors.paperElevated,
        border: Border.all(color: LudoColors.ink, width: 1),
      ),
      child: const SizedBox(
        width: 16,
        height: 16,
        child: Center(
          child: Text(
            '1',
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: LudoColors.ink,
              fontSize: kTypeLabel,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// The 300 ms horizontal shake an illegal token tap uses (C-471 D3).
/// Reduced motion holds still; the invalid cue still plays.
class _HintShake extends StatelessWidget {
  const _HintShake({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.linear,
      builder: (BuildContext context, double t, Widget? staticChild) {
        final double dx =
            math.sin(t * math.pi * 4) * _kHintVisual * 0.18 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: staticChild);
      },
      child: child,
    );
  }
}
