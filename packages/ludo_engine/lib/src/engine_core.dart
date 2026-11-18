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
  if (config.rules.yardRelease && !config.rules.rollQueue) {
    throw ArgumentError(
      'GameConfig.rules.yardRelease requires rules.rollQueue',
    );
  }
  if (config.rules.sharedRelease && !config.rules.yardRelease) {
    throw ArgumentError(
      'GameConfig.rules.sharedRelease requires rules.yardRelease',
    );
  }
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
  if (state.releaseOwed) {
    // Section 11.4: while a release is owed the legal tokens are the ones a
    // 6 would bring out of the yard.
    return _releasableTokens(state, state.currentSeat);
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
  if (state.phase != GamePhase.awaitMove || state.releaseOwed) {
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
  if (state.phase != GamePhase.awaitMove || state.releaseOwed) {
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
  if (intention is RetireIntention) {
    // Section 12.4: the server's own intention, checked in its own order and
    // never against the turn.
    return _applyRetire(state, intention);
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
    RetireIntention() => _applyRetire(state, intention),
    DeclineIntention() => _applyDecline(state, intention),
  };
}

/// Rule 33p, docs/ENGINE_API.md section 12.3: [seat] has all four tokens at
/// 57 after a move that produced [events]. It takes the next place, its queue
/// and release are discarded and it earns no bonus. The turn passes to the
/// next playing seat, or, with one seat left, that seat takes the last place
/// and the game ends (rule 36p).
ApplyResult _finishSeat(
  GameState state,
  List<List<int>> newTokens,
  int seat,
  List<GameEvent> events,
  List<int> drought,
) {
  final placings = <int>[...state.placings, seat];
  events.add(SeatFinished(seat: seat, place: placings.length));
  return _afterSeatLeft(
    state: state,
    tokens: newTokens,
    placings: placings,
    retired: state.retired,
    drought: drought,
    events: events,
    leaver: seat,
  );
}

/// Rule 34p, docs/ENGINE_API.md section 12.4: the server removes a seat.
ApplyResult _applyRetire(GameState state, RetireIntention intention) {
  if (!state.config.rules.playOut) {
    return const Rejected(EngineError.wrongPhase);
  }
  final seat = intention.seat;
  if (!state.config.seats.contains(seat)) {
    return const Rejected(EngineError.seatNotInPlay);
  }
  if (state.placings.contains(seat) || state.retired.contains(seat)) {
    return const Rejected(EngineError.illegalMove);
  }

  final newTokens = <List<int>>[
    for (final row in state.tokens) List<int>.of(row),
  ];
  for (var t = 0; t < 4; t++) {
    if (newTokens[seat][t] != 57) {
      newTokens[seat][t] = -1;
    }
  }
  final retired = <int>[...state.retired, seat];
  final events = <GameEvent>[SeatRetired(seat: seat)];

  final playing = _playingSeats(state.config.seats, state.placings, retired);
  if (playing.length >= 2 && seat != state.currentSeat) {
    // The seat to act keeps its phase, queue and roll.
    return Applied(
      GameState(
        config: state.config,
        placings: state.placings,
        retired: retired,
        tokens: newTokens,
        currentSeat: state.currentSeat,
        phase: state.phase,
        roll: state.roll,
        sixes: state.sixes,
        winner: state.winner,
        seq: state.seq + 1,
        rngState: state.rngState,
        queue: state.queue,
        drought: state.drought,
        releaseOwed: state.releaseOwed,
        banked: state.banked,
        releaseOffered: state.releaseOffered,
      ),
      events,
    );
  }
  return _afterSeatLeft(
    state: state,
    tokens: newTokens,
    placings: state.placings,
    retired: retired,
    drought: state.drought,
    events: events,
    leaver: seat,
  );
}

/// What follows once [leaver] has left the turn order (finished or retired)
/// and [leaver] was the seat to act, or the game may be over. Two or more
/// seats still playing: the turn passes. One: it takes the next place and the
/// game ends. None: the game ends with the places already taken.
ApplyResult _afterSeatLeft({
  required GameState state,
  required List<List<int>> tokens,
  required List<int> placings,
  required List<int> retired,
  required List<int> drought,
  required List<GameEvent> events,
  required int leaver,
}) {
  final seats = state.config.seats;
  final playing = _playingSeats(seats, placings, retired);
  if (playing.length >= 2) {
    final turn = _beginNextTurn(
      state,
      leaver,
      events,
      placings: placings,
      retired: retired,
    );
    return Applied(
      GameState(
        config: state.config,
        placings: placings,
        retired: retired,
        tokens: tokens,
        currentSeat: turn.seat,
        phase: GamePhase.awaitRoll,
        roll: null,
        sixes: 0,
        winner: state.winner,
        seq: state.seq + 1,
        rngState: state.rngState,
        queue: turn.queue,
        drought: drought,
        banked: turn.banked,
      ),
      events,
    );
  }
  var finalPlacings = placings;
  if (playing.length == 1) {
    finalPlacings = <int>[...placings, playing.first];
    events.add(SeatFinished(seat: playing.first, place: finalPlacings.length));
  }
  final winner = finalPlacings.isEmpty ? null : finalPlacings.first;
  if (winner != null) {
    events.add(GameWon(seat: winner));
  }
  return Applied(
    GameState(
      config: state.config,
      placings: finalPlacings,
      retired: retired,
      tokens: tokens,
      currentSeat: state.currentSeat,
      phase: GamePhase.finished,
      roll: null,
      sixes: 0,
      winner: winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: const <int>[],
      drought: drought,
      banked: state.banked,
    ),
    events,
  );
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
    placings: state.placings,
    retired: state.retired,
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
  final nextSeat = _nextSeat(state, seat);
  final newState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
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

  if (state.releaseOwed) {
    return _applyRelease(state, intention, token);
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
  if (allHome && state.config.rules.playOut) {
    return _finishSeat(state, newTokens, seat, events, state.drought);
  }
  if (allHome) {
    events.add(GameWon(seat: seat));
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
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
      placings: state.placings,
      retired: state.retired,
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

  final nextSeat = _nextSeat(state, seat);
  events.add(TurnBegan(seat: nextSeat));
  final newState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
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
  // Rules 9r and 10r (docs/ENGINE_API.md section 11.3): the drought moves
  // first, then section 10.3 runs as written on the updated count.
  var drought = state.drought;
  var releaseGranted = false;
  if (state.config.rules.yardRelease) {
    if (value == 6 || state.tokens[seat].any((p) => p != -1)) {
      drought = _withDrought(drought, seat, 0);
    } else if (drought[seat] + 1 >= _releaseAfter) {
      // Rule 18s: with a shared release the count rests at 9 while the offer
      // is open, and only a lapse or a taken release brings it to 0.
      drought = _withDrought(
        drought,
        seat,
        state.config.rules.sharedRelease ? _releaseAfter - 1 : 0,
      );
      releaseGranted = true;
    } else {
      drought = _withDrought(drought, seat, drought[seat] + 1);
    }
  }

  if (releaseGranted) {
    return _grantRelease(state, seat, value, drought);
  }

  if (value == 6 && state.sixes == 2) {
    // Rule 10q: the third consecutive 6 is not queued; every unspent face is
    // discarded and the turn passes. Moves already made this turn stand.
    final events = <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      TurnEnded(seat: seat, reason: TurnEndReason.threeSixes),
    ];
    final turn = _beginNextTurn(state, seat, events);
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: state.tokens,
      currentSeat: turn.seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: turn.queue,
      drought: drought,
      banked: turn.banked,
    );
    return Applied(newState, events);
  }

  final newQueue = <int>[...state.queue, value];

  if (value == 6) {
    // Rule 10q: a 6 is queued and the same seat rolls again at once, before
    // any move is offered. Section 10.3: the new state is awaitRoll, so
    // nothing is movable yet -- Rolled.legal is [], not the 6's own set.
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: state.tokens,
      currentSeat: seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: state.sixes + 1,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: newQueue,
      drought: drought,
      banked: state.banked,
    );
    return Applied(newState, <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      ExtraRoll(seat: seat),
    ]);
  }

  // Rule 11q: a non-6 ends the rolling. sixes resets to 0 either way below.
  final tentativeState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: state.tokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: newQueue,
    drought: drought,
    banked: state.banked,
  );

  if (legalByFace(tentativeState).isEmpty) {
    // Rule 13q: no queued face has a legal move. The faces are discarded and
    // the turn passes, so Rolled.legal is [], not the closing face's set.
    final events = <GameEvent>[
      Rolled(seat: seat, value: value, legal: const <int>[]),
      TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove),
    ];
    final turn = _beginNextTurn(state, seat, events);
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: state.tokens,
      currentSeat: turn.seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: turn.queue,
      drought: drought,
      banked: turn.banked,
    );
    return Applied(newState, events);
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

  // Rule 10r (docs/ENGINE_API.md section 11.4): a token leaving the yard
  // clears the mover's drought. With the toggle off the list is all zeros and
  // stays untouched.
  final droughtAfter = state.config.rules.yardRelease && fromProgress == -1
      ? _withDrought(state.drought, seat, 0)
      : state.drought;

  final allHome = newTokens[seat].every((p) => p == 57);
  if (allHome && state.config.rules.playOut) {
    return _finishSeat(state, newTokens, seat, events, droughtAfter);
  }
  if (allHome) {
    // Rule 14q: winning discards whatever is left unspent.
    events.add(GameWon(seat: seat));
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: newTokens,
      currentSeat: seat,
      phase: GamePhase.finished,
      roll: null,
      sixes: state.sixes,
      winner: seat,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: const <int>[],
      drought: droughtAfter,
      banked: state.banked,
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
      placings: state.placings,
      retired: state.retired,
      tokens: newTokens,
      currentSeat: seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: queueAfterSpend,
      drought: droughtAfter,
      banked: state.banked,
    );
    return Applied(newState, events);
  }

  final tentativeState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: newTokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: null,
    sixes: state.sixes,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: queueAfterSpend,
    drought: droughtAfter,
    banked: state.banked,
  );

  if (legalByFace(tentativeState).isNotEmpty) {
    // No event beyond the move's own: the same seat keeps spending.
    return Applied(tentativeState, events);
  }

  if (queueAfterSpend.isNotEmpty) {
    // Rule 13q: faces remain but none can move. They are discarded.
    events.add(TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove));
  }
  final turn = _beginNextTurn(state, seat, events);
  final newState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: newTokens,
    currentSeat: turn.seat,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: turn.queue,
    drought: droughtAfter,
    banked: turn.banked,
  );
  return Applied(newState, events);
}

/// Rule 11r: the roll that brings the drought to this count grants a release.
const int _releaseAfter = 10;

/// [drought] with [seat]'s count replaced by [count]; the input is untouched.
List<int> _withDrought(List<int> drought, int seat, int count) =>
    _withCount(drought, seat, count);

/// [counts] with the entry at [seat] replaced by [count]; the input is
/// untouched.
List<int> _withCount(List<int> counts, int seat, int count) {
  final result = List<int>.of(counts);
  result[seat] = count;
  return result;
}

/// Tokens of [seat] a 6 would bring out of the yard: the same legality as a
/// rolled 6 (rules 17 and 22), restricted to tokens in the yard.
List<int> _releasableTokens(GameState state, int seat) => <int>[
      for (final t in _legalTokensFor(state, seat, 6))
        if (state.tokens[seat][t] == -1) t,
    ];

/// Rules 11r and 14r, docs/ENGINE_API.md section 11.3: the tenth non-6 with
/// every token in the yard. The face is queued as drawn (rule 15r), the seat
/// is told, and either a release is owed or, with the entry square blocked,
/// it lapses and the turn passes.
ApplyResult _grantRelease(
  GameState state,
  int seat,
  int value,
  List<int> drought,
) {
  final newQueue = <int>[...state.queue, value];
  final releasable = _releasableTokens(state, seat);
  final shared = state.config.rules.sharedRelease;
  if (releasable.isNotEmpty) {
    final newState = GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: state.tokens,
      currentSeat: seat,
      phase: GamePhase.awaitMove,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: newQueue,
      drought: drought,
      releaseOwed: true,
      banked: state.banked,
      releaseOffered: shared,
    );
    return Applied(newState, <GameEvent>[
      Rolled(seat: seat, value: value, legal: releasable),
      // Section 13.5: with a shared release it is emitted when the release is
      // taken, not here.
      if (!shared) YardReleased(seat: seat),
    ]);
  }
  final events = <GameEvent>[
    Rolled(seat: seat, value: value, legal: const <int>[]),
    // Section 13.3: a lapse is no release, so nothing is emitted for one.
    if (!shared) YardReleased(seat: seat),
    TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove),
  ];
  final turn = _beginNextTurn(state, seat, events);
  final newState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: state.tokens,
    currentSeat: turn.seat,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: turn.queue,
    drought: shared ? _withDrought(drought, seat, 0) : drought,
    banked: turn.banked,
  );
  return Applied(newState, events);
}

/// Rules 12r and 13r, docs/ENGINE_API.md section 11.4: a `MoveIntention`
/// against a state with a release owed. It spends the release and never a
/// face; the drawn face stays queued.
ApplyResult _applyRelease(GameState state, MoveIntention intention, int token) {
  if (intention.face != null) {
    return const Rejected(EngineError.illegalMove);
  }
  if (!_releasableTokens(state, state.currentSeat).contains(token)) {
    return const Rejected(EngineError.illegalMove);
  }

  final seat = state.currentSeat;
  final newTokens = <List<int>>[
    for (final row in state.tokens) List<int>.of(row),
  ];
  newTokens[seat][token] = 0;
  final events = <GameEvent>[Moved(seat: seat, token: token, from: -1, to: 0)];

  if (state.releaseOffered) {
    return _takeOffer(state, newTokens, events);
  }

  final tentativeState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: newTokens,
    currentSeat: seat,
    phase: GamePhase.awaitMove,
    roll: null,
    sixes: state.sixes,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: state.queue,
    drought: state.drought,
    banked: state.banked,
  );
  if (legalByFace(tentativeState).isNotEmpty) {
    return Applied(tentativeState, events);
  }

  events.add(TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove));
  final turn = _beginNextTurn(state, seat, events);
  final newState = GameState(
    config: state.config,
    placings: state.placings,
    retired: state.retired,
    tokens: newTokens,
    currentSeat: turn.seat,
    phase: GamePhase.awaitRoll,
    roll: null,
    sixes: 0,
    winner: state.winner,
    seq: state.seq + 1,
    rngState: state.rngState,
    queue: turn.queue,
    drought: state.drought,
    banked: turn.banked,
  );
  return Applied(newState, events);
}

/// Rule 17s, docs/ENGINE_API.md section 13.4: the offered release is taken.
/// [events] already holds the `Moved`. The drawn face and every other unspent
/// face are discarded, every other playing seat is granted a banked six and
/// the turn passes at once.
ApplyResult _takeOffer(
  GameState state,
  List<List<int>> newTokens,
  List<GameEvent> events,
) {
  final seat = state.currentSeat;
  final grantees = <int>[
    for (final other in _playingSeats(
      state.config.seats,
      state.placings,
      state.retired,
    ))
      if (other != seat) other,
  ];
  var banked = state.banked;
  if (grantees.isNotEmpty) {
    banked = List<int>.of(banked);
    for (final other in grantees) {
      banked[other] += 1;
    }
  }
  events.add(YardReleased(seat: seat));
  if (grantees.isNotEmpty) {
    events.add(SixesBanked(seats: grantees));
  }
  events.add(TurnEnded(seat: seat, reason: TurnEndReason.released));
  final turn = _beginNextTurn(state, seat, events, banked: banked);
  return Applied(
    GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: newTokens,
      currentSeat: turn.seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: turn.queue,
      drought: _withDrought(state.drought, seat, 0),
      banked: turn.banked,
    ),
    events,
  );
}

/// Rule 18s, docs/ENGINE_API.md section 13.4: the offered release is
/// declined. Nothing comes out, nothing is granted, the drought stays at 9
/// and the turn passes as a roll with no legal move would.
ApplyResult _applyDecline(GameState state, DeclineIntention intention) {
  if (state.phase != GamePhase.awaitMove || !state.releaseOffered) {
    return const Rejected(EngineError.wrongPhase);
  }
  final seat = state.currentSeat;
  final events = <GameEvent>[
    ReleaseDeclined(seat: seat),
    TurnEnded(seat: seat, reason: TurnEndReason.noLegalMove),
  ];
  final turn = _beginNextTurn(state, seat, events);
  return Applied(
    GameState(
      config: state.config,
      placings: state.placings,
      retired: state.retired,
      tokens: state.tokens,
      currentSeat: turn.seat,
      phase: GamePhase.awaitRoll,
      roll: null,
      sixes: 0,
      winner: state.winner,
      seq: state.seq + 1,
      rngState: state.rngState,
      queue: turn.queue,
      drought: state.drought,
      banked: turn.banked,
    ),
    events,
  );
}

/// The one place a next seat's turn begins (docs/ENGINE_API.md section 13.6):
/// the next playing seat after [from], `TurnBegan`, and with `sharedRelease`
/// on, when that seat holds banked sixes, `SixesQueued` and a queue of that
/// many 6s with its bank emptied. [placings], [retired] and [banked] default
/// to the state's own.
({int seat, List<int> queue, List<int> banked}) _beginNextTurn(
  GameState state,
  int from,
  List<GameEvent> events, {
  List<int>? placings,
  List<int>? retired,
  List<int>? banked,
}) {
  final next = _nextPlaying(
    state.config.seats,
    placings ?? state.placings,
    retired ?? state.retired,
    from,
  );
  final bank = banked ?? state.banked;
  events.add(TurnBegan(seat: next));
  if (state.config.rules.sharedRelease && bank[next] > 0) {
    final count = bank[next];
    events.add(SixesQueued(seat: next, count: count));
    return (
      seat: next,
      queue: List<int>.filled(count, 6),
      banked: _withCount(bank, next, 0),
    );
  }
  return (seat: next, queue: const <int>[], banked: bank);
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

/// docs/ENGINE_API.md section 12.1: the next playing seat after
/// [currentSeat] in `config.seats`, cyclically. A seat is playing when it is
/// in `config.seats` and in neither `placings` nor `retired`; with `playOut`
/// off both lists are empty, so this is the plain next seat.
int _nextSeat(GameState state, int currentSeat) => _nextPlaying(
    state.config.seats, state.placings, state.retired, currentSeat);

int _nextPlaying(
  List<int> seats,
  List<int> placings,
  List<int> retired,
  int currentSeat,
) {
  final index = seats.indexOf(currentSeat);
  for (var k = 1; k <= seats.length; k++) {
    final candidate = seats[(index + k) % seats.length];
    if (!placings.contains(candidate) && !retired.contains(candidate)) {
      return candidate;
    }
  }
  return currentSeat;
}

List<int> _playingSeats(
  List<int> seats,
  List<int> placings,
  List<int> retired,
) =>
    <int>[
      for (final seat in seats)
        if (!placings.contains(seat) && !retired.contains(seat)) seat,
    ];
