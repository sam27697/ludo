// docs/ENGINE_API.md sections 4 and 5, and docs/RULES.md sections 3 and 4.
// The whole engine is two functions and three queries; this file is all of
// them plus the private helpers legality and movement share, kept in one
// place on purpose (docs/RULES.md rule 36 and the work order's warning
// about legality logic scattered through movement code).

import 'board.dart';
import 'enums.dart';
import 'events.dart';
import 'game_config.dart';
import 'game_state.dart';
import 'intentions.dart';
import 'apply_result.dart';

/// A fresh game: `awaitRoll`, the lowest occupied seat to move first, every
/// token in the yard, `seq = 0`, `rngState = config.seed`.
///
/// Throws [ArgumentError] on a malformed config: seats out of range, not
/// ascending, duplicated, or a length outside 2..4. This is the only place
/// the engine throws; a malformed config is a programming error, not a game
/// event.
GameState newGame(GameConfig config) {
  _validateConfig(config);
  final tokens = <List<int>>[
    for (var s = 0; s < 4; s++) List<int>.filled(4, -1),
  ];
  return GameState(
    config: config,
    tokens: tokens,
    currentSeat: config.seats.first,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: null,
    seq: 0,
    rngState: config.seed,
  );
}

void _validateConfig(GameConfig config) {
  final seats = config.seats;
  if (seats.length < 2 || seats.length > 4) {
    throw ArgumentError(
      'GameConfig.seats must have length 2..4, got ${seats.length}',
    );
  }
  for (var i = 0; i < seats.length; i++) {
    final seat = seats[i];
    if (seat < 0 || seat > 3) {
      throw ArgumentError('GameConfig.seats has an out-of-range seat: $seat');
    }
    if (i > 0 && seats[i] <= seats[i - 1]) {
      throw ArgumentError(
        'GameConfig.seats must be strictly ascending, got $seats',
      );
    }
  }
}

/// Token indices, ascending, movable with `state.roll`. Empty whenever
/// `state.phase != awaitMove`. Never throws.
List<int> legalTokens(GameState state) {
  if (state.phase != GamePhase.awaitMove) {
    return const <int>[];
  }
  return _legalTokensFor(state, state.currentSeat, state.roll!);
}

/// A state with a winner accepts no further roll, move or timer action.
bool isTerminal(GameState state) => state.phase == GamePhase.finished;

/// Fixed order of checks, docs/ENGINE_API.md section 4. `apply` never
/// throws; every refusal is a [Rejected].
ApplyResult apply(GameState state, Intention intention) {
  if (isTerminal(state)) {
    return const Rejected(EngineError.gameFinished);
  }
  if (!state.config.seats.contains(intention.seat)) {
    return const Rejected(EngineError.seatNotInPlay);
  }
  if (intention.seat != state.currentSeat) {
    return const Rejected(EngineError.notYourTurn);
  }
  return switch (intention) {
    RollIntention() => _applyRoll(state, intention),
    MoveIntention() => _applyMove(state, intention),
  };
}

ApplyResult _applyRoll(GameState state, RollIntention intention) {
  if (state.phase != GamePhase.awaitRoll) {
    return const Rejected(EngineError.wrongPhase);
  }
  final value = intention.face;
  if (value < 1 || value > 6) {
    // Step 5 of the check ladder, docs/ENGINE_API.md section 4: a face
    // outside 1..6 is rejected before anything else in the roll step runs,
    // and rngState does not move -- the engine draws nothing, rule 38.
    return const Rejected(EngineError.badFace);
  }

  final seat = state.currentSeat;

  if (value == 6 && state.sixes == 2) {
    // Rule 10: the third consecutive 6 is not played at all.
    return _passTurn(
      state: state,
      seat: seat,
      rolledEvent: Rolled(seat: seat, value: value, legal: const <int>[]),
      turnEndReason: TurnEndReason.threeSixes,
    );
  }

  final legal = _legalTokensFor(state, seat, value);
  if (legal.isEmpty) {
    // Rule 7: an empty legal set passes the turn immediately.
    return _passTurn(
      state: state,
      seat: seat,
      rolledEvent: Rolled(seat: seat, value: value, legal: const <int>[]),
      turnEndReason: TurnEndReason.noLegalMove,
    );
  }

  final newSixes = value == 6 ? state.sixes + 1 : 0;
  final newState = GameState(
    config: state.config,
    tokens: state.tokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: value,
    sixes: newSixes,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
  );
  return Applied(newState, <GameEvent>[
    Rolled(seat: seat, value: value, legal: legal),
  ]);
}

ApplyResult _passTurn({
  required GameState state,
  required int seat,
  required Rolled rolledEvent,
  required TurnEndReason turnEndReason,
}) {
  final nextSeat = _nextSeat(state.config.seats, seat);
  final newState = GameState(
    config: state.config,
    tokens: state.tokens,
    currentSeat: nextSeat,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
  );
  return Applied(newState, <GameEvent>[
    rolledEvent,
    TurnEnded(seat: seat, reason: turnEndReason),
    TurnBegan(seat: nextSeat),
  ]);
}

ApplyResult _applyMove(GameState state, MoveIntention intention) {
  if (state.phase != GamePhase.awaitMove) {
    return const Rejected(EngineError.wrongPhase);
  }
  final token = intention.token;
  if (token < 0 || token > 3) {
    return const Rejected(EngineError.noSuchToken);
  }
  if (!legalTokens(state).contains(token)) {
    return const Rejected(EngineError.illegalMove);
  }

  final seat = state.currentSeat;
  final rollValue = state.roll!;
  final fromProgress = state.tokens[seat][token];
  final toProgress = fromProgress == -1 ? 0 : fromProgress + rollValue;

  final newTokens = <List<int>>[
    for (final row in state.tokens) List<int>.of(row),
  ];
  newTokens[seat][token] = toProgress;

  final events = <GameEvent>[
    Moved(seat: seat, token: token, from: fromProgress, to: toProgress),
  ];

  var captured = false;
  if (toProgress >= 0 && toProgress <= 51) {
    final destination = absoluteSquare(seat, toProgress);
    if (!isSafeSquare(destination)) {
      final opponents = _opponentsAt(state.tokens, seat, destination);
      if (opponents.length == 1) {
        final (victimSeat, victimToken) = opponents[0];
        newTokens[victimSeat][victimToken] = -1;
        captured = true;
        events.add(
          Captured(
            seat: victimSeat,
            token: victimToken,
            by: seat,
            byToken: token,
          ),
        );
      }
    }
  }

  if (toProgress == 57) {
    events.add(TokenHome(seat: seat, token: token));
  }

  final allHome = newTokens[seat].every((p) => p == 57);
  if (allHome) {
    events.add(GameWon(seat: seat));
    final newState = GameState(
      config: state.config,
      tokens: newTokens,
      currentSeat: seat,
      phase: GamePhase.finished,
      roll: null,
      sixes: state.sixes,
      winner: seat,
      seq: state.seq + 1,
      rngState: state.rngState,
    );
    return Applied(newState, events);
  }

  final grantsExtraRoll =
      rollValue == 6 || (captured && state.config.rules.captureBonus);

  if (grantsExtraRoll) {
    events.add(ExtraRoll(seat: seat));
    final newState = GameState(
      config: state.config,
      tokens: newTokens,
      currentSeat: seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: state.sixes,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
    );
    return Applied(newState, events);
  }

  final nextSeat = _nextSeat(state.config.seats, seat);
  events.add(TurnBegan(seat: nextSeat));
  final newState = GameState(
    config: state.config,
    tokens: newTokens,
    currentSeat: nextSeat,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
  );
  return Applied(newState, events);
}

/// The core legality computation, rules 17 to 26. Shared by `legalTokens`
/// and by the roll step, which needs the legal set for a value that has not
/// been written into `state.roll` yet.
List<int> _legalTokensFor(GameState state, int seat, int rollValue) {
  final tokens = state.tokens;
  final blocksOn = state.config.rules.blocks;
  final result = <int>[];
  for (var t = 0; t < 4; t++) {
    final progress = tokens[seat][t];
    if (progress == 57) {
      continue;
    }
    int destination;
    if (progress == -1) {
      if (rollValue != 6) {
        continue;
      }
      destination = 0;
    } else {
      destination = progress + rollValue;
      if (destination > 57) {
        continue;
      }
    }
    if (blocksOn && _pathBlocked(tokens, seat, progress, destination)) {
      continue;
    }
    result.add(t);
  }
  return result;
}

/// Rules 22 and 23: every square strictly between origin and destination,
/// plus the destination, on the shared main track only -- the home column
/// cannot be blocked (rule 25). A yard exit's path is exactly its entry
/// square.
bool _pathBlocked(
  List<List<int>> tokens,
  int seat,
  int fromProgress,
  int toProgress,
) {
  final firstStep = fromProgress == -1 ? 0 : fromProgress + 1;
  for (var step = firstStep; step <= toProgress; step++) {
    if (step > 51) {
      continue;
    }
    final square = absoluteSquare(seat, step);
    if (_hasOpponentBlock(tokens, seat, square)) {
      return true;
    }
  }
  return false;
}

/// Whether some seat other than [seat] has two or more tokens on the
/// absolute main-track square [square]. A seat never blocks itself, rule 24.
bool _hasOpponentBlock(List<List<int>> tokens, int seat, int square) {
  for (var otherSeat = 0; otherSeat < 4; otherSeat++) {
    if (otherSeat == seat) {
      continue;
    }
    var count = 0;
    for (var t = 0; t < 4; t++) {
      final p = tokens[otherSeat][t];
      if (p >= 0 && p <= 51 && absoluteSquare(otherSeat, p) == square) {
        count++;
      }
    }
    if (count >= 2) {
      return true;
    }
  }
  return false;
}

/// Every token of a seat other than [seat] standing on the absolute
/// main-track square [square]. Rule 27 fires a capture only when this has
/// exactly one entry; two or more (a block, or two different seats each
/// with one token) captures nothing, rule 28.
List<(int seat, int token)> _opponentsAt(
  List<List<int>> tokens,
  int seat,
  int square,
) {
  final result = <(int, int)>[];
  for (var otherSeat = 0; otherSeat < 4; otherSeat++) {
    if (otherSeat == seat) {
      continue;
    }
    for (var t = 0; t < 4; t++) {
      final p = tokens[otherSeat][t];
      if (p >= 0 && p <= 51 && absoluteSquare(otherSeat, p) == square) {
        result.add((otherSeat, t));
      }
    }
  }
  return result;
}

int _nextSeat(List<int> seats, int currentSeat) {
  final index = seats.indexOf(currentSeat);
  return seats[(index + 1) % seats.length];
}
