// docs/VERIFY.md section 3 and the table of section 1.1: the JSON object
// stored for a finished game and later served at `/v/<game_id>.json` and
// embedded in `/v/<game_id>`.
//
// This never stores a die face: `room` only ever kept a reveal and the seat
// that rolled it (`room.rollSeats`, `room.chain`), because the face is a
// pure function of the reveal, the game id, the frozen client seeds, the
// roll number and the die index -- exactly the function `roll()` in
// `registry.dart` already called to produce the face in the first place.
// Recomputing it here with the same call is the same value, not a guess at
// it, and it means there is no second place that could disagree with the
// roll the players actually saw.

import 'package:fair_dice/fair_dice.dart' show drawDie;

import 'room.dart';

/// The record format this file produces. Bump this, and the shape below,
/// together if the table of `docs/VERIFY.md` section 1.1 ever changes; a
/// checker reading an older record is expected to key off this field.
const int verifyRecordFormat = 1;

/// Builds the verification record for [room], a game that has just been won
/// by [winner] at [finishedAt]. Every value comes from [room] and the two
/// arguments -- nothing here reads a clock or a generator of its own.
///
/// [room.gameId] and [room.clientSeeds] must already be set (true of any
/// room that has reached `start_game`, which every finished game has) and
/// `room.rollSeats.length` must equal `room.rollCount` (true on the one
/// code path in `registry.dart` that ever advances either of them).
Map<String, Object?> buildVerifyRecord(
  Room room, {
  required int winner,
  required DateTime finishedAt,
}) {
  final String gameId = room.gameId!;
  final String clientSeeds = room.clientSeeds!;

  final List<Map<String, Object?>> seeds = <Map<String, Object?>>[
    for (final Seat seat in room.seats)
      <String, Object?>{
        'seat': seat.seat,
        'seed': seat.clientSeed,
        'origin': seat.seedOrigin,
      },
  ];

  // Ascending k, 1 .. room.rollCount, no gap: the loop bound is rollCount
  // itself, so a reveal for any k above it -- in particular the chain root,
  // unless the game truly reached k == chain_length -- is never read, let
  // alone published.
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[
    for (var k = 1; k <= room.rollCount; k++)
      _rollEntry(room, gameId, clientSeeds, k),
  ];

  return <String, Object?>{
    'format': verifyRecordFormat,
    'game_id': gameId,
    'chain_commit': room.chain.commit,
    'chain_index': room.chainIndex,
    'chain_length': room.chain.chainLength,
    'client_seeds': clientSeeds,
    'seeds': seeds,
    'rolls': rolls,
    'winner': winner,
    'finished_at': _formatFinishedAt(finishedAt),
  };
}

Map<String, Object?> _rollEntry(
  Room room,
  String gameId,
  String clientSeeds,
  int k,
) {
  final String reveal = room.chain.reveal(k);
  return <String, Object?>{
    'k': k,
    'seat': room.rollSeats[k - 1],
    'reveal': reveal,
    'die': drawDie(reveal, gameId, clientSeeds, k, 0),
  };
}

/// `YYYY-MM-DDTHH:MM:SSZ`, UTC, whole seconds -- `docs/VERIFY.md` section
/// 1.1's `finished_at`. [dt] is converted to UTC first so a caller handing
/// in a local `DateTime` still gets the wire format the spec asks for.
String _formatFinishedAt(DateTime dt) {
  final DateTime utc = dt.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}Z';
}
