// C-232: the loser's end card (a later order) shows "a few honest, simple
// numbers from their own game" (doctrine P6) so a loss reads as "close, go
// again" rather than a verdict. `computeGameStats` is the whole computation,
// pure Dart, reading only the frames this client already holds. Frame shapes
// are docs/PROTOCOL.md section 5.

import 'net/frame.dart';

/// Six honest numbers from one game, for one seat. Value equality and
/// [toString] cover all six fields, so a failing test prints something
/// readable rather than an object identity.
class GameStats {
  const GameStats({
    required this.rolls,
    required this.sixes,
    required this.capturesMade,
    required this.timesCaptured,
    required this.tokensHome,
    required this.complete,
  });

  final int rolls;
  final int sixes;
  final int capturesMade;
  final int timesCaptured;
  final int tokensHome;
  final bool complete;

  @override
  bool operator ==(Object other) {
    return other is GameStats &&
        other.rolls == rolls &&
        other.sixes == sixes &&
        other.capturesMade == capturesMade &&
        other.timesCaptured == timesCaptured &&
        other.tokensHome == tokensHome &&
        other.complete == complete;
  }

  @override
  int get hashCode {
    return Object.hash(
      rolls,
      sixes,
      capturesMade,
      timesCaptured,
      tokensHome,
      complete,
    );
  }

  @override
  String toString() {
    final String rendered =
        'GameStats(rolls: $rolls, sixes: $sixes, '
        'capturesMade: $capturesMade, timesCaptured: $timesCaptured, '
        'tokensHome: $tokensHome, complete: $complete)';
    return rendered;
  }
}

/// Computed on the device from this game's own frames, never from anywhere
/// else and never sent anywhere (doctrine P9, hard rule 3: no analytics SDK).
/// Only the window after the last `game_started` in [frames] counts, up to
/// and including the `game_over` that follows it if one has arrived yet; a
/// room that hosts a second game later does not pollute the first one's
/// numbers. `complete` exists because a reconnect leaves a hole in the
/// frames this client actually saw: once a frame is missing, `rolls`,
/// `sixes`, `capturesMade` and `timesCaptured` can no longer be trusted, and
/// a wrong number reads worse than none, so the end card is told to fall
/// back to [GameStats.tokensHome] alone, which always comes from
/// [finalTokens] and so is right even with gaps in the frames.
///
/// Throws [ArgumentError] if [seat] is outside 0..3 or [finalTokens] is not
/// of length 4. Reject, never repair. Any other malformed input -- a counted
/// frame missing the field it is counted by -- is not counted, marks
/// [GameStats.complete] false, and is never a reason to throw.
GameStats computeGameStats({
  required List<Frame> frames,
  required int seat,
  required List<int> finalTokens,
}) {
  if (seat < 0 || seat > 3) {
    throw ArgumentError.value(seat, 'seat', 'must be 0..3');
  }
  if (finalTokens.length != 4) {
    throw ArgumentError.value(finalTokens, 'finalTokens', 'must have length 4');
  }

  final int tokensHome = finalTokens.where((int token) => token == 57).length;

  int gameStartedIndex = -1;
  for (int i = 0; i < frames.length; i++) {
    if (frames[i].type == 'game_started') {
      gameStartedIndex = i;
    }
  }
  if (gameStartedIndex == -1) {
    return GameStats(
      rolls: 0,
      sixes: 0,
      capturesMade: 0,
      timesCaptured: 0,
      tokensHome: tokensHome,
      complete: false,
    );
  }

  int windowEnd = frames.length - 1;
  for (int i = gameStartedIndex; i < frames.length; i++) {
    if (frames[i].type == 'game_over') {
      windowEnd = i;
      break;
    }
  }

  int rolls = 0;
  int sixes = 0;
  int capturesMade = 0;
  int timesCaptured = 0;
  bool malformed = false;
  int? previousSeq;
  bool seqStarted = false;

  for (int i = gameStartedIndex; i <= windowEnd; i++) {
    final Frame frame = frames[i];

    final int? frameSeq = frame.seq;
    if (i == gameStartedIndex && frameSeq == null) {
      // No seq on the game_started itself: there is nothing for the chain
      // to anchor to, so completeness is already lost. The window still
      // opens here and the counters below still run.
      malformed = true;
    } else if (frameSeq != null) {
      if (seqStarted && frameSeq != previousSeq! + 1) {
        malformed = true;
      }
      previousSeq = frameSeq;
      seqStarted = true;
    }

    if (frame.type == 'rolled') {
      final Object? seatRaw = frame.data['seat'];
      if (seatRaw is! int) {
        malformed = true;
        continue;
      }
      if (seatRaw != seat) {
        continue;
      }
      rolls++;
      final Object? valueRaw = frame.data['value'];
      if (valueRaw is! int) {
        malformed = true;
        continue;
      }
      if (valueRaw == 6) {
        sixes++;
      }
      continue;
    }

    if (frame.type == 'moved') {
      final Object? capturedRaw = frame.data['captured'];
      if (capturedRaw is! List) {
        malformed = true;
        continue;
      }

      final Object? moverSeatRaw = frame.data['seat'];
      if (moverSeatRaw is! int) {
        malformed = true;
      } else if (moverSeatRaw == seat) {
        capturesMade += capturedRaw.length;
      }

      for (final Object? entry in capturedRaw) {
        if (entry is! Map) {
          malformed = true;
          continue;
        }
        final Object? entrySeatRaw = entry['seat'];
        if (entrySeatRaw is! int) {
          malformed = true;
          continue;
        }
        if (entrySeatRaw == seat) {
          timesCaptured++;
        }
      }
    }
  }

  return GameStats(
    rolls: rolls,
    sixes: sixes,
    capturesMade: capturesMade,
    timesCaptured: timesCaptured,
    tokensHome: tokensHome,
    complete: !malformed,
  );
}

/// The threshold at or below which a loss is considered near home (C-307):
/// two sixes' worth of squares (12) across all four tokens.
const int kNearFinishSquares = 12;

/// Total squares remaining for a seat to bring all four tokens home (C-307).
///
/// Each token at progress `p` (0..56) has `57 - p` squares left to reach
/// home (57). A yard token (-1) counts 58 squares because it needs a six to
/// enter at 0 and then 57 steps home.
///
/// Reads only [finalTokens], never the transcript, so the count is right
/// even when reconnects leave a gap in the frames (C-232).
///
/// Throws [ArgumentError] if [finalTokens] is not of length 4 or any progress
/// is outside -1..57. Reject, never repair.
int stepsLeftOf(List<int> finalTokens) {
  if (finalTokens.length != 4) {
    throw ArgumentError.value(finalTokens, 'finalTokens', 'must have length 4');
  }
  int sum = 0;
  for (final int token in finalTokens) {
    if (token < -1 || token > 57) {
      throw ArgumentError.value(
        token,
        'finalTokens',
        'token progress must be in -1..57',
      );
    }
    if (token == -1) {
      sum += 58;
    } else {
      sum += 57 - token;
    }
  }
  return sum;
}
