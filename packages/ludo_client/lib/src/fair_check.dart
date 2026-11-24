// The end card's own check of every roll of a finished game (C-704, doctrine
// P7 and P9). It is the check the verification page makes (docs/VERIFY.md
// section 7, checks 3 to 5), run on the device over the frames of the game:
//
//  - the rolls carry k = 1, 2, 3 ... in order, with no gap and no repeat;
//  - each reveal hashes back to the one before it, the first one to
//    `chain_commit`: SHA-256 over the reveal's bytes, docs/FAIRNESS.md
//    section 2.1;
//  - each face equals drawDie(reveal, game_id, client_seeds, k, 0),
//    docs/FAIRNESS.md section 2.3 with Ludo's die index 0 (PROTOCOL.md
//    section 11.2).
//
// The hashing and the draw are `packages/fair_dice`, the same code the
// server rolls with; nothing here reimplements them. Pure: no clock, no I/O,
// nothing sent anywhere.

import 'package:fair_dice/fair_dice.dart';
import 'package:flutter/foundation.dart';

import 'net/frame.dart';

enum FairVerdict { fair, mismatch }

/// The outcome of [checkFairness].
@immutable
class FairCheck {
  const FairCheck({
    required this.verdict,
    required this.rolls,
    this.badK,
    this.reason,
  });

  final FairVerdict verdict;

  /// How many rolls were checked: every roll of the game when [verdict] is
  /// fair; on a mismatch, the rolls up to and including the one that failed.
  final int rolls;

  /// The first roll number that failed, null when fair. On a `gap` it is the
  /// roll number that was due and did not come next. Null for
  /// `no_game_started` and `no_rolls`, which name no roll.
  final int? badK;

  /// `'gap'`, `'chain'`, `'value'`, `'no_game_started'` or `'no_rolls'`;
  /// null when fair.
  final String? reason;

  bool get isFair => verdict == FairVerdict.fair;

  @override
  bool operator ==(Object other) =>
      other is FairCheck &&
      other.verdict == verdict &&
      other.rolls == rolls &&
      other.badK == badK &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(verdict, rolls, badK, reason);

  @override
  String toString() =>
      'FairCheck(verdict: ${verdict.name}, rolls: $rolls, badK: $badK, '
      'reason: $reason)';
}

/// 64 lowercase hex characters: the shape of `chain_commit` and of every
/// `reveal` on the wire (PROTOCOL.md section 11.2).
final RegExp _link = RegExp(r'^[0-9a-f]{64}$');

/// Checks every `rolled` frame of [frames] against [chainCommit].
///
/// [frames] is a game's frames as `RoomController.fetchGameLog` returns
/// them: from the game's `game_started` on. Only the last `game_started` and
/// the `rolled` frames after it are read; every other frame is ignored. A
/// `game_started` without a string `game_id` and `client_seeds` cannot seed
/// a single draw and counts as no `game_started`.
FairCheck checkFairness({
  required String chainCommit,
  required List<Frame> frames,
}) {
  int start = -1;
  for (int i = 0; i < frames.length; i++) {
    if (frames[i].type == 'game_started') {
      start = i;
    }
  }
  if (start == -1) {
    return const FairCheck(
      verdict: FairVerdict.mismatch,
      rolls: 0,
      reason: 'no_game_started',
    );
  }
  final Object? gameId = frames[start].data['game_id'];
  final Object? clientSeeds = frames[start].data['client_seeds'];
  if (gameId is! String || clientSeeds is! String) {
    return const FairCheck(
      verdict: FairVerdict.mismatch,
      rolls: 0,
      reason: 'no_game_started',
    );
  }

  int checked = 0;
  String previous = chainCommit;
  for (int i = start + 1; i < frames.length; i++) {
    final Frame frame = frames[i];
    if (frame.type != 'rolled') {
      continue;
    }
    final int due = checked + 1;
    checked = due;
    FairCheck failed(String reason) => FairCheck(
      verdict: FairVerdict.mismatch,
      rolls: due,
      badK: due,
      reason: reason,
    );

    final Object? k = frame.data['k'];
    if (k is! int || k != due) {
      return failed('gap');
    }
    final Object? reveal = frame.data['reveal'];
    if (reveal is! String ||
        !_link.hasMatch(reveal) ||
        !_link.hasMatch(previous) ||
        !verifyReveal(reveal: reveal, parent: previous)) {
      return failed('chain');
    }
    final Object? value = frame.data['value'];
    if (value is! int || value != drawDie(reveal, gameId, clientSeeds, k, 0)) {
      return failed('value');
    }
    previous = reveal;
  }

  if (checked == 0) {
    return const FairCheck(
      verdict: FairVerdict.mismatch,
      rolls: 0,
      reason: 'no_rolls',
    );
  }
  return FairCheck(verdict: FairVerdict.fair, rolls: checked);
}

/// The frames of game [gameId] exactly as this device received them, when
/// they are the whole game: a `game_started` naming [gameId], then every
/// numbered push through the `game_over`, each `seq` one more than the last.
/// Null when any of that is missing (a dropped socket, a resume, an app
/// that was killed): the device then has to ask for the game log instead.
/// The window runs from that `game_started` to that `game_over`, both
/// included.
List<Frame>? wholeGameFrames(List<Frame> frames, {required String gameId}) {
  int start = -1;
  for (int i = 0; i < frames.length; i++) {
    if (frames[i].type == 'game_started') {
      start = i;
    }
  }
  if (start == -1 || frames[start].data['game_id'] != gameId) {
    return null;
  }
  final int? firstSeq = frames[start].seq;
  if (firstSeq == null) {
    return null;
  }
  int previousSeq = firstSeq;
  for (int i = start + 1; i < frames.length; i++) {
    final int? seq = frames[i].seq;
    if (seq != null) {
      if (seq != previousSeq + 1) {
        return null;
      }
      previousSeq = seq;
    }
    if (frames[i].type == 'game_over') {
      return List<Frame>.unmodifiable(frames.sublist(start, i + 1));
    }
  }
  return null;
}

/// C-704: what the end card needs to recheck every roll of the game it
/// shows: the game's id, the `chain_commit` the room published before the
/// game began, and where the game's frames come from. [loadFrames] completes
/// with the frames [checkFairness] reads, or with an [Exception] when they
/// cannot be had (offline, an error answer, a timeout).
@immutable
class EndCardFairSource {
  const EndCardFairSource({
    required this.gameId,
    required this.chainCommit,
    required this.loadFrames,
  });

  /// The finished game's `game_id`. A new id is a new game: the card drops
  /// the result it holds and checks again.
  final String gameId;

  /// `chain_commit` of the room the game was played in.
  final String chainCommit;

  final Future<List<Frame>> Function() loadFrames;
}

/// Test seam for games whose dice are scripted, so their reveals are not a
/// real chain. When set, `GameScreen` asks it first for the game's
/// [EndCardFairSource]; its answer is used as given, and null means no check
/// runs. It is read only inside an `assert`, so a release build never
/// consults it and no variable can tell a shipped app that a game is fair.
EndCardFairSource? Function(String gameId, String chainCommit)?
debugFairSourceOverride;
