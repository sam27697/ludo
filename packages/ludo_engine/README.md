# ludo_engine

Pure Ludo rules engine: the board, the tokens, the legal-move generator and
the state transition, modelled as immutable data and two functions,
`newGame` and `apply`. See `docs/ENGINE_API.md` for the frozen public
interface and `docs/RULES.md` for the rules those functions implement.

This package has no dependency beyond the Dart SDK and `test` as a dev
dependency: no clock, no network, no file access, no global mutable state.
Every roll comes from the seeded SplitMix64 generator carried in
`GameState.rngState`; given the same seed and the same ordered list of
intentions, `apply` produces byte-identical state on any machine, every
time.

What this package is not: a server, a protocol, a client, a bot, a timer.
The 45-second turn clock in `docs/RULES.md` rule 14 lives in the server; this
engine only ever sees the move that results from it, submitted as an
ordinary `MoveIntention`.

## Layout

- `lib/ludo_engine.dart` -- the single public entry point.
- `lib/src/` -- implementation. Not part of the public API.
- `tool/generate_corpus.dart` -- plays complete games from seeds and writes
  the golden corpus that `test/golden_replay_test.dart` replays. Run from
  this directory, writing outside the repository: `dart run
  tool/generate_corpus.dart --games 40 --out /tmp/corpus.jsonl`.

  `test/golden/corpus.jsonl` is committed, and it is written only by whoever
  reviewed the engine, only after that review passed. Do not regenerate it to
  make a failing golden gate go green. A hash that changes is a defect until
  someone proves it was an intended rule change; regenerating the corpus proves
  nothing except that the code agrees with itself.

## The shared release

With `rules.sharedRelease` (which needs `yardRelease`) the exceptional release
of rule 11r is an offer: the seat takes it with a `MoveIntention` of a
releasable token and no face, or declines it with a `DeclineIntention`. A
taken release ends the turn and banks one six for every other playing seat;
`state.banked` holds the counts and the next turn of a seat with a bank begins
with that many 6s in its queue. `docs/ENGINE_API.md` section 13 is the spec.
With the toggle off nothing differs, byte for byte.
