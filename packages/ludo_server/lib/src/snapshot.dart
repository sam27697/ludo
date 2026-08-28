// docs/PROTOCOL.md sections 6, 5 and 11, and the section 5 payload shapes
// that are built straight from a `Room` or a `Seat` rather than from an
// inbound message. `docs/ENGINE_API.md` section 9 is the wire mapping for
// the engine's own vocabulary; this file is the server's half of that
// mapping, turning a `GameState` into the redacted snapshot a client is
// allowed to see. `rngState`, `config.seed` and a room's dice-chain server
// secret never appear below, on purpose: sending any of them would hand a
// client every future roll.

import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'room.dart';

/// The full `room` push, section 6. `seq` is read, never computed: it is
/// `room.seq`, the registry's own counter, moved by exactly one on every
/// successful state-changing call before this is ever built.
///
/// [now] is the instant `turn.deadline_ms` is computed against, per section
/// 6: "the value is `max(0, turn_seconds * 1000 - elapsed)` measured on the
/// server's injected clock, so it is computable in a snapshot whether or not
/// anything is scheduled to fire at zero." This file has no clock of its
/// own -- `clock.dart` says nothing under `lib/src/` calls `DateTime.now()`
/// directly -- so the caller (`connection.dart`, holding the same injected
/// `Clock` the registry was built with) passes the reading in.
Map<String, Object?> buildRoomSnapshot(Room room, {required DateTime now}) {
  return <String, Object?>{
    'code': room.code,
    'state': _wireState(room.state),
    'host_seat': room.hostSeat,
    'players': room.players,
    'rules': <String, Object?>{
      'blocks': room.rules.blocks,
      'capture_bonus': room.rules.captureBonus,
      'turn_seconds': room.rules.turnSeconds,
    },
    // docs/PROTOCOL.md section 11.2: present in every state, including
    // LOBBY, from the moment the room exists. `chain_commit` is
    // `room.chain.commit`, never `room`'s raw server secret.
    'chain_commit': room.chain.commit,
    'chain_index': room.chainIndex,
    'game_id': room.gameId,
    'client_seeds': room.clientSeeds,
    'seats': <Object?>[
      for (final Seat seat in room.seats) _seatSnapshot(room, seat),
    ],
    'turn': _turnSnapshot(room, now),
    'winner': room.game?.winner,
    'seq': room.seq,
  };
}

Map<String, Object?> _seatSnapshot(Room room, Seat seat) {
  final List<int> tokens =
      room.game?.tokens[seat.seat] ?? const <int>[-1, -1, -1, -1];
  return <String, Object?>{
    'seat': seat.seat,
    'name': seat.name,
    'connected': seat.connected,
    'tokens': tokens,
    // docs/PROTOCOL.md section 6: null until this seat's seed is fixed,
    // and `seed_origin` is `"player"` or `"server"` from that point on and
    // never null again.
    'client_seed': seat.clientSeed,
    'seed_origin': seat.seedOrigin,
  };
}

/// `docs/PROTOCOL.md` section 6: `value`, `legal` and `sixes` are absent
/// when `phase` is `await_roll`; `deadline_ms` and `k` are present in every
/// phase. Before `start_game`, `room.game` is null and there is no turn yet.
Map<String, Object?>? _turnSnapshot(Room room, DateTime now) {
  final engine.GameState? game = room.game;
  if (game == null) {
    return null;
  }
  final Map<String, Object?> turn = <String, Object?>{
    'seat': game.currentSeat,
    'phase': _wirePhase(game.phase),
  };
  if (game.phase == engine.GamePhase.awaitMove) {
    turn['value'] = game.roll;
    turn['legal'] = engine.legalTokens(game);
    turn['sixes'] = game.sixes;
  }
  turn['deadline_ms'] = _deadlineMs(room, now);
  turn['k'] = room.rollCount;
  return turn;
}

/// `docs/PROTOCOL.md` section 6's `deadline_ms` formula, read against [now]
/// rather than against the moment some earlier frame was built -- a `room`
/// snapshot can be requested at any time after the segment it describes
/// started, so this is computed fresh every time this function runs, unlike
/// the `deadline_ms` on a `rolled` or `turn` push, which the registry fixed
/// once, at the instant that specific frame was decided, and which this
/// file never recomputes.
int _deadlineMs(Room room, DateTime now) {
  final DateTime? startedAt = room.turnSegmentStartedAt;
  if (startedAt == null) {
    return 0;
  }
  final int budgetMs = room.rules.turnSeconds * 1000;
  final int elapsedMs = now.difference(startedAt).inMilliseconds;
  final int remaining = budgetMs - elapsedMs;
  return remaining > 0 ? remaining : 0;
}

String _wireState(RoomState state) {
  switch (state) {
    case RoomState.lobby:
      return 'LOBBY';
    case RoomState.playing:
      return 'PLAYING';
    case RoomState.finished:
      return 'FINISHED';
  }
}

String _wirePhase(engine.GamePhase phase) {
  switch (phase) {
    case engine.GamePhase.awaitRoll:
      return 'await_roll';
    case engine.GamePhase.awaitMove:
      return 'await_move';
    case engine.GamePhase.finished:
      return 'finished';
  }
}

/// `seat_assigned`, section 5. Goes to exactly one socket, the one that just
/// took this seat, and its `seat_token` must never appear anywhere else: not
/// in a broadcast, not in a log line, not in any other client's snapshot.
Map<String, Object?> buildSeatAssigned(Seat seat) {
  return <String, Object?>{
    'seat': seat.seat,
    'seat_token': seat.seatToken,
  };
}

/// `player_joined`, section 5. `seq` is read from `room.seq` at the moment
/// the push is built, per section 5's "carrying `seq`" list.
Map<String, Object?> buildPlayerJoined(Seat seat, int seq) {
  return <String, Object?>{
    'seat': seat.seat,
    'name': seat.name,
    'seq': seq,
  };
}

/// `player_left`, section 5.
Map<String, Object?> buildPlayerLeft(int seat, int seq) {
  return <String, Object?>{'seat': seat, 'seq': seq};
}

/// `presence`, section 5.
Map<String, Object?> buildPresence(int seat, bool connected, int seq) {
  return <String, Object?>{'seat': seat, 'connected': connected, 'seq': seq};
}

/// `game_started`, section 5 and section 11.2: `{ "turn": int, "game_id":
/// string, "client_seeds": string }`, plus `seq`.
///
/// No `seed_commit` -- the commitment is `chain_commit`, already published
/// in `room` at room creation, and it is not repeated here because it has
/// not changed. `game_id` and `client_seeds` are read off [room], which
/// `RoomRegistry.startGame` has already set by the time this is called;
/// both are frozen from this instant on and never appear anywhere else in
/// this file.
Map<String, Object?> buildGameStarted(Room room, int seq) {
  final engine.GameState game = room.game!;
  return <String, Object?>{
    'turn': game.currentSeat,
    'game_id': room.gameId,
    'client_seeds': room.clientSeeds,
    'seq': seq,
  };
}

/// `seat_seed`, section 5 and section 11.2: broadcast to the whole room
/// whenever a seat's seed is fixed -- once on an accepted `set_seed`
/// (`origin: "player"`), and again at `start_game` for every seat that sent
/// none (`origin: "server"`).
Map<String, Object?> buildSeatSeed({
  required int seat,
  required String clientSeed,
  required String origin,
  required int seq,
}) {
  return <String, Object?>{
    'seat': seat,
    'client_seed': clientSeed,
    'origin': origin,
    'seq': seq,
  };
}

/// `rolled`, section 5 and section 11.2/11.3: `value`, `legal`,
/// `deadline_ms`, `k` and `reveal` are exactly what the registry's `roll()`
/// call decided -- this never recomputes a face, a chain link or a `seq`,
/// it only lays out the fields that were already fixed by the one code path
/// allowed to read `chain.reveal(k)` and publish it.
Map<String, Object?> buildRolled({
  required int seat,
  required int value,
  required List<int> legal,
  required int deadlineMs,
  required int k,
  required String reveal,
  required int seq,
}) {
  return <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': legal,
    'deadline_ms': deadlineMs,
    'k': k,
    'reveal': reveal,
    'seq': seq,
  };
}

/// `turn_passed`, section 5: `reason` is `"no_legal_move"` or
/// `"three_sixes"`, the wire strings for `engine.TurnEndReason`.
Map<String, Object?> buildTurnPassed({
  required int seat,
  required String reason,
  required int seq,
}) {
  return <String, Object?>{'seat': seat, 'reason': reason, 'seq': seq};
}

/// `turn`, section 5: sent for the seat that now holds the turn, whether
/// because the turn passed or because that seat was granted an extra roll.
Map<String, Object?> buildTurn({
  required int seat,
  required int deadlineMs,
  required int seq,
}) {
  return <String, Object?>{'seat': seat, 'deadline_ms': deadlineMs, 'seq': seq};
}

/// `moved`, section 5 and section 12.2: built from the engine's own `Moved`
/// and `Captured` events and from nothing else. `captured` is the list of
/// `{seat, token}` the engine reported captured by this move, in the order
/// it reported them, empty when there were none.
Map<String, Object?> buildMoved({
  required int seat,
  required int token,
  required int from,
  required int to,
  required List<Map<String, Object?>> captured,
  required bool extraRoll,
  required int seq,
}) {
  return <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
    'seq': seq,
  };
}

/// `game_over`, section 5 and section 11.2: no `seed` -- every roll's secret
/// was already published in its own `rolled` frame -- and `verify_url` is
/// the permalink, `https://provefair.app/v/<game_id>`, built by the
/// registry from `room.gameId` and handed in here unchanged.
Map<String, Object?> buildGameOver({
  required int winner,
  required String verifyUrl,
  required int seq,
}) {
  return <String, Object?>{
    'winner': winner,
    'verify_url': verifyUrl,
    'seq': seq,
  };
}
