// A hand transcription of the dice generator specified in
// docs/ENGINE_API.md section 7. This file does not read, import or depend on
// anything under lib/src/; it exists so the rules tests can predict what the
// engine's own generator will draw from a given starting rngState, and so a
// handful of tests can pin the exact magic numbers the spec prints rather
// than trusting whatever the implementation happens to produce.
library;

const int goldenGamma = 0x9E3779B97F4A7C15;
const int mix1 = 0xBF58476D1CE4E5B9;
const int mix2 = 0x94D049BB133111EB;

// 2^32 - (2^32 mod 6), the rejection threshold from section 7.
const int rejectAtOrAbove = 4294967292;

/// One step of the underlying SplitMix64 generator. Returns the new 64-bit
/// state and the 64-bit output `z`, exactly as docs/ENGINE_API.md prints it.
(int, int) splitMix64Next(int state) {
  final int newState = state + goldenGamma;
  var z = newState;
  z = (z ^ (z >>> 30)) * mix1;
  z = (z ^ (z >>> 27)) * mix2;
  z = z ^ (z >>> 31);
  return (newState, z);
}

/// One die draw with rejection sampling, exactly as docs/ENGINE_API.md
/// section 7 specifies it. Returns the new rngState and a face 1..6.
(int, int) referenceRollDie(int state) {
  var s = state;
  while (true) {
    final (nextState, z) = splitMix64Next(s);
    s = nextState;
    final int u = (z >>> 32) & 0xFFFFFFFF;
    if (u < rejectAtOrAbove) {
      return (s, (u % 6) + 1);
    }
  }
}

/// Draws [count] consecutive faces from [state] using the reference
/// generator above, returning only the sequence of faces (not the states in
/// between). Used to compute an expected sequence "by hand" from the spec to
/// compare against what the engine actually produces from the same seed.
List<int> referenceRollSequence(int state, int count) {
  final List<int> faces = <int>[];
  var s = state;
  for (var i = 0; i < count; i++) {
    final (nextState, face) = referenceRollDie(s);
    s = nextState;
    faces.add(face);
  }
  return faces;
}

/// Searches, from [start], for the smallest rngState whose very next die
/// draw equals [want]. Used to build fixtures that need one controlled,
/// known die outcome without touching engine internals: the test picks the
/// rngState, the engine draws from it, and rule 5 of docs/RULES.md
/// guarantees the draw is a pure function of that state.
int findRngStateForNextRoll(int want, {int start = 1, int limit = 1000000}) {
  for (var s = start; s < start + limit; s++) {
    final (_, face) = referenceRollDie(s);
    if (face == want) {
      return s;
    }
  }
  throw StateError(
    'no rngState in [$start, ${start + limit}) produces a first roll of '
    '$want; widen the search window',
  );
}
