// Offline dice-chain search used by `dice_steering_test.dart` to pick a
// server secret whose first few faces are a sequence chosen in advance,
// before a single frame is sent to a real server.
//
// docs/PROTOCOL.md section 12.1: on an accepted `roll`, the server takes
// `reveal = chain.reveal(k)` and `value = drawDie(reveal, game_id,
// client_seeds, k, 0)`. Section 11.2: the chain is rooted at a 32-byte server
// secret drawn once at room creation, and `s[k-1] = SHA-256(s[k])` for
// `k = chainLength .. 1`. Both `game_id` and `client_seeds` are fixed before
// the first roll and neither depends on the secret, so for a *known*
// `game_id` and `client_seeds`, the whole face sequence a room will produce
// is a pure function of that one secret. This file inverts that function:
// given a wanted prefix of faces, it searches for a secret that produces it.
//
// Nothing here is random. `candidateSecretAt` is a deterministic function of
// an integer index -- `T[index]`, where `T[0]` is a fixed 32-byte root and
// `T[m] = SHA-256(T[m-1])` -- so the same search run twice, in the same or a
// different process, tries candidates in the same order and finds the same
// secret.
//
// That `T` chain is also what makes the default search cheap. Consecutive
// candidates' reveal windows are the same walk of `T` shifted by one: with
// `L = chainLength`, candidate `i`'s reveal `s[j]` is `T[L - j + i]` and its
// `chain_commit` is `T[L + i]` (see `_findSecretForFacesFast` below for the
// derivation). Walking `T` once, forward, from `T[0]` to `T[L + maxCandidates]`
// and reading each candidate out of a small sliding window costs
// `L + maxCandidates` hashes total, instead of `L` hashes for every single
// candidate.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fair_dice/fair_dice.dart';

/// One secret found to reproduce a wanted prefix of faces, together with
/// enough of the chain to check it: [faces] and [reveals] for
/// `k = 1 .. faces.length`, in that order, and [chainCommit] (`s[0]`) so a
/// caller knows what the room's `room` frame is expected to publish, before
/// the room the secret describes even exists.
class SteeredSecret {
  const SteeredSecret({
    required this.secret,
    required this.faces,
    required this.reveals,
    required this.chainCommit,
  });

  /// The 32-byte server secret, `s[chainLength]`.
  final List<int> secret;

  /// `faces[i]` is the face rolled at `k = i + 1`; matches the `wanted` list
  /// [findSecretForFaces] was called with.
  final List<int> faces;

  /// `reveals[i]` is `s[i + 1]` (the reveal published with roll `k = i + 1`),
  /// 64 lowercase hex characters, in the same order as [faces].
  final List<String> reveals;

  /// `chain_commit`: `s[0]`, 64 lowercase hex characters.
  final String chainCommit;
}

/// `s[1] .. s[count]`, lowercase hex, computed by walking the chain once
/// from [secret] (`s[chainLength]`) down to `s[1]` -- the same recurrence
/// `package:fair_dice`'s `DiceChain.build` uses, without materialising all
/// `chainLength` links, since a search that tries thousands of candidate
/// secrets only ever needs a short prefix of each one's chain.
List<String> revealsFor(
  List<int> secret, {
  required int count,
  int chainLength = defaultChainLength,
}) {
  if (count < 1 || count > chainLength) {
    throw RangeError.range(count, 1, chainLength, 'count');
  }
  final List<String> out = List<String>.filled(count, '');
  List<int> value = secret;
  for (int k = chainLength; k >= 1; k--) {
    if (k <= count) {
      out[k - 1] = hexEncode(value);
    }
    value = sha256.convert(value).bytes;
  }
  return out;
}

/// Faces for roll `k = 1 .. count`, drawn exactly the way
/// `RoomRegistry.roll` draws them (`docs/PROTOCOL.md` section 12.1), from a
/// chain of [chainLength] rooted at [secret].
List<int> facesFor(
  List<int> secret, {
  required String gameId,
  required String clientSeeds,
  required int count,
  int chainLength = defaultChainLength,
}) {
  final List<String> reveals =
      revealsFor(secret, count: count, chainLength: chainLength);
  return <int>[
    for (int j = 0; j < count; j++)
      drawDie(reveals[j], gameId, clientSeeds, j + 1, 0),
  ];
}

/// `T[0]`: the fixed 32-byte root every candidate secret is ultimately
/// derived from. `SHA-256` of a fixed label, already exactly 32 bytes, so
/// no expansion step is needed.
final List<int> _candidateChainRoot =
    sha256.convert(utf8.encode('dice-steering-candidate-root')).bytes;

/// A deterministic, well-distributed 32-byte candidate secret for
/// [findSecretForFaces]'s search: `T[index]`, where `T[0]` is
/// [_candidateChainRoot] and `T[m] = SHA-256(T[m-1])`. The same [index]
/// always produces the same candidate, in this process or any other,
/// because the root is fixed and `SHA-256` carries no state beyond its
/// input.
///
/// [findSecretForFaces]'s default search does not call this function once
/// per candidate -- it walks the same `T` chain once, forward, and reads
/// every candidate out of a sliding window (`_findSecretForFacesFast`
/// below). This function exists so a caller (this file's own equivalence
/// test, in particular) can ask for one candidate's secret directly,
/// independently of that walk. Recomputing `T[index]` this way costs
/// [index] hashes from the root, so calling it directly for a large index
/// is exactly the cost the fast search avoids paying per candidate; this
/// is not that hot path.
List<int> candidateSecretAt(int index) {
  List<int> value = _candidateChainRoot;
  for (int m = 0; m < index; m++) {
    value = sha256.convert(value).bytes;
  }
  return value;
}

/// Searches candidate secrets, produced by calling [nextCandidate] with
/// `0, 1, 2, ...` in order, until one's first `wanted.length` faces equal
/// [wanted], for the given [gameId] and [clientSeeds]. Throws a
/// [StateError] carrying [wanted], [gameId] and [clientSeeds] -- everything
/// needed to reproduce the search -- if none of the first [maxCandidates]
/// candidates match.
///
/// A `k`-face [wanted] sequence matches an arbitrary secret's output with
/// probability `(1/6)^k` (each face is drawn by an HMAC construction with no
/// structural bias towards any wanted sequence over any other, per
/// `docs/FAIRNESS.md` section 2.3's rejection sampling), so the expected
/// number of candidates to try is `6^k`. [maxCandidates] defaults to
/// comfortably more than `6^5` for a five-face search.
///
/// When [nextCandidate] is left at its default, this does not walk the
/// full `chainLength`-link chain for every candidate the way [revealsFor]
/// would; see `_findSecretForFacesFast`'s doc comment for why that is safe.
/// A caller who supplies a different [nextCandidate] gets the general,
/// slower search, because the sliding-window trick depends on candidates
/// being consecutive links of one `T` chain, which only [candidateSecretAt]
/// is known to produce.
SteeredSecret findSecretForFaces({
  required List<int> wanted,
  required String gameId,
  required String clientSeeds,
  List<int> Function(int candidateIndex) nextCandidate = candidateSecretAt,
  int maxCandidates = 200000,
  int chainLength = defaultChainLength,
}) {
  if (identical(nextCandidate, candidateSecretAt)) {
    return _findSecretForFacesFast(
      wanted: wanted,
      gameId: gameId,
      clientSeeds: clientSeeds,
      maxCandidates: maxCandidates,
      chainLength: chainLength,
    );
  }
  for (int i = 0; i < maxCandidates; i++) {
    final List<int> secret = nextCandidate(i);
    final List<String> reveals =
        revealsFor(secret, count: wanted.length, chainLength: chainLength);
    final List<int> faces = <int>[
      for (int j = 0; j < wanted.length; j++)
        drawDie(reveals[j], gameId, clientSeeds, j + 1, 0),
    ];
    if (_sameFaces(faces, wanted)) {
      return SteeredSecret(
        secret: secret,
        faces: faces,
        reveals: reveals,
        chainCommit: chainCommit(secret, chainLength: chainLength),
      );
    }
  }
  throw StateError(_exhaustedMessage(
    wanted: wanted,
    gameId: gameId,
    clientSeeds: clientSeeds,
    maxCandidates: maxCandidates,
  ));
}

/// One candidate's reveals and `chain_commit`, as produced by
/// [_candidateWindowWalk].
typedef _WindowedCandidate = ({
  int index,
  List<String> reveals,
  String chainCommit,
});

/// Walks the `T` chain once, forward from `T[0]`, yielding candidate `0`,
/// `1`, `2`, ... in order, each with its reveals and `chain_commit` already
/// computed -- lazily, so a caller that stops early (both callers below do)
/// never pays for candidates past the one it needed.
///
/// [candidateSecretAt] defines candidate `i`'s secret as `T[i]`, where
/// `T[0]` is a fixed root and `T[m] = SHA-256(T[m-1])`. A candidate's own
/// chain (`s[chainLength] = T[i]`, `s[k-1] = SHA-256(s[k])`) is therefore
/// also a run of `T`: `s[k] = SHA-256^(chainLength-k)(T[i]) =
/// T[chainLength - k + i]`. Writing `L` for [chainLength], that gives, for
/// every candidate `i`:
///
///   reveal `s[j]` (`j = 1..count`) == `T[L - j + i]`
///   `chain_commit` (`s[0]`)        == `T[L + i]`
///
/// So keeping only the last `count + 1` values of the `T` walk gives every
/// candidate's full set of reveals and its `chain_commit` for free, in the
/// order candidates are tried: at the point the walk reaches `T[L + i]`,
/// the `count` values just before it in the walk are exactly candidate
/// `i`'s reveals. Reaching candidate `i` costs `L + i` hashes total to walk
/// `T`, instead of `L` hashes to walk a fresh chain rooted at candidate
/// `i`'s own secret the way [revealsFor] does.
///
/// This does not hand back a candidate's own secret (`T[i]` itself, not
/// kept once the window has scrolled past it) -- callers that need it call
/// [candidateSecretAt] directly, and only for the one candidate they end up
/// wanting, not for every candidate the walk passes through.
Iterable<_WindowedCandidate> _candidateWindowWalk({
  required int count,
  required int chainLength,
}) sync* {
  if (count < 1 || count > chainLength) {
    throw RangeError.range(count, 1, chainLength, 'count');
  }
  final int windowSize = count + 1;
  // window[m % windowSize] holds T[m] once T[m] has been computed; only the
  // most recent windowSize values are ever live at once.
  final List<List<int>> window =
      List<List<int>>.filled(windowSize, const <int>[]);

  List<int> tAtM = _candidateChainRoot; // T[0]
  int m = 0;
  while (true) {
    window[m % windowSize] = tAtM;
    if (m >= chainLength) {
      final int i = m - chainLength;
      final List<String> reveals = List<String>.filled(count, '');
      for (int j = 1; j <= count; j++) {
        reveals[j - 1] = hexEncode(window[(m - j) % windowSize]);
      }
      yield (index: i, reveals: reveals, chainCommit: hexEncode(tAtM));
    }
    m++;
    tAtM = sha256.convert(tAtM).bytes;
  }
}

/// The fast path [findSecretForFaces] takes for its default
/// [candidateSecretAt] generator: consumes [_candidateWindowWalk] until a
/// candidate's faces match [wanted] or [maxCandidates] is exhausted.
SteeredSecret _findSecretForFacesFast({
  required List<int> wanted,
  required String gameId,
  required String clientSeeds,
  required int maxCandidates,
  required int chainLength,
}) {
  final int count = wanted.length;
  for (final _WindowedCandidate candidate
      in _candidateWindowWalk(count: count, chainLength: chainLength)) {
    if (candidate.index >= maxCandidates) {
      break;
    }
    final List<int> faces = <int>[
      for (int j = 0; j < count; j++)
        drawDie(candidate.reveals[j], gameId, clientSeeds, j + 1, 0),
    ];
    if (_sameFaces(faces, wanted)) {
      return SteeredSecret(
        secret: candidateSecretAt(candidate.index),
        faces: faces,
        reveals: candidate.reveals,
        chainCommit: candidate.chainCommit,
      );
    }
  }
  throw StateError(_exhaustedMessage(
    wanted: wanted,
    gameId: gameId,
    clientSeeds: clientSeeds,
    maxCandidates: maxCandidates,
  ));
}

/// Candidate [index]'s reveals (`s[1]..s[count]`) and `chain_commit`,
/// computed the same way [findSecretForFaces]'s default search computes
/// them: by consuming [_candidateWindowWalk] up to [index], off a sliding
/// window of the `T` chain, rather than walking a full [chainLength]-link
/// chain rooted at that candidate's own secret the way [revealsFor] does.
///
/// This is not part of the search; it exists so `test/dice_oracle_test.dart`
/// can ask the fast path's own question -- "what does candidate `i`
/// produce?" -- for an arbitrary [index], not only for whichever index
/// [findSecretForFaces] happens to land on, and check the answer against
/// [revealsFor]'s independent full-chain walk.
({List<String> reveals, String chainCommit}) fastRevealsAndCommitAt(
  int index, {
  required int count,
  int chainLength = defaultChainLength,
}) {
  for (final _WindowedCandidate candidate
      in _candidateWindowWalk(count: count, chainLength: chainLength)) {
    if (candidate.index == index) {
      return (reveals: candidate.reveals, chainCommit: candidate.chainCommit);
    }
  }
  // _candidateWindowWalk never terminates on its own (it is an infinite
  // walk of T), so the loop above always returns before falling through.
  throw StateError('unreachable: _candidateWindowWalk did not reach index '
      '$index');
}

String _exhaustedMessage({
  required List<int> wanted,
  required String gameId,
  required String clientSeeds,
  required int maxCandidates,
}) =>
    'no secret among $maxCandidates candidates (indices 0..'
    '${maxCandidates - 1}) produced the wanted face sequence $wanted for '
    'game_id=$gameId, client_seeds=$clientSeeds; expected roughly '
    '6^${wanted.length} candidates on average, so this should not happen -- '
    'rerun with a larger maxCandidates if it does, and report it, since a '
    'search this far from its own expectation is itself worth investigating';

bool _sameFaces(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
