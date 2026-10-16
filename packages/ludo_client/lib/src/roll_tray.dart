// The roll tray: every face a seat is still owed, beside the big die on
// the same row (docs/PROTOCOL.md section 21, C-362-roll-queue-client.md
// Part B, order 365). Pure presentation, like game_die.dart: this widget
// never decides which face is alive, never calls the server, and never
// invents a face. `GameScreen` hands it the queue, which faces are
// selected or dead, and whose colour to draw in; a tap on an alive,
// unselected die calls [onSelect] and a tap on a dead one calls
// [onInvalidTap], and nothing else here ever sends anything.
//
// Drawn with its own small die face (not GameDie's: K2 forbids reusing
// GameDie's `game-die-face-N` key inside the tray, since tests find the
// big die by that key alone), in the same rounded-square, seat-edged
// style GameDie and die_mark.dart already share, just smaller.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'dead_mark.dart';
import 'theme.dart';

/// One tray die's state, K3: a face is never both selected and dead.
enum TrayDieState { plain, selected, dead }

/// Visual face size of a tray die. Smaller than GameDie's 72dp `_kDieSize`
/// so the tray reads as a cluster of small dice beside the big one, never
/// a second copy of it.
const double _kTrayDieArt = 38;

/// K11 / doctrine P9: every tray die's tap target, even though the art
/// above is drawn smaller.
const double _kTrayHitMin = 48;

/// K12: the enter/exit motion's duration. Instant (zero) under reduced
/// motion, per [MediaQuery.disableAnimations].
const Duration _kTrayMotion = Duration(milliseconds: 220);

/// Beside the current seat's die (K1), one small die per queued face, in
/// roll order. [faces] and [states] always carry the same length. Every
/// tray die is `interactive` identically: when false, every tap on this
/// tray does nothing and plays no cue at all (K5's own last line); the
/// caller is what tells an own-seat, awaitMove tray apart from anything
/// else's.
class RollTray extends StatefulWidget {
  const RollTray({
    super.key,
    required this.faces,
    required this.states,
    required this.seatColor,
    this.interactive = false,
    this.onSelect,
    this.onInvalidTap,
  }) : assert(faces.length == states.length);

  /// Roll order, K1/K2: `turn.queue` order, or the dead faces D (K9) while
  /// the no-move or three-sixes beat holds.
  final List<int> faces;

  /// Same length and order as [faces].
  final List<TrayDieState> states;

  /// The turn seat's colour (K1's own last line: every viewer sees every
  /// seat's tray, in the turn seat's colour).
  final Color seatColor;

  /// True only for the room's own seat, mid-`awaitMove` (K5). False for
  /// every other viewer's copy of this seat's tray, and for the
  /// `awaitRoll` display (K1b) and the dead-faces hold (K1c) alike.
  final bool interactive;

  /// K5: a tap on an alive, unselected die while [interactive]. Called
  /// with the tapped die's index into [faces].
  final ValueChanged<int>? onSelect;

  /// K5: a tap on a dead die while [interactive]. The die shakes itself;
  /// this is only the cue the caller still has to play.
  final VoidCallback? onInvalidTap;

  @override
  State<RollTray> createState() => _RollTrayState();
}

/// One die's identity across rebuilds, independent of its position: a
/// face spent out of the middle of the queue must not make the dice after
/// it animate as though they were freshly rolled (K12).
class _TraySlot {
  _TraySlot({
    required this.id,
    required this.face,
    required this.state,
    required this.visible,
  });

  final int id;
  int face;
  TrayDieState state;

  /// The two-phase enter/exit flag (K12): a fresh slot starts `false` and
  /// is flipped to `true` one frame later so [AnimatedOpacity] has a prior
  /// value to animate away from; a retiring slot starts `true` and is
  /// flipped to `false` the same way, then removed once the fade finishes.
  bool visible;
}

class _RollTrayState extends State<RollTray> with TickerProviderStateMixin {
  int _nextId = 0;
  List<_TraySlot> _slots = <_TraySlot>[];
  final List<_TraySlot> _exiting = <_TraySlot>[];
  final Map<int, AnimationController> _shakeControllers =
      <int, AnimationController>{};
  final List<Timer> _pendingTimers = <Timer>[];

  @override
  void initState() {
    super.initState();
    _slots = <_TraySlot>[
      for (int i = 0; i < widget.faces.length; i++)
        _TraySlot(
          id: _nextId++,
          face: widget.faces[i],
          state: widget.states[i],
          visible: true,
        ),
    ];
  }

  @override
  void didUpdateWidget(covariant RollTray old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    for (final Timer timer in _pendingTimers) {
      timer.cancel();
    }
    for (final AnimationController controller in _shakeControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  AnimationController _shakeFor(int id) {
    return _shakeControllers.putIfAbsent(
      id,
      () => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 260),
        value: 1,
      ),
    );
  }

  /// Matches the new `widget.faces`/`widget.states` against the slots
  /// still carrying the old ones, by value, in order -- a face removed
  /// from the middle (a token spent that was not the last-queued face)
  /// retires that one slot and leaves every other slot's identity alone,
  /// so none of them replay an enter animation they did not earn.
  void _sync() {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final List<_TraySlot> source = _slots;
    final List<_TraySlot> next = <_TraySlot>[];
    int oldPtr = 0;
    for (int i = 0; i < widget.faces.length; i++) {
      final int face = widget.faces[i];
      int foundAt = -1;
      for (int j = oldPtr; j < source.length; j++) {
        if (source[j].face == face) {
          foundAt = j;
          break;
        }
      }
      if (foundAt == -1) {
        next.add(
          _TraySlot(
            id: _nextId++,
            face: face,
            state: widget.states[i],
            visible: reduced,
          ),
        );
      } else {
        for (int k = oldPtr; k < foundAt; k++) {
          _retire(source[k], reduced);
        }
        final _TraySlot reused = source[foundAt];
        reused.state = widget.states[i];
        next.add(reused);
        oldPtr = foundAt + 1;
      }
    }
    for (int k = oldPtr; k < source.length; k++) {
      _retire(source[k], reduced);
    }
    _slots = next;

    if (reduced) {
      return;
    }
    final List<_TraySlot> entering = next
        .where((_TraySlot s) => !s.visible)
        .toList();
    if (entering.isEmpty) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        for (final _TraySlot s in entering) {
          s.visible = true;
        }
      });
    });
  }

  /// A slot whose face no longer appears in `widget.faces`: dropped at
  /// once under reduced motion, or faded out over [_kTrayMotion] and then
  /// dropped (K12: "it never vanishes between two frames").
  void _retire(_TraySlot slot, bool reduced) {
    _shakeControllers.remove(slot.id)?.dispose();
    if (reduced) {
      return;
    }
    _exiting.add(slot);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        slot.visible = false;
      });
    });
    final Timer timer = Timer(_kTrayMotion, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _exiting.remove(slot);
      });
    });
    _pendingTimers.add(timer);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < _slots.length; i++) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: kSpace2));
      }
      children.add(_liveTile(loc, _slots[i], i, reduced));
    }
    for (final _TraySlot ghost in _exiting) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: kSpace2));
      }
      children.add(_ghostTile(ghost, reduced));
    }
    return Semantics(
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  /// K2/K3/K11: one live, indexed tray die -- the only place the
  /// `game-roll-tray-die-<i>`, `game-roll-tray-face-<i>-<face>`,
  /// `game-roll-tray-selected-<i>` and `game-roll-tray-dead-<i>` keys are
  /// drawn, since the index they carry must always track the live queue.
  Widget _liveTile(
    AppLocalizations loc,
    _TraySlot slot,
    int index,
    bool reduced,
  ) {
    final bool alive = slot.state != TrayDieState.dead;
    final bool selected = slot.state == TrayDieState.selected;
    final bool exposesTapAction = widget.interactive && alive && !selected;
    final String label = selected
        ? loc.trayDieSelected(slot.face)
        : !alive
        ? loc.trayDieNoMove(slot.face)
        : widget.interactive
        ? loc.trayDieCanMove(slot.face)
        : loc.trayDie(slot.face);

    void handleTap() {
      if (!widget.interactive) {
        return;
      }
      if (!alive) {
        _shakeFor(slot.id).forward(from: 0);
        widget.onInvalidTap?.call();
        return;
      }
      if (selected) {
        return;
      }
      widget.onSelect?.call(index);
    }

    final Widget face = KeyedSubtree(
      key: Key('game-roll-tray-face-$index-${slot.face}'),
      child: CustomPaint(
        size: const Size.square(_kTrayDieArt),
        painter: _TrayDiePainter(
          face: slot.face,
          edgeColor: widget.seatColor,
          dimmed: !alive,
        ),
      ),
    );

    // The badge hangs off the corner (C-380 D1). Clip.none keeps that
    // overhang. The badge is positioned, so the tray row does not grow
    // or shift to make room for it.
    final Widget stacked = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: <Widget>[
        if (selected)
          KeyedSubtree(
            key: Key('game-roll-tray-selected-$index'),
            child: _SelectedGlow(color: widget.seatColor),
          ),
        face,
        if (!alive) _deadBadge(index),
      ],
    );

    final Widget shaking = AnimatedBuilder(
      animation: _shakeFor(slot.id),
      builder: (context, child) {
        final double t = _shakeFor(slot.id).value;
        final double dx = reduced ? 0 : math.sin(t * math.pi * 4) * 5 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: stacked,
    );

    return KeyedSubtree(
      key: ValueKey<int>(slot.id),
      child: AnimatedOpacity(
        opacity: slot.visible ? 1 : 0,
        duration: reduced ? Duration.zero : _kTrayMotion,
        // K11: each die keeps its own announcement through the whole
        // enter fade, never silently absent mid-transition.
        alwaysIncludeSemantics: true,
        child: Semantics(
          key: Key('game-roll-tray-die-$index'),
          // K2/K11: a boundary of its own -- without it, two adjacent
          // dice with their own tap action and label collapse into one
          // merged node, which hid die 1 and 2's own reading behind
          // die 0's whenever a queue held more than one die.
          container: true,
          button: true,
          label: label,
          enabled: exposesTapAction,
          onTap: handleTap,
          child: GestureDetector(
            excludeFromSemantics: true,
            behavior: HitTestBehavior.opaque,
            onTap: handleTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: _kTrayHitMin,
                minHeight: _kTrayHitMin,
              ),
              child: Center(child: shaking),
            ),
          ),
        ),
      ),
    );
  }

  /// C-380 D4: `game-roll-tray-dead-<i>` sits on the badge. Physical
  /// top-right, the same corner in Arabic as in English.
  Widget _deadBadge(int index) {
    final Rect badge = deadBadgeRect(const Size.square(_kTrayDieArt));
    return Positioned.fromRect(
      rect: badge,
      child: IgnorePointer(
        child: CustomPaint(
          key: Key('game-roll-tray-dead-$index'),
          painter: const DeadMarkPainter(),
        ),
      ),
    );
  }

  /// A retiring slot's last, fading frame: no K2/K3 key (it is no longer
  /// part of the live queue, so it must never claim an index another live
  /// die might now hold), not tappable, not announced.
  Widget _ghostTile(_TraySlot slot, bool reduced) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: KeyedSubtree(
          key: ValueKey<String>('game-roll-tray-ghost-${slot.id}'),
          child: AnimatedOpacity(
            opacity: slot.visible ? 1 : 0,
            duration: reduced ? Duration.zero : _kTrayMotion,
            child: SizedBox.square(
              dimension: _kTrayHitMin,
              child: Center(
                child: CustomPaint(
                  size: const Size.square(_kTrayDieArt),
                  painter: _TrayDiePainter(
                    face: slot.face,
                    edgeColor: widget.seatColor,
                    dimmed: slot.state == TrayDieState.dead,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// K3: "raised, seat-colour glow" behind the selected die's face.
class _SelectedGlow extends StatelessWidget {
  const _SelectedGlow({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kTrayDieArt + 12,
      height: _kTrayDieArt + 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: 0.55),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

/// A small die face, in GameDie's own rounded-square-with-seat-edge style,
/// at tray scale. [dimmed] (P9: a dead face is never colour alone; the
/// badge from [DeadMarkPainter] is the signal) keeps every pip and draws
/// them at 0.45 (C-380 D2). Pip places come from [pipCentresFor] (D3).
class _TrayDiePainter extends CustomPainter {
  const _TrayDiePainter({
    required this.face,
    required this.edgeColor,
    required this.dimmed,
  });

  final int face;
  final Color edgeColor;
  final bool dimmed;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final RRect faceRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.04, s * 0.04, s * 0.92, s * 0.92),
      Radius.circular(s * 0.18),
    );
    // A dead die still has to read its face at a glance (K3, doctrine
    // P3/P9): the body stays close to the plain die colour (only a light
    // wash, not a grey fill that swallows the pips) and the pips stay
    // the real ink at 0.45, so they stay darker than the body. The badge
    // is the "no" signal. No stroke crosses the face.
    final Color faceColor = dimmed
        ? Color.alphaBlend(
            LudoColors.ink.withValues(alpha: 0.08),
            LudoColors.dieFace,
          )
        : LudoColors.dieFace;
    final Color pipColor = dimmed
        ? LudoColors.ink.withValues(alpha: 0.45)
        : LudoColors.ink;
    final Color edge = dimmed ? LudoColors.inkMuted : edgeColor;

    canvas.drawRRect(faceRect, Paint()..color = faceColor);
    canvas.drawRRect(
      faceRect,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, s * 0.07),
    );

    if (face < 1 || face > 6) {
      return;
    }
    final double pipR = pipRadiusFor(size);
    final Paint pipPaint = Paint()..color = pipColor;
    for (final Offset centre in pipCentresFor(face, size)) {
      canvas.drawCircle(centre, pipR, pipPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrayDiePainter oldDelegate) =>
      oldDelegate.face != face ||
      oldDelegate.edgeColor != edgeColor ||
      oldDelegate.dimmed != dimmed;
}
