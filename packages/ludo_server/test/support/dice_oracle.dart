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
// an integer index (`SHA-256` of a fixed label and the index -- already
// exactly 32 bytes, so no expansion step is needed), so the same search run
// twice, in the same or a different process, tries candidates in the same
// order and finds the same secret.

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

/// A deterministic, well-distributed 32-byte candidate secret for
/// [findSecretForFaces]'s search: `SHA-256("dice-steering-candidate|<index>")`,
/// which is already exactly 32 bytes. The same [index] always produces the
/// same candidate, in this process or any other.
List<int> candidateSecretAt(int index) =>
    sha256.convert(utf8.encode('dice-steering-candidate|$index')).bytes;

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
SteeredSecret findSecretForFaces({
  required List<int> wanted,
  required String gameId,
  required String clientSeeds,
  List<int> Function(int candidateIndex) nextCandidate = candidateSecretAt,
  int maxCandidates = 200000,
  int chainLength = defaultChainLength,
}) {
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
  throw StateError(
    'no secret among $maxCandidates candidates (indices 0..'
    '${maxCandidates - 1}) produced the wanted face sequence $wanted for '
    'game_id=$gameId, client_seeds=$clientSeeds; expected roughly '
    '6^${wanted.length} candidates on average, so this should not happen -- '
    'rerun with a larger maxCandidates if it does, and report it, since a '
    'search this far from its own expectation is itself worth investigating',
  );
}

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
