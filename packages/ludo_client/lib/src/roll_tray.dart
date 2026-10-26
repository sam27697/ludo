// The roll tray beside the big die (docs/PROTOCOL.md section 21, C-362
// Part B). C-462 D6: a read-only record of the roll, not a second die.
// The C-420 layout stands: one 48dp slot per tile, natural and grouped
// widths, the count mark, and the same enter/exit motion. GameScreen
// hands it the queue and which faces are dead. Nothing here is tappable
// and nothing here sends a move.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'dead_mark.dart';
import 'theme.dart';

/// One tray tile's state (C-462 D6). A face is plain or dead.
enum TrayDieState { plain, dead }

/// Box the numeral is drawn in. The old die art used this same side, so
/// the dead badge still hangs off that corner and the slot around it
/// stays 48dp (C-420, C-462 D6).
const double _kTrayDieArt = 38;

/// C-420: every tray tile's slot, even though the numeral is drawn smaller.
const double _kTrayHitMin = 48;

/// K12: the enter/exit motion's duration. Instant (zero) under reduced
/// motion, per [MediaQuery.disableAnimations].
const Duration _kTrayMotion = Duration(milliseconds: 220);

/// C-420 D1: a queue of [n] tiles at natural width, the same formula the
/// contract states (n * 48 + (n - 1) * 8). Used only to decide whether the
/// row still fits one tile per face; natural mode, once chosen, renders
/// through the untouched pre-C-420 code path so every case the old probe
/// already measured green stays pixel-for-pixel as it was.
double _naturalRowWidth(int n) =>
    n <= 0 ? 0 : n * _kTrayHitMin + (n - 1) * kSpace2;

/// C-420 D2' (RESPEC run 101: D2's pill covered a pip, replaced). A grouped
/// tile's count is text beside the numeral, on its end side, never drawn
/// over the art. `_kCountGap` is the clearance from the 48dp slot's own
/// edge to the text (the contract's "at least 2dp clear of it" is measured
/// from the art, and the slot already leaves its own margin around the
/// art, so a gap measured from the slot only ever adds to that clearance).
/// `_kCountTextMaxWidth` is the cap the text is never allowed to grow past
/// (`_countText`'s `FittedBox` only ever shrinks into it, at text scale
/// 1.0 the digits sit at their natural size with room to spare). Together
/// with the 48dp slot and the 8dp gap the tray already places between
/// sibling tiles, a two-tile grouped row is at most
/// 48 + _kCountGap + _kCountTextMaxWidth + 8 + 48 = 138dp, which the
/// contract measured fits beside the board die at 320dp.
const double _kCountGap = 2;
const double _kCountTextMaxWidth = 32;
const double _kCountFontSize = 15;

/// Beside the current seat's die (K1), one numeral per queued face, in
/// roll order. [faces] and [states] always carry the same length.
/// [ownMove] only picks the alive tile's label (C-462 D6).
class RollTray extends StatefulWidget {
  const RollTray({
    super.key,
    required this.faces,
    required this.states,
    required this.seatColor,
    this.ownMove = false,
  }) : assert(faces.length == states.length);

  /// Roll order, K1/K2: `turn.queue` order, or the dead faces D (K9) while
  /// the no-move or three-sixes beat holds.
  final List<int> faces;

  /// Same length and order as [faces].
  final List<TrayDieState> states;

  /// The turn seat's colour (K1's own last line: every viewer sees every
  /// seat's tray, in the turn seat's colour).
  final Color seatColor;

  /// True exactly when this is the room's own seat, mid-awaitMove, under
  /// the roll queue. An alive tile then reads `trayDieCanMove`; otherwise
  /// it reads `trayDie`. Never makes a tile tappable (C-462 D6).
  final bool ownMove;

  @override
  State<RollTray> createState() => _RollTrayState();
}

/// One tile's identity across rebuilds, independent of its position: a
/// face spent out of the middle of the queue must not make the tiles after
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

/// C-420 D2: one grouped tile -- every live slot sharing [slot.face],
/// collapsed in order of first appearance. [index] is the queue index of
/// the first (earliest) member, which is also the only member that carries
/// the K2/K3 keys. [count] is how many queued faces this one tile stands
/// for; 1 draws exactly as a natural-mode tile.
class _TrayGroup {
  _TrayGroup({required this.index, required this.slot, required this.count});

  final int index;
  final _TraySlot slot;
  int count;
}

class _RollTrayState extends State<RollTray> {
  int _nextId = 0;
  List<_TraySlot> _slots = <_TraySlot>[];
  final List<_TraySlot> _exiting = <_TraySlot>[];
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
    super.dispose();
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
    // C-420 D1/D4: the tray reads its own width from its parent (the
    // `Flexible` beside the board die in game_screen.dart) rather than
    // assuming one; the fit check counts live tiles and the still-fading
    // exiting ones alike, since both take width on this frame.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int totalTiles = _slots.length + _exiting.length;
        final bool natural =
            totalTiles <= 1 ||
            _naturalRowWidth(totalTiles) <= constraints.maxWidth;
        final List<Widget> children = <Widget>[];
        if (natural) {
          // D1: unchanged from before C-420, pixel-for-pixel.
          for (int i = 0; i < _slots.length; i++) {
            if (children.isNotEmpty) {
              children.add(const SizedBox(width: kSpace2));
            }
            children.add(_liveTile(loc, _slots[i], i, reduced));
          }
        } else {
          // D2: equal faces collapse into one tile, in order of first
          // appearance.
          for (final _TrayGroup group in _groupSlots()) {
            if (children.isNotEmpty) {
              children.add(const SizedBox(width: kSpace2));
            }
            children.add(
              _liveTile(
                loc,
                group.slot,
                group.index,
                reduced,
                count: group.count,
              ),
            );
          }
        }
        for (final _TraySlot ghost in _exiting) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(width: kSpace2));
          }
          children.add(_ghostTile(ghost, reduced));
        }
        // C-462 D6: one pill behind the whole row. No padding, so the
        // C-420 widths are the widget's widths.
        return Semantics(
          container: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.seatColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: children,
            ),
          ),
        );
      },
    );
  }

  /// C-420 D2: every live slot, grouped by face in order of first
  /// appearance in the queue. A face seen before only grows the existing
  /// group's [_TrayGroup.count]; it never starts a second tile.
  List<_TrayGroup> _groupSlots() {
    final List<_TrayGroup> groups = <_TrayGroup>[];
    final Map<int, _TrayGroup> byFace = <int, _TrayGroup>{};
    for (int i = 0; i < _slots.length; i++) {
      final _TraySlot slot = _slots[i];
      final _TrayGroup? existing = byFace[slot.face];
      if (existing == null) {
        final _TrayGroup group = _TrayGroup(index: i, slot: slot, count: 1);
        byFace[slot.face] = group;
        groups.add(group);
      } else {
        existing.count += 1;
      }
    }
    return groups;
  }

  /// K2/K3: one live, indexed tray tile -- the only place the
  /// `game-roll-tray-die-<i>`, `game-roll-tray-face-<i>-<face>` and
  /// `game-roll-tray-dead-<i>` keys are drawn, since the index they carry
  /// must always track the live queue. [count] (C-420 D2) is how many
  /// queued faces this one tile stands for under the grouped layout; 1
  /// (the default, every natural-mode call) draws and reads exactly as a
  /// single face.
  Widget _liveTile(
    AppLocalizations loc,
    _TraySlot slot,
    int index,
    bool reduced, {
    int count = 1,
  }) {
    final bool alive = slot.state != TrayDieState.dead;
    String label = !alive
        ? loc.trayDieNoMove(slot.face)
        : widget.ownMove
        ? loc.trayDieCanMove(slot.face)
        : loc.trayDie(slot.face);
    if (count > 1) {
      // D3: the locale's own list comma joins the state label and the
      // count, the same separator end_card.dart already uses to join a
      // list of names for the same two locales.
      final String comma = Localizations.localeOf(context).languageCode == 'ar'
          ? '، '
          : ', ';
      label = '$label$comma${loc.trayDieCount(count)}';
    }

    final Color numeralColor = alive
        ? widget.seatColor
        : widget.seatColor.withValues(alpha: 0.45);
    final Widget stacked = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: <Widget>[
        _TrayNumeral(
          face: slot.face,
          color: numeralColor,
          artKey: Key('game-roll-tray-face-$index-${slot.face}'),
        ),
        if (!alive) _deadBadge(index),
      ],
    );

    // The slot itself: 48dp, the numeral centred in it. C-420 D2' left
    // this box alone; the count text sits beside it, not inside it.
    final Widget dieBox = ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: _kTrayHitMin,
        minHeight: _kTrayHitMin,
      ),
      child: Center(child: stacked),
    );

    // C-420 D2': a grouped tile (count > 1) is the slot followed, on its
    // end side, by the `×<count>` text -- a plain `Row`'s children mirror
    // for free under an ambient RTL `Directionality`, the same as every
    // other end-anchored layout in this screen, so this file never tests
    // the direction itself. A count-1 tile is exactly `dieBox`, pixel for
    // pixel the natural tile.
    final Widget tileContent = count > 1
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              dieBox,
              const SizedBox(width: _kCountGap),
              _countText(loc, index, count),
            ],
          )
        : dieBox;

    return KeyedSubtree(
      key: ValueKey<int>(slot.id),
      child: AnimatedOpacity(
        opacity: slot.visible ? 1 : 0,
        duration: reduced ? Duration.zero : _kTrayMotion,
        // K11: each tile keeps its own announcement through the whole
        // enter fade, never silently absent mid-transition.
        alwaysIncludeSemantics: true,
        child: Semantics(
          key: Key('game-roll-tray-die-$index'),
          // K2/K11: a boundary of its own, so adjacent tiles keep their
          // own labels. C-462 D6: not a button, no onTap. D2': on a
          // grouped tile this node covers the numeral and its count
          // text together.
          container: true,
          label: label,
          child: tileContent,
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

  /// C-420 D2' (RESPEC run 101: D2's pill covered a pip, replaced):
  /// `game-roll-tray-count-<i>` reads `×<count>` beside the numeral, on
  /// its end side -- never drawn over the art, and never its own semantics
  /// node (the enclosing tile's `Semantics` already covers it;
  /// `ExcludeSemantics` here keeps the glyph itself out of the tree, since
  /// the tile's own `Semantics.label` already carries the count in words,
  /// `trayDieCount` -- without this, TalkBack read the count twice, the
  /// second time as "times count"). `ConstrainedBox` caps the width at
  /// `_kCountTextMaxWidth`; `FittedBox` only ever shrinks a child that
  /// wants to be wider than the box it is offered (`BoxFit.scaleDown`), so
  /// the digits sit at their natural size at text scale 1.0 and shrink
  /// only once they would cross the cap at a larger scale, never growing
  /// past it. Digits are always Western (U+00D7 then ASCII), the same ones
  /// the countdown ring draws in both locales, so `TextDirection.ltr` here
  /// is not a locale choice.
  Widget _countText(AppLocalizations loc, int index, int count) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kCountTextMaxWidth),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ExcludeSemantics(
          child: Text(
            loc.trayDieCountMark(count),
            key: Key('game-roll-tray-count-$index'),
            textDirection: TextDirection.ltr,
            style: TextStyle(
              color: widget.seatColor,
              fontWeight: FontWeight.bold,
              fontSize: _kCountFontSize,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// A retiring slot's last, fading frame: no K2/K3 key (it is no longer
  /// part of the live queue, so it must never claim an index another live
  /// tile might now hold), not announced.
  Widget _ghostTile(_TraySlot slot, bool reduced) {
    final Color numeralColor = slot.state == TrayDieState.dead
        ? widget.seatColor.withValues(alpha: 0.45)
        : widget.seatColor;
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
                child: _TrayNumeral(face: slot.face, color: numeralColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// C-462 D6: the face as a Western numeral, bold, in [color]. No die
/// body. Dead tiles pass [color] already at about 45% opacity. The glyph
/// is out of the semantics tree; the tile's own label names the face.
/// C-462 D6.3: [artKey] sits on this 38dp box. The numeral is centred in
/// it, and the dead badge is deadBadgeRect of the same box.
class _TrayNumeral extends StatelessWidget {
  const _TrayNumeral({required this.face, required this.color, this.artKey});

  final int face;
  final Color color;
  final Key? artKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      key: artKey,
      dimension: _kTrayDieArt,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ExcludeSemantics(
          child: Text(
            face.toString(),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 28,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
