// The board widget: draws the 15 by 15 grid and every seat's tokens on top
// of it. Every token's board-space cell comes from cellFor; every conversion
// of a cell into pixels goes through toView(cell, viewQuarters(mySeat)).
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

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../l10n/gen/app_localizations.dart';
import 'board_geometry.dart';
import 'capture_gloat.dart';
import 'move_hint.dart';
import 'safe_cue.dart';
import 'seat_die.dart';
import 'seat_mark.dart';
import 'theme.dart';
import 'token_face_picker.dart';

export 'board_geometry.dart';

/// How long the drawn token dwells on each square of a travel step, contract
/// C-252 rule 5. [kTokenStepDurationReduced] is the same dwell under
/// `MediaQuery.disableAnimationsOf`: shorter, never skipped, same order.
const Duration kTokenStepDuration = Duration(milliseconds: 140);
const Duration kTokenStepDurationReduced = Duration(milliseconds: 40);

/// How long a captured token's straight flight home takes, contract C-252
/// rule 5, and its reduced-motion counterpart.
const Duration kCaptureFlightDuration = Duration(milliseconds: 360);
const Duration kCaptureFlightDurationReduced = Duration(milliseconds: 120);

/// Contract C-417 D2: the one constant the unique-legal hold counts from,
/// shared by the countdown arc drawn here and by game_screen.dart's own
/// hold timer, so the arc reaching empty and the held move actually being
/// sent coincide within a frame rather than drifting apart as two
/// separately-declared 1500s.
const Duration kAutoMoveHold = Duration(milliseconds: 1500);

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

/// Rank of [seat] relative to the viewer. My seat is 0, then the seats
/// after it around the table. A spectator (`mySeat` null) ranks a seat as
/// itself. Same expression the token Semantics sort key uses.
int _seatRank(int seat, int? mySeat) =>
    mySeat == null ? seat : (seat - mySeat) % 4;

/// One token standing on a cell, truth progress included so a shared-track
/// check can tell a main-track square from a yard, home or finished one.
class _TokenOccupant {
  const _TokenOccupant({
    required this.seat,
    required this.tokenIndex,
    required this.progress,
  });

  final int seat;
  final int tokenIndex;
  final int progress;
}

/// Centre and diameter of one drawn token, in view pixels.
class _TokenLayout {
  const _TokenLayout({required this.center, required this.size});

  final Offset center;
  final double size;
}

/// The four centres used when a shared cell holds four tokens or fewer,
/// in occupant order: top-left, top-right, bottom-left, bottom-right, in
/// view space. Multiplied by `cellSize * 0.22` and added to the cell centre.
const List<(int, int)> _sharedQuad = <(int, int)>[
  (-1, -1),
  (1, -1),
  (-1, 1),
  (1, 1),
];

/// Occupants of [cell] (board space), each token's position read through
/// [progressOf] -- truth (`tokens[seat]![tokenIndex]`) by default, or
/// contract C-408 decision 3's drawn position when the caller passes one:
/// a token still travelling toward [cell] (its own [progressOf] not yet
/// equal to the square it is crossing) is not an occupant of it yet, and a
/// token already drawn there (even if truth has since moved it on) still
/// is. Other seats first, by [_seatRank] ascending, then the viewer's seat;
/// within a seat by token index ascending. A spectator has no seat of
/// their own, so the whole list is rank order.
List<_TokenOccupant> _occupantsOnCell({
  required BoardCell cell,
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  required int? mySeat,
  int Function(int seat, int tokenIndex)? progressOf,
}) {
  final int Function(int seat, int tokenIndex) resolvedProgressOf =
      progressOf ?? ((int seat, int tokenIndex) => tokens[seat]![tokenIndex]);
  final List<_TokenOccupant> occupants = <_TokenOccupant>[];
  for (final int seat in seatsInPlay) {
    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
      final int progress = resolvedProgressOf(seat, tokenIndex);
      if (cellFor(seat: seat, progress: progress, tokenIndex: tokenIndex) !=
          cell) {
        continue;
      }
      occupants.add(
        _TokenOccupant(seat: seat, tokenIndex: tokenIndex, progress: progress),
      );
    }
  }
  occupants.sort((_TokenOccupant a, _TokenOccupant b) {
    final bool aMine = mySeat != null && a.seat == mySeat;
    final bool bMine = mySeat != null && b.seat == mySeat;
    if (aMine != bMine) {
      return aMine ? 1 : -1;
    }
    final int rank = _seatRank(
      a.seat,
      mySeat,
    ).compareTo(_seatRank(b.seat, mySeat));
    if (rank != 0) {
      return rank;
    }
    return a.tokenIndex.compareTo(b.tokenIndex);
  });
  return occupants;
}

/// A main-track cell with tokens of two or more seats. Yard, home-column
/// and finished cells are not this, even where two seats happen to share
/// a coordinate: C-386's slots are only for the shared track.
bool _isSharedTrack(List<_TokenOccupant> occupants) {
  if (occupants.length < 2) {
    return false;
  }
  final Set<int> seats = <int>{};
  for (final _TokenOccupant occupant in occupants) {
    if (occupant.progress < 0 || occupant.progress > 51) {
      return false;
    }
    seats.add(occupant.seat);
  }
  return seats.length >= 2;
}

/// Centre and diameter of token [tokenIndex] of [seat] drawn at [progress].
///
/// One seat on the cell keeps the old fan: diameter `cellSize * 0.7`,
/// offset `cellSize * 0.12`, x by even or odd index, y by index below 2.
/// That is every yard slot, every finished slot, a home-column cell, and
/// any main-track cell a single seat occupies.
///
/// Two or more seats on a main-track cell use the shared slots. Four or
/// fewer occupants: diameter `cellSize * 0.5`, centre at the cell centre
/// plus `(dx, dy) * cellSize * 0.22` for [_sharedQuad] in occupant order.
/// Five or more: diameter `cellSize * 0.36` on a 3 by 3 grid of step
/// `cellSize * 0.3`, row by row from the top-left of the grid. The grid is
/// centred on the cell, so slot 4 sits on the cell centre and the outer
/// slots stay inside the cell. Past nine occupants the count starts again
/// at slot 0, and two tokens may share a centre.
///
/// The offsets are applied after [toView], in view axes, so they do not
/// turn with the board and they do not mirror.
///
/// [tokens] is truth, read for occupancy through [progressOf] when the
/// caller passes one (contract C-408 decision 3; see [_occupantsOnCell]).
/// A token drawn at a [progress] it does not occupy (mid-step, or held on
/// its old square before the flight home) is not an occupant of that
/// cell, so it keeps the fan there.
_TokenLayout _tokenLayout({
  required int seat,
  required int tokenIndex,
  required int progress,
  required double cellSize,
  required int? mySeat,
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
  int Function(int seat, int tokenIndex)? progressOf,
}) {
  final BoardCell cell = cellFor(
    seat: seat,
    progress: progress,
    tokenIndex: tokenIndex,
  );
  final BoardCell viewCell = toView(cell, viewQuarters(mySeat));
  final List<_TokenOccupant> occupants = _occupantsOnCell(
    cell: cell,
    tokens: tokens,
    seatsInPlay: seatsInPlay,
    mySeat: mySeat,
    progressOf: progressOf,
  );

  var slot = -1;
  for (var i = 0; i < occupants.length; i++) {
    final _TokenOccupant occupant = occupants[i];
    if (occupant.seat == seat && occupant.tokenIndex == tokenIndex) {
      slot = i;
      break;
    }
  }

  if (slot < 0 || !_isSharedTrack(occupants)) {
    final double fan = cellSize * 0.12;
    final double fanDx = tokenIndex.isEven ? -fan : fan;
    final double fanDy = tokenIndex < 2 ? -fan : fan;
    return _TokenLayout(
      center: Offset(
        viewCell.col * cellSize + cellSize / 2 + fanDx,
        viewCell.row * cellSize + cellSize / 2 + fanDy,
      ),
      size: cellSize * 0.7,
    );
  }

  final Offset cellCenter = Offset(
    viewCell.col * cellSize + cellSize / 2,
    viewCell.row * cellSize + cellSize / 2,
  );
  if (occupants.length <= 4) {
    final (int sx, int sy) = _sharedQuad[slot];
    return _TokenLayout(
      center: Offset(
        cellCenter.dx + sx * cellSize * 0.22,
        cellCenter.dy + sy * cellSize * 0.22,
      ),
      size: cellSize * 0.5,
    );
  }

  final int gridSlot = slot % 9;
  final int col = gridSlot % 3;
  final int row = gridSlot ~/ 3;
  final double step = cellSize * 0.3;
  return _TokenLayout(
    center: Offset(
      cellCenter.dx + (col - 1) * step,
      cellCenter.dy + (row - 1) * step,
    ),
    size: cellSize * 0.36,
  );
}

/// The pixel rect [tokenIndex] of [seat] at [progress] gets as its tap
/// target. Same centre as the drawn disc, side [_tokenHitSize] of that
/// disc. Both come from [_tokenLayout], so the Semantics hit box and the
/// paint cannot land on different points.
Rect _tokenHitRect({
  required int seat,
  required int tokenIndex,
  required int progress,
  required double cellSize,
  required int? mySeat,
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
}) {
  final _TokenLayout layout = _tokenLayout(
    seat: seat,
    tokenIndex: tokenIndex,
    progress: progress,
    cellSize: cellSize,
    mySeat: mySeat,
    tokens: tokens,
    seatsInPlay: seatsInPlay,
  );
  final double hit = _tokenHitSize(layout.size);
  return Rect.fromCenter(center: layout.center, width: hit, height: hit);
}

/// The pixel rect [tokenIndex] of [seat] at [progress] paints as its
/// circle: the disc itself, not the enlarged [_tokenHitRect]. Same centre,
/// from [_tokenLayout]. The name-chip placement check reads this one.
Rect _tokenDrawnRect({
  required int seat,
  required int tokenIndex,
  required int progress,
  required double cellSize,
  required int? mySeat,
  required Map<int, List<int>> tokens,
  required List<int> seatsInPlay,
}) {
  final _TokenLayout layout = _tokenLayout(
    seat: seat,
    tokenIndex: tokenIndex,
    progress: progress,
    cellSize: cellSize,
    mySeat: mySeat,
    tokens: tokens,
    seatsInPlay: seatsInPlay,
  );
  return Rect.fromCenter(
    center: layout.center,
    width: layout.size,
    height: layout.size,
  );
}

/// Top-left cell and size of the axis-aligned block that [toView] maps
/// the [width] by [height] rectangle at ([col], [row]) onto after
/// [quarters] clockwise turns. A rotated rectangle's own top-left is not
/// in general [toView] of its pre-rotation top-left (the same reason
/// [yardQuadrantOrigin] is listed rather than generated).
({int col, int row, int width, int height}) _viewBlock({
  required int col,
  required int row,
  required int width,
  required int height,
  required int quarters,
}) {
  int minCol = col;
  int minRow = row;
  int maxCol = col;
  int maxRow = row;
  var first = true;
  for (final BoardCell corner in <BoardCell>[
    BoardCell(col, row),
    BoardCell(col + width - 1, row),
    BoardCell(col, row + height - 1),
    BoardCell(col + width - 1, row + height - 1),
  ]) {
    final BoardCell viewed = toView(corner, quarters);
    if (first) {
      minCol = viewed.col;
      minRow = viewed.row;
      maxCol = viewed.col;
      maxRow = viewed.row;
      first = false;
    } else {
      if (viewed.col < minCol) minCol = viewed.col;
      if (viewed.row < minRow) minRow = viewed.row;
      if (viewed.col > maxCol) maxCol = viewed.col;
      if (viewed.row > maxRow) maxRow = viewed.row;
    }
  }
  return (
    col: minCol,
    row: minRow,
    width: maxCol - minCol + 1,
    height: maxRow - minRow + 1,
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

/// The quick message line that is up, as the board is told of it: the seat
/// that said it and the line's serial. A serial a seat's name chip has not
/// seen pops that chip once. The line itself is drawn by the game screen in
/// the header band. C-500 D6.
class BoardChatPop {
  const BoardChatPop({required this.seat, required this.serial});

  final int seat;
  final int serial;
}

/// A Ludo board: the static grid plus every token of every seat in
/// [seatsInPlay], each placed by [cellFor] then [toView].
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
    this.interactive = true,
    this.legal = const <int>{},
    this.autoMoveToken,
    this.sentToken,
    this.onTokenTap,
    this.onIllegalTokenTap,
    this.seatNames,
    this.youLabel,
    this.turnSeat,
    this.onTokenStep,
    this.onMoveLanded,
    this.onTravelReset,
    this.overlay,
    this.safeCue,
    this.facePick,
    this.seatDice = const <SeatDie>[],
    this.seatRecord,
    this.gloat,
    this.hint,
    this.hintNamesFace = false,
    this.chatPop,
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

  /// Whether the board is a play surface at all. True, the default, draws
  /// and behaves exactly as it always has for [mySeat]: hit targets, tap
  /// handling, the legal ring, the shake. False draws the same board (same
  /// [mySeat], same rotation, same "You" tag) with none of that: no
  /// `board-token-hit-*` widget for any token, [_handleTapUp] a no-op, and
  /// nothing ever shakes. The finished board uses this -- a game that is
  /// over has nothing to tap.
  final bool interactive;

  /// Token indices of [mySeat] that may move right now. Ignored for any
  /// other seat's tokens, which are never tappable regardless.
  final Set<int> legal;

  /// The token index (of [mySeat]) glowing for the unique-legal hold, or
  /// null when no hold is pending.
  final int? autoMoveToken;

  /// C-422 D4: the token index (of [mySeat]) the screen just sent a move
  /// for, or null when no move is in flight. While this is non-null and
  /// [interactive] is true, that token's disc is drawn lifted (keyed
  /// `board-token-lifted-<seat>-<token>`) and no `board-legal-ring-*`,
  /// `board-automove-glow-*` or `board-automove-arc-*` is built for any of
  /// [mySeat]'s tokens. The lift changes neither layout nor hit target:
  /// `board-token-hit-*` stays the rect it always was. Null, the default,
  /// draws exactly what the board drew before this contract.
  final int? sentToken;

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

  /// Called once each time a travelling token's drawn position arrives on a
  /// square, contract C-252 rule 7: `(seat, token)`, never for the captured
  /// token's flight home. Null by default, which plays every travel exactly
  /// as it plays today, with nothing to call. A later order wires this to
  /// the feedback service; this widget only ever calls it, never decides
  /// what it means.
  final void Function(int seat, int token)? onTokenStep;

  /// Called once as the mover's final step lands, contract C-268 rule 1:
  /// `(seat, token)`, before any capture flight starts, never for a
  /// captured token's flight. Null by default.
  final void Function(int seat, int token)? onMoveLanded;

  /// Called every time [_snapToTruth] runs, contract C-268 rule 2. Null by
  /// default.
  final VoidCallback? onTravelReset;

  /// Drawn above the tokens, inside the board square. Null draws nothing.
  /// The thrown die (C-377) lives here so it sits in the board's rect and
  /// never changes the board's own size. The caller owns its motion.
  final Widget? overlay;

  /// The safe-landing pill, or null when none is showing. Placed on the
  /// mover's destination cell. The screen owns when it appears and when
  /// it leaves; this widget only anchors it. C-384.
  final SafeCue? safeCue;

  /// C-462 D5: the face picker on one of [mySeat]'s tokens, or null when
  /// none is open. Null adds nothing, so a board built without it draws
  /// exactly what it drew before.
  final TokenFacePick? facePick;

  /// One die per other seat in play, centred on that seat's yard. Empty,
  /// the default, draws none, so a board built without it is unchanged.
  /// C-465 D2.
  final List<SeatDie> seatDice;

  /// Another seat's roll record, drawn in that seat's yard. Null, the
  /// default, draws none. C-465 D4.
  final SeatRollRecord? seatRecord;

  /// The capture gloat, or null when none is showing. Null, the default,
  /// adds nothing, so a board built without it draws exactly what it drew
  /// before. C-468 D5.
  final BoardGloat? gloat;

  /// The token and face to mark, or null. Null, the default, adds nothing,
  /// so a board built without it draws exactly what it drew before
  /// (C-471 D4).
  final MoveHint? hint;

  /// When true and [hint] is non-null, the marker carries [MoveHint.face]
  /// and the token's semantics use the face suffix. The screen sets this
  /// when D1's candidates hold more than one face (C-471 D4). Default
  /// false draws the marker with no numeral.
  final bool hintNamesFace;

  /// The quick message line that is up, as the seat that said it and its
  /// serial. A serial this board has not seen pops that seat's name chip once;
  /// the line itself is drawn in the header band, never here. Null, the
  /// default, pops nothing. C-500 D6.
  final BoardChatPop? chatPop;

  @override
  State<LudoBoard> createState() => _LudoBoardState();
}

/// One positioned child of [_SeatPieceLayer]. [id] is stable for a seat
/// so the layout can keep that child when the others appear. C-465 D2, D4.
class _SeatPiece {
  const _SeatPiece({required this.id, required this.rect, required this.child});

  final Object id;
  final Rect rect;
  final Widget child;
}

/// Holds every seat die and the on-board record in one child of the board
/// stack, so a piece appearing does not move the thrown-die overlay onto
/// a new element and start its tumble over (C-465 D3).
class _SeatPieceLayer extends StatelessWidget {
  const _SeatPieceLayer({required this.pieces});

  final List<_SeatPiece> pieces;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: _SeatPieceDelegate(pieces),
      children: <Widget>[
        for (final _SeatPiece piece in pieces)
          LayoutId(id: piece.id, child: piece.child),
      ],
    );
  }
}

class _SeatPieceDelegate extends MultiChildLayoutDelegate {
  _SeatPieceDelegate(this.pieces);

  final List<_SeatPiece> pieces;

  @override
  void performLayout(Size size) {
    for (final _SeatPiece piece in pieces) {
      layoutChild(piece.id, BoxConstraints.tight(piece.rect.size));
      positionChild(piece.id, piece.rect.topLeft);
    }
  }

  @override
  bool shouldRelayout(covariant _SeatPieceDelegate oldDelegate) {
    if (oldDelegate.pieces.length != pieces.length) {
      return true;
    }
    for (var i = 0; i < pieces.length; i++) {
      if (oldDelegate.pieces[i].id != pieces[i].id ||
          oldDelegate.pieces[i].rect != pieces[i].rect) {
        return true;
      }
    }
    return false;
  }
}

class _LudoBoardState extends State<LudoBoard> {
  int? _shakingToken;
  Timer? _shakeTimer;

  // Travel (contract C-252). `_override` holds, keyed by "seat-token", the
  // progress the drawn token is actually showing right now whenever that
  // differs from truth (`widget.tokens`): the mover mid-step, or a captured
  // token held on its old square before it flies. A pair with no entry here
  // draws straight from truth, same as before this contract -- that is also
  // the whole of what a board built once and never updated does, since
  // nothing ever populates this map without a tokens change to react to.
  final Map<String, int> _override = <String, int>{};

  // The move currently stepping, the steps still to play after it (FIFO,
  // nothing ever dropped from it except by a snap), which step of the
  // current move comes next, and the captured token (if any) currently
  // flying home. At most one of each at a time; rule 6's queue is exactly
  // this list.
  _Move? _playingMove;
  int _playingStepIndex = 0;
  final List<_Move> _queue = <_Move>[];
  _FlyingCapture? _flying;
  Timer? _stepTimer;

  @override
  void dispose() {
    _shakeTimer?.cancel();
    _stepTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LudoBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reactToTokensChange(oldWidget);
  }

  /// Contract C-252 rule 2: classify what changed between the previous
  /// build's `tokens` and this one's, then either start (or queue) the one
  /// move it describes, or -- for anything else, including a changed
  /// [LudoBoard.seatsInPlay] -- drop every pending step and let truth draw
  /// itself with no animation. Mutates state directly rather than calling
  /// `setState`: the framework always builds this element again right after
  /// `didUpdateWidget` returns, so there is nothing to schedule.
  void _reactToTokensChange(LudoBoard oldWidget) {
    if (!_sameSeats(oldWidget.seatsInPlay, widget.seatsInPlay)) {
      _snapToTruth();
      return;
    }

    final List<_TokenDiff> diffs = <_TokenDiff>[];
    for (final int seat in widget.seatsInPlay) {
      final List<int> oldProgresses = oldWidget.tokens[seat]!;
      final List<int> newProgresses = widget.tokens[seat]!;
      for (var token = 0; token < 4; token++) {
        final int oldP = oldProgresses[token];
        final int newP = newProgresses[token];
        if (oldP != newP) {
          diffs.add(
            _TokenDiff(seat: seat, token: token, oldP: oldP, newP: newP),
          );
        }
      }
    }
    if (diffs.isEmpty) {
      return;
    }

    final List<_TokenDiff> moverDiffs = diffs
        .where(
          (d) =>
              (d.oldP == -1 && d.newP == 0) ||
              (d.oldP >= 0 && d.newP - d.oldP >= 1 && d.newP - d.oldP <= 6),
        )
        .toList();
    if (moverDiffs.length != 1) {
      _snapToTruth();
      return;
    }
    final _TokenDiff mover = moverDiffs.single;

    final List<_TokenDiff> rest = diffs.where((d) => d != mover).toList();
    _TokenDiff? capture;
    if (rest.length == 1) {
      final _TokenDiff candidate = rest.single;
      if (candidate.seat != mover.seat &&
          candidate.oldP >= 0 &&
          candidate.newP == -1) {
        capture = candidate;
      }
    }
    final bool restIsOnlyTheCapture =
        rest.isEmpty || (rest.length == 1 && capture != null);
    if (!restIsOnlyTheCapture) {
      _snapToTruth();
      return;
    }

    _enqueueOrStart(
      _Move(
        seat: mover.seat,
        token: mover.token,
        oldProgress: mover.oldP,
        newProgress: mover.newP,
        capturedSeat: capture?.seat,
        capturedToken: capture?.token,
        capturedOldProgress: capture?.oldP,
      ),
    );
  }

  /// Drops every step still waiting and every timer that would have played
  /// them, and clears the override so the very next build draws straight
  /// from truth -- contract C-252 rule 2's "the board snaps to the truth".
  void _snapToTruth() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _playingMove = null;
    _playingStepIndex = 0;
    _queue.clear();
    _override.clear();
    _flying = null;
    widget.onTravelReset?.call();
  }

  /// Holds [move]'s mover (and its captured token, if any) on their old
  /// square by overriding the drawn progress to it -- true the instant this
  /// runs, whether or not stepping starts immediately -- then either starts
  /// stepping now (nothing else is playing) or joins the queue behind
  /// whatever is, contract C-252 rule 6.
  void _enqueueOrStart(_Move move) {
    _override[_key(move.seat, move.token)] = move.oldProgress;
    if (move.capturedSeat != null) {
      _override[_key(move.capturedSeat!, move.capturedToken!)] =
          move.capturedOldProgress!;
    }
    if (_playingMove == null) {
      _playingMove = move;
      _playingStepIndex = 0;
      _scheduleNextStep();
    } else {
      _queue.add(move);
    }
  }

  /// Contract C-252 rule 3: every progress from `old + 1` to `new`, in
  /// order, or -- leaving the yard -- the single square of progress 0.
  static List<int> _pathFor(_Move move) {
    if (move.oldProgress == -1) {
      return const <int>[0];
    }
    return <int>[
      for (var p = move.oldProgress + 1; p <= move.newProgress; p++) p,
    ];
  }

  /// Schedules the next step of [_playingMove]. The duration is read fresh
  /// at this call rather than fixed for the whole move, which is what makes
  /// rule 6's half-duration apply only to steps that have not started yet:
  /// a step already ticking keeps whatever duration it was given when it
  /// was scheduled, and only the ones scheduled after another move joined
  /// the queue see [_queue] non-empty here.
  void _scheduleNextStep() {
    final _Move? move = _playingMove;
    if (move == null) {
      return;
    }
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final Duration base = reduced
        ? kTokenStepDurationReduced
        : kTokenStepDuration;
    final Duration stepDuration = _queue.isNotEmpty
        ? Duration(microseconds: base.inMicroseconds ~/ 2)
        : base;
    _stepTimer = Timer(stepDuration, () => _onStepElapsed(move));
  }

  void _onStepElapsed(_Move move) {
    if (!mounted || _playingMove != move) {
      return;
    }
    final List<int> path = _pathFor(move);
    final int step = path[_playingStepIndex];
    setState(() {
      _override[_key(move.seat, move.token)] = step;
    });
    widget.onTokenStep?.call(move.seat, move.token);
    _playingStepIndex++;
    if (_playingStepIndex < path.length) {
      _scheduleNextStep();
    } else {
      _stepTimer = null;
      _onMoveArrived(move);
    }
  }

  /// The mover's last step has landed. Its override already holds
  /// [_Move.newProgress] (the final step's own `setState` put it there)
  /// and is deliberately left alone rather than cleared: contract C-408
  /// decision 6 -- when another move for the same token is already queued
  /// (truth jumped straight to that move's own destination the moment it
  /// was recognised, long before this leg's steps finished playing),
  /// clearing the override here would uncover that further-ahead truth for
  /// one frame before the queued move's first step pulls the disc back to
  /// where it actually continues from. Leaving the entry in place costs
  /// nothing when nothing is queued either: `widget.tokens` already holds
  /// this same value, so the override and the fallback agree, and whatever
  /// starts (or doesn't start) next either overwrites this entry on its own
  /// terms or clears the whole map outright ([_snapToTruth]). A captured
  /// token starts its flight home now, contract C-252 rule 4; a move with
  /// no capture is simply done, and the queue (if anything is waiting)
  /// moves on.
  void _onMoveArrived(_Move move) {
    widget.onMoveLanded?.call(move.seat, move.token);
    final int? capturedSeat = move.capturedSeat;
    if (capturedSeat != null) {
      final int capturedToken = move.capturedToken!;
      final int fromProgress =
          _override.remove(_key(capturedSeat, capturedToken)) ??
          move.capturedOldProgress!;
      setState(() {
        _flying = _FlyingCapture(
          seat: capturedSeat,
          token: capturedToken,
          fromProgress: fromProgress,
        );
      });
    } else {
      _finishPlaying();
    }
  }

  /// The captured token's flight landed: drop it, and move the queue on.
  /// Called by the [_CaptureFlight] widget itself, never by a timer this
  /// state owns -- the flight's own ticker lives and dies with that widget.
  void _handleCaptureArrived(int seat, int token) {
    if (!mounted) {
      return;
    }
    final _FlyingCapture? flying = _flying;
    if (flying != null && flying.seat == seat && flying.token == token) {
      setState(() {
        _flying = null;
      });
    }
    _finishPlaying();
  }

  /// [_playingMove] is fully done (its steps, and its capture's flight if it
  /// had one). Starts the next queued move, if any; its mover and captured
  /// token were already held on their old squares the moment it was
  /// queued, so starting it here changes no drawn position by itself.
  void _finishPlaying() {
    _playingMove = null;
    _playingStepIndex = 0;
    if (_queue.isNotEmpty) {
      _playingMove = _queue.removeAt(0);
      _playingStepIndex = 0;
      _scheduleNextStep();
    }
  }

  static String _key(int seat, int token) => '$seat-$token';

  /// What the drawn token for (seat, token) actually shows right now: the
  /// override if travel or a pending capture put one there, truth
  /// otherwise. Contract C-252 rule 1 -- only this, and the pixel position
  /// built from it, ever differs from truth; the hit target, the ring and
  /// the Semantics identifier never read this.
  int _drawnProgress(int seat, int token) =>
      _override[_key(seat, token)] ?? widget.tokens[seat]![token];

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
    final int quarters = viewQuarters(widget.mySeat);
    final List<_CellGroup> groups = <_CellGroup>[];
    for (final MapEntry<BoardCell, List<int>> entry in byCell.entries) {
      final BoardCell viewed = toView(entry.key, quarters);
      groups.add(
        _CellGroup(
          center: Offset(
            viewed.col * cellSize + cellSize / 2,
            viewed.row * cellSize + cellSize / 2,
          ),
          indices: entry.value..sort(),
        ),
      );
    }
    return groups;
  }

  void _handleTapUp(TapUpDetails details, double cellSize, double tokenSize) {
    if (!widget.interactive) {
      return;
    }
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
    final ({int col, int row, int width, int height}) viewed = _viewBlock(
      col: origin.col,
      row: origin.row,
      width: yardQuadrantSide,
      height: yardQuadrantSide,
      quarters: viewQuarters(widget.mySeat),
    );
    final BoardCell viewedOrigin = BoardCell(viewed.col, viewed.row);
    final double left = viewedOrigin.col * cellSize;
    final double top = viewedOrigin.row * cellSize;
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
        _nameChip(
          seat: seat,
          name: name,
          cellSize: cellSize,
          origin: viewedOrigin,
        ),
      );
    }

    return layer;
  }

  /// C-339 decision 2: "You" gives way before the name does -- the name is
  /// what a player is actually reading, "You" is the badge beside it --
  /// so when the two do not both fit at their own base size (board art,
  /// no system scaling, contract decision 1), "You" is the one asked to
  /// shrink first, down to its own floor (7px, unchanged), before the
  /// name gives up anything at all. Only once "You" is already at that
  /// floor and the pair still does not fit does the name shrink too, into
  /// whatever "You" at its floor left over, never below its own floor
  /// (10px, A2). Both are measured with a disposable [TextPainter], laid
  /// out unconstrained, in the same font and weight the chip itself
  /// paints ([kLudoFontFamily] / [kLudoFontFallbacks] -- the name's own
  /// `FontWeight.w600` matters here, semibold glyphs measure wider than
  /// the regular weight "You" uses). A small margin against rounding
  /// keeps a fit that is merely exact from reading as a one-pixel
  /// overflow. A name over 10 characters can still ask for a scale the
  /// floor refuses: `Flexible` and `TextOverflow.ellipsis` on the actual
  /// `Text` below are what the contract's "may still ellipsize" leans on
  /// when that happens.
  ({double name, double? you}) _fittedChipFontSizes({
    required String name,
    required String? you,
    required double baseNameFontSize,
    required double baseYouFontSize,
    required double available,
    required TextDirection direction,
    required TextStyle ambientStyle,
  }) {
    const double nameFloor = 10.0;
    const double youFloor = 7.0;
    const double safetyMargin = 0.98;
    // A flat, visually-silent 1px held back from whatever the geometry
    // offers: the branch that keeps one side at its full base size (no
    // ratio, so no `safetyMargin` of its own) would otherwise sit exactly
    // on the boundary, where this measurement's own rounding and the
    // live `RenderParagraph`'s do not quite have to agree.
    available = math.max(0.0, available - 1.0);

    // The real `Text` below inherits (`TextStyle.inherit` defaults true)
    // whatever is ambient -- letter spacing and the rest of it -- merged
    // under the fontFamily/size/weight it sets itself; measuring against
    // the bare override alone under-counts exactly that inherited part.
    double naturalWidth(String text, double fontSize, FontWeight weight) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: text,
          style: ambientStyle.merge(
            TextStyle(
              fontFamily: kLudoFontFamily,
              fontFamilyFallback: kLudoFontFallbacks,
              fontSize: fontSize,
              fontWeight: weight,
            ),
          ),
        ),
        textDirection: direction,
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout();
      final double width = painter.width;
      painter.dispose();
      return width;
    }

    final double nameNaturalBase = naturalWidth(
      name,
      baseNameFontSize,
      FontWeight.w600,
    );

    if (you == null) {
      if (available >= nameNaturalBase || nameNaturalBase <= 0) {
        return (name: baseNameFontSize, you: null);
      }
      final double scale = math.min(
        1.0,
        math.max(
          (available / nameNaturalBase) * safetyMargin,
          nameFloor / baseNameFontSize,
        ),
      );
      return (name: math.max(nameFloor, baseNameFontSize * scale), you: null);
    }

    final double youNaturalBase = naturalWidth(
      you,
      baseYouFontSize,
      FontWeight.normal,
    );

    if (nameNaturalBase + youNaturalBase <= available) {
      return (name: baseNameFontSize, you: baseYouFontSize);
    }

    final double availableForYouAtFullName = math.max(
      0.0,
      available - nameNaturalBase,
    );
    if (availableForYouAtFullName >=
            youNaturalBase * (youFloor / baseYouFontSize) ||
        youNaturalBase <= 0) {
      // The name keeps its own base size; "You" alone shrinks (never below
      // its own floor) to make room for it.
      final double youScale = youNaturalBase <= 0
          ? 1.0
          : math.min(
              1.0,
              math.max(
                (availableForYouAtFullName / youNaturalBase) * safetyMargin,
                youFloor / baseYouFontSize,
              ),
            );
      return (
        name: baseNameFontSize,
        you: math.max(youFloor, baseYouFontSize * youScale),
      );
    }

    // "You" at its own floor still leaves the name short of room: pin
    // "You" there and let the name shrink into what is left, never below
    // its own floor.
    final double youNaturalAtFloor = naturalWidth(
      you,
      youFloor,
      FontWeight.normal,
    );
    final double availableForName = math.max(
      0.0,
      available - youNaturalAtFloor,
    );
    final double nameScale = nameNaturalBase <= 0
        ? 1.0
        : math.min(
            1.0,
            math.max(
              (availableForName / nameNaturalBase) * safetyMargin,
              nameFloor / baseNameFontSize,
            ),
          );
    return (
      name: math.max(nameFloor, baseNameFontSize * nameScale),
      you: youFloor,
    );
  }

  /// [seat]'s name chip: a pill in [LudoColors.seats][seat], sat in the row
  /// of its yard that touches the real edge of the board (the top row for
  /// the two top yards, the bottom row for the two bottom ones), centred
  /// across the yard's own width. Contract C-264 rule A1 drops the old
  /// "never touch a yard token's 48dp hit box" test -- that hit box is
  /// bigger than the row itself at phone widths, which is exactly what left
  /// the chip a sliver -- for the narrower one the rule actually asks for:
  /// never paint over a yard token's own drawn disc. Rule A2 then sizes the
  /// chip from the row, not from whatever the tokens leave over: the row's
  /// full height less a small cosmetic inset, pulled back further only if a
  /// disc genuinely reaches into the row.
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

    // A2's "small inset", comfortably inside its "at most 15% of the cell"
    // ceiling, kept on the row's inner side so the chip still sits flush
    // against the board's real outer edge.
    final double cosmeticInset = cellSize * 0.10;
    double innerBound = edgeIsTop
        ? rowBottom - cosmeticInset
        : rowTop + cosmeticInset;

    // A1: pull back further only if a yard token's actual painted disc (not
    // its enlarged hit box) reaches into the row. At this board's own
    // proportions a yard slot's disc never does -- its own fan offset keeps
    // it inside the row next to the edge one -- but the rule reads "never
    // overlaps the disc", not "never overlaps it given today's numbers", so
    // the clamp stays rather than being assumed away.
    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
      final Rect discRect = _tokenDrawnRect(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: -1,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
      );
      if (discRect.bottom <= rowTop || discRect.top >= rowBottom) {
        continue;
      }
      if (edgeIsTop) {
        innerBound = math.min(innerBound, discRect.top);
      } else {
        innerBound = math.max(innerBound, discRect.bottom);
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
    // A2: about 60% of the chip height, never below 10 logical px -- the
    // old 7px floor is exactly what let the name itself go unreadable even
    // once the chip stopped being a sliver. These are the chip's own
    // *base* sizes -- what it draws when there is room -- not yet the
    // sizes it actually paints; C-339 decision 2 may shrink both of them
    // together, see `_fittedChipFontSizes` below.
    final double baseNameFontSize = math.max(10.0, chipHeight * 0.6);
    final double baseYouFontSize = math.max(7.0, chipHeight * 0.55);
    // Rule 3: the chip draws no disc of its own today (it is a plain pill
    // around the name); this is the one this rule adds, as tall as the
    // chip's inner content height -- chipHeight less the vertical padding
    // already applied below -- holding the seat's mark at half that disc's
    // own diameter.
    final double chipVerticalPadding = chipHeight * 0.08;
    final double nameDiscSize = math.max(
      0.0,
      chipHeight - chipVerticalPadding * 2,
    );
    // C-339 decision 1: the chip's text is board art, not system text --
    // it is measured and painted with no system scaling at all, the same
    // at every text-size setting. Width left for the name and "You" once
    // the fixed parts of the row (the two outer/inner paddings, the mark
    // disc, the spacer before the name, and -- when there is a "You" --
    // the spacer before it) are taken out.
    final double contentMaxWidth = math.max(0.0, chipWidth - cellSize * 1.0);
    final double textAvailableWidth = math.max(
      0.0,
      contentMaxWidth -
          nameDiscSize -
          cellSize * 0.15 -
          (you != null ? cellSize * 0.15 : 0.0),
    );
    final ({double name, double? you}) fittedFontSizes = _fittedChipFontSizes(
      name: name,
      you: you,
      baseNameFontSize: baseNameFontSize,
      baseYouFontSize: baseYouFontSize,
      available: textAvailableWidth,
      direction: Directionality.of(context),
      ambientStyle: DefaultTextStyle.of(context).style,
    );
    final double nameFontSize = fittedFontSizes.name;
    final double? youFontSize = fittedFontSizes.you;

    final BoardChatPop? pop = widget.chatPop;
    return Positioned(
      // Keyed so a turn glow coming and going in the list does not hand this
      // slot to another child and restart the pop. C-500 D6.
      key: ValueKey<String>('board-name-chip-slot-$seat'),
      left: chipLeft,
      top: chipTop,
      width: chipWidth,
      height: chipHeight,
      child: IgnorePointer(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: cellSize * 0.2),
            child: _ChipPop(
              seat: seat,
              fromTop: edgeIsTop,
              serial: (pop != null && pop.seat == seat) ? pop.serial : null,
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
                      Container(
                        key: Key('board-seat-name-$seat-mark'),
                        width: nameDiscSize,
                        height: nameDiscSize,
                        decoration: BoxDecoration(
                          color: seatColor,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: SeatMark(seat: seat, size: nameDiscSize * 0.5),
                        ),
                      ),
                      SizedBox(width: cellSize * 0.15),
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          // C-339 decision 1: pinned to the board's own
                          // measure, never the system text scale.
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: ink,
                            fontFamily: kLudoFontFamily,
                            fontFamilyFallback: kLudoFontFallbacks,
                            fontSize: nameFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (you != null) ...<Widget>[
                        SizedBox(width: cellSize * 0.15),
                        // Not `Flexible`: `_fittedChipFontSizes` already sized
                        // this and the name above it to share the chip's
                        // width honestly (by how wide each actually is at its
                        // own font size), not by `Flex`'s own equal-by-default
                        // split of whatever is left -- a plain child takes
                        // exactly the natural width that sizing computed, and
                        // the name's own `Flexible` absorbs whatever is left
                        // over (or, past the 10-character guarantee, still
                        // ellipsizes).
                        Text(
                          you,
                          key: const Key('board-seat-you'),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: ink,
                            fontFamily: kLudoFontFamily,
                            fontFamilyFallback: kLudoFontFallbacks,
                            fontSize: youFontSize,
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
                // C-471 D4: the hint arrow may stand above a token on the
                // top row, outside the board square. Without a hint the
                // clip is what it always was.
                clipBehavior: widget.hint != null ? Clip.none : Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BoardPainter(
                        seatsInPlay: widget.seatsInPlay,
                        mySeat: widget.mySeat,
                      ),
                    ),
                  ),
                  ..._safeSquareMarks(cellSize, widget.mySeat),
                  for (final seat in widget.seatsInPlay)
                    ..._seatIdentityLayer(seat: seat, cellSize: cellSize),
                  // C-465 D2, D4: above the yard glow, below the tokens,
                  // the thrown die, the safe cue and the face picker.
                  // One slot for the whole layer, so a die or a record
                  // appearing does not move the thrown-die overlay and
                  // restart its flight (C-465 D3).
                  Positioned.fill(
                    child: _SeatPieceLayer(pieces: _seatPieces(cellSize)),
                  ),
                  for (final int seat in _tokenPaintSeats())
                    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++)
                      ..._tokenLayer(
                        seat: seat,
                        tokenIndex: tokenIndex,
                        cellSize: cellSize,
                      ),
                  // C-471 D4: above my disc, under the thrown die and the
                  // face picker. IgnorePointer, so a tap lands on the token.
                  if (widget.hint != null && widget.mySeat != null)
                    _hintMarker(cellSize),
                  // C-468 D5: above tokens, seat dice and the record;
                  // below the thrown die and the face picker. IgnorePointer
                  // so the face never takes a tap.
                  if (widget.gloat != null) _gloatLayer(cellSize),
                  if (widget.overlay != null)
                    Positioned.fill(child: widget.overlay!),
                  if (widget.safeCue != null)
                    Positioned.fill(
                      child: _AnchoredSafeCue(
                        cue: widget.safeCue!,
                        cellSize: cellSize,
                        mySeat: widget.mySeat,
                      ),
                    ),
                  // C-462 D5: above every other layer, the thrown die and
                  // the safe cue included. Absent when [facePick] is null.
                  if (widget.facePick != null && widget.mySeat != null)
                    _anchoredFacePick(cellSize),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The viewed 6 by 6 yard of [seat]: its top-left and its side, in pixels.
  ({double left, double top, double side, BoardCell origin}) _viewedYard(
    double cellSize,
    int seat,
  ) {
    final BoardCell origin = yardQuadrantOrigin(seat);
    final ({int col, int row, int width, int height}) viewed = _viewBlock(
      col: origin.col,
      row: origin.row,
      width: yardQuadrantSide,
      height: yardQuadrantSide,
      quarters: viewQuarters(widget.mySeat),
    );
    return (
      left: viewed.col * cellSize,
      top: viewed.row * cellSize,
      side: yardQuadrantSide * cellSize,
      origin: BoardCell(viewed.col, viewed.row),
    );
  }

  /// C-468 D5. Diameter is two cells, centred on the viewed yard, the
  /// same point a seat die uses. Not shrunk out of the yard tokens' way:
  /// the face sits above them.
  Widget _gloatLayer(double cellSize) {
    final BoardGloat gloat = widget.gloat!;
    final int seat = gloat.seat;
    if (seat < 0 || seat > 3) {
      return const SizedBox.shrink();
    }
    final ({double left, double top, double side, BoardCell origin}) yard =
        _viewedYard(cellSize, seat);
    final Offset center = Offset(
      yard.left + yard.side / 2,
      yard.top + yard.side / 2,
    );
    final double diameter = cellSize * 2;
    return Positioned(
      left: center.dx - diameter / 2,
      top: center.dy - diameter / 2,
      width: diameter,
      height: diameter,
      child: IgnorePointer(
        child: CaptureGloat(
          seat: seat,
          serial: gloat.serial,
          diameter: diameter,
          cellSize: cellSize,
        ),
      ),
    );
  }

  /// C-465 D2 and D4, in paint order: dice, then the record.
  List<_SeatPiece> _seatPieces(double cellSize) {
    return <_SeatPiece>[
      ..._seatDiePieces(cellSize),
      ..._seatRecordPieces(cellSize),
    ];
  }

  /// C-465 D2. Centred on the yard. Side starts at two cells and shrinks,
  /// never moves, when a yard-slot disc of that seat reaches in. The same
  /// measurement [_nameChip] uses: [_tokenDrawnRect] at progress -1.
  List<_SeatPiece> _seatDiePieces(double cellSize) {
    if (widget.seatDice.isEmpty) {
      return const <_SeatPiece>[];
    }
    final List<_SeatPiece> layer = <_SeatPiece>[];
    for (final SeatDie die in widget.seatDice) {
      if (die.seat < 0 || die.seat > 3) {
        continue;
      }
      final ({double left, double top, double side, BoardCell origin}) yard =
          _viewedYard(cellSize, die.seat);
      final Offset center = Offset(
        yard.left + yard.side / 2,
        yard.top + yard.side / 2,
      );
      final double side = _seatDieSide(die.seat, cellSize, center);
      if (side <= 0) {
        continue;
      }
      final String name = widget.seatNames?[die.seat] ?? '';
      layer.add(
        _SeatPiece(
          id: 'die-${die.seat}',
          rect: Rect.fromCenter(center: center, width: side, height: side),
          child: IgnorePointer(
            child: SeatDieView(die: die, name: name, side: side),
          ),
        ),
      );
    }
    return layer;
  }

  /// Largest half-side of a square centred on [center] that does not
  /// overlap [disc]. Zero when the disc covers the centre.
  double _halfClearOf(Offset center, Rect disc) {
    final List<double> gaps = <double>[
      center.dx - disc.right,
      disc.left - center.dx,
      center.dy - disc.bottom,
      disc.top - center.dy,
    ];
    double best = 0;
    for (final double gap in gaps) {
      if (gap > best) {
        best = gap;
      }
    }
    return best;
  }

  double _seatDieSide(int seat, double cellSize, Offset center) {
    double half = cellSize;
    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
      final Rect disc = _tokenDrawnRect(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: -1,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
      );
      final double allowed = _halfClearOf(center, disc);
      if (allowed < half) {
        half = allowed;
      }
    }
    return half * 2;
  }

  /// C-465 D4. The yard row that touches the track, opposite the name
  /// chip's edge row. Height is that row less the name chip's cosmetic
  /// inset, pulled back further if a yard-slot disc reaches in. Width is
  /// the yard's. Centred across that width by [SeatYardRecord].
  List<_SeatPiece> _seatRecordPieces(double cellSize) {
    final SeatRollRecord? record = widget.seatRecord;
    if (record == null || record.seat < 0 || record.seat > 3) {
      return const <_SeatPiece>[];
    }
    final ({double left, double top, double side, BoardCell origin}) yard =
        _viewedYard(cellSize, record.seat);
    final bool yardOnTop = yard.origin.row == 0;
    final double rowTop = yardOnTop
        ? yard.top + (yardQuadrantSide - 1) * cellSize
        : yard.top;
    final double rowBottom = rowTop + cellSize;
    // The name chip's own inset, on the yard-interior side of this row.
    final double cosmeticInset = cellSize * 0.10;
    double innerBound = yardOnTop
        ? rowTop + cosmeticInset
        : rowBottom - cosmeticInset;
    for (var tokenIndex = 0; tokenIndex < 4; tokenIndex++) {
      final Rect disc = _tokenDrawnRect(
        seat: record.seat,
        tokenIndex: tokenIndex,
        progress: -1,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
      );
      if (disc.bottom <= rowTop || disc.top >= rowBottom) {
        continue;
      }
      if (yardOnTop) {
        innerBound = math.max(innerBound, disc.bottom);
      } else {
        innerBound = math.min(innerBound, disc.top);
      }
    }
    final double recordTop = yardOnTop ? innerBound : rowTop;
    final double recordBottom = yardOnTop ? rowBottom : innerBound;
    final double recordHeight = math.max(0.0, recordBottom - recordTop);
    if (recordHeight <= 0 || yard.side <= 0) {
      return const <_SeatPiece>[];
    }
    return <_SeatPiece>[
      _SeatPiece(
        id: 'record-${record.seat}',
        rect: Rect.fromLTWH(yard.left, recordTop, yard.side, recordHeight),
        child: KeyedSubtree(
          key: Key('board-seat-record-${record.seat}'),
          child: SeatYardRecord(record: record),
        ),
      ),
    ];
  }

  /// [LudoBoard.seatsInPlay], with [LudoBoard.mySeat] moved to the end so
  /// that seat's tokens paint after every other seat. The identity layer
  /// does not use this. A spectator view, or a viewer who is not in the
  /// list, keeps [seatsInPlay] order.
  List<int> _tokenPaintSeats() {
    final int? mine = widget.mySeat;
    final List<int> seats = widget.seatsInPlay;
    if (mine == null || !seats.contains(mine)) {
      return seats;
    }
    return <int>[
      for (final int seat in seats)
        if (seat != mine) seat,
      mine,
    ];
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

    // Hit target and ring follow truth. The disc follows [_drawnProgress],
    // which differs only mid-travel or mid-capture-hold. Both positions
    // come from [_tokenLayout].
    _TokenLayout layoutAt(int atProgress) {
      return _tokenLayout(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: atProgress,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
      );
    }

    // Contract C-408 decision 3: the drawn disc's own shared-vs-fan slot
    // reads every token's occupancy off its drawn position, not truth, so
    // a token already standing on the mover's destination keeps its own
    // layout until the mover's disc actually arrives there too.
    _TokenLayout layoutAtDrawn(int atProgress) {
      return _tokenLayout(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: atProgress,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
        progressOf: _drawnProgress,
      );
    }

    final _TokenLayout atTruth = layoutAt(progress);

    final bool isMine = seat == widget.mySeat;
    final bool legalHere = isMine && widget.legal.contains(tokenIndex);
    final bool autoMoveHere = isMine && widget.autoMoveToken == tokenIndex;
    final bool shakingHere = isMine && _shakingToken == tokenIndex;
    // C-422 D4: while a move is in flight for one of mine, every ring and
    // auto-move mark of mine is hidden, not only the lifted token's own.
    final bool liftActive =
        isMine && widget.interactive && widget.sentToken != null;
    final bool liftedHere = liftActive && widget.sentToken == tokenIndex;
    final int seatRank = _seatRank(seat, widget.mySeat);
    final OrdinalSortKey tokenSortKey = OrdinalSortKey(
      seatRank * 4.0 + tokenIndex,
    );

    // Contract C-408 decisions 1/2: a legal token carries no ring (and no
    // auto-move glow, nested inside it below) while its disc is drawn
    // anywhere other than its truth -- mid-travel, including the travel
    // out of the yard, or mid-capture-hold. The ring starts its pulse the
    // frame the disc actually reaches truth, driven by the very same
    // travel playback that moves the disc (decision 5: no new timer).
    final int drawnProgress = _drawnProgress(seat, tokenIndex);
    final bool atRestAtTruth = drawnProgress == progress;

    final List<Widget> layer = <Widget>[];

    if (isMine && widget.interactive) {
      final Rect hitRect = _tokenHitRect(
        seat: seat,
        tokenIndex: tokenIndex,
        progress: progress,
        cellSize: cellSize,
        mySeat: widget.mySeat,
        tokens: widget.tokens,
        seatsInPlay: widget.seatsInPlay,
      );
      final AppLocalizations loc = AppLocalizations.of(context);
      // C-471 A1: TalkBack reads this hit node, so the hint suffix is
      // appended to the label it already had. The drawn token node
      // below keeps no label.
      final String tokenLabel = loc.gameTokenButton(tokenIndex + 1);
      final MoveHint? hint = widget.hint;
      final String label;
      if (hint != null && hint.token == tokenIndex) {
        final String suffix = widget.hintNamesFace
            ? loc.hintTokenFaceSuffix(hint.face)
            : loc.hintTokenSuffix;
        label = '$tokenLabel, $suffix';
      } else {
        label = tokenLabel;
      }
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
            sortKey: tokenSortKey,
            button: true,
            label: label,
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

    if (legalHere && atRestAtTruth && !liftActive) {
      final double ringSize = atTruth.size * 1.7;
      // C-223 clarification 2: the legal ring key is present for every
      // legal token, the unique-legal token included; the faster glow key
      // nests around that same ring rather than drawing a second one on
      // top of it. The ring is centred on the token's own centre and
      // scales with the disc it marks.
      //
      // C-417 D1: the glow's own rate difference is gone -- every legal
      // ring, the unique-legal one included, breathes at the same 900ms
      // now, since the countdown arc nested inside the glow key below is
      // the hold's own signal.
      Widget ring = _PulsingRing(period: const Duration(milliseconds: 900));
      double markerSize = ringSize;
      if (autoMoveHere) {
        // D1: the arc's own radius clears the ring's outer edge by at
        // least 1.5x the ring's own peak stroke width (_PulsingRingState's
        // own ceiling, 4.0 reached at full pulse), on each side, so its
        // stroke and the ring's never touch.
        const double ringMaxStrokeWidth = 4.0;
        final double arcSize = ringSize + ringMaxStrokeWidth * 1.5 * 2;
        markerSize = arcSize;
        ring = KeyedSubtree(
          key: Key('board-automove-glow-$seat-$tokenIndex'),
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                key: Key('board-automove-arc-$seat-$tokenIndex'),
                width: arcSize,
                height: arcSize,
                child: const _AutoMoveArc(),
              ),
              SizedBox(width: ringSize, height: ringSize, child: ring),
            ],
          ),
        );
      }
      layer.add(
        Positioned(
          key: Key('board-legal-ring-$seat-$tokenIndex'),
          left: atTruth.center.dx - markerSize / 2,
          top: atTruth.center.dy - markerSize / 2,
          width: markerSize,
          height: markerSize,
          child: ring,
        ),
      );
    }

    // Contract C-252 rule 1: `cell` (board space) still feeds the
    // Semantics identifier. The hit target and the ring read [atTruth].
    // Only the drawn circle below reads `_drawnProgress` (already read
    // above as `drawnProgress`), which is truth too except mid-travel or
    // mid-capture-hold, through [layoutAtDrawn] so its own occupancy
    // follows decision 3. A step along the path is not an occupant of the
    // cell it is crossing, so it keeps the fan; the square it has actually
    // landed on takes the shared slot once every occupant there has
    // actually arrived.
    final _TokenLayout drawn = layoutAtDrawn(drawnProgress);
    final double drawnSize = drawn.size;
    final double drawnLeft = drawn.center.dx - drawnSize / 2;
    final double drawnTop = drawn.center.dy - drawnSize / 2;

    final Widget token = Semantics(
      key: Key('token-$seat-$tokenIndex'),
      identifier: 'cell-${cell.col}-${cell.row}',
      sortKey: tokenSortKey,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: LudoColors.seats[seat],
          border: Border.all(
            color: LudoColors.ink.withValues(alpha: 0.55),
            width: math.max(1, drawnSize * 0.06),
          ),
        ),
        // Rule 2: every token carries its seat's shape, centred, at half the
        // drawn disc's diameter, in every state this disc is ever drawn in
        // -- yard, track, home column, finished, mid-travel, mid-capture --
        // since all of those share this one `token` widget.
        child: Center(
          child: SeatMark(seat: seat, size: drawnSize * 0.5),
        ),
      ),
    );

    final _FlyingCapture? flying = _flying;
    if (flying != null && flying.seat == seat && flying.token == tokenIndex) {
      // Rule 4: this token stayed drawn on its own old square until the
      // mover's last step landed; now it flies home in a straight line.
      // `drawnLeft`/`drawnTop` here are truth's yard slot -- the capture
      // already cleared this pair's override in `_onMoveArrived`, so
      // `_drawnProgress` fell back to truth, which is already -1.
      // The flight starts at the centre [_tokenLayout] gives the old
      // square, in a box the size of the disc that is flying. Through
      // [layoutAtDrawn] for the same reason the disc itself reads it: by
      // the time this flight starts, this token's own drawn position has
      // already moved on (to -1 above), so it is never mistaken for still
      // occupying the old square it is departing, shared slot or not.
      final _TokenLayout fromLayout = layoutAtDrawn(flying.fromProgress);
      final double fromLeft = fromLayout.center.dx - drawnSize / 2;
      final double fromTop = fromLayout.center.dy - drawnSize / 2;
      layer.add(
        _CaptureFlight(
          key: Key('board-capture-flight-$seat-$tokenIndex'),
          from: Offset(fromLeft, fromTop),
          to: Offset(drawnLeft, drawnTop),
          size: drawnSize,
          duration: kCaptureFlightDuration,
          reducedDuration: kCaptureFlightDurationReduced,
          onArrived: () => _handleCaptureArrived(seat, tokenIndex),
          child: token,
        ),
      );
    } else if (shakingHere) {
      layer.add(
        Positioned(
          left: drawnLeft,
          top: drawnTop,
          width: drawnSize,
          height: drawnSize,
          child: _ShakeOnce(
            key: Key('board-token-shake-$seat-$tokenIndex'),
            size: drawnSize,
            child: token,
          ),
        ),
      );
    } else if (liftedHere) {
      // C-422 D4/D5: a state, not a tween -- scaled 1.18x about its own
      // centre with a soft drop shadow 2dp down, present at full strength
      // from the very first frame the key exists, reduced motion or not
      // (D5: "may ease in", never required to). The shadow's offset is a
      // fixed logical `Offset`, not run through Directionality, so it
      // reads the same in Arabic: light comes from above in both locales.
      // `drawnLeft`/`drawnTop`/`drawnSize` are truth's own box, unchanged
      // by the lift -- only the paint inside it scales, so neither layout
      // nor the hit target above moves.
      layer.add(
        Positioned(
          left: drawnLeft,
          top: drawnTop,
          width: drawnSize,
          height: drawnSize,
          child: KeyedSubtree(
            key: Key('board-token-lifted-$seat-$tokenIndex'),
            child: Transform.scale(
              scale: 1.18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: LudoColors.ink.withValues(alpha: 0.35),
                      blurRadius: drawnSize * 0.18,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: token,
              ),
            ),
          ),
        ),
      );
    } else {
      layer.add(
        Positioned(
          left: drawnLeft,
          top: drawnTop,
          width: drawnSize,
          height: drawnSize,
          child: token,
        ),
      );
    }

    return layer;
  }

  /// C-471 D4. The arrow stands wholly above the legal ring, one cell
  /// wide, so a first-time player finds it. The bob is 4 dp over about
  /// 900 ms; reduced motion holds it still. The face chip sits on the
  /// arrow and grows with it.
  Widget _hintMarker(double cellSize) {
    final MoveHint? hint = widget.hint;
    final int? seat = widget.mySeat;
    if (hint == null || seat == null) {
      return const SizedBox.shrink();
    }
    final List<int>? mine = widget.tokens[seat];
    if (mine == null || hint.token < 0 || hint.token >= mine.length) {
      return const SizedBox.shrink();
    }
    final int drawnProgress = _drawnProgress(seat, hint.token);
    final _TokenLayout drawn = _tokenLayout(
      seat: seat,
      tokenIndex: hint.token,
      progress: drawnProgress,
      cellSize: cellSize,
      mySeat: seat,
      tokens: widget.tokens,
      seatsInPlay: widget.seatsInPlay,
      progressOf: _drawnProgress,
    );
    final bool namesFace = widget.hintNamesFace;
    // The ring's outer edge, as _tokenLayer sizes it. The auto-move arc
    // clears that edge by 12 dp when this token carries it.
    final double ringSide =
        drawn.size * 1.7 + (widget.autoMoveToken == hint.token ? 12 : 0);
    final double ringTop = drawn.center.dy - ringSide / 2;
    final double chevronW = cellSize * _kHintArrowCells;
    final double chevronH = chevronW * 0.8;
    final double chipSide = namesFace ? chevronW * 0.8 : 0;
    final double gap = namesFace ? 2 : 0;
    final double contentH = chipSide + gap + chevronH;
    // The lowest point clears the ring by the bob's travel and the
    // outline's half stroke, so it never touches the ring (C-471 D4).
    final double clearance = _kHintBob + _hintOutlineWidth(chevronW) / 2 + 1;
    final double left = drawn.center.dx - chevronW / 2;
    final double top = ringTop - clearance - contentH;
    return Positioned(
      key: Key('board-hint-${hint.token}'),
      left: left,
      top: top,
      width: chevronW,
      height: contentH,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: _BobbingMarker(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (namesFace) _hintFaceChip(hint.face, chipSide),
                SizedBox(
                  width: chevronW,
                  height: chevronH,
                  child: CustomPaint(painter: const _HintChevronPainter()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The small die on the marker when D1 holds more than one face
  /// (C-471 D4). The numeral is the signal, not a colour.
  Widget _hintFaceChip(int face, double side) {
    return SizedBox(
      key: Key('board-hint-face-$face'),
      width: side,
      height: side,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: LudoColors.dieFace,
          borderRadius: BorderRadius.circular(side * 0.18),
          border: Border.all(color: LudoColors.dieEdge, width: 1),
        ),
        child: Center(
          child: Text(
            face.toString(),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LudoColors.ink,
              fontSize: side * 0.62,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// The hinted face, when this picker is open on the hinted token
  /// (C-471 D4). Null leaves the bubble unchanged.
  int? _hintedPickerFace(TokenFacePick pick) {
    final MoveHint? hint = widget.hint;
    if (hint == null || hint.token != pick.token) {
      return null;
    }
    if (!pick.faces.contains(hint.face)) {
      return null;
    }
    return hint.face;
  }

  /// C-462 D5: the bubble on the drawn centre of (mySeat, token), the same
  /// layout the disc is painted at. Above the token, or below when that
  /// would cross the board's top edge, then clamped inside the board.
  Widget _anchoredFacePick(double cellSize) {
    final TokenFacePick pick = widget.facePick!;
    final int seat = widget.mySeat!;
    final List<int>? progresses = widget.tokens[seat];
    if (progresses == null ||
        pick.token < 0 ||
        pick.token >= progresses.length) {
      return const SizedBox.shrink();
    }
    final int progress = _drawnProgress(seat, pick.token);
    final _TokenLayout layout = _tokenLayout(
      seat: seat,
      tokenIndex: pick.token,
      progress: progress,
      cellSize: cellSize,
      mySeat: seat,
      tokens: widget.tokens,
      seatsInPlay: widget.seatsInPlay,
      progressOf: _drawnProgress,
    );
    final double boardSide = cellSize * 15;
    final double width = facePickerBubbleWidth(pick.faces.length);
    final double aboveTop =
        layout.center.dy -
        layout.size / 2 -
        kFacePickerTipGap -
        kFacePickerBubbleHeight;
    final bool placeBelow = aboveTop < 0;
    final double left = _clampOrigin(
      layout.center.dx - width / 2,
      width,
      boardSide,
    );
    return CustomSingleChildLayout(
      delegate: _FacePickAnchorDelegate(
        center: layout.center,
        tokenRadius: layout.size / 2,
        placeBelow: placeBelow,
      ),
      child: TokenFacePickerBubble(
        key: ValueKey<int>(pick.token),
        pick: pick,
        placeBelow: placeBelow,
        pointerDx: layout.center.dx - left,
        hintedFace: _hintedPickerFace(pick),
      ),
    );
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

/// Places the face-picker bubble on the token (C-462 D5). [placeBelow] is
/// decided from the bubble's fixed height before layout; the position
/// itself uses the child's measured size, which matches that height.
class _FacePickAnchorDelegate extends SingleChildLayoutDelegate {
  _FacePickAnchorDelegate({
    required this.center,
    required this.tokenRadius,
    required this.placeBelow,
  });

  final Offset center;
  final double tokenRadius;
  final bool placeBelow;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: constraints.maxWidth,
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double rawLeft = center.dx - childSize.width / 2;
    final double rawTop = placeBelow
        ? center.dy + tokenRadius + kFacePickerTipGap
        : center.dy - tokenRadius - kFacePickerTipGap - childSize.height;
    return Offset(
      _clampOrigin(rawLeft, childSize.width, size.width),
      _clampOrigin(rawTop, childSize.height, size.height),
    );
  }

  @override
  bool shouldRelayout(covariant _FacePickAnchorDelegate oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.tokenRadius != tokenRadius ||
        oldDelegate.placeBelow != placeBelow;
  }
}

/// Puts [SafeCuePill] on the destination cell: centred above the cell,
/// below it when that cell is in the top row of the viewed board, then
/// shifted back inside the board square. C-384 S3.
class _AnchoredSafeCue extends StatelessWidget {
  const _AnchoredSafeCue({
    required this.cue,
    required this.cellSize,
    required this.mySeat,
  });

  final SafeCue cue;
  final double cellSize;
  final int? mySeat;

  @override
  Widget build(BuildContext context) {
    final BoardCell viewed = toView(
      cellFor(seat: cue.seat, progress: cue.progress),
      viewQuarters(mySeat),
    );
    return CustomSingleChildLayout(
      delegate: _SafeCueAnchorDelegate(cell: viewed, cellSize: cellSize),
      child: SafeCuePill(cue: cue),
    );
  }
}

class _SafeCueAnchorDelegate extends SingleChildLayoutDelegate {
  _SafeCueAnchorDelegate({required this.cell, required this.cellSize});

  final BoardCell cell;
  final double cellSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: constraints.maxWidth,
      maxHeight: constraints.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double gap = math.max(1.0, cellSize * 0.08);
    final double centerX = (cell.col + 0.5) * cellSize;
    final double rawLeft = centerX - childSize.width / 2;
    final double rawTop = cell.row == 0
        ? (cell.row + 1) * cellSize + gap
        : cell.row * cellSize - childSize.height - gap;
    return Offset(
      _clampOrigin(rawLeft, childSize.width, size.width),
      _clampOrigin(rawTop, childSize.height, size.height),
    );
  }

  @override
  bool shouldRelayout(covariant _SafeCueAnchorDelegate oldDelegate) {
    return oldDelegate.cell != cell || oldDelegate.cellSize != cellSize;
  }
}

/// Keeps a child of [childExtent] inside 0..[boardExtent]. A child that
/// is itself wider or taller than the board is pinned to the origin;
/// the pill scales down before that happens.
double _clampOrigin(double origin, double childExtent, double boardExtent) {
  final double room = boardExtent - childExtent;
  if (room <= 0) {
    return 0;
  }
  final double inset = math.min(1.0, room / 2);
  final double maxOrigin = boardExtent - childExtent - inset;
  if (origin < inset) {
    return inset;
  }
  if (origin > maxOrigin) {
    return maxOrigin;
  }
  return origin;
}

/// The star mark on each of the eight safe squares (RULES.md 1.3, contract
/// C-241), one per entry of [safeTrackSquares]. Painted above the board
/// painter and below every token layer so a token standing on a safe
/// square is never hidden under its own star, and wrapped in
/// [IgnorePointer] so the mark never answers a tap meant for the token on
/// it: a legal tap on a token that happens to sit on a safe square must
/// still resolve to exactly one move.
List<Widget> _safeSquareMarks(double cellSize, int? mySeat) {
  final int quarters = viewQuarters(mySeat);
  return <Widget>[
    for (final int absolute in safeTrackSquares)
      Positioned(
        key: Key('board-safe-$absolute'),
        left: toView(safeSquareCell(absolute), quarters).col * cellSize,
        top: toView(safeSquareCell(absolute), quarters).row * cellSize,
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

/// One truth change between two builds' `tokens`, before it has been
/// classified -- contract C-252 rule 2's raw material. `oldP`/`newP` are
/// that one token's progress before and after.
class _TokenDiff {
  const _TokenDiff({
    required this.seat,
    required this.token,
    required this.oldP,
    required this.newP,
  });

  final int seat;
  final int token;
  final int oldP;
  final int newP;
}

/// One move a board plays back: a mover (`seat`, `token`) travelling from
/// `oldProgress` to `newProgress`, plus the captured token it took, if any.
/// Built once per [_TokenDiff] pair that rule 2 accepts and never mutated;
/// `_LudoBoardState` tracks progress through it with its own fields.
class _Move {
  const _Move({
    required this.seat,
    required this.token,
    required this.oldProgress,
    required this.newProgress,
    this.capturedSeat,
    this.capturedToken,
    this.capturedOldProgress,
  });

  final int seat;
  final int token;
  final int oldProgress;
  final int newProgress;
  final int? capturedSeat;
  final int? capturedToken;
  final int? capturedOldProgress;
}

/// A captured token currently flying home: which one, and the progress its
/// old square was at -- the flight's visual starting point, contract C-252
/// rule 4. `_LudoBoardState` holds at most one at a time.
class _FlyingCapture {
  const _FlyingCapture({
    required this.seat,
    required this.token,
    required this.fromProgress,
  });

  final int seat;
  final int token;
  final int fromProgress;
}

/// The captured token's straight flight home, contract C-252 rule 4: a
/// plain linear interpolation from [from] to [to] in pixels over
/// [duration] ([reducedDuration] under reduced motion), reporting back
/// through [onArrived] once, the moment it lands -- never for a mid-flight
/// rebuild, only when the controller itself reaches its end. Its own ticker,
/// owned and disposed here exactly like [_PulsingRing] and [_TurnGlow]
/// above, which is also what satisfies rule 8 for it: this widget is only
/// ever in the tree for the length of one flight, and the framework tears
/// it down (ticker included) the moment `_LudoBoardState` stops drawing it.
class _CaptureFlight extends StatefulWidget {
  const _CaptureFlight({
    super.key,
    required this.from,
    required this.to,
    required this.size,
    required this.duration,
    required this.reducedDuration,
    required this.onArrived,
    required this.child,
  });

  final Offset from;
  final Offset to;
  final double size;
  final Duration duration;
  final Duration reducedDuration;
  final VoidCallback onArrived;
  final Widget child;

  @override
  State<_CaptureFlight> createState() => _CaptureFlightState();
}

class _CaptureFlightState extends State<_CaptureFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    _controller.duration = reduced ? widget.reducedDuration : widget.duration;
    _controller.forward();
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onArrived();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final Offset at = Offset.lerp(
          widget.from,
          widget.to,
          _controller.value,
        )!;
        return Positioned(
          left: at.dx,
          top: at.dy,
          width: widget.size,
          height: widget.size,
          child: widget.child,
        );
      },
    );
  }
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

/// C-471 D4: 4 dp up and down, one cycle about 900 ms. Reduced motion
/// holds the marker at rest. The shape is the signal; the colour matches
/// the legal ring.
class _BobbingMarker extends StatefulWidget {
  const _BobbingMarker({required this.child});

  final Widget child;

  @override
  State<_BobbingMarker> createState() => _BobbingMarkerState();
}

class _BobbingMarkerState extends State<_BobbingMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool? _reduced;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced == _reduced) {
      return;
    }
    _reduced = reduced;
    if (reduced) {
      _controller.stop();
      _controller.value = 0;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double dy = _reduced == true
            ? 0
            : math.sin(_controller.value * math.pi * 2) * _kHintBob;
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
      child: widget.child,
    );
  }
}

/// The marker's arrow is this many cells wide (C-471 D4).
const double _kHintArrowCells = 1.0;

/// Travel of the marker's bob, up and down (C-471 D4).
const double _kHintBob = 4;

double _hintOutlineWidth(double arrowWidth) => math.max(2.0, arrowWidth * 0.14);

class _HintChevronPainter extends CustomPainter {
  const _HintChevronPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path()
      ..moveTo(0, h * 0.08)
      ..lineTo(w * 0.5, h * 0.92)
      ..lineTo(w, h * 0.08)
      ..lineTo(w * 0.72, h * 0.08)
      ..lineTo(w * 0.5, h * 0.52)
      ..lineTo(w * 0.28, h * 0.08)
      ..close();
    // C-471 D4: the outline is the paintbox near-white, not a new hex.
    canvas.drawPath(
      path,
      Paint()
        ..color = LudoColors.actionOn
        ..style = PaintingStyle.stroke
        ..strokeWidth = _hintOutlineWidth(w)
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(path, Paint()..color = LudoColors.success);
  }

  @override
  bool shouldRepaint(covariant _HintChevronPainter oldDelegate) => false;
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

/// The unique-legal hold's own countdown, contract C-417 D1: a stroke in
/// [LudoColors.success], starting at 12 o'clock, whose sweep is
/// `remaining * 360` degrees. [remaining] runs from 1.0 (the frame the
/// glow first appears) to 0.0 (the frame the held move is actually sent),
/// so a full circle depletes clockwise, always anchored at the top, down
/// to nothing right as the send happens -- never on a clock of its own.
/// Public with a public field because the acceptance tests for this
/// contract read [remaining] straight off the painter.
class AutoMoveArcPainter extends CustomPainter {
  const AutoMoveArcPainter({required this.remaining, this.strokeWidth = 3.0});

  final double remaining;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double clamped = remaining.clamp(0.0, 1.0);
    if (clamped <= 0) {
      return;
    }
    final Rect rect = (Offset.zero & size).deflate(strokeWidth / 2);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      clamped * 2 * math.pi,
      false,
      Paint()
        ..color = LudoColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant AutoMoveArcPainter oldDelegate) =>
      oldDelegate.remaining != remaining ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// Hosts [AutoMoveArcPainter]'s own clock: one [AnimationController] of
/// [kAutoMoveHold], started once on this element's first frame and never
/// again -- a rebuild of the board, a new frame under the same decision, a
/// locale or text-scale change all reuse this same State (it lives inside
/// the `board-automove-glow-S-T` `KeyedSubtree`, which does not get torn
/// down for any of those), so none of them restarts the arc. Only a new
/// decision -- the glow key leaving the tree and a fresh one appearing --
/// tears this element down and the next one starts fresh at 1.0, exactly
/// contract C-417 D2's own "a new decision starts a new arc at 1.0".
///
/// D3: under `MediaQuery.disableAnimationsOf`, [remaining] does not track
/// the controller's own interpolated value -- it holds at 1.0, 2/3 and
/// 1/3 for the 500ms spans starting at 0, 500 and 1000ms after this
/// widget's first frame, then 0.0 once the controller completes at
/// [kAutoMoveHold], read off the controller's own elapsed duration in
/// whole milliseconds rather than its fractional `value`, so the three
/// held readings land on the exact fractions the contract names rather
/// than whatever a `1/1500` division happens to round to.
class _AutoMoveArc extends StatefulWidget {
  const _AutoMoveArc();

  @override
  State<_AutoMoveArc> createState() => _AutoMoveArcState();
}

class _AutoMoveArcState extends State<_AutoMoveArc>
    with SingleTickerProviderStateMixin {
  static const List<double> _reducedSteps = <double>[1.0, 2 / 3, 1 / 3, 0.0];

  late final AnimationController _controller;
  bool _reduced = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kAutoMoveHold);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _remaining {
    if (!_reduced) {
      return 1.0 - _controller.value;
    }
    final int elapsedMs = _controller.lastElapsedDuration?.inMilliseconds ?? 0;
    final int step = (elapsedMs ~/ 500).clamp(0, _reducedSteps.length - 1);
    return _reducedSteps[step];
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: AutoMoveArcPainter(remaining: _remaining),
          );
        },
      ),
    );
  }
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
  const _BoardPainter({required this.seatsInPlay, this.mySeat});

  /// Which seats are playing, same list [LudoBoard] was given. A seat not
  /// in it gets its yard fill muted -- C-248 rule 4, the one default change
  /// this contract makes: today's drawing painted every yard the same
  /// whether or not anyone sat there.
  final List<int> seatsInPlay;

  /// The seat this board is drawn for. Null is today's unrotated layout.
  final int? mySeat;

  @override
  void paint(Canvas canvas, Size size) {
    final cellSize = size.width / 15;
    final int quarters = viewQuarters(mySeat);

    canvas.drawRect(Offset.zero & size, Paint()..color = LudoColors.dieFace);

    for (var seat = 0; seat < 4; seat++) {
      final BoardCell origin = yardQuadrantOrigin(seat);
      final ({int col, int row, int width, int height}) viewed = _viewBlock(
        col: origin.col,
        row: origin.row,
        width: yardQuadrantSide,
        height: yardQuadrantSide,
        quarters: quarters,
      );
      final bool inPlay = seatsInPlay.contains(seat);
      final double yardAlpha = inPlay ? 0.16 : 0.16 * 0.35;
      _fillCells(
        canvas,
        cellSize,
        viewed.col,
        viewed.row,
        viewed.width,
        viewed.height,
        LudoColors.seats[seat].withValues(alpha: yardAlpha),
      );
    }

    for (var seat = 0; seat < 4; seat++) {
      for (var progress = 52; progress <= 56; progress++) {
        final cell = toView(cellFor(seat: seat, progress: progress), quarters);
        _fillCell(
          canvas,
          cellSize,
          cell,
          LudoColors.seats[seat].withValues(alpha: 0.32),
        );
      }
    }

    for (var progress = 0; progress < 52; progress++) {
      final cell = toView(cellFor(seat: 0, progress: progress), quarters);
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
      final cell = toView(cellFor(seat: seat, progress: 0), quarters);
      _fillCell(
        canvas,
        cellSize,
        cell,
        LudoColors.seats[seat].withValues(alpha: 0.85),
      );
    }

    final ({int col, int row, int width, int height}) centre = _viewBlock(
      col: 6,
      row: 6,
      width: 3,
      height: 3,
      quarters: quarters,
    );
    _fillCells(
      canvas,
      cellSize,
      centre.col,
      centre.row,
      centre.width,
      centre.height,
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
      oldDelegate.mySeat != mySeat ||
      !_sameSeats(oldDelegate.seatsInPlay, seatsInPlay);
}

/// How long the speaker's name chip takes to swell, and to settle back.
/// C-500 D6.
const Duration _kChipPopUp = Duration(milliseconds: 120);
const Duration _kChipPopDown = Duration(milliseconds: 180);
const double _kChipPopPeak = 1.15;

/// Scales its child from 1.0 to 1.15 (easeOut) and back to 1.0 (easeIn) once
/// whenever [serial] is one it has not shown. The root is always a
/// `Transform.scale` keyed `board-chip-pop-<seat>`, at 1.0 when idle. Under
/// `MediaQuery.disableAnimations` it never scales: the line in the header
/// band carries the meaning. The scale is anchored on the chip's outer edge
/// ([fromTop]: top-centre, else bottom-centre) because the chip sits flush on
/// the board's edge and the board clips, so it grows inward. C-500 D6.
class _ChipPop extends StatefulWidget {
  const _ChipPop({
    required this.seat,
    required this.fromTop,
    required this.serial,
    required this.child,
  });

  final int seat;
  final bool fromTop;
  final int? serial;
  final Widget child;

  @override
  State<_ChipPop> createState() => _ChipPopState();
}

class _ChipPopState extends State<_ChipPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  int? _shownSerial;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: _kChipPopUp + _kChipPopDown,
    );
    _pop();
  }

  @override
  void didUpdateWidget(covariant _ChipPop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pop();
  }

  void _pop() {
    final int? serial = widget.serial;
    if (serial == null || serial == _shownSerial) {
      return;
    }
    _shownSerial = serial;
    _clock.forward(from: 0);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  double _scaleAt(double ms) {
    final double up = _kChipPopUp.inMilliseconds.toDouble();
    final double down = _kChipPopDown.inMilliseconds.toDouble();
    if (ms <= 0 || ms >= up + down) {
      return 1;
    }
    if (ms <= up) {
      return 1 + (_kChipPopPeak - 1) * Curves.easeOut.transform(ms / up);
    }
    return 1 +
        (_kChipPopPeak - 1) * (1 - Curves.easeIn.transform((ms - up) / down));
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _clock,
      builder: (BuildContext context, Widget? child) {
        final double ms = _clock.value * _clock.duration!.inMilliseconds;
        return Transform.scale(
          key: Key('board-chip-pop-${widget.seat}'),
          scale: reduced ? 1 : _scaleAt(ms),
          alignment: widget.fromTop
              ? Alignment.topCenter
              : Alignment.bottomCenter,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
