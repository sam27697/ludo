// docs/PROTOCOL.md section 6, and the section 5 payload shapes that are
// built straight from a `Room` or a `Seat` rather than from an inbound
// message. `docs/ENGINE_API.md` section 9 is the wire mapping for the
// engine's own vocabulary; this file is the server's half of that mapping,
// turning a `GameState` into the redacted snapshot a client is allowed to
// see. `rngState` and `config.seed` never appear below, on purpose: sending
// either would hand a client every future roll.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'room.dart';

/// The full `room` push, section 6. `seq` is read, never computed: it is
/// `room.seq`, the registry's own counter, moved by exactly one on every
/// successful state-changing call before this is ever built.
Map<String, Object?> buildRoomSnapshot(Room room) {
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
    'seats': <Object?>[
      for (final Seat seat in room.seats) _seatSnapshot(room, seat),
    ],
    'turn': _turnSnapshot(room.game),
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
  };
}

/// `docs/PROTOCOL.md` section 6: `value`, `legal` and `sixes` are absent
/// when `phase` is `await_roll`. `deadline_ms` is not built here at all --
/// the 45 second timer is order 008's, per this order's "Out of scope".
/// Before `start_game`, `room.game` is null and there is no turn yet.
Map<String, Object?>? _turnSnapshot(engine.GameState? game) {
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
  return turn;
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

/// `game_started`, section 5: `{ "turn": int, "seed_commit": string }`, plus
/// `seq`, now on the "carrying `seq`" list.
///
/// `seed_commit` is pinned by section 6: SHA-256, lowercase hex, over the
/// UTF-8 bytes of the seed's decimal representation, so that
/// `seed_commit == sha256(seed.toString())`. It is deliberately not
/// `engine.stateHash`, which is FNV-1a and a checksum rather than a
/// commitment -- collisions are cheap to construct, so a server committing
/// with a checksum could still pick a different seed afterwards that
/// happened to match.
Map<String, Object?> buildGameStarted(engine.GameState freshGame, int seq) {
  final String seedCommit = crypto.sha256
      .convert(utf8.encode(freshGame.config.seed.toString()))
      .toString();
  return <String, Object?>{
    'turn': freshGame.currentSeat,
    'seed_commit': seedCommit,
    'seq': seq,
  };
}
