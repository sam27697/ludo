// docs/ENGINE_API.md section 6. Events describe what an accepted intention
// just did, in order; Applied.state is already the state after all of them.

import 'enums.dart';

sealed class GameEvent {
  const GameEvent();
}

class Rolled extends GameEvent {
  const Rolled({required this.seat, required this.value, required this.legal});

  final int seat;
  final int value;
  final List<int> legal;

  @override
  String toString() => 'Rolled(seat: $seat, value: $value, legal: $legal)';
}

class Moved extends GameEvent {
  const Moved({
    required this.seat,
    required this.token,
    required this.from,
    required this.to,
  });

  final int seat;
  final int token;
  final int from;
  final int to;

  @override
  String toString() =>
      'Moved(seat: $seat, token: $token, from: $from, to: $to)';
}

/// `seat`/`token` are the victim; `by`/`byToken` are the capturer.
class Captured extends GameEvent {
  const Captured({
    required this.seat,
    required this.token,
    required this.by,
    required this.byToken,
  });

  final int seat;
  final int token;
  final int by;
  final int byToken;

  @override
  String toString() =>
      'Captured(seat: $seat, token: $token, by: $by, byToken: $byToken)';
}

class TokenHome extends GameEvent {
  const TokenHome({required this.seat, required this.token});

  final int seat;
  final int token;

  @override
  String toString() => 'TokenHome(seat: $seat, token: $token)';
}

class ExtraRoll extends GameEvent {
  const ExtraRoll({required this.seat});

  final int seat;

  @override
  String toString() => 'ExtraRoll(seat: $seat)';
}

class TurnEnded extends GameEvent {
  const TurnEnded({required this.seat, required this.reason});

  final int seat;
  final TurnEndReason reason;

  @override
  String toString() => 'TurnEnded(seat: $seat, reason: $reason)';
}

class TurnBegan extends GameEvent {
  const TurnBegan({required this.seat});

  final int seat;

  @override
  String toString() => 'TurnBegan(seat: $seat)';
}

class GameWon extends GameEvent {
  const GameWon({required this.seat});

  final int seat;

  @override
  String toString() => 'GameWon(seat: $seat)';
}

/// docs/ENGINE_API.md section 11.1, rule 11r: the seat rolled no 6 for 10
/// rolls in a row with every token in the yard and is granted one release.
/// Emitted right after the `Rolled` of the tenth roll, whether or not a token
/// can come out (rule 14r).
class YardReleased extends GameEvent {
  const YardReleased({required this.seat});

  final int seat;

  @override
  String toString() => 'YardReleased(seat: $seat)';
}

/// docs/ENGINE_API.md section 13.1, rule 18s: the seat declined the release it
/// was offered; nothing came out and nothing is granted.
class ReleaseDeclined extends GameEvent {
  const ReleaseDeclined({required this.seat});

  final int seat;

  @override
  String toString() => 'ReleaseDeclined(seat: $seat)';
}

/// docs/ENGINE_API.md section 13.1, rule 17s: a release was taken and each of
/// [seats] (every other playing seat, ascending) is granted one banked six.
class SixesBanked extends GameEvent {
  const SixesBanked({required this.seats});

  final List<int> seats;

  @override
  String toString() => 'SixesBanked(seats: $seats)';
}

/// docs/ENGINE_API.md section 13.6, rule 19s: [count] banked sixes were put at
/// the front of [seat]'s queue as its turn began.
class SixesQueued extends GameEvent {
  const SixesQueued({required this.seat, required this.count});

  final int seat;
  final int count;

  @override
  String toString() => 'SixesQueued(seat: $seat, count: $count)';
}

/// docs/ENGINE_API.md section 12.1, rule 33p: `seat` brought its fourth token
/// home, or was the last seat playing, and takes `place` (1-based).
class SeatFinished extends GameEvent {
  const SeatFinished({required this.seat, required this.place});

  final int seat;
  final int place;

  @override
  String toString() => 'SeatFinished(seat: $seat, place: $place)';
}

/// docs/ENGINE_API.md section 12.1, rule 34p: the server retired `seat`.
class SeatRetired extends GameEvent {
  const SeatRetired({required this.seat});

  final int seat;

  @override
  String toString() => 'SeatRetired(seat: $seat)';
}
