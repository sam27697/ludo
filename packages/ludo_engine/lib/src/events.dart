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
