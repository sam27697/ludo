// docs/PROTOCOL.md section 6 (the room snapshot), section 5 (the fields it
// shares with the rest of server-to-client), and section 14 (the two
// rulings on `turn` that section 6 alone did not say enough to decode
// against). Pure JSON-to-Dart mapping; nothing here opens a socket or
// touches a widget.
//
// packages/ludo_server/lib/src/snapshot.dart is the reference producer for
// every shape decoded below.

/// Thrown by every `fromJson` in this file and by nothing else in it.
class SnapshotFormatException implements Exception {
  const SnapshotFormatException(this.reason);
  final String reason;
  @override
  String toString() => 'SnapshotFormatException: $reason';
}

enum RoomState { lobby, playing, finished }

/// Three values, not two. docs/PROTOCOL.md section 14.1.
enum TurnPhase { awaitRoll, awaitMove, finished }

enum SeedOrigin { player, server }

class RulesConfig {
  const RulesConfig({
    this.blocks = true,
    this.captureBonus = true,
    this.turnSeconds = 45,
  });

  final bool blocks;
  final bool captureBonus;
  final int turnSeconds;

  /// Defaults each key individually when it is absent from [json], matching
  /// docs/PROTOCOL.md section 13.4. An absent `rules` object entirely is the
  /// caller's problem, not this constructor's: `RoomSnapshot.fromJson` is the
  /// one that requires the `rules` key to exist at all.
  factory RulesConfig.fromJson(Map<String, Object?> json) {
    bool blocks = true;
    if (json.containsKey('blocks')) {
      final Object? value = json['blocks'];
      if (value is! bool) {
        throw const SnapshotFormatException('blocks');
      }
      blocks = value;
    }

    bool captureBonus = true;
    if (json.containsKey('capture_bonus')) {
      final Object? value = json['capture_bonus'];
      if (value is! bool) {
        throw const SnapshotFormatException('capture_bonus');
      }
      captureBonus = value;
    }

    int turnSeconds = 45;
    if (json.containsKey('turn_seconds')) {
      final Object? value = json['turn_seconds'];
      if (value is! int) {
        throw const SnapshotFormatException('turn_seconds');
      }
      turnSeconds = value;
    }
    if (turnSeconds < 15 || turnSeconds > 120) {
      throw const SnapshotFormatException('turn_seconds');
    }

    return RulesConfig(
      blocks: blocks,
      captureBonus: captureBonus,
      turnSeconds: turnSeconds,
    );
  }

  /// Emits exactly the three keys of docs/PROTOCOL.md section 4, always all
  /// three, in the order `blocks`, `capture_bonus`, `turn_seconds`.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'blocks': blocks,
      'capture_bonus': captureBonus,
      'turn_seconds': turnSeconds,
    };
  }
}

class SeatState {
  const SeatState({
    required this.seat,
    required this.name,
    required this.connected,
    required this.tokens,
    required this.clientSeed,
    required this.seedOrigin,
  });

  final int seat;
  final String name;
  final bool connected;

  /// Exactly four `progress` integers, docs/RULES.md section 1.2.
  final List<int> tokens;

  final String? clientSeed;
  final SeedOrigin? seedOrigin;

  factory SeatState.fromJson(Map<String, Object?> json) {
    final int seat = _reqInt(json, 'seat');
    if (seat < 0 || seat > 3) {
      throw const SnapshotFormatException('seat');
    }
    final String name = _reqString(json, 'name');
    final bool connected = _reqBool(json, 'connected');
    final List<int> tokens = _reqIntList(json, 'tokens', exactLength: 4);
    final String? clientSeed = _optString(json, 'client_seed');
    final SeedOrigin? seedOrigin = _optSeedOrigin(json, 'seed_origin');

    return SeatState(
      seat: seat,
      name: name,
      connected: connected,
      tokens: tokens,
      clientSeed: clientSeed,
      seedOrigin: seedOrigin,
    );
  }

  /// A copy with the given fields replaced. Every omitted parameter keeps
  /// this instance's value; there is no way to null out [clientSeed] or
  /// [seedOrigin] through this method, because nothing that constructs a
  /// [SeatState] copy today needs to.
  SeatState copyWith({
    int? seat,
    String? name,
    bool? connected,
    List<int>? tokens,
    String? clientSeed,
    SeedOrigin? seedOrigin,
  }) {
    return SeatState(
      seat: seat ?? this.seat,
      name: name ?? this.name,
      connected: connected ?? this.connected,
      tokens: tokens ?? this.tokens,
      clientSeed: clientSeed ?? this.clientSeed,
      seedOrigin: seedOrigin ?? this.seedOrigin,
    );
  }
}

class TurnState {
  const TurnState({
    required this.seat,
    required this.phase,
    required this.deadlineMs,
    required this.k,
    this.value,
    this.legal,
    this.sixes,
  });

  final int seat;
  final TurnPhase phase;
  final int deadlineMs;
  final int k;
  final int? value;
  final List<int>? legal;
  final int? sixes;

  factory TurnState.fromJson(Map<String, Object?> json) {
    final int seat = _reqInt(json, 'seat');
    if (seat < 0 || seat > 3) {
      throw const SnapshotFormatException('seat');
    }
    final TurnPhase phase = _reqTurnPhase(json, 'phase');
    final int deadlineMs = _reqInt(json, 'deadline_ms');
    final int k = _reqInt(json, 'k');
    final int? value = _optInt(json, 'value');
    final List<int>? legal = _optIntList(json, 'legal');
    final int? sixes = _optInt(json, 'sixes');

    return TurnState(
      seat: seat,
      phase: phase,
      deadlineMs: deadlineMs,
      k: k,
      value: value,
      legal: legal,
      sixes: sixes,
    );
  }
}

class RoomSnapshot {
  const RoomSnapshot({
    required this.code,
    required this.state,
    required this.hostSeat,
    required this.players,
    required this.rules,
    required this.chainCommit,
    required this.chainIndex,
    required this.gameId,
    required this.clientSeeds,
    required this.seats,
    required this.turn,
    required this.winner,
    required this.seq,
  });

  final String code;
  final RoomState state;
  final int hostSeat;
  final int players;
  final RulesConfig rules;
  final String chainCommit;
  final int chainIndex;
  final String? gameId;
  final String? clientSeeds;
  final List<SeatState> seats;

  /// Null in LOBBY only. Non-null in PLAYING and in FINISHED.
  /// docs/PROTOCOL.md section 14.2.
  final TurnState? turn;

  final int? winner;
  final int seq;

  /// No cross-field consistency is checked here. docs/PROTOCOL.md section 10
  /// makes the server authoritative and the client a renderer: this decoder
  /// does not require `turn` to be null in LOBBY, does not require `winner`
  /// to be set in FINISHED, and does not require `value`, `legal` and
  /// `sixes` to be absent under `await_roll`. If those fields arrive, they
  /// are recorded as they arrived. Type safety is this function's job;
  /// game-state coherence is the server's.
  factory RoomSnapshot.fromJson(Map<String, Object?> json) {
    final String code = _reqString(json, 'code');
    final RoomState state = _reqRoomState(json, 'state');

    final int hostSeat = _reqInt(json, 'host_seat');
    if (hostSeat < 0 || hostSeat > 3) {
      throw const SnapshotFormatException('host_seat');
    }

    final int players = _reqInt(json, 'players');
    if (players < 2 || players > 4) {
      throw const SnapshotFormatException('players');
    }

    final Map<String, Object?> rulesJson = _reqObject(json, 'rules');
    final RulesConfig rules = RulesConfig.fromJson(rulesJson);

    final String chainCommit = _reqString(json, 'chain_commit');
    final int chainIndex = _reqInt(json, 'chain_index');
    final String? gameId = _optString(json, 'game_id');
    final String? clientSeeds = _optString(json, 'client_seeds');

    final Object? seatsValue = json['seats'];
    if (seatsValue is! List) {
      throw const SnapshotFormatException('seats');
    }
    final List<SeatState> seats = <SeatState>[];
    for (final Object? seatJson in seatsValue) {
      if (seatJson is! Map<String, Object?>) {
        throw const SnapshotFormatException('seats');
      }
      seats.add(SeatState.fromJson(seatJson));
    }

    TurnState? turn;
    final Object? turnValue = json['turn'];
    if (turnValue != null) {
      if (turnValue is! Map<String, Object?>) {
        throw const SnapshotFormatException('turn');
      }
      turn = TurnState.fromJson(turnValue);
    }

    final int? winner = _optInt(json, 'winner');
    if (winner != null && (winner < 0 || winner > 3)) {
      throw const SnapshotFormatException('winner');
    }

    final int seq = _reqInt(json, 'seq');

    return RoomSnapshot(
      code: code,
      state: state,
      hostSeat: hostSeat,
      players: players,
      rules: rules,
      chainCommit: chainCommit,
      chainIndex: chainIndex,
      gameId: gameId,
      clientSeeds: clientSeeds,
      seats: seats,
      turn: turn,
      winner: winner,
      seq: seq,
    );
  }

  /// A copy with the given fields replaced. Every omitted parameter keeps
  /// this instance's value; there is no way to null out [gameId],
  /// [clientSeeds], [turn] or [winner] through this method, because nothing
  /// that constructs a [RoomSnapshot] copy today needs to.
  RoomSnapshot copyWith({
    String? code,
    RoomState? state,
    int? hostSeat,
    int? players,
    RulesConfig? rules,
    String? chainCommit,
    int? chainIndex,
    String? gameId,
    String? clientSeeds,
    List<SeatState>? seats,
    TurnState? turn,
    int? winner,
    int? seq,
  }) {
    return RoomSnapshot(
      code: code ?? this.code,
      state: state ?? this.state,
      hostSeat: hostSeat ?? this.hostSeat,
      players: players ?? this.players,
      rules: rules ?? this.rules,
      chainCommit: chainCommit ?? this.chainCommit,
      chainIndex: chainIndex ?? this.chainIndex,
      gameId: gameId ?? this.gameId,
      clientSeeds: clientSeeds ?? this.clientSeeds,
      seats: seats ?? this.seats,
      turn: turn ?? this.turn,
      winner: winner ?? this.winner,
      seq: seq ?? this.seq,
    );
  }
}

// --- decoding helpers -------------------------------------------------
//
// Every one of these throws SnapshotFormatException naming the offending
// key and never lets a cast failure or a TypeError escape. `_req*` is for a
// field whose Dart type is non-nullable: missing, explicit null, or the
// wrong runtime type all throw. `_opt*` is for a field whose Dart type is
// nullable: missing or explicit null both decode to null, and only the
// wrong runtime type throws. Unknown keys elsewhere in the map are never
// inspected, so they are implicitly ignored.
//
// JSON integers arriving as a double with a zero fraction (`1.0` rather
// than `1`) are rejected by the plain `is! int` check below rather than
// coerced: the server always sends `int`, and accepting `1.0` would hide a
// producer that has drifted.

int _reqInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! int) {
    throw SnapshotFormatException(key);
  }
  return value;
}

int? _optInt(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw SnapshotFormatException(key);
  }
  return value;
}

String _reqString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String) {
    throw SnapshotFormatException(key);
  }
  return value;
}

String? _optString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw SnapshotFormatException(key);
  }
  return value;
}

bool _reqBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! bool) {
    throw SnapshotFormatException(key);
  }
  return value;
}

Map<String, Object?> _reqObject(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! Map<String, Object?>) {
    throw SnapshotFormatException(key);
  }
  return value;
}

List<int> _reqIntList(
  Map<String, Object?> json,
  String key, {
  int? exactLength,
}) {
  final Object? value = json[key];
  if (value is! List) {
    throw SnapshotFormatException(key);
  }
  if (exactLength != null && value.length != exactLength) {
    throw SnapshotFormatException(key);
  }
  final List<int> result = <int>[];
  for (final Object? element in value) {
    if (element is! int) {
      throw SnapshotFormatException(key);
    }
    result.add(element);
  }
  return result;
}

List<int>? _optIntList(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  return _reqIntList(json, key);
}

RoomState _reqRoomState(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String) {
    throw SnapshotFormatException(key);
  }
  switch (value) {
    case 'LOBBY':
      return RoomState.lobby;
    case 'PLAYING':
      return RoomState.playing;
    case 'FINISHED':
      return RoomState.finished;
    default:
      throw SnapshotFormatException(key);
  }
}

TurnPhase _reqTurnPhase(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String) {
    throw SnapshotFormatException(key);
  }
  switch (value) {
    case 'await_roll':
      return TurnPhase.awaitRoll;
    case 'await_move':
      return TurnPhase.awaitMove;
    case 'finished':
      return TurnPhase.finished;
    default:
      throw SnapshotFormatException(key);
  }
}

SeedOrigin? _optSeedOrigin(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw SnapshotFormatException(key);
  }
  switch (value) {
    case 'player':
      return SeedOrigin.player;
    case 'server':
      return SeedOrigin.server;
    default:
      throw SnapshotFormatException(key);
  }
}
