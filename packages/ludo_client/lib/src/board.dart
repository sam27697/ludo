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

import '../l10n/gen/app_localizations.dart';
import 'board_geometry.dart';
import 'theme.dart';

export 'board_geometry.dart';

/// The four entry squares among [safeTrackSquares], absolute indices, each
/// one seat's own starting square (RULES.md 1.2, contract C-241 rule 2):
/// seat 0 enters at 0, seat 1 at 13, seat 2 at 26, seat 3 at 39. These are
/// the four stars painted in paper rather than ink.
const Set<int> _entrySquares = <int>{0, 13, 26, 39};

/// The 48dp minimum touch target a token's hit box uses, whichever of that
/// or the token's own drawn size is larger. One place for the 48, so the
/// tap handler, the Semantics hit box and the C-248 chip-placement check
/// below can never disagree about where a token is actually tappable.
double _tokenHitSize(double tokenSize) => math.max(48.0, tokenSize);

/// The pixel rect [tokenIndex] of [seat] at [progress] actually gets as its
/// tap target: the same cell, fan offset (see the comment on the fan in
/// `_tokenLayer`) and [_tokenHitSize] math that widget uses to place that
/// Positioned, factored out so nothing else that needs to know where a hit
/// box really sits -- the C-248 name-chip placement check below is the
/// first -- can drift from it by recomputing the fan separately.
Rect _tokenHitRect({
  required int seat,
  required int tokenIndex,
  required int progress,
  required double cellSize,
}) {
  final BoardCell cell = cellFor(
    seat: seat,
    progress: progress,
    tokenIndex: tokenIndex,
  );
  final double fan = cellSize * 0.12;
  final double fanDx = tokenIndex.isEven ? -fan : fan;
  final double fanDy = tokenIndex < 2 ? -fan : fan;
  final double tokenSize = cellSize * 0.7;
  final double hitSize = _tokenHitSize(tokenSize);
  final double centerX = cell.col * cellSize + cellSize / 2 + fanDx;
  final double centerY = cell.row * cellSize + cellSize / 2 + fanDy;
  return Rect.fromCenter(
    center: Offset(centerX, centerY),
    width: hitSize,
    height: hitSize,
  );
}

/// WCAG contrast ratio of two colours, the larger luminance over the
/// smaller, both offset by 0.05 per the standard formula.
double _contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double lighter = math.max(la, lb);
  final double darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Whichever of [LudoColors.actionOn] (this paintbox's existing near-white,
/// the ink every action-coloured surface already sits on) or [LudoColors.ink]
/// contrasts more against [background] -- C-248 rule 1's "contrasting ink",
/// with no new literal white: the order's "use an existing colour" applies
/// here even though actionOn needs no opacity change to read.
Color _contrastingInk(Color background) {
  final double lightContrast = _contrastRatio(background, LudoColors.actionOn);
  final double darkContrast = _contrastRatio(background, LudoColors.ink);
  return lightContrast >= darkContrast ? LudoColors.actionOn : LudoColors.ink;
}

/// Same seats, same order -- [_BoardPainter.shouldRepaint]'s way of asking
/// whether [LudoBoard.seatsInPlay] actually changed without pulling in a
/// collection-equality package for one list.
bool _sameSeats(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

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
    this.seatNames,
    this.youLabel,
    this.turnSeat,
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

  /// Display name of every seat that has one, keyed by seat. Null (the
  /// default) draws exactly what the board drew before this: no name chip
  /// at all. A seat in [seatsInPlay] with no entry here stays bare too; the
  /// screen decides who gets named, this widget only draws what it is told.
  /// C-248 rule 1.
  final Map<int, String>? seatNames;

  /// The word that tags [mySeat]'s own name chip ("You" / "أنت"), shown
  /// only when this is non-null and [seatNames] has an entry for [mySeat].
  /// Null draws no tag at all, the default. C-248 rule 2.
  final String? youLabel;

  /// The seat whose yard carries the soft turn glow right now, or null for
  /// none -- the default, which draws no glow, same as today. Ignored for a
  /// seat outside [seatsInPlay]. C-248 rule 3.
  final int? turnSeat;

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
    final double hitSize = _tokenHitSize(tokenSize);
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

    _resolveTap(best.indices);
  }

  /// The one place a tap -- real or Semantics -- turns into either
  /// `onTokenTap` or `onIllegalTokenTap` plus a shake. [indices] is every
  /// index of mine sharing the tapped cell, sorted ascending: the stack rule
  /// is "the lowest legal index on that cell", so a legal hit here always
  /// resolves the same way regardless of which stacked token the tap or the
  /// Semantics action actually named.
  void _resolveTap(List<int> indices) {
    final List<int> legalHere =
        indices.where((int index) => widget.legal.contains(index)).toList()
          ..sort();
    if (legalHere.isNotEmpty) {
      widget.onTokenTap?.call(legalHere.first);
      return;
    }

    final int shakeIndex = indices.first;
    widget.onIllegalTokenTap?.call(shakeIndex);
    _triggerShake(shakeIndex);
  }

  /// Every index of [mySeat] sharing the same cell as [tokenIndex], sorted
  /// ascending -- the Semantics path's way of asking the same "what shares
  /// this cell" question [_cellGroups] answers for a pixel tap, without
  /// needing a cell size to do it.
  List<int> _groupIndicesFor(int mySeat, int tokenIndex) {
    final List<int> progresses = widget.tokens[mySeat]!;
    final BoardCell cell = cellFor(
      seat: mySeat,
      progress: progresses[tokenIndex],
      tokenIndex: tokenIndex,
    );
    return <int>[
      for (var i = 0; i < 4; i++)
        if (cellFor(seat: mySeat, progress: progresses[i], tokenIndex: i) ==
            cell)
          i,
    ]..sort();
  }

  /// Every widget one seat's identity contributes to the stack: the turn
  /// glow behind its whole yard, the "this one is mine" ring around it, and
  /// its name chip, in that order so the tokens drawn afterward always sit
  /// on top of all three. Contract C-248; an empty list for a seat with
  /// nothing to show (no [LudoBoard.seatNames] entry, not [LudoBoard.turnSeat],
  /// not [LudoBoard.mySeat]).
  List<Widget> _seatIdentityLayer({
    required int seat,
    required double cellSize,
  }) {
    final BoardCell origin = yardQuadrantOrigin(seat);
    final double left = origin.col * cellSize;
    final double top = origin.row * cellSize;
    final double side = yardQuadrantSide * cellSize;

    final List<Widget> layer = <Widget>[];

    if (widget.turnSeat == seat) {
      layer.add(
        Positioned(
          left: left,
          top: top,
          width: side,
          height: side,
          child: IgnorePointer(
            child: KeyedSubtree(
              key: Key('board-turn-yard-$seat'),
              child: _TurnGlow(color: LudoColors.seats[seat]),
            ),
          ),
        ),
      );
    }

    // C-248 rule 2, read literally: the ring follows mySeat and seatNames
    // being given at all, not whether seatNames happens to name mySeat
    // itself -- the ring is the colour signal P9 asks to stand beside the
    // name, not a part of the name chip.
    if (widget.mySeat == seat && widget.seatNames != null) {
      layer.add(
        Positioned(
          key: const Key('board-my-yard'),
          left: left,
          top: top,
          width: side,
          height: side,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: LudoColors.seats[seat], width: 3),
              ),
            ),
          ),
        ),
      );
    }

    final String? name = widget.seatNames?[seat];
    if (name != null) {
      layer.add(
        _nameChip(seat: seat, name: name, cellSize: cellSize, origin: origin),
      );
    }

    return layer;
  }

  /// [seat]'s name chip: a pill in [LudoColors.seats][seat], sat in the row
  /// of its yard that touches the real edge of the board (the top row for
  /// the two top yards, the bottom row for the two bottom ones), centred
  /// across the yard's own width. Shrunk away from the yard's interior by
  /// however much any of this seat's own yard tokens' 48dp hit boxes reach
  /// into that row -- at this board's actual viewport sizes a hit box is
  /// bigger than one cell, so it is checked rather than assumed clear.
  Widget _nameChip({
    required int seat,
    required String name,
    required double cellSize,
    required BoardCell origin,
  }) {
    final bool edgeIsTop = origin.row == 0;
    final double rowTop = edgeIsTop
        ? origin.row * cellSize
        : (origin.row + yardQuadrantSide - 1) * cellSize;
    final double rowBottom = rowTop + cellSize;

    double innerBound = edgeIsTop ? rowBottom : rowTop;
    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
      final Rect hitRect = _tokenHitRect(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: -1,
        cellSize: cellSize,
      );
      if (hitRect.bottom <= rowTop || hitRect.top >= rowBottom) {
        continue;
      }
      if (edgeIsTop) {
        innerBound = math.min(innerBound, hitRect.top);
      } else {
        innerBound = math.max(innerBound, hitRect.bottom);
      }
    }

    final double chipTop = edgeIsTop ? rowTop : innerBound;
    final double chipBottom = edgeIsTop ? innerBound : rowBottom;
    final double chipHeight = math.max(0.0, chipBottom - chipTop);
    final double chipWidth = yardQuadrantSide * cellSize;
    final double chipLeft = origin.col * cellSize;

    final Color seatColor = LudoColors.seats[seat];
    final Color ink = _contrastingInk(seatColor);
    final bool isMine = widget.mySeat == seat;
    final String? you = isMine ? widget.youLabel : null;

    return Positioned(
      left: chipLeft,
      top: chipTop,
      width: chipWidth,
      height: chipHeight,
      child: IgnorePointer(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: cellSize * 0.2),
            child: DecoratedBox(
              key: Key('board-seat-name-$seat'),
              decoration: BoxDecoration(
                color: seatColor,
                borderRadius: BorderRadius.circular(chipHeight),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: cellSize * 0.3,
                  vertical: chipHeight * 0.08,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink,
                          fontSize: math.max(7.0, chipHeight * 0.6),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (you != null) ...<Widget>[
                      SizedBox(width: cellSize * 0.15),
                      Text(
                        you,
                        key: const Key('board-seat-you'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink,
                          fontSize: math.max(7.0, chipHeight * 0.55),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
                    child: CustomPaint(
                      painter: _BoardPainter(seatsInPlay: widget.seatsInPlay),
                    ),
                  ),
                  ..._safeSquareMarks(cellSize),
                  for (final seat in widget.seatsInPlay)
                    ..._seatIdentityLayer(seat: seat, cellSize: cellSize),
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
      final Rect hitRect = _tokenHitRect(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: progress,
        cellSize: cellSize,
      );
      final AppLocalizations loc = AppLocalizations.of(context);
      layer.add(
        Positioned(
          left: hitRect.left,
          top: hitRect.top,
          width: hitRect.width,
          height: hitRect.height,
          // The Semantics node itself carries the key: a key on a plain
          // child below it (as this used to be) finds a node with no
          // button flag, because getSemantics walks up from the keyed
          // element to whichever ancestor owns the node, and that search
          // does not reliably land back on this one. An opaque MetaData,
          // not a bare SizedBox, inside it: it needs to register its own
          // hit test without painting a colour, so a real tap still
          // lands through the board's outer
          // opaque GestureDetector underneath it exactly as before --
          // this node adds the accessible route, it does not replace the
          // pixel one.
          child: Semantics(
            key: Key('board-token-hit-$seat-$tokenIndex'),
            button: true,
            label: loc.gameTokenButton(tokenIndex + 1),
            enabled: legalHere,
            onTap: () => _resolveTap(_groupIndicesFor(seat, tokenIndex)),
            child: const MetaData(
              behavior: HitTestBehavior.opaque,
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
    }

    if (legalHere) {
      final double ringSize = tokenSize * 1.7;
      // C-223 clarification 2: the legal ring key is present for every
      // legal token, the unique-legal token included; the faster glow key
      // nests around that same ring rather than drawing a second one on
      // top of it.
      Widget ring = _PulsingRing(
        period: autoMoveHere
            ? const Duration(milliseconds: 450)
            : const Duration(milliseconds: 900),
      );
      if (autoMoveHere) {
        ring = KeyedSubtree(
          key: Key('board-automove-glow-$seat-$tokenIndex'),
          child: ring,
        );
      }
      layer.add(
        Positioned(
          key: Key('board-legal-ring-$seat-$tokenIndex'),
          left: left + tokenSize / 2 - ringSize / 2,
          top: top + tokenSize / 2 - ringSize / 2,
          width: ringSize,
          height: ringSize,
          child: ring,
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

/// The star mark on each of the eight safe squares (RULES.md 1.3, contract
/// C-241), one per entry of [safeTrackSquares]. Painted above the board
/// painter and below every token layer so a token standing on a safe
/// square is never hidden under its own star, and wrapped in
/// [IgnorePointer] so the mark never answers a tap meant for the token on
/// it: a legal tap on a token that happens to sit on a safe square must
/// still resolve to exactly one move.
List<Widget> _safeSquareMarks(double cellSize) {
  return <Widget>[
    for (final int absolute in safeTrackSquares)
      Positioned(
        key: Key('board-safe-$absolute'),
        left: safeSquareCell(absolute).col * cellSize,
        top: safeSquareCell(absolute).row * cellSize,
        width: cellSize,
        height: cellSize,
        child: IgnorePointer(
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.7,
              heightFactor: 0.7,
              child: CustomPaint(
                painter: _StarPainter(
                  color: _entrySquares.contains(absolute)
                      ? LudoColors.paperElevated
                      : LudoColors.inkMuted,
                ),
              ),
            ),
          ),
        ),
      ),
  ];
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

/// The soft glow a seat's whole yard carries while it holds the turn
/// (`board-turn-yard-S`, C-248 rule 3): a blurred stroke around the yard,
/// breathing over a fixed 1200ms period. Reduced motion holds it at its
/// brightest rather than animating -- the same rule [_PulsingRing] and the
/// shake follow: the meaning ("this is the seat to watch") stays, only the
/// motion that says so goes. This widget exists in the tree for exactly as
/// long as its seat is [LudoBoard.turnSeat]; its own [dispose] is the
/// ticker's stop, so there is nothing separate to wire for "turnSeat
/// changed" or "the board itself was removed".
class _TurnGlow extends StatefulWidget {
  const _TurnGlow({required this.color});

  final Color color;

  @override
  State<_TurnGlow> createState() => _TurnGlowState();
}

class _TurnGlowState extends State<_TurnGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool? _reduced;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
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
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final double t = _controller.value;
        final double opacity = reduced ? 0.55 : 0.2 + 0.35 * t;
        final double blurSigma = reduced ? 10.0 : 6.0 + 8.0 * t;
        return CustomPaint(
          painter: _GlowPainter(
            color: widget.color,
            opacity: opacity,
            blurSigma: blurSigma,
          ),
        );
      },
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.color,
    required this.opacity,
    required this.blurSigma,
  });

  final Color color;
  final double opacity;
  final double blurSigma;

  @override
  void paint(Canvas canvas, Size size) {
    final double stroke = size.shortestSide * 0.06;
    final Rect rect = (Offset.zero & size).deflate(stroke);
    final Paint glow = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
    canvas.drawRect(rect, glow);
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.opacity != opacity ||
      oldDelegate.blurSigma != blurSigma;
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

/// A plain five-point star, point up, filling a disc of radius
/// `min(size.width, size.height) / 2` -- the safe-square mark itself. Shape
/// carries the meaning (doctrine P9): the star alone says "safe", the
/// entry square's paper-coloured fill under four of them is only the extra
/// signal. Ten vertices at 36 degree steps starting straight up, alternating
/// the outer radius with an inner radius at the classic 0.382 ratio of a
/// regular pentagram -- the same arithmetic a pencil-and-compass star uses,
/// not ten hand-placed points.
class _StarPainter extends CustomPainter {
  const _StarPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double outerRadius = math.min(size.width, size.height) / 2;
    final double innerRadius = outerRadius * 0.382;
    final Path path = Path();
    for (var point = 0; point < 10; point++) {
      final double radius = point.isEven ? outerRadius : innerRadius;
      final double angle = -math.pi / 2 + point * math.pi / 5;
      final double x = center.dx + radius * math.cos(angle);
      final double y = center.dy + radius * math.sin(angle);
      if (point == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _StarPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Paints the static board: the grid, the four yards, the shared track, the
/// four home columns and the centre. None of this determines where a token
/// goes; it is drawn from the same [cellFor] a token uses, so the background
/// and the tokens can never show a track that disagrees with each other.
///
/// Seat fills and board inks come from [LudoColors]: one paintbox with theme.
class _BoardPainter extends CustomPainter {
  const _BoardPainter({required this.seatsInPlay});

  /// Which seats are playing, same list [LudoBoard] was given. A seat not
  /// in it gets its yard fill muted -- C-248 rule 4, the one default change
  /// this contract makes: today's drawing painted every yard the same
  /// whether or not anyone sat there.
  final List<int> seatsInPlay;

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = size.width / 15;

    canvas.drawRect(Offset.zero & size, Paint()..color = LudoColors.dieFace);

    for (var seat = 0; seat < 4; seat++) {
      final BoardCell origin = yardQuadrantOrigin(seat);
      final bool inPlay = seatsInPlay.contains(seat);
      final double yardAlpha = inPlay ? 0.16 : 0.16 * 0.35;
      _fillCells(
        canvas,
        cellSize,
        origin.col,
        origin.row,
        yardQuadrantSide,
        yardQuadrantSide,
        LudoColors.seats[seat].withValues(alpha: yardAlpha),
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

    // Each seat's own entry square, filled in that seat's colour after the
    // plain track fill above so it is not painted over. Contract C-241 rule
    // 2; the four absolute squares are 0, 13, 26, 39, one per seat.
    for (var seat = 0; seat < 4; seat++) {
      final cell = cellFor(seat: seat, progress: 0);
      _fillCell(
        canvas,
        cellSize,
        cell,
        LudoColors.seats[seat].withValues(alpha: 0.85),
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
  bool shouldRepaint(covariant _BoardPainter oldDelegate) =>
      !_sameSeats(oldDelegate.seatsInPlay, seatsInPlay);
}
