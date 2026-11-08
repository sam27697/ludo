/// C-590 D1: the one definition of "next". Turn order is ascending seat
/// index over the seats in play, wrapping to the lowest (docs/RULES.md rule
/// 4). Works on a sorted, de-duplicated copy of [seatsInPlay]. Null when
/// fewer than two seats remain or [current] is not one of them; otherwise
/// the seat after [current].
int? nextSeatInPlay(List<int> seatsInPlay, int current) {
  final List<int> ordered = seatsInPlay.toSet().toList()..sort();
  if (ordered.length < 2) {
    return null;
  }
  final int at = ordered.indexOf(current);
  if (at == -1) {
    return null;
  }
  return ordered[(at + 1) % ordered.length];
}
