// C-536 D1: one display name per seat, computed from the room's seats and
// nothing else. Two players who never typed a name both arrive as "Player";
// this is what tells their cards, dice, chat lines and announcements apart.
// The screens hand in the localised `numbered` and every phone, seeing the
// same snapshot, derives the same label per seat.
//
// C-706: a computer seat (docs/PROTOCOL.md section 34 item 1) is shown by its
// character's name in the app's language, never by the English name the wire
// carries. [seatShownName] is the one place that rule lives; every place a
// seat name is drawn or spoken reaches it, through [seatDisplayNames] or
// directly.

import '../l10n/gen/app_localizations.dart';
import 'net/snapshot.dart' show SeatState;

/// The name of computer character [bot] (1..6) in the app's language.
String botCharacterName(AppLocalizations loc, int bot) {
  switch (bot) {
    case 1:
      return loc.botName1;
    case 2:
      return loc.botName2;
    case 3:
      return loc.botName3;
    case 4:
      return loc.botName4;
    case 5:
      return loc.botName5;
    case 6:
      return loc.botName6;
    default:
      throw ArgumentError.value(bot, 'bot', 'must be 1..6');
  }
}

/// The name [seat] is shown by before any numbering: a computer seat's
/// character name in the app's language, otherwise the name the player sent.
String seatShownName(AppLocalizations loc, SeatState seat) {
  final int? bot = seat.bot;
  return bot == null ? seat.name : botCharacterName(loc, bot);
}

/// The label to draw or speak for each seat in [seats], keyed by `seat`.
///
/// Each seat's base name is `shownName(seat)`, or `seat.name` when
/// [shownName] is null. Seats are taken in ascending `seat` order and names
/// are compared after `trim()`, exactly (case and script as sent). The first
/// seat holding a name keeps it unchanged; the second holder gets
/// `numbered(name, 2)`, the third `numbered(name, 3)`, and so on. A name held
/// once is unchanged.
///
/// A computer seat is never numbered: its character name is what it is
/// called everywhere, and the characters in one room are distinct. It still
/// holds its name, so a player who typed the same name is numbered after it.
Map<int, String> seatDisplayNames(
  Iterable<SeatState> seats,
  String Function(String name, int number) numbered, {
  String Function(SeatState seat)? shownName,
}) {
  final List<SeatState> ordered = List<SeatState>.of(seats)
    ..sort((SeatState a, SeatState b) => a.seat.compareTo(b.seat));
  String base(SeatState seat) =>
      shownName == null ? seat.name : shownName(seat);
  final Map<String, int> held = <String, int>{};
  final Map<int, String> labels = <int, String>{};
  for (final SeatState seat in ordered) {
    if (seat.bot != null) {
      final String name = base(seat);
      held[name.trim()] = (held[name.trim()] ?? 0) + 1;
      labels[seat.seat] = name;
    }
  }
  for (final SeatState seat in ordered) {
    if (seat.bot != null) {
      continue;
    }
    final String name = base(seat);
    final String key = name.trim();
    final int count = (held[key] ?? 0) + 1;
    held[key] = count;
    labels[seat.seat] = count == 1 ? name : numbered(name, count);
  }
  return <int, String>{
    for (final SeatState seat in ordered) seat.seat: labels[seat.seat]!,
  };
}
