// C-536 D1: one display name per seat, computed from the room's seats and
// nothing else. Two players who never typed a name both arrive as "Player";
// this is what tells their cards, dice, chat lines and announcements apart.
// Pure Dart on purpose: the screens hand in the localised `numbered` and
// every phone, seeing the same snapshot, derives the same label per seat.

import 'net/snapshot.dart' show SeatState;

/// The label to draw or speak for each seat in [seats], keyed by `seat`.
///
/// Seats are taken in ascending `seat` order and names are compared after
/// `trim()`, exactly (case and script as sent). The first seat holding a
/// name keeps it unchanged; the second holder gets `numbered(name, 2)`, the
/// third `numbered(name, 3)`, and so on. A name held once is unchanged.
Map<int, String> seatDisplayNames(
  Iterable<SeatState> seats,
  String Function(String name, int number) numbered,
) {
  final List<SeatState> ordered = List<SeatState>.of(seats)
    ..sort((SeatState a, SeatState b) => a.seat.compareTo(b.seat));
  final Map<String, int> held = <String, int>{};
  final Map<int, String> labels = <int, String>{};
  for (final SeatState seat in ordered) {
    final String key = seat.name.trim();
    final int count = (held[key] ?? 0) + 1;
    held[key] = count;
    labels[seat.seat] = count == 1 ? seat.name : numbered(seat.name, count);
  }
  return labels;
}
