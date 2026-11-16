/// `docs/PROTOCOL.md` section 29: the grace the next seat's clock waits for
/// the last move to land. Pure arithmetic over the engine's events, no I/O,
/// so the registry and the tests share one reading of rule 2.
library;

import 'package:ludo_engine/ludo_engine.dart' as engine;

/// Milliseconds one square of a token's walk takes on the board. Mirrors the
/// client's `kTokenStepDuration`.
const int graceStepMs = 140;

/// Milliseconds a captured token's flight home takes. Mirrors the client's
/// `kCaptureFlightDuration`.
const int graceCaptureFlightMs = 360;

/// The hold after a step that sent `turn_passed`, either reason. Mirrors the
/// client's no-move hold (`_noMoveHold`).
const int graceNoMoveHoldMs = 1500;

/// The half second after everything has landed, in every other step.
const int graceSettleMs = 500;

/// Section 29 rule 2: the `grace_ms` of the `turn` frame a step ends with,
/// read off the step's own [events] and never off a state difference.
/// [actor] is the seat whose turn the step ended: the seat that rolled or
/// moved, or the seat that was retired while on turn (rule 7).
///
/// Null when the step's `turn` is not a grace's (rule 1): no `TurnBegan`, or
/// one for the seat that acted (it keeps the turn, a same-seat `turn`).
int? graceForStep(List<engine.GameEvent> events, int actor) {
  final Iterable<engine.TurnBegan> began = events.whereType<engine.TurnBegan>();
  if (began.isEmpty || began.last.seat == actor) {
    return null;
  }
  int travel = 0;
  final Iterable<engine.Moved> moved = events.whereType<engine.Moved>();
  if (moved.isNotEmpty) {
    final engine.Moved last = moved.last;
    final int steps = last.from >= 0 ? last.to - last.from : 1;
    travel = graceStepMs * steps;
    if (events.whereType<engine.Captured>().isNotEmpty) {
      travel += graceCaptureFlightMs;
    }
  }
  final bool passed = events.whereType<engine.TurnEnded>().isNotEmpty;
  return travel + (passed ? graceNoMoveHoldMs : graceSettleMs);
}
