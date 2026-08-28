// The board geometry: where a token sits, given its seat and its progress.
//
// The whole file is pure integer arithmetic over a 15 by 15 grid. It has no
// Flutter dependency on purpose, so it can be exercised by a plain Dart test
// and reasoned about without a render tree. lib/src/board.dart re-exports it.
//
// Layout, decided once here and never restated anywhere else:
//
//   col 0 is the left edge, row 0 is the top edge, both 0..14.
//   Four 6 by 6 yards fill the corners. A cross three cells wide (columns 6
//   to 8 and rows 6 to 8) fills the rest.
//   The 52-square track is the ring running out along one side of each arm
//   of the cross, around the tip, and back along the other side.
//   Each seat's home column is the five middle cells of its own arm, running
//   inward toward the centre. The centre 3 by 3 block is where finished
//   tokens sit.
//
// Everything below is generated from one quarter of the board and three
// applications of a 90 degree rotation about the centre (7, 7). Nothing is
// hand-placed. That is deliberate: the four seats are rotations of each
// other by definition of the board, so making them rotations by construction
// removes the whole class of bug where one seat's entry square is off by a
// cell and the arithmetic that shares the track between seats stops holding.

import 'package:meta/meta.dart';

/// One cell of the 15 by 15 board grid.
///
/// [col] is board space, not screen space. Mirroring for a right-to-left
/// locale is the renderer's business and must not change these numbers.
@immutable
class BoardCell {
  const BoardCell(this.col, this.row);

  /// 0..14, 0 is the left edge in a left-to-right layout.
  final int col;

  /// 0..14, 0 is the top edge.
  final int row;

  @override
  bool operator ==(Object other) =>
      other is BoardCell && other.col == col && other.row == row;

  @override
  int get hashCode => Object.hash(col, row);

  @override
  String toString() => 'BoardCell($col, $row)';
}

/// A 90 degree clockwise rotation about the board centre (7, 7).
BoardCell _rotate(BoardCell c) => BoardCell(14 - c.row, c.col);

/// Applies [_rotate] [quarters] times.
BoardCell _rotateBy(BoardCell c, int quarters) {
  BoardCell out = c;
  for (int i = 0; i < quarters; i++) {
    out = _rotate(out);
  }
  return out;
}

/// Builds the four seats' versions of one seat-0 template by rotation.
List<List<BoardCell>> _rotations(List<BoardCell> seatZero) => <List<BoardCell>>[
  for (int seat = 0; seat < 4; seat++)
    <BoardCell>[for (final BoardCell c in seatZero) _rotateBy(c, seat)],
];

/// Seat 0's thirteenth of the ring: out along the top row of the left arm,
/// around the corner, up the left side of the top arm, and onto the tip.
///
/// Index 0 is seat 0's entry square. The step from (5, 6) to (6, 5) is one of
/// the four diagonal turns of the track; see BOARD_API.md property 3 for why
/// no 52-square ring on this board can avoid them.
const List<BoardCell> _trackQuarter = <BoardCell>[
  BoardCell(0, 6),
  BoardCell(1, 6),
  BoardCell(2, 6),
  BoardCell(3, 6),
  BoardCell(4, 6),
  BoardCell(5, 6),
  BoardCell(6, 5),
  BoardCell(6, 4),
  BoardCell(6, 3),
  BoardCell(6, 2),
  BoardCell(6, 1),
  BoardCell(6, 0),
  BoardCell(7, 0),
];

/// The 52 squares of the main track, in travel order, absolute.
///
/// A seat's `progress: p` is at index `(entry[seat] + p) % 52`, and the entry
/// offsets 0, 13, 26 and 39 fall out of the rotation rather than being
/// written down twice: index 13 is the rotation of index 0 by construction.
final List<BoardCell> _track = <BoardCell>[
  for (int quarter = 0; quarter < 4; quarter++)
    for (final BoardCell c in _trackQuarter) _rotateBy(c, quarter),
];

/// Entry offsets into [_track], one per seat. RULES.md section 1.2.
const List<int> _entry = <int>[0, 13, 26, 39];

/// The five home-column cells of each seat, `progress` 52 to 56 in order,
/// running inward toward the centre. Seat 0's is the middle row of the left
/// arm; the rest are rotations of it.
final List<List<BoardCell>> _homeColumn = _rotations(const <BoardCell>[
  BoardCell(1, 7),
  BoardCell(2, 7),
  BoardCell(3, 7),
  BoardCell(4, 7),
  BoardCell(5, 7),
]);

/// The four yard slots of each seat, by token index. Seat 0's yard is the
/// top-left 6 by 6 corner, the one its entry square (0, 6) sits beside.
final List<List<BoardCell>> _yard = _rotations(const <BoardCell>[
  BoardCell(1, 1),
  BoardCell(4, 1),
  BoardCell(1, 4),
  BoardCell(4, 4),
]);

/// Where each seat's finished tokens rest, by token index, inside the centre
/// 3 by 3 block. Seat 0 takes the side of the block its own arm arrives on,
/// plus the middle. Four distinct cells per seat is what lets a renderer draw
/// four finished tokens without stacking them into one.
final List<List<BoardCell>> _finished = _rotations(const <BoardCell>[
  BoardCell(6, 6),
  BoardCell(6, 7),
  BoardCell(6, 8),
  BoardCell(7, 7),
]);

/// The grid cell a token of [seat] sits in at [progress].
///
/// [progress] is the entire position: -1 is the yard, 0..51 the shared main
/// track, 52..56 the seat's own home column, 57 finished. See RULES.md
/// section 1.2, which is normative.
///
/// [tokenIndex] distinguishes the four yard slots and the four finished
/// slots of one seat. **For [progress] in 0..56 it is ignored entirely**, so
/// two tokens of one seat on one square return one cell and the renderer is
/// the thing that fans them out.
///
/// Throws [ArgumentError] if [seat] is outside 0..3, [progress] is outside
/// -1..57, or [tokenIndex] is outside 0..3. Reject, never repair.
BoardCell cellFor({
  required int seat,
  required int progress,
  int tokenIndex = 0,
}) {
  if (seat < 0 || seat > 3) {
    throw ArgumentError.value(seat, 'seat', 'must be 0..3');
  }
  if (progress < -1 || progress > 57) {
    throw ArgumentError.value(progress, 'progress', 'must be -1..57');
  }
  if (tokenIndex < 0 || tokenIndex > 3) {
    throw ArgumentError.value(tokenIndex, 'tokenIndex', 'must be 0..3');
  }

  if (progress == -1) {
    return _yard[seat][tokenIndex];
  }
  if (progress == 57) {
    return _finished[seat][tokenIndex];
  }
  if (progress >= 52) {
    return _homeColumn[seat][progress - 52];
  }
  return _track[(_entry[seat] + progress) % _track.length];
}
