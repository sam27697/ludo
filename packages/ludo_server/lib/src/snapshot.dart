// docs/PROTOCOL.md sections 6, 5 and 11, and the section 5 payload shapes
// that are built straight from a `Room` or a `Seat` rather than from an
// inbound message. `docs/ENGINE_API.md` section 9 is the wire mapping for
// the engine's own vocabulary; this file is the server's half of that
// mapping, turning a `GameState` into the redacted snapshot a client is
// allowed to see. `rngState`, `config.seed` and a room's dice-chain server
// secret never appear below, on purpose: sending any of them would hand a
// client every future roll.

import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'registry.dart';
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
      // docs/PROTOCOL.md section 4, 2026-10-15 ruling: every room plays
      // with blocks off, so every frame that carries rules says so,
      // whatever was requested at create_room.
      'blocks': false,
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
    // docs/PROTOCOL.md section 16.6: null, or { "by": seat, "ready": [seat,
    // ...] } with `ready` in ascending seat order. Present in every state;
    // non-null only in a rematch LOBBY.
    'rematch': _rematchSnapshot(room.rematch),
    'seq': room.seq,
  };
}

Map<String, Object?>? _rematchSnapshot(Rematch? rematch) {
  if (rematch == null) {
    return null;
  }
  return <String, Object?>{
    'by': rematch.by,
    'ready': List<int>.of(rematch.ready)..sort(),
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

/// `docs/PROTOCOL.md` section 6 and section 21.3 rule 2: `value`, `legal`,
/// `sixes` and `legal_by_face` are absent when `phase` is `await_roll`;
/// `deadline_ms`, `k` and `queue` are present in every phase (`queue` is
/// `[]` in `finished`, never omitted there). Before `start_game`,
/// `room.game` is null and there is no turn yet.
Map<String, Object?>? _turnSnapshot(Room room, DateTime now) {
  final engine.GameState? game = room.game;
  if (game == null) {
    return null;
  }
  final TurnQueueFields queueFields = turnQueueFields(game);
  final Map<String, Object?> turn = <String, Object?>{
    'seat': game.currentSeat,
    'phase': queueFields.phase,
    'queue': queueFields.queue,
  };
  if (game.phase == engine.GamePhase.awaitMove) {
    // docs/PROTOCOL.md section 21.3 rule 2: `value` is `defaultFace`, not
    // `game.roll` -- `game.roll` is always null under the queue
    // (ENGINE_API.md section 10.1) and `defaultFace` is the one thing that
    // decides which queued face an omitted `move.face` would spend.
    turn['value'] = queueFields.value;
    turn['legal'] = queueFields.legal;
    turn['sixes'] = game.sixes;
    turn['legal_by_face'] = queueFields.legalByFace;
  }
  turn['deadline_ms'] = _deadlineMs(room, now);
  turn['k'] = room.rollCount;
  return turn;
}

/// `docs/PROTOCOL.md` section 21.1 and 21.3: the fields every `turn` --
/// pushed or snapshotted -- carries about the roll queue, computed once
/// from the engine state the moment that specific frame is fixed, never
/// re-derived from any legality rule of this file's own. `phase` and
/// `queue` are always set; `value`, `legal` and `legalByFace` are set only
/// when [game]'s phase is `awaitMove`, where `value` is
/// `engine.defaultFace` (the engine's own `roll` is always null under the
/// queue) and `legal` is that face's own legal tokens, ascending.
class TurnQueueFields {
  TurnQueueFields({
    required this.phase,
    required this.queue,
    this.value,
    this.legal,
    this.legalByFace,
  });

  final String phase;
  final List<int> queue;
  final int? value;
  final List<int>? legal;
  final List<Map<String, Object?>>? legalByFace;
}

TurnQueueFields turnQueueFields(engine.GameState game) {
  final String phase = _wirePhase(game.phase);
  final List<int> queue = List<int>.of(game.queue);
  if (game.phase != engine.GamePhase.awaitMove) {
    return TurnQueueFields(phase: phase, queue: queue);
  }
  return TurnQueueFields(
    phase: phase,
    queue: queue,
    value: engine.defaultFace(game),
    legal: engine.legalTokens(game),
    legalByFace: _wireLegalByFace(game),
  );
}

/// `docs/ENGINE_API.md` section 10.1's `legalByFace`, in the wire shape
/// section 21.1 fixes: `[{"face": int, "tokens": [int]}]`, in first-queued
/// order (the map's own iteration order, which `engine.legalByFace` already
/// builds in that order and this file does not re-sort).
List<Map<String, Object?>> _wireLegalByFace(engine.GameState game) {
  final Map<int, List<int>> byFace = engine.legalByFace(game);
  return <Map<String, Object?>>[
    for (final entry in byFace.entries)
      <String, Object?>{'face': entry.key, 'tokens': entry.value},
  ];
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

/// `seat_assigned`, section 5. Sent to one socket at a time: the seat that
/// just took its place on `create_room` or `join_room`, the resuming socket
/// on every `resume` whether or not its seat number moved while it was away
/// (section 15 rule 2), and a connected seat whose number `set_players` just
/// changed (section 15 rule 1). Its `seat_token` must never appear anywhere
/// else: not in a broadcast, not in a log line, not in any other client's
/// snapshot.
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

/// `player_left`, section 5 and section 18: `host_seat` is the room's host
/// after the seat was freed, or -1 when none is left.
Map<String, Object?> buildPlayerLeft(int seat, int hostSeat, int seq) {
  return <String, Object?>{
    'seat': seat,
    'host_seat': hostSeat,
    'seq': seq,
  };
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

/// `rolled`, section 5, section 11.2/11.3 and section 21.1/21.3: `value`,
/// `legal`, `deadline_ms`, `k` and `reveal` are exactly what the registry's
/// `roll()` call decided -- this never recomputes a face, a chain link or a
/// `seq`, it only lays out the fields that were already fixed by the one
/// code path allowed to read `chain.reveal(k)` and publish it. `queue` is
/// the queue after the roll (section 21.3 rule 3), and `legalByFace` is
/// given, and only given, when the phase after the roll is `await_move`.
Map<String, Object?> buildRolled({
  required int seat,
  required int value,
  required List<int> legal,
  required int deadlineMs,
  required int k,
  required String reveal,
  required int seq,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) {
  return <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': legal,
    'deadline_ms': deadlineMs,
    'k': k,
    'reveal': reveal,
    'seq': seq,
    if (queue != null) 'queue': queue,
    if (legalByFace != null) 'legal_by_face': legalByFace,
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

/// `turn`, section 5 and section 21.3 rule 1: sent for the seat that now
/// holds the turn, whether because the turn passed, because that seat was
/// granted an extra roll, or because that seat still has faces left to
/// spend. `phase` and `queue` are given on every call since every room
/// plays the queue (section 21.3 rule 5); `value`, `legal` and
/// `legalByFace` are given, and only given, when `phase` is `await_move`.
Map<String, Object?> buildTurn({
  required int seat,
  required int deadlineMs,
  required int seq,
  String? phase,
  List<int>? queue,
  int? value,
  List<int>? legal,
  List<Map<String, Object?>>? legalByFace,
}) {
  return <String, Object?>{
    'seat': seat,
    'deadline_ms': deadlineMs,
    'seq': seq,
    if (phase != null) 'phase': phase,
    if (queue != null) 'queue': queue,
    if (value != null) 'value': value,
    if (legal != null) 'legal': legal,
    if (legalByFace != null) 'legal_by_face': legalByFace,
  };
}

/// `moved`, section 5, section 12.2 and section 21.1: built from the
/// engine's own `Moved` and `Captured` events and from nothing else, plus
/// the face this move spent, which the registry fixed at `move()` time
/// because the engine's own `Moved` event carries none. `captured` is the
/// list of `{seat, token}` the engine reported captured by this move, in
/// the order it reported them, empty when there were none.
Map<String, Object?> buildMoved({
  required int seat,
  required int token,
  required int from,
  required int to,
  required List<Map<String, Object?>> captured,
  required bool extraRoll,
  required int seq,
  int? face,
}) {
  return <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
    'seq': seq,
    if (face != null) 'face': face,
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

/// One frame the wire layer must publish, and the type name it goes out
/// under. A list of these is an order, not a set: section 12 fixes the order
/// frames are sent in and a caller sends them exactly as given.
class OutFrame {
  const OutFrame(this.type, this.data);

  final String type;
  final Map<String, Object?> data;
}

/// The wire string for `engine.TurnEndReason`, `docs/PROTOCOL.md` section 5's
/// `turn_passed.reason`. Public because both the client-driven path in
/// `connection.dart` and the timer-driven path below need it and a second
/// copy of a two-branch mapping is a second place for it to drift.
String wireTurnEndReason(engine.TurnEndReason reason) {
  switch (reason) {
    case engine.TurnEndReason.noLegalMove:
      return 'no_legal_move';
    case engine.TurnEndReason.threeSixes:
      return 'three_sixes';
  }
}

/// Every frame a timer-played turn publishes, in section 21.3 rule 4's own
/// order, which replaces section 12 for every room since every room plays
/// the queue: for a roll, `rolled` and then whichever of `turn_passed` +
/// `turn` or a bare `turn` applies, exactly as the client-driven path in
/// `connection.dart` decides it (`rolled.turnPassedSeq`/`rolled.turnSeq`);
/// for a move, `moved` and then `game_over`, or whichever of `turn_passed` +
/// `turn` or a bare `turn` applies (`moved.turnPassedSeq`/`moved.turnSeq`).
/// None of them carries `re`: no client request is being answered, so there
/// is no id to answer.
List<OutFrame> buildExpiryFrames(ExpiredTurn expired) {
  final List<OutFrame> frames = <OutFrame>[];

  final RollOk? rolled = expired.roll;
  if (rolled != null) {
    final engine.Rolled event = rolled.events.whereType<engine.Rolled>().single;
    final engine.GameState afterRoll = rolled.room.game!;
    final TurnQueueFields afterRollFields = turnQueueFields(afterRoll);
    frames.add(
      OutFrame(
        'rolled',
        buildRolled(
          seat: event.seat,
          value: event.value,
          legal: event.legal,
          deadlineMs: rolled.rolledDeadlineMs,
          k: rolled.k,
          reveal: rolled.reveal,
          seq: rolled.rolledSeq,
          queue: afterRollFields.queue,
          legalByFace: afterRollFields.legalByFace,
        ),
      ),
    );
    if (rolled.turnPassedSeq != null) {
      final engine.TurnEnded ended =
          rolled.events.whereType<engine.TurnEnded>().single;
      frames.add(
        OutFrame(
          'turn_passed',
          buildTurnPassed(
            seat: ended.seat,
            reason: wireTurnEndReason(ended.reason),
            seq: rolled.turnPassedSeq!,
          ),
        ),
      );
    }
    if (rolled.turnSeq != null) {
      frames.add(
        OutFrame(
          'turn',
          buildTurn(
            seat: afterRoll.currentSeat,
            deadlineMs: rolled.nextDeadlineMs!,
            seq: rolled.turnSeq!,
            phase: afterRollFields.phase,
            queue: afterRollFields.queue,
            value: afterRollFields.value,
            legal: afterRollFields.legal,
            legalByFace: afterRollFields.legalByFace,
          ),
        ),
      );
    }
    return frames;
  }

  final MoveOk moved = expired.move!;
  final engine.Moved event = moved.events.whereType<engine.Moved>().single;
  frames.add(
    OutFrame(
      'moved',
      buildMoved(
        seat: event.seat,
        token: event.token,
        from: event.from,
        to: event.to,
        captured: <Map<String, Object?>>[
          for (final engine.Captured c
              in moved.events.whereType<engine.Captured>())
            <String, Object?>{'seat': c.seat, 'token': c.token},
        ],
        extraRoll: moved.events.whereType<engine.ExtraRoll>().isNotEmpty,
        seq: moved.movedSeq,
        face: moved.face,
      ),
    ),
  );
  final List<engine.GameWon> won =
      moved.events.whereType<engine.GameWon>().toList();
  if (won.isNotEmpty) {
    frames.add(
      OutFrame(
        'game_over',
        buildGameOver(
          winner: won.single.seat,
          verifyUrl: moved.verifyUrl!,
          seq: moved.gameOverSeq!,
        ),
      ),
    );
    return frames;
  }
  final engine.GameState afterMove = moved.room.game!;
  final TurnQueueFields afterMoveFields = turnQueueFields(afterMove);
  if (moved.turnPassedSeq != null) {
    final engine.TurnEnded ended =
        moved.events.whereType<engine.TurnEnded>().single;
    frames.add(
      OutFrame(
        'turn_passed',
        buildTurnPassed(
          seat: ended.seat,
          reason: wireTurnEndReason(ended.reason),
          seq: moved.turnPassedSeq!,
        ),
      ),
    );
  }
  frames.add(
    OutFrame(
      'turn',
      buildTurn(
        seat: afterMove.currentSeat,
        deadlineMs: moved.nextDeadlineMs!,
        seq: moved.turnSeq!,
        phase: afterMoveFields.phase,
        queue: afterMoveFields.queue,
        value: afterMoveFields.value,
        legal: afterMoveFields.legal,
        legalByFace: afterMoveFields.legalByFace,
      ),
    ),
  );
  return frames;
}
