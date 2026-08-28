// Reveal verification of FAIRNESS.md section 2.1: "A player verifies a
// reveal by hashing it once: SHA-256(s[k]) == s[k-1]". Deliberately does not
// depend on DiceChain: an offline client holding one `roll` frame has only
// that frame's reveal and the previous frame's reveal (or `chain_commit`
// when the previous roll is the first one), never a chain object.

import 'package:crypto/crypto.dart';

import 'hex.dart';

/// True if [reveal] hashes to [parent], i.e. `SHA-256(reveal) == parent`,
/// both given as lowercase hex. This is the whole check: chaining it back to
/// `chain_commit` is just calling this once per roll already played, each
/// time against the previous roll's reveal (or `chain_commit` itself for the
/// first roll).
///
/// [parent] is compared case-insensitively; the return value does not depend
/// on which case either argument was given in.
bool verifyReveal({required String reveal, required String parent}) {
  final digest = sha256.convert(hexDecode(reveal)).bytes;
  return hexEncode(digest) == parent.toLowerCase();
}
