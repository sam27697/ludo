// The fairness assertion order 014 requires: every `rolled` frame carries
// `k` and `reveal` (docs/PROTOCOL.md sections 11.2 and 12), the reveal
// verifies against the chain published at room creation using
// `package:fair_dice`'s own `verifyReveal`, and the face the server reported
// equals what `drawDie` computes from that reveal and the frozen client
// seeds. This file is pure bookkeeping on top of `fair_dice`; it never
// reimplements the cryptography itself.

import 'package:fair_dice/fair_dice.dart';

/// Thrown by [FairnessTracker.verifyRolled] when a `rolled` frame fails any
/// part of the fairness assertion. [message] names the `k` that broke and
/// exactly how, per the work order: "the reason line must say which `k`
/// broke and how."
class FairnessBreach implements Exception {
  FairnessBreach(this.message);
  final String message;
  @override
  String toString() => message;
}

bool _isLowercaseHex64(String s) {
  if (s.length != 64) {
    return false;
  }
  for (final int unit in s.codeUnits) {
    final bool isDigit = unit >= 0x30 && unit <= 0x39;
    final bool isLowerAF = unit >= 0x61 && unit <= 0x66;
    if (!isDigit && !isLowerAF) {
      return false;
    }
  }
  return true;
}

/// Verifies the whole chain of `rolled` frames observed for one game, in
/// the order they arrived on one socket. Holds the running "parent" reveal
/// -- `chain_commit` before the first roll, then each roll's own `reveal`
/// after it -- exactly as docs/FAIRNESS.md section 2.1 describes: "chaining
/// it back to the `chain_commit` they were given at the start."
class FairnessTracker {
  FairnessTracker({
    required this.chainCommit,
    required this.gameId,
    required this.clientSeeds,
  }) : _parentReveal = chainCommit;

  /// `s[0]`, published in `room` at room creation, before any player
  /// action. Section 11.1's ordering guarantee starts here.
  final String chainCommit;

  /// The `game_id` from `game_started`, the key of the HMAC message per
  /// docs/FAIRNESS.md section 2.3.
  final String gameId;

  /// The frozen `client_seeds` string from `game_started`, taken from the
  /// wire exactly as the server sent it rather than reassembled locally --
  /// section 11.2 is explicit that a client must "ship the exact bytes".
  final String clientSeeds;

  String _parentReveal;
  int _lastK = 0;

  /// How many `rolled` frames have been verified so far.
  int get rollsVerified => _lastK;

  /// Verifies one `rolled` frame's `d` payload. Throws [FairnessBreach] on
  /// the first thing that does not hold:
  ///
  ///  - `k` absent, not an integer, or not exactly the previous `k + 1`
  ///    (docs/PROTOCOL.md section 12.1: "`k` increments by exactly one per
  ///    roll");
  ///  - `reveal` absent or not 64 lowercase hex characters;
  ///  - `SHA-256(reveal)` not equal to the previous reveal, or to
  ///    `chain_commit` for the first roll (`verifyReveal`, section 2.1 of
  ///    docs/FAIRNESS.md);
  ///  - `value` absent, or not equal to what `drawDie(reveal, game_id,
  ///    client_seeds, k, 0)` computes (section 2.3 and section 11.2's "Ludo
  ///    always uses die index `d = 0`").
  void verifyRolled(Map<String, Object?> d) {
    final Object? kRaw = d['k'];
    if (kRaw is! int) {
      throw FairnessBreach(
        'rolled frame carries no integer "k" (got $kRaw); '
        'docs/PROTOCOL.md section 11.2 requires k on every rolled frame',
      );
    }
    final int k = kRaw;
    final int expectedK = _lastK + 1;
    if (k != expectedK) {
      throw FairnessBreach(
        'k=$k: expected k=$expectedK (k must increment by exactly one per '
        'roll, docs/PROTOCOL.md section 12.1); previous verified k was '
        '$_lastK',
      );
    }

    final Object? revealRaw = d['reveal'];
    if (revealRaw is! String || !_isLowercaseHex64(revealRaw)) {
      throw FairnessBreach(
        'k=$k: "reveal" is missing or not 64 lowercase hex characters '
        '(got $revealRaw)',
      );
    }
    final String reveal = revealRaw;

    if (!verifyReveal(reveal: reveal, parent: _parentReveal)) {
      throw FairnessBreach(
        'k=$k: reveal $reveal does not satisfy SHA-256(reveal) == '
        '$_parentReveal (the previous link, or chain_commit for k=1); the '
        'chain is broken at this roll',
      );
    }

    final Object? valueRaw = d['value'];
    if (valueRaw is! int) {
      throw FairnessBreach(
        'k=$k: "value" is missing or not an integer (got $valueRaw)',
      );
    }
    final int expectedFace = drawDie(reveal, gameId, clientSeeds, k, 0);
    if (valueRaw != expectedFace) {
      throw FairnessBreach(
        'k=$k: server reported value=$valueRaw but drawDie(reveal=$reveal, '
        'game_id=$gameId, client_seeds=$clientSeeds, k=$k, d=0) computed '
        'face=$expectedFace',
      );
    }

    _parentReveal = reveal;
    _lastK = k;
  }
}
