// Board geometry, docs/RULES.md section 1. Kept in one place because every
// place that converts between a seat's progress and the shared 52-square
// track is exactly where the safe-square and block bugs live.

/// Entry (absolute) square for each seat index, rule 1.1.
const List<int> seatEntrySquare = [0, 13, 26, 39];

/// The eight safe squares, rule 1.3: the four entry squares plus the square
/// eight ahead of each.
const List<int> _safeAbsoluteSquares = [0, 8, 13, 21, 26, 34, 39, 47];

/// The absolute main-track square (0..51) a seat's token occupies at a given
/// main-track progress (0..51). Not meaningful for progress outside that
/// range; callers must check first.
int absoluteSquare(int seat, int progress) =>
    (seatEntrySquare[seat] + progress) % 52;

/// Whether an absolute main-track square is one of the eight safe squares.
bool isSafeSquare(int absolute) {
  for (final s in _safeAbsoluteSquares) {
    if (s == absolute) {
      return true;
    }
  }
  return false;
}
