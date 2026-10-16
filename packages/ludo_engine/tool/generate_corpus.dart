// Plays complete games through the public engine API and writes the golden
// corpus that packages/ludo_engine/test/golden_replay_test.dart replays.
//
// Usage:
//   dart run tool/generate_corpus.dart --games 40 --out /tmp/corpus.jsonl
//   dart run tool/generate_corpus.dart --games 24 --roll-queue \
//       --out /tmp/corpus-queue.jsonl
//
// --out is required and has no default, deliberately. Write it somewhere
// outside the repository. test/golden/corpus.jsonl is the one path this tool
// must never be pointed at casually: that file is the frozen record every
// future change is checked against, and it is placed there only after the
// engine has been reviewed, by the person doing the review. Regenerating it
// from an unreviewed engine turns the golden gate into a photograph of
// whatever the code currently does, including its bugs, which is the one
// failure mode the gate exists to prevent.
//
// --roll-queue is off unless named. With it, every record is a server-room
// game (docs/ENGINE_API.md section 10.5): blocks false, rollQueue true,
// homeBonus true, captureBonus alternating true/false with the game index,
// seats cycling through [0, 2], [0, 1, 2] and [0, 1, 2, 3]. Each move spends
// the face and token one seeded draw picks among legalByFace, and the move
// intention records that face. Without the flag the records are the legacy
// corpus: no rollQueue key, no homeBonus key, no face on a move.
//
// Rule 38 (docs/RULES.md): the engine draws no randomness at all, so this
// tool draws the faces itself. Each game holds its own SplitMix64 state,
// seeded from that game's `seed` exactly as `newGame` used to seed
// `GameState.rngState`, and draws a face with the rejection sampling pinned
// in docs/ENGINE_API.md section 7 before building each RollIntention. The
// face drawn is recorded on the intention, per the corpus format in that
// same section.
//
// The choice of which legal token to move each turn is deterministic and
// seed-derived (a second, independent SplitMix64 stream kept apart from the
// dice stream above), not Dart's Random() and not always the first legal
// token, so the corpus actually exercises captures, blocks and multi-token
// turns instead of playing the same degenerate line every time. Under
// --roll-queue that same stream picks one (face, token) pair from
// legalByFace instead of one token from legalTokens.

import 'dart:convert';
import 'dart:io';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:ludo_engine/src/rng.dart';

/// A second, independent SplitMix64 stream used only to pick which legal
/// token to move. It is seeded from the game seed but is not the engine's
/// own dice stream (that one is private inside GameState.rngState and this
/// tool never touches it directly).
(int state, int output) _choiceStreamNext(int state) {
  const goldenGamma = 0x9E3779B97F4A7C15;
  const mix1 = 0xBF58476D1CE4E5B9;
  const mix2 = 0x94D049BB133111EB;
  final newState = state + goldenGamma;
  var z = newState;
  z = (z ^ (z >>> 30)) * mix1;
  z = (z ^ (z >>> 27)) * mix2;
  z = z ^ (z >>> 31);
  return (newState, z);
}

int _choiceSeedFor(int gameSeed) => gameSeed ^ 0x5A5A5A5A5A5A5A5A;

class GameRecord {
  GameRecord({
    required this.name,
    required this.seed,
    required this.seats,
    required this.blocks,
    required this.captureBonus,
    required this.intentions,
    required this.finalHash,
    required this.finalSeq,
    required this.captures,
    required this.blockRejections,
    required this.threeSixForfeits,
    this.rollQueue = false,
    this.queuesAtLeastTwo = 0,
    this.capturesWhileQueued = 0,
    this.homeArrivalsEarningRoll = 0,
    this.droppedDeadFaces = 0,
    this.nonFirstFaceSpends = 0,
  });

  final String name;
  final int seed;
  final List<int> seats;
  final bool blocks;
  final bool captureBonus;
  final List<Map<String, Object?>> intentions;
  final String finalHash;
  final int finalSeq;
  final int captures;
  final int blockRejections;
  final int threeSixForfeits;

  /// True only for a --roll-queue record. Legacy records leave it false so
  /// [toJson] writes the two-key rules object the frozen corpus has.
  final bool rollQueue;

  /// Post-intention states whose queue length is at least 2.
  final int queuesAtLeastTwo;

  /// Captures whose move started with at least one other face still queued.
  final int capturesWhileQueued;

  /// Non-winning home arrivals that were followed by an extra roll.
  final int homeArrivalsEarningRoll;

  /// Faces discarded because no queued face could move (rule 13q). A roll
  /// that passes drops the queue it just appended to; a move that passes
  /// drops whatever remains after the spent face.
  final int droppedDeadFaces;

  /// Moves whose spent face was not the first face in the queue.
  final int nonFirstFaceSpends;

  Map<String, Object?> toJson() {
    final rules = <String, Object?>{
      'blocks': blocks,
      'captureBonus': captureBonus,
    };
    if (rollQueue) {
      rules['rollQueue'] = true;
      rules['homeBonus'] = true;
    }
    return <String, Object?>{
      'name': name,
      'seed': seed,
      'seats': seats,
      'rules': rules,
      'intentions': intentions,
      'finalHash': finalHash,
      'finalSeq': finalSeq,
    };
  }
}

/// Plays one complete game from [seed] to a terminal state. Throws if the
/// game does not terminate within [maxIntentions], naming the seed, rather
/// than looping forever or truncating the recording.
///
/// [rollQueue] false is the legacy game: the move intention has no face.
/// [rollQueue] true plays blocks, captureBonus and homeBonus as passed
/// (the caller sets the server-room combination) and records the face each
/// move spends.
GameRecord simulateGame({
  required String name,
  required int seed,
  required List<int> seats,
  required bool blocks,
  required bool captureBonus,
  bool rollQueue = false,
  int maxIntentions = 5000,
}) {
  final config = GameConfig(
    seats: seats,
    rules: rollQueue
        ? RulesConfig(
            blocks: blocks,
            captureBonus: captureBonus,
            rollQueue: true,
            homeBonus: true,
          )
        : RulesConfig(blocks: blocks, captureBonus: captureBonus),
    seed: seed,
  );
  var state = newGame(config);
  final intentions = <Map<String, Object?>>[];
  var captures = 0;
  var blockRejections = 0;
  var threeSixForfeits = 0;
  var queuesAtLeastTwo = 0;
  var capturesWhileQueued = 0;
  var homeArrivalsEarningRoll = 0;
  var droppedDeadFaces = 0;
  var nonFirstFaceSpends = 0;
  var choiceState = _choiceSeedFor(seed);
  // Seeded exactly as newGame used to seed GameState.rngState, before the
  // engine stopped drawing its own dice.
  var diceState = seed;

  while (!isTerminal(state)) {
    if (intentions.length >= maxIntentions) {
      throw StateError(
        'game "$name" (seed=$seed) did not terminate within '
        '$maxIntentions intentions',
      );
    }

    final phaseBefore = state.phase;
    final queueBefore = state.queue.length;
    var spentNonFirstFace = false;
    late final ApplyResult result;
    if (state.phase == GamePhase.awaitRoll) {
      final seat = state.currentSeat;
      final (nextDiceState, face) = rollDie(diceState);
      diceState = nextDiceState;
      intentions.add(<String, Object?>{
        't': 'roll',
        'seat': seat,
        'face': face,
      });
      result = apply(state, RollIntention(seat, face));
      if (result is! Applied) {
        throw StateError(
          'game "$name" (seed=$seed): unexpected rejection on roll: '
          '${(result as Rejected).error}',
        );
      }
      final rolledState = result.state;
      if (blocks && rolledState.phase == GamePhase.awaitMove) {
        blockRejections += _countBlockRejections(rolledState);
      }
    } else if (state.phase == GamePhase.awaitMove) {
      final seat = state.currentSeat;
      if (rollQueue) {
        final options = _legalFaceTokenOptions(state);
        if (options.isEmpty) {
          throw StateError(
            'game "$name" (seed=$seed), intention ${intentions.length}: '
            'awaitMove with rollQueue but legalByFace is empty',
          );
        }
        if (state.queue.isEmpty) {
          throw StateError(
            'game "$name" (seed=$seed), intention ${intentions.length}: '
            'awaitMove with rollQueue but the queue is empty',
          );
        }
        final (nextChoiceState, z) = _choiceStreamNext(choiceState);
        choiceState = nextChoiceState;
        final chosen = options[(z >>> 1) % options.length];
        final face = chosen.$1;
        final token = chosen.$2;
        spentNonFirstFace = face != state.queue.first;
        intentions.add(<String, Object?>{
          't': 'move',
          'seat': seat,
          'token': token,
          'face': face,
        });
        result = apply(state, MoveIntention(seat, token, face: face));
      } else {
        final legal = legalTokens(state);
        final (nextChoiceState, z) = _choiceStreamNext(choiceState);
        choiceState = nextChoiceState;
        final token = legal[(z >>> 1) % legal.length];
        intentions.add(<String, Object?>{
          't': 'move',
          'seat': seat,
          'token': token,
        });
        result = apply(state, MoveIntention(seat, token));
      }
      if (result is! Applied) {
        throw StateError(
          'game "$name" (seed=$seed), intention ${intentions.length - 1}: '
          'unexpected rejection on move: ${(result as Rejected).error}',
        );
      }
    } else {
      break;
    }

    var capturedThis = false;
    var tokenHomeThis = false;
    var extraRollThis = false;
    var gameWonThis = false;
    var noLegalMoveThis = false;
    for (final event in result.events) {
      if (event is Captured) {
        captures++;
        capturedThis = true;
      } else if (event is TurnEnded &&
          event.reason == TurnEndReason.threeSixes) {
        threeSixForfeits++;
      } else if (event is TokenHome) {
        tokenHomeThis = true;
      } else if (event is ExtraRoll) {
        extraRollThis = true;
      } else if (event is GameWon) {
        gameWonThis = true;
      } else if (event is TurnEnded &&
          event.reason == TurnEndReason.noLegalMove) {
        noLegalMoveThis = true;
      }
    }
    if (rollQueue) {
      if (result.state.queue.length >= 2) {
        queuesAtLeastTwo++;
      }
      if (capturedThis && queueBefore >= 2) {
        capturesWhileQueued++;
      }
      if (tokenHomeThis && extraRollThis && !gameWonThis) {
        homeArrivalsEarningRoll++;
      }
      if (noLegalMoveThis) {
        if (phaseBefore == GamePhase.awaitRoll) {
          droppedDeadFaces += queueBefore + 1;
        } else if (queueBefore >= 2) {
          droppedDeadFaces += queueBefore - 1;
        } else {
          throw StateError(
            'game "$name" (seed=$seed), intention ${intentions.length - 1}: '
            'noLegalMove on a move with queue length $queueBefore',
          );
        }
      }
      if (spentNonFirstFace) {
        nonFirstFaceSpends++;
      }
    }
    state = result.state;
  }

  if (rollQueue && !isTerminal(state)) {
    throw StateError(
      'game "$name" (seed=$seed) ended in ${state.phase}, not finished',
    );
  }

  return GameRecord(
    name: name,
    seed: seed,
    seats: seats,
    blocks: blocks,
    captureBonus: captureBonus,
    intentions: intentions,
    finalHash: stateHash(state),
    finalSeq: state.seq,
    captures: captures,
    blockRejections: blockRejections,
    threeSixForfeits: threeSixForfeits,
    rollQueue: rollQueue,
    queuesAtLeastTwo: queuesAtLeastTwo,
    capturesWhileQueued: capturesWhileQueued,
    homeArrivalsEarningRoll: homeArrivalsEarningRoll,
    droppedDeadFaces: droppedDeadFaces,
    nonFirstFaceSpends: nonFirstFaceSpends,
  );
}

/// (face, token) pairs from [legalByFace], first-queued face order, tokens
/// ascending within a face. One seeded draw picks among this list.
List<(int, int)> _legalFaceTokenOptions(GameState state) {
  final options = <(int, int)>[];
  for (final entry in legalByFace(state).entries) {
    for (final token in entry.value) {
      options.add((entry.key, token));
    }
  }
  return options;
}

/// Rule 22: a block excludes a token that would otherwise be legal. Counted
/// by comparing the actual legal set against what it would be with blocks
/// off, on the same tokens and roll, through the public API only.
int _countBlockRejections(GameState state) {
  final json = state.toJson();
  final configJson = Map<String, Object?>.of(
    json['config']! as Map<String, Object?>,
  );
  final rulesJson = Map<String, Object?>.of(
    configJson['rules']! as Map<String, Object?>,
  );
  rulesJson['blocks'] = false;
  configJson['rules'] = rulesJson;
  json['config'] = configJson;
  final withoutBlocks = GameState.fromJson(json);

  final actual = legalTokens(state);
  final withoutBlocksLegal = legalTokens(withoutBlocks);
  var count = 0;
  for (final t in withoutBlocksLegal) {
    if (!actual.contains(t)) {
      count++;
    }
  }
  return count;
}

List<int> _seatsForPlayerCount(int players) => switch (players) {
      2 => const <int>[0, 2],
      3 => const <int>[0, 1, 2],
      4 => const <int>[0, 1, 2, 3],
      _ => throw ArgumentError('unsupported player count: $players'),
    };

class _Combo {
  const _Combo(this.players, this.blocks, this.captureBonus);
  final int players;
  final bool blocks;
  final bool captureBonus;
}

List<_Combo> _buildCombos() {
  final combos = <_Combo>[];
  for (final players in const [2, 3, 4]) {
    for (final blocks in const [true, false]) {
      for (final captureBonus in const [true, false]) {
        combos.add(_Combo(players, blocks, captureBonus));
      }
    }
  }
  return combos;
}

/// Searches, deterministically, for a seed whose 4-player, blocks-on,
/// capture-bonus-on game contains at least one capture, one block
/// rejection and one three-six forfeit -- the coverage the work order
/// requires in a single game.
GameRecord _findStressGame({
  required String name,
  required int searchStart,
  required int maxAttempts,
}) {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final seed = searchStart + attempt;
    final record = simulateGame(
      name: name,
      seed: seed,
      seats: _seatsForPlayerCount(4),
      blocks: true,
      captureBonus: true,
    );
    if (record.captures > 0 &&
        record.blockRejections > 0 &&
        record.threeSixForfeits > 0) {
      return record;
    }
  }
  throw StateError(
    'no seed in [$searchStart, ${searchStart + maxAttempts}) produced a '
    'game with a capture, a block rejection and a three-six forfeit',
  );
}

void main(List<String> args) {
  int? gameCount;
  String? outPath;
  var rollQueue = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--games':
        gameCount = int.parse(args[++i]);
      case '--out':
        outPath = args[++i];
      case '--roll-queue':
        rollQueue = true;
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(64);
    }
  }
  if (gameCount == null || outPath == null) {
    stderr.writeln(
      'usage: dart run tool/generate_corpus.dart '
      '--games N --out PATH [--roll-queue]',
    );
    exit(64);
  }
  if (gameCount < 1) {
    stderr.writeln('--games must be at least 1, got $gameCount');
    exit(64);
  }

  const baseSeed = 1000003;
  final combos = _buildCombos();
  final records = <GameRecord>[];

  if (rollQueue) {
    // Server-room rules, seats mixed across the three legal layouts.
    // captureBonus follows the game index: even true, odd false.
    // No stress game: that search forces blocks on and four seats, which
    // these records are not allowed to be.
    const seatLayouts = <int>[2, 3, 4];
    for (var i = 0; i < gameCount; i++) {
      final players = seatLayouts[i % seatLayouts.length];
      final captureBonus = i % 2 == 0;
      final seed = baseSeed + i * 97;
      final seats = _seatsForPlayerCount(players);
      final name = 'game $i: ${players}p blocks=false '
          'captureBonus=$captureBonus rollQueue=true homeBonus=true '
          'seed=$seed';
      records.add(
        simulateGame(
          name: name,
          seed: seed,
          seats: seats,
          blocks: false,
          captureBonus: captureBonus,
          rollQueue: true,
        ),
      );
    }
  } else {
    for (var i = 0; i < gameCount; i++) {
      // The last game is reserved for the guaranteed-coverage stress game.
      if (i == gameCount - 1) {
        records.add(
          _findStressGame(
            name: 'game $i: stress (4p, blocks on, captureBonus on)',
            searchStart: 9000000,
            maxAttempts: 20000,
          ),
        );
        continue;
      }
      final combo = combos[i % combos.length];
      final seed = baseSeed + i * 97;
      final seats = _seatsForPlayerCount(combo.players);
      final name = 'game $i: ${combo.players}p blocks=${combo.blocks} '
          'captureBonus=${combo.captureBonus} seed=$seed';
      records.add(
        simulateGame(
          name: name,
          seed: seed,
          seats: seats,
          blocks: combo.blocks,
          captureBonus: combo.captureBonus,
        ),
      );
    }
  }

  final buffer = StringBuffer();
  for (final record in records) {
    buffer.writeln(jsonEncode(record.toJson()));
  }
  final file = File(outPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(buffer.toString());

  final totalCaptures = records.fold<int>(0, (sum, r) => sum + r.captures);
  final totalBlockRejections = records.fold<int>(
    0,
    (sum, r) => sum + r.blockRejections,
  );
  final totalThreeSixForfeits = records.fold<int>(
    0,
    (sum, r) => sum + r.threeSixForfeits,
  );
  var shortest = records.first.intentions.length;
  var longest = records.first.intentions.length;
  for (final r in records) {
    final len = r.intentions.length;
    if (len < shortest) {
      shortest = len;
    }
    if (len > longest) {
      longest = len;
    }
  }

  // ignore: avoid_print
  print('wrote ${records.length} games to $outPath');
  // ignore: avoid_print
  print('total captures: $totalCaptures');
  // ignore: avoid_print
  print('total block rejections: $totalBlockRejections');
  // ignore: avoid_print
  print('total three-six forfeits: $totalThreeSixForfeits');
  // ignore: avoid_print
  print('shortest game: $shortest intentions');
  // ignore: avoid_print
  print('longest game: $longest intentions');

  if (rollQueue) {
    final queuesAtLeastTwo = records.fold<int>(
      0,
      (sum, r) => sum + r.queuesAtLeastTwo,
    );
    final capturesWhileQueued = records.fold<int>(
      0,
      (sum, r) => sum + r.capturesWhileQueued,
    );
    final homeArrivalsEarningRoll = records.fold<int>(
      0,
      (sum, r) => sum + r.homeArrivalsEarningRoll,
    );
    final droppedDeadFaces = records.fold<int>(
      0,
      (sum, r) => sum + r.droppedDeadFaces,
    );
    final nonFirstFaceSpends = records.fold<int>(
      0,
      (sum, r) => sum + r.nonFirstFaceSpends,
    );
    // ignore: avoid_print
    print('queues of length 2 or more: $queuesAtLeastTwo');
    // ignore: avoid_print
    print(
      'third consecutive six voiding the turn: $totalThreeSixForfeits',
    );
    // ignore: avoid_print
    print(
      'capture made while faces were still queued: $capturesWhileQueued',
    );
    // ignore: avoid_print
    print('home arrival earning a roll: $homeArrivalsEarningRoll');
    // ignore: avoid_print
    print('dropped dead face: $droppedDeadFaces');
    // ignore: avoid_print
    print(
      'move that spent a face other than the first in the queue: '
      '$nonFirstFaceSpends',
    );
  }
}
