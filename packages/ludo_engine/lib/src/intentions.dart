// docs/ENGINE_API.md section 3.

/// What a seat asks the engine to do. Carries the seat itself, so the
/// engine can reject an out-of-turn action without trusting the caller to
/// have checked.
sealed class Intention {
  const Intention(this.seat);

  final int seat;
}

/// Wire: "roll". Rule 38: the engine draws no randomness, so the face rides
/// in the intention. The caller drew it; the engine only validates it.
class RollIntention extends Intention {
  const RollIntention(super.seat, this.face);

  /// The die value the caller drew, meant to be 1..6. A value outside that
  /// range is not rejected here; `apply` rejects it with `badFace`, per the
  /// check ladder in docs/ENGINE_API.md section 4.
  final int face;

  @override
  bool operator ==(Object other) =>
      other is RollIntention && other.seat == seat && other.face == face;

  @override
  int get hashCode => Object.hash(RollIntention, seat, face);

  @override
  String toString() => 'RollIntention(seat: $seat, face: $face)';
}

/// Wire: "move" { "token": 0..3 }.
class MoveIntention extends Intention {
  const MoveIntention(super.seat, this.token, {this.face});

  final int token;

  /// docs/ENGINE_API.md section 10.1: the queued face this move spends, when
  /// `rules.rollQueue` is on. Null means "the default face" -- see
  /// `defaultFace`. With `rollQueue` off this is ignored entirely: section 5's
  /// `MoveIntention` never read a face, and a field it never reads cannot
  /// change what it does.
  final int? face;

  @override
  bool operator ==(Object other) =>
      other is MoveIntention &&
      other.seat == seat &&
      other.token == token &&
      other.face == face;

  @override
  int get hashCode => Object.hash(MoveIntention, seat, token, face);

  @override
  String toString() => 'MoveIntention(seat: $seat, token: $token, face: $face)';
}
