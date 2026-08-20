// docs/ENGINE_API.md section 2 (the GameState shape) and section 8 (the
// serialisation). The toJson key order below is normative: the golden
// corpus hash is pinned to it.

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
  }) : tokens = _freezeTokens(tokens);

  final GameConfig config;

  /// Always 4 rows of 4. tokens[seat][index] is that token's progress.
  /// Rows for seats not in config.seats stay [-1,-1,-1,-1] forever.
  final List<List<int>> tokens;

  final int currentSeat;
  final GamePhase phase;

  /// null in awaitRoll and finished; 1..6 in awaitMove.
  final int? roll;

  /// Consecutive 6s already rolled this turn, 0..2.
  final int sixes;

  /// null until a seat wins, then that seat.
  final int? winner;

  /// Increments by 1 on every accepted intention.
  final int seq;

  /// The future of the dice. Secret; never leaves the server.
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
      );

  @override
  String toString() =>
      'GameState(config: $config, tokens: $tokens, currentSeat: $currentSeat, '
      'phase: $phase, roll: $roll, sixes: $sixes, winner: $winner, '
      'seq: $seq, rngState: $rngState)';
}

Map<String, Object?> _configToJson(GameConfig config) => <String, Object?>{
      'seats': List<int>.of(config.seats),
      'rules': <String, Object?>{
        'blocks': config.rules.blocks,
        'captureBonus': config.rules.captureBonus,
      },
      'seed': config.seed,
    };

GameConfig _configFromJson(Map<String, Object?> json) {
  final rulesJson = json['rules']! as Map<String, Object?>;
  final rules = RulesConfig(
    blocks: rulesJson['blocks']! as bool,
    captureBonus: rulesJson['captureBonus']! as bool,
  );
  final seatsJson = json['seats']! as List<Object?>;
  final seats = <int>[for (final s in seatsJson) _asInt(s)];
  return GameConfig(seats: seats, rules: rules, seed: _asInt(json['seed']));
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
