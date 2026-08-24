// docs/ENGINE_API.md section 4.

import 'enums.dart';
import 'events.dart';
import 'game_state.dart';

sealed class ApplyResult {
  const ApplyResult();
}

class Applied extends ApplyResult {
  const Applied(this.state, this.events);

  /// The new state.
  final GameState state;

  /// Ordered, see docs/ENGINE_API.md section 6.
  final List<GameEvent> events;

  @override
  String toString() => 'Applied(state: $state, events: $events)';
}

class Rejected extends ApplyResult {
  const Rejected(this.error);

  final EngineError error;

  @override
  String toString() => 'Rejected(error: $error)';
}
