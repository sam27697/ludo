// SplitMix64, exactly as pinned in docs/ENGINE_API.md section 7. Nothing
// else in the engine consumes randomness; rngState changes only here.

const int _goldenGamma = 0x9E3779B97F4A7C15;
const int _mix1 = 0xBF58476D1CE4E5B9;
const int _mix2 = 0x94D049BB133111EB;

/// One SplitMix64 step. Returns the advanced generator state and the raw
/// 64-bit output for that step.
(int state, int output) splitMix64Next(int state) {
  final newState = state + _goldenGamma;
  var z = newState;
  z = (z ^ (z >>> 30)) * _mix1;
  z = (z ^ (z >>> 27)) * _mix2;
  z = z ^ (z >>> 31);
  return (newState, z);
}

/// Rejection threshold from docs/ENGINE_API.md: 2^32 - (2^32 mod 6).
const int splitMix64DieRejectionThreshold = 4294967292;

/// Draws one die face, 1..6, by rejection sampling over the top 32 bits of
/// a SplitMix64 step. A rejected draw still advances the state, per spec.
(int state, int value) rollDie(int state) {
  var current = state;
  while (true) {
    final (nextState, z) = splitMix64Next(current);
    final u = (z >>> 32) & 0xFFFFFFFF;
    if (u < splitMix64DieRejectionThreshold) {
      return (nextState, (u % 6) + 1);
    }
    current = nextState;
  }
}
