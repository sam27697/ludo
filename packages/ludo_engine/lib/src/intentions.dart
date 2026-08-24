// docs/ENGINE_API.md section 3.

/// What a seat asks the engine to do. Carries the seat itself, so the
/// engine can reject an out-of-turn action without trusting the caller to
/// have checked.
sealed class Intention {
  const Intention(this.seat);

  final int seat;
}

/// Wire: "roll".
class RollIntention extends Intention {
  const RollIntention(super.seat);

  @override
  bool operator ==(Object other) =>
      other is RollIntention && other.seat == seat;

  @override
  int get hashCode => Object.hash(RollIntention, seat);

  @override
  String toString() => 'RollIntention(seat: $seat)';
}

/// Wire: "move" { "token": 0..3 }.
class MoveIntention extends Intention {
  const MoveIntention(super.seat, this.token);

  final int token;

  @override
  bool operator ==(Object other) =>
      other is MoveIntention && other.seat == seat && other.token == token;

  @override
  int get hashCode => Object.hash(MoveIntention, seat, token);

  @override
  String toString() => 'MoveIntention(seat: $seat, token: $token)';
}
