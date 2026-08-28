// docs/ENGINE_API.md section 2. The spec shows the field list for
// GameConfig without a constructor signature (unlike RulesConfig, which
// shows one explicitly). The named, defaultable-rules constructor below
// mirrors RulesConfig's own style; see the work order report for this as a
// flagged ambiguity.

import 'rules_config.dart';

/// What a game is: who is seated, which rule toggles are on, and the seed
/// that drives every future die roll.
class GameConfig {
  GameConfig({
    required List<int> seats,
    this.rules = const RulesConfig(),
    required this.seed,
  }) : seats = List<int>.unmodifiable(seats);

  /// Occupied seat indices, ascending, unique, length 2..4. Rule 2.
  final List<int> seats;

  final RulesConfig rules;

  /// 64-bit, from the server CSPRNG. Never sent to a client.
  ///
  /// No longer read by the engine as of rule 38 (docs/RULES.md): the die
  /// face now rides in `RollIntention` and the engine draws nothing from
  /// this seed. It is kept on `GameConfig` only because dropping it would
  /// break `packages/ludo_server`'s `seed_commit` computation; that removal
  /// belongs to the protocol order that follows this one
  /// (`docs/FAIRNESS.md` section 7 item 3).
  final int seed;

  @override
  bool operator ==(Object other) {
    if (other is! GameConfig) {
      return false;
    }
    if (seed != other.seed || rules != other.rules) {
      return false;
    }
    if (seats.length != other.seats.length) {
      return false;
    }
    for (var i = 0; i < seats.length; i++) {
      if (seats[i] != other.seats[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(seats), rules, seed);

  @override
  String toString() => 'GameConfig(seats: $seats, rules: $rules, seed: $seed)';
}
