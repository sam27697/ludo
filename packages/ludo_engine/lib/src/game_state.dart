// docs/ENGINE_API.md section 2 (the GameState shape), section 8 (the
// serialisation) and section 10 (the roll queue). The toJson key order below
// is normative: the golden corpus hash is pinned to it.

import 'enums.dart';
import 'game_config.dart';
import 'rules_config.dart';

class GameState {
  GameState({
    required this.config,
    required List<List<int>> tokens,
    required this.currentSeat,
    required this.phase,
    required this.roll,
    required this.sixes,
    required this.winner,
    required this.seq,
    required this.rngState,
    List<int> queue = const <int>[],
  })  : tokens = _freezeTokens(tokens),
        queue = List<int>.unmodifiable(queue);

  final GameConfig config;

  /// Always 4 rows of 4. tokens[seat][index] is that token's progress.
  /// Rows for seats not in config.seats stay [-1,-1,-1,-1] forever.
  final List<List<int>> tokens;

  final int currentSeat;
  final GamePhase phase;

  /// null in awaitRoll and finished; 1..6 in awaitMove. Always null with
  /// `rules.rollQueue` on (docs/ENGINE_API.md section 10.1): `queue` carries
  /// the faces instead.
  final int? roll;

  /// docs/ENGINE_API.md section 10.1: unspent faces in roll order. Always
  /// `[]` when `rules.rollQueue` is off.
  final List<int> queue;

  /// Consecutive 6s already rolled this turn, 0..2.
  final int sixes;

  /// null until a seat wins, then that seat.
  final int? winner;

  /// Increments by 1 on every accepted intention.
  final int seq;

  /// The future of the dice, in the sense that it still is one -- but the
  /// engine no longer reads it. Since rule 38 (docs/RULES.md), the die face
  /// travels inside `RollIntention` and `apply` never touches this field; it
  /// is carried forward unchanged from `newGame` on every transition. It
  /// stays in the state and in `stateHash` because removing it would break
  /// `packages/ludo_server`'s `seed_commit` computation, which is a change
  /// that belongs to the protocol order (`docs/FAIRNESS.md` section 7 item 3,
  /// work order 021's successor), not to this one. Secret; never leaves the
  /// server.
  final int rngState;

  static List<List<int>> _freezeTokens(List<List<int>> tokens) {
    return List<List<int>>.unmodifiable(<List<int>>[
      for (final row in tokens) List<int>.unmodifiable(row),
    ]);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'config': _configToJson(config),
        'tokens': <List<int>>[
          for (final row in tokens) List<int>.of(row),
        ],
        'currentSeat': currentSeat,
        'phase': _phaseToWire(phase),
        'roll': roll,
        if (config.rules.rollQueue) 'queue': List<int>.of(queue),
        'sixes': sixes,
        'winner': winner,
        'seq': seq,
        'rngState': rngState,
      };

  factory GameState.fromJson(Map<String, Object?> json) {
    final configJson = json['config']! as Map<String, Object?>;
    final config = _configFromJson(configJson);
    final tokensJson = json['tokens']! as List<Object?>;
    final tokens = <List<int>>[
      for (final row in tokensJson)
        <int>[for (final v in row! as List<Object?>) _asInt(v)],
    ];
    return GameState(
      config: config,
      tokens: tokens,
      currentSeat: _asInt(json['currentSeat']),
      phase: _phaseFromWire(json['phase']! as String),
      roll: _asIntOrNull(json['roll']),
      sixes: _asInt(json['sixes']),
      winner: _asIntOrNull(json['winner']),
      seq: _asInt(json['seq']),
      rngState: _asInt(json['rngState']),
      queue: _queueFromJson(json, config.rules.rollQueue),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! GameState) {
      return false;
    }
    if (config != other.config ||
        currentSeat != other.currentSeat ||
        phase != other.phase ||
        roll != other.roll ||
        sixes != other.sixes ||
        winner != other.winner ||
        seq != other.seq ||
        rngState != other.rngState) {
      return false;
    }
    if (tokens.length != other.tokens.length) {
      return false;
    }
    for (var s = 0; s < tokens.length; s++) {
      final row = tokens[s];
      final otherRow = other.tokens[s];
      if (row.length != otherRow.length) {
        return false;
      }
      for (var t = 0; t < row.length; t++) {
        if (row[t] != otherRow[t]) {
          return false;
        }
      }
    }
    if (queue.length != other.queue.length) {
      return false;
    }
    for (var i = 0; i < queue.length; i++) {
      if (queue[i] != other.queue[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        config,
        Object.hashAll(<int>[for (final row in tokens) ...row]),
        currentSeat,
        phase,
        roll,
        sixes,
        winner,
        seq,
        rngState,
        Object.hashAll(queue),
      );

  @override
  String toString() =>
      'GameState(config: $config, tokens: $tokens, currentSeat: $currentSeat, '
      'phase: $phase, roll: $roll, queue: $queue, sixes: $sixes, '
      'winner: $winner, seq: $seq, rngState: $rngState)';
}

Map<String, Object?> _configToJson(GameConfig config) => <String, Object?>{
      'seats': List<int>.of(config.seats),
      'rules': <String, Object?>{
        'blocks': config.rules.blocks,
        'captureBonus': config.rules.captureBonus,
        if (config.rules.rollQueue) 'rollQueue': true,
        if (config.rules.homeBonus) 'homeBonus': true,
      },
      'seed': config.seed,
    };

GameConfig _configFromJson(Map<String, Object?> json) {
  final rulesJson = json['rules']! as Map<String, Object?>;
  final rules = RulesConfig(
    blocks: rulesJson['blocks']! as bool,
    captureBonus: rulesJson['captureBonus']! as bool,
    rollQueue: _rollQueueFromJson(rulesJson['rollQueue']),
    homeBonus: _homeBonusFromJson(rulesJson['homeBonus']),
  );
  final seatsJson = json['seats']! as List<Object?>;
  final seats = <int>[for (final s in seatsJson) _asInt(s)];
  return GameConfig(seats: seats, rules: rules, seed: _asInt(json['seed']));
}

/// Rule 11a / docs/ENGINE_API.md section 8: absent means false, `true` is
/// accepted, and an explicit `false` or any non-bool is malformed -- allowing
/// it would give one state two serialisations.
bool _homeBonusFromJson(Object? value) {
  if (value == null) {
    return false;
  }
  if (value == true) {
    return true;
  }
  throw FormatException('rules.homeBonus must be absent or true, got $value');
}

/// docs/ENGINE_API.md section 10.2: same shape as [_homeBonusFromJson] --
/// absent means false, `true` is accepted, an explicit `false` or any
/// non-bool is malformed.
bool _rollQueueFromJson(Object? value) {
  if (value == null) {
    return false;
  }
  if (value == true) {
    return true;
  }
  throw FormatException('rules.rollQueue must be absent or true, got $value');
}

/// docs/ENGINE_API.md section 10.2: `queue` is present, and only present,
/// exactly when `rollQueue` is on; a mismatch in either direction is
/// malformed, as is a face outside 1..6.
List<int> _queueFromJson(Map<String, Object?> json, bool rollQueue) {
  final hasQueue = json.containsKey('queue');
  if (!rollQueue) {
    if (hasQueue) {
      throw FormatException(
        'queue is present but rules.rollQueue is not set: ${json['queue']}',
      );
    }
    return const <int>[];
  }
  if (!hasQueue) {
    throw FormatException('rules.rollQueue is set but queue is missing');
  }
  final queueJson = json['queue']! as List<Object?>;
  return <int>[for (final v in queueJson) _asQueueFace(v)];
}

int _asQueueFace(Object? value) {
  final face = _asInt(value);
  if (face < 1 || face > 6) {
    throw FormatException('queue face must be 1..6, got $face');
  }
  return face;
}

String _phaseToWire(GamePhase phase) => switch (phase) {
      GamePhase.awaitRoll => 'awaitRoll',
      GamePhase.awaitMove => 'awaitMove',
      GamePhase.finished => 'finished',
    };

GamePhase _phaseFromWire(String wire) => switch (wire) {
      'awaitRoll' => GamePhase.awaitRoll,
      'awaitMove' => GamePhase.awaitMove,
      'finished' => GamePhase.finished,
      _ => throw ArgumentError('unknown phase: $wire'),
    };

int _asInt(Object? value) => (value! as num).toInt();

int? _asIntOrNull(Object? value) => value == null ? null : _asInt(value);
