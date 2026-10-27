// C-474 D1: why a roll had no legal move, worked out on the device from
// the snapshot the no-move notice already reads. Pure Dart so it is tested
// on its own; the rules behind it are docs/RULES.md section 3 (a 6 brings a
// token out of the yard, home must be reached by exact count).

/// The words the no-move line uses. [plain] is today's line, unchanged.
enum NoMoveReason { needSix, needExact, plain }

/// Progress value of a token still in the yard.
const int _yard = -1;

/// Progress value of a finished token.
const int _finished = 57;

/// The first reason that holds, in this order (C-474 D1):
///
/// 1. [NoMoveReason.needSix]: some token is unfinished, every unfinished
///    token is in the yard, and no face is a 6.
/// 2. [NoMoveReason.needExact]: some token is unfinished, none of them is in
///    the yard, and every face overshoots every unfinished token (`p + f > 57`).
/// 3. [NoMoveReason.plain]: anything else, including an empty [faces].
NoMoveReason noMoveReason({
  required List<int> myTokens,
  required List<int> faces,
}) {
  if (faces.isEmpty) {
    return NoMoveReason.plain;
  }
  final List<int> unfinished = <int>[
    for (final int progress in myTokens)
      if (progress != _finished) progress,
  ];
  if (unfinished.isEmpty) {
    return NoMoveReason.plain;
  }
  if (unfinished.every((int p) => p == _yard) && !faces.contains(6)) {
    return NoMoveReason.needSix;
  }
  if (!unfinished.any((int p) => p == _yard) &&
      faces.every((int f) => unfinished.every((int p) => p + f > _finished))) {
    return NoMoveReason.needExact;
  }
  return NoMoveReason.plain;
}
