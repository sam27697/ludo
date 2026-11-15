// docs/ENGINE_API.md section 2 (the GameState shape), section 8 (the
// serialisation), section 10 (the roll queue) and section 11 (the yard
// release) and section 12 (playing out the places). The toJson key order below
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
    List<int> drought = const <int>[0, 0, 0, 0],
    this.releaseOwed = false,
    List<int> placings = const <int>[],
    List<int> retired = const <int>[],
  })  : tokens = _freezeTokens(tokens),
        queue = List<int>.unmodifiable(queue),
        drought = List<int>.unmodifiable(drought),
        placings = List<int>.unmodifiable(placings),
        retired = List<int>.unmodifiable(retired);

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

  /// docs/ENGINE_API.md section 11.1, rule 9r: per seat index 0..3, the
  /// consecutive rolls without a 6 while all four of that seat's tokens are in
  /// the yard. Always `[0, 0, 0, 0]` when `rules.yardRelease` is off; a seat
  /// not in `config.seats` stays 0.
  final List<int> drought;

  /// docs/ENGINE_API.md section 11.1: `currentSeat` holds an unspent release
  /// (rule 11r). Only ever true in `awaitMove`.
  final bool releaseOwed;

  /// null until a seat wins, then that seat. With `rules.playOut` on: null
  /// until the game ends, then `placings.first` (null if `placings` is empty
  /// at the end, rule 36p).
  final int? winner;

  /// docs/ENGINE_API.md section 12.1: seats in place order. `[]` until the
  /// first seat finishes, and always `[]` when `rules.playOut` is off.
  final List<int> placings;

  /// docs/ENGINE_API.md section 12.1: seats retired by the server, in the
  /// order they were retired. Always `[]` when `rules.playOut` is off.
  final List<int> retired;

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
        'tokens': <List<int>>[for (final row in tokens) List<int>.of(row)],
        'currentSeat': currentSeat,
        'phase': _phaseToWire(phase),
        'roll': roll,
        if (config.rules.rollQueue) 'queue': List<int>.of(queue),
        'sixes': sixes,
        if (config.rules.yardRelease) ...<String, Object?>{
          'drought': List<int>.of(drought),
          'releaseOwed': releaseOwed,
        },
        'winner': winner,
        if (config.rules.playOut) ...<String, Object?>{
          'placings': List<int>.of(placings),
          'retired': List<int>.of(retired),
        },
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
    final phase = _phaseFromWire(json['phase']! as String);
    final releaseOwed = _releaseOwedFromJson(json, config.rules.yardRelease);
    if (releaseOwed && phase != GamePhase.awaitMove) {
      throw FormatException('releaseOwed is true outside awaitMove: $phase');
    }
    final winner = _asIntOrNull(json['winner']);
    final placings = _seatListFromJson(json, 'placings', config);
    final retired = _seatListFromJson(json, 'retired', config);
    _checkPlayOut(config, phase, winner, placings, retired);
    return GameState(
      config: config,
      tokens: tokens,
      currentSeat: _asInt(json['currentSeat']),
      phase: phase,
      roll: _asIntOrNull(json['roll']),
      sixes: _asInt(json['sixes']),
      winner: winner,
      seq: _asInt(json['seq']),
      rngState: _asInt(json['rngState']),
      queue: _queueFromJson(json, config.rules.rollQueue),
      drought: _droughtFromJson(json, config.rules.yardRelease),
      releaseOwed: releaseOwed,
      placings: placings,
      retired: retired,
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
        rngState != other.rngState ||
        releaseOwed != other.releaseOwed) {
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
    if (drought.length != other.drought.length) {
      return false;
    }
    for (var i = 0; i < drought.length; i++) {
      if (drought[i] != other.drought[i]) {
        return false;
      }
    }
    return _sameList(placings, other.placings) &&
        _sameList(retired, other.retired);
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
        Object.hashAll(drought),
        releaseOwed,
        Object.hashAll(placings),
        Object.hashAll(retired),
      );

  @override
  String toString() =>
      'GameState(config: $config, tokens: $tokens, currentSeat: $currentSeat, '
      'phase: $phase, roll: $roll, queue: $queue, sixes: $sixes, '
      'drought: $drought, releaseOwed: $releaseOwed, '
      'winner: $winner, placings: $placings, retired: $retired, '
      'seq: $seq, rngState: $rngState)';
}

Map<String, Object?> _configToJson(GameConfig config) => <String, Object?>{
      'seats': List<int>.of(config.seats),
      'rules': <String, Object?>{
        'blocks': config.rules.blocks,
        'captureBonus': config.rules.captureBonus,
        if (config.rules.rollQueue) 'rollQueue': true,
        if (config.rules.homeBonus) 'homeBonus': true,
        if (config.rules.yardRelease) 'yardRelease': true,
        if (config.rules.playOut) 'playOut': true,
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
    yardRelease: _yardReleaseFromJson(rulesJson['yardRelease']),
    playOut: _playOutFromJson(rulesJson['playOut']),
  );
  if (rules.yardRelease && !rules.rollQueue) {
    throw const FormatException(
      'rules.yardRelease is set but rules.rollQueue is not',
    );
  }
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

/// docs/ENGINE_API.md section 11.2: same shape as [_homeBonusFromJson] --
/// absent means false, `true` is accepted, an explicit `false` or any
/// non-bool is malformed.
bool _yardReleaseFromJson(Object? value) {
  if (value == null) {
    return false;
  }
  if (value == true) {
    return true;
  }
  throw FormatException('rules.yardRelease must be absent or true, got $value');
}

/// docs/ENGINE_API.md section 11.2: `drought` is present, and only present,
/// exactly when `yardRelease` is on; a mismatch in either direction is
/// malformed, as is a list not of length 4 or a count outside 0..9.
List<int> _droughtFromJson(Map<String, Object?> json, bool yardRelease) {
  final hasDrought = json.containsKey('drought');
  if (!yardRelease) {
    if (hasDrought) {
      throw FormatException(
        'drought is present but rules.yardRelease is not set: '
        '${json['drought']}',
      );
    }
    return const <int>[0, 0, 0, 0];
  }
  if (!hasDrought) {
    throw const FormatException(
      'rules.yardRelease is set but drought is '
      'missing',
    );
  }
  final list = json['drought']! as List<Object?>;
  if (list.length != 4) {
    throw FormatException('drought must have length 4, got ${list.length}');
  }
  return <int>[
    for (final v in list)
      if (_asInt(v) < 0 || _asInt(v) > 9)
        throw FormatException('drought count must be 0..9, got $v')
      else
        _asInt(v),
  ];
}

/// docs/ENGINE_API.md section 11.2: `releaseOwed` is present, and only
/// present, exactly when `yardRelease` is on, and is a bool.
bool _releaseOwedFromJson(Map<String, Object?> json, bool yardRelease) {
  final hasKey = json.containsKey('releaseOwed');
  if (!yardRelease) {
    if (hasKey) {
      throw FormatException(
        'releaseOwed is present but rules.yardRelease is not set: '
        '${json['releaseOwed']}',
      );
    }
    return false;
  }
  if (!hasKey) {
    throw const FormatException(
      'rules.yardRelease is set but releaseOwed is '
      'missing',
    );
  }
  final value = json['releaseOwed'];
  if (value is! bool) {
    throw FormatException('releaseOwed must be a bool, got $value');
  }
  return value;
}

/// docs/ENGINE_API.md section 12.2: same shape as [_homeBonusFromJson] --
/// absent means false, `true` is accepted, an explicit `false` or any
/// non-bool is malformed.
bool _playOutFromJson(Object? value) {
  if (value == null) {
    return false;
  }
  if (value == true) {
    return true;
  }
  throw FormatException('rules.playOut must be absent or true, got $value');
}

/// docs/ENGINE_API.md section 12.2: `placings` and `retired` are present, and
/// only present, exactly when `playOut` is on; each is a list of seats of
/// `config.seats`, without repeats.
List<int> _seatListFromJson(
  Map<String, Object?> json,
  String key,
  GameConfig config,
) {
  final hasKey = json.containsKey(key);
  if (!config.rules.playOut) {
    if (hasKey) {
      throw FormatException(
        '$key is present but rules.playOut is not set: ${json[key]}',
      );
    }
    return const <int>[];
  }
  if (!hasKey) {
    throw FormatException('rules.playOut is set but $key is missing');
  }
  final value = json[key];
  if (value is! List<Object?>) {
    throw FormatException('$key must be a list, got $value');
  }
  final seats = <int>[for (final v in value) _asInt(v)];
  for (final seat in seats) {
    if (!config.seats.contains(seat)) {
      throw FormatException('$key holds a seat not in config.seats: $seat');
    }
  }
  if (seats.toSet().length != seats.length) {
    throw FormatException('$key holds a seat twice: $seats');
  }
  return seats;
}

/// docs/ENGINE_API.md section 12.2: the cross-field checks of a `playOut`
/// state.
void _checkPlayOut(
  GameConfig config,
  GamePhase phase,
  int? winner,
  List<int> placings,
  List<int> retired,
) {
  if (!config.rules.playOut) {
    return;
  }
  for (final seat in placings) {
    if (retired.contains(seat)) {
      throw FormatException('seat $seat is in both placings and retired');
    }
  }
  if (winner != null && phase != GamePhase.finished) {
    throw FormatException('winner $winner is set but phase is $phase');
  }
  if (phase == GamePhase.finished &&
      placings.isNotEmpty &&
      winner != placings.first) {
    throw FormatException(
      'winner $winner is not the first place ${placings.first}',
    );
  }
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
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
