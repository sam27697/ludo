/// Verifiable dice: the backward hash chain, reveal verification, and the
/// HMAC-SHA256 die draw of `docs/FAIRNESS.md` sections 2.1 through 2.3.
///
/// This library is game-agnostic on purpose. It knows nothing about Ludo,
/// seats, boards or rules, and nothing about backgammon either beyond the
/// fact that a roll may ask for more than one die from the same reveal. A
/// game engine is a consumer of this library, never the other way around.
///
/// It is pure: no filesystem or process access, no wall clock, no
/// pseudo-random generator of its own. Every secret it works with was drawn
/// by the caller; this library only hashes, HMACs and hex-encodes.
library;

export 'src/chain.dart';
export 'src/die.dart';
export 'src/hex.dart';
export 'src/reveal.dart';
