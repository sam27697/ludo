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
///
/// docs/ENGINE_API.md section 10.1: with `rules.rollQueue` on, `state.roll`
/// is always null and this returns the legal tokens of `defaultFace(state)`
/// instead.
List<int> legalTokens(GameState state) {
  if (state.phase != GamePhase.awaitMove) {
    return const <int>[];
  }
  if (state.config.rules.rollQueue) {
    final face = defaultFace(state);
    if (face == null) {
      return const <int>[];
    }
    return _legalTokensFor(state, state.currentSeat, face);
  }
  return _legalTokensFor(state, state.currentSeat, state.roll!);
}

/// docs/ENGINE_API.md section 10.1: faces with at least one legal token, in
/// first-queued order, each with its legal tokens ascending. Empty in
/// `awaitRoll` and `finished`. With `!rollQueue`, this is
/// `{state.roll: legalTokens(state)}` in `awaitMove`.
Map<int, List<int>> legalByFace(GameState state) {
  if (state.phase != GamePhase.awaitMove) {
    return const <int, List<int>>{};
  }
  if (!state.config.rules.rollQueue) {
    return <int, List<int>>{state.roll!: legalTokens(state)};
  }
  final result = <int, List<int>>{};
  for (final face in state.queue) {
    if (result.containsKey(face)) {
      continue;
    }
    final legal = _legalTokensFor(state, state.currentSeat, face);
    if (legal.isNotEmpty) {
      result[face] = legal;
    }
  }
  return result;
}

/// docs/ENGINE_API.md section 10.1: the face a move with `face == null`
/// spends -- the first entry of the queue, in queue order, that has a legal
/// token. Null outside `awaitMove` (a queue may be non-empty in `awaitRoll`,
/// e.g. a queued 6 that owes another roll) and when no face can move.
int? defaultFace(GameState state) {
  if (state.phase != GamePhase.awaitMove) {
    return null;
  }
  for (final face in state.queue) {
    if (_legalTokensFor(state, state.currentSeat, face).isNotEmpty) {
      return face;
    }
  }
  return null;
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

  if (state.config.rules.rollQueue) {
    return _applyRollQueued(state, seat, value);
  }

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

  if (state.config.rules.rollQueue) {
    return _applyMoveQueued(state, intention, token);
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

  final reachedHome = toProgress == 57;
  if (reachedHome) {
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

  final grantsExtraRoll = rollValue == 6 ||
      (captured && state.config.rules.captureBonus) ||
      (reachedHome && state.config.rules.homeBonus);

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

/// docs/RULES.md section 3.2a / docs/ENGINE_API.md section 10.3. Rules 9, 12
/// and 13 are replaced wholesale by rules 9q to 13q when `rollQueue` is on;
/// this is a separate path from `_applyRoll`'s rather than threaded through
/// it, because the two share nothing past the face-range check -- the queue
/// changes what "the turn passes" and "the move is offered" mean.
ApplyResult _applyRollQueued(GameState state, int seat, int value) {
  if (value == 6 && state.sixes == 2) {
    // Rule 10q: the third consecutive 6 is not queued; every unspent face is
    // discarded and the turn passes. Moves already made this turn stand.
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
      queue: const <int>[],
    );
    return Applied(newState, <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      TurnEnded(seat: seat, reason: TurnEndReason.threeSixes),
      TurnBegan(seat: nextSeat),
    ]);
  }

  final newQueue = <int>[...state.queue, value];

  if (value == 6) {
    // Rule 10q: a 6 is queued and the same seat rolls again at once, before
    // any move is offered. Section 10.3: the new state is awaitRoll, so
    // nothing is movable yet -- Rolled.legal is [], not the 6's own set.
    final newState = GameState(
      config: state.config,
      tokens: state.tokens,
      currentSeat: seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: state.sixes + 1,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: newQueue,
    );
    return Applied(newState, <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      ExtraRoll(seat: seat),
    ]);
  }

  // Rule 11q: a non-6 ends the rolling. sixes resets to 0 either way below.
  final tentativeState = GameState(
    config: state.config,
    tokens: state.tokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: newQueue,
  );

  if (legalByFace(tentativeState).isEmpty) {
    // Rule 13q: no queued face has a legal move. The faces are discarded and
    // the turn passes, so Rolled.legal is [], not the closing face's set.
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
      queue: const <int>[],
    );
    return Applied(newState, <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove),
      TurnBegan(seat: nextSeat),
    ]);
  }

  // Section 10.3: the new state is awaitMove, so Rolled.legal is
  // legalTokens of that state -- the default face's tokens, not
  // necessarily this closing face's own set.
  return Applied(tentativeState, <GameEvent>[
    Rolled(seat: seat, value: value, legal: legalTokens(tentativeState)),
  ]);
}

/// docs/RULES.md rules 12q to 14q / docs/ENGINE_API.md section 10.4.
ApplyResult _applyMoveQueued(
  GameState state,
  MoveIntention intention,
  int token,
) {
  final seat = state.currentSeat;
  final requestedFace = intention.face;
  int faceToUse;
  if (requestedFace != null) {
    if (requestedFace < 1 ||
        requestedFace > 6 ||
        !state.queue.contains(requestedFace)) {
      return const Rejected(EngineError.illegalMove);
    }
    faceToUse = requestedFace;
  } else {
    final chosen = defaultFace(state);
    if (chosen == null) {
      // Impossible in awaitMove per 10.3: legalByFace is non-empty whenever
      // the engine puts a seat in awaitMove under rollQueue. Guarded anyway
      // because apply() never throws.
      return const Rejected(EngineError.illegalMove);
    }
    faceToUse = chosen;
  }

  final legalForFace = _legalTokensFor(state, seat, faceToUse);
  if (!legalForFace.contains(token)) {
    return const Rejected(EngineError.illegalMove);
  }

  final fromProgress = state.tokens[seat][token];
  final toProgress = fromProgress == -1 ? 0 : fromProgress + faceToUse;

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

  final reachedHome = toProgress == 57;
  if (reachedHome) {
    events.add(TokenHome(seat: seat, token: token));
  }

  final queueAfterSpend = _removeFirstOccurrence(state.queue, faceToUse);

  final allHome = newTokens[seat].every((p) => p == 57);
  if (allHome) {
    // Rule 14q: winning discards whatever is left unspent.
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
      queue: const <int>[],
    );
    return Applied(newState, events);
  }

  // Rule 12q: a 6 spent on a move grants nothing by itself -- it already
  // earned its reroll when it landed in the queue (rule 10q).
  final bonusOwed = (captured && state.config.rules.captureBonus) ||
      (reachedHome && state.config.rules.homeBonus);

  if (bonusOwed) {
    events.add(ExtraRoll(seat: seat));
    final newState = GameState(
      config: state.config,
      tokens: newTokens,
      currentSeat: seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: queueAfterSpend,
    );
    return Applied(newState, events);
  }

  final tentativeState = GameState(
    config: state.config,
    tokens: newTokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: null,
    sixes: state.sixes,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: queueAfterSpend,
  );

  if (legalByFace(tentativeState).isNotEmpty) {
    // No event beyond the move's own: the same seat keeps spending.
    return Applied(tentativeState, events);
  }

  final nextSeat = _nextSeat(state.config.seats, seat);
  if (queueAfterSpend.isEmpty) {
    events.add(TurnBegan(seat: nextSeat));
  } else {
    // Rule 13q: faces remain but none can move. They are discarded.
    events.add(TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove));
    events.add(TurnBegan(seat: nextSeat));
  }
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
    queue: const <int>[],
  );
  return Applied(newState, events);
}

/// The first occurrence of [face] removed from [queue], preserving the
/// order of everything else. Rule 11q: the player chooses which queued face
/// to spend; only that one occurrence leaves the queue.
List<int> _removeFirstOccurrence(List<int> queue, int face) {
  final result = <int>[];
  var removed = false;
  for (final f in queue) {
    if (!removed && f == face) {
      removed = true;
      continue;
    }
    result.add(f);
  }
  return result;
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
