// The HMAC-SHA256 die draw of FAIRNESS.md section 2.3:
//
//   msg    = "<game_id>|<client_seeds>|<k>|<d>"
//   digest = HMAC-SHA256(key = s[k], message = UTF-8 bytes of msg)
//
// digest read as eight big-endian 32-bit words; the first word u with
// u < 4294967292 gives the face (u mod 6) + 1. If all eight words of a
// round are rejected, re-HMAC with msg + "|r1", then "|r2", and so on.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'hex.dart';

/// `2^32 - (2^32 mod 6)`: the largest multiple of 6 that fits in 32 bits.
/// Accepting only words below this threshold makes every accepted word
/// equally likely to fall in each of the six residue classes mod 6, so
/// `u mod 6` carries no modulo bias.
const int rejectionThreshold = 4294967292;

/// The outcome of one draw: the [face] (1..6) and how many 32-bit words
/// were examined and rejected before it, including words from any re-HMAC
/// rounds. `wordsRejected` is 0 on the overwhelming majority of draws; it
/// exists so the rejection path can be exercised and counted in tests
/// without changing what callers who only want the face have to handle.
class DieDraw {
  const DieDraw({required this.face, required this.wordsRejected});

  /// The die face, 1 through 6 inclusive.
  final int face;

  /// How many 32-bit words (across all re-HMAC rounds) were rejected before
  /// [face] was accepted.
  final int wordsRejected;
}

/// Draws one die face for roll [k], die index [dieIndex], from the per-roll
/// secret [secret] (`s[k]`, lowercase hex), [gameId] and the frozen
/// [clientSeeds] string. [dieIndex] is `0` for a single die, and `0`/`1` for
/// the two dice of a backgammon roll drawn from the same reveal.
///
/// Returns only the face; use [drawDieDetailed] for the rejection count.
int drawDie(
  String secret,
  String gameId,
  String clientSeeds,
  int k,
  int dieIndex,
) {
  return drawDieDetailed(secret, gameId, clientSeeds, k, dieIndex).face;
}

/// As [drawDie], but also reports how many 32-bit words were rejected by
/// the sampling threshold before a face was accepted. See [DieDraw].
DieDraw drawDieDetailed(
  String secret,
  String gameId,
  String clientSeeds,
  int k,
  int dieIndex,
) {
  final key = hexDecode(secret);
  var round = 0;
  var wordsRejected = 0;
  while (true) {
    final suffix = round == 0 ? '' : '|r$round';
    final message = '$gameId|$clientSeeds|$k|$dieIndex$suffix';
    final mac = Hmac(sha256, key).convert(utf8.encode(message)).bytes;
    for (var word = 0; word < 8; word++) {
      final offset = word * 4;
      final u = (mac[offset] << 24) |
          (mac[offset + 1] << 16) |
          (mac[offset + 2] << 8) |
          mac[offset + 3];
      if (u < rejectionThreshold) {
        return DieDraw(face: (u % 6) + 1, wordsRejected: wordsRejected);
      }
      wordsRejected++;
    }
    round++;
  }
}
