// The backward hash chain of FAIRNESS.md section 2.1:
//
//   N = 4096
//   s[N] = 32 bytes from the server CSPRNG          (the server secret)
//   s[k-1] = SHA-256(s[k])                           for k = N .. 1
//   chain_commit = lowercase hex of s[0]
//
// This file draws no randomness itself: the server secret is handed in by
// the caller, already drawn. Everything here is a pure function of that
// secret.

import 'package:crypto/crypto.dart';

import 'hex.dart';

/// The chain length used everywhere in the fairness scheme unless a game
/// somehow runs past it, per section 2.1.
const int defaultChainLength = 4096;

/// Computes a single link `s[k]` of a chain of the given [chainLength]
/// rooted at [serverSecret] (`s[chainLength]`), by hashing backward
/// `chainLength - k` times.
///
/// This never holds more than one 32-byte value at a time: it does not
/// build the array of all links, so a caller who wants only `chain_commit`
/// (`k = 0`) or a handful of individual reveals never pays for the other
/// 4095. The cost is that each call redoes the hashing from the server
/// secret; a caller making many calls for the same secret and chain length
/// should use [DiceChain.build] instead, which pays for the whole chain
/// once and then answers every [DiceChain.revealBytes] call in O(1).
List<int> deriveChainLink(List<int> serverSecret, int chainLength, int k) {
  _checkChainLength(chainLength);
  _checkK(k, chainLength);
  var value = serverSecret;
  for (var i = chainLength; i > k; i--) {
    value = sha256.convert(value).bytes;
  }
  return value;
}

/// `chain_commit`: the lowercase hex of `s[0]` for a chain of the given
/// [chainLength] rooted at [serverSecret]. Published in the `room` frame
/// before any player has submitted anything.
///
/// Computed with [deriveChainLink], so this does not hold the full chain in
/// memory either: O(1) extra space beyond the running 32-byte hash.
String chainCommit(List<int> serverSecret,
    {int chainLength = defaultChainLength}) {
  return hexEncode(deriveChainLink(serverSecret, chainLength, 0));
}

/// A fully materialised hash chain: every link `s[chainLength] .. s[0]`
/// computed once and held in memory (`(chainLength + 1) x 32` bytes, about
/// 132 KB for the default length of 4096), so that [revealBytes] and
/// [reveal] answer in O(1) after construction.
///
/// Use this when a caller expects to look up many links from the same
/// secret, for example a server serving many rolls of one game. A caller
/// that wants only [commit] or a small, known set of reveals and would
/// rather not hold the array should call [deriveChainLink] or
/// [chainCommit] directly instead; those never build this array.
class DiceChain {
  DiceChain._(this.chainLength, this._links);

  /// Builds every link of the chain rooted at [serverSecret] up front.
  factory DiceChain.build(
    List<int> serverSecret, {
    int chainLength = defaultChainLength,
  }) {
    _checkChainLength(chainLength);
    final links = List<List<int>>.filled(chainLength + 1, const <int>[]);
    links[chainLength] = List<int>.unmodifiable(serverSecret);
    for (var k = chainLength; k > 0; k--) {
      links[k - 1] = sha256.convert(links[k]).bytes;
    }
    return DiceChain._(chainLength, List<List<int>>.unmodifiable(links));
  }

  /// `N`: the chain length this instance was built with.
  final int chainLength;

  final List<List<int>> _links;

  /// `s[k]` as raw bytes, `0 <= k <= chainLength`.
  List<int> revealBytes(int k) {
    _checkK(k, chainLength);
    return _links[k];
  }

  /// `s[k]` as lowercase hex, `0 <= k <= chainLength`.
  String reveal(int k) => hexEncode(revealBytes(k));

  /// `chain_commit`: the lowercase hex of `s[0]`.
  String get commit => hexEncode(_links[0]);
}

void _checkChainLength(int chainLength) {
  if (chainLength < 1) {
    throw ArgumentError.value(chainLength, 'chainLength', 'must be at least 1');
  }
}

void _checkK(int k, int chainLength) {
  if (k < 0 || k > chainLength) {
    throw RangeError.range(k, 0, chainLength, 'k');
  }
}
