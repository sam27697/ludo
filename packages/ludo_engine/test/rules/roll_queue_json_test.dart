// docs/ENGINE_API.md section 10.2: serialisation of the roll queue.
// `queue` is written right after `roll`; `rollQueue` is written in `rules`
// after `captureBonus` and before `homeBonus`; both only when on, and both
// only together.

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// A bare-minimum, otherwise-valid wire map matching docs/ENGINE_API.md
/// section 8's key shape, for tests that need to hand-break one specific
/// field without going through buildState's guard rails.
Map<String, Object?> _baseJson({
  Map<String, Object?>? rules,
  Object? queue = const _Omit(),
}) {
  final json = <String, Object?>{
    'config': <String, Object?>{
      'seats': twoPlayerSeats,
      'rules': rules ?? <String, Object?>{'blocks': true, 'captureBonus': true},
      'seed': 1,
    },
    'tokens': List<List<int>>.generate(4, (_) => const [-1, -1, -1, -1]),
    'currentSeat': 0,
    'phase': 'awaitRoll',
    'roll': null,
    'sixes': 0,
    'winner': null,
    'seq': 0,
    'rngState': 1,
  };
  if (queue is! _Omit) {
    json['queue'] = queue;
  }
  return json;
}

/// Sentinel meaning "do not add a queue key at all", distinct from an
/// explicit `null` or `[]`.
class _Omit {
  const _Omit();
}

void main() {
  group('docs/ENGINE_API.md section 10.2: roll queue serialisation', () {
    test(
      'J1: queue and rollQueue are written only when rollQueue is true, '
      'queue right after roll and rollQueue right after captureBonus',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3],
          tokens: const {
            0: <int>[0, -1, -1, -1],
          },
        );
        final json = state.toJson();

        expect(
          json.keys.toList(),
          equals(const [
            'config',
            'tokens',
            'currentSeat',
            'phase',
            'roll',
            'queue',
            'sixes',
            'winner',
            'seq',
            'rngState',
          ]),
        );
        expect(json['queue'], equals(const [6, 3]));

        final config = json['config'] as Map<String, Object?>;
        final rules = config['rules'] as Map<String, Object?>;
        expect(
          rules.keys.toList(),
          equals(const ['blocks', 'captureBonus', 'rollQueue']),
          reason: 'homeBonus is false here, so it is absent entirely',
        );
        expect(rules['rollQueue'], isTrue);
      },
    );

    test(
      'J1b: with homeBonus also on, rollQueue still sits between '
      'captureBonus and homeBonus',
      () {
        final state = GameState.fromJson(<String, Object?>{
          'config': <String, Object?>{
            'seats': twoPlayerSeats,
            'rules': <String, Object?>{
              'blocks': true,
              'captureBonus': true,
              'rollQueue': true,
              'homeBonus': true,
            },
            'seed': 1,
          },
          'tokens': List<List<int>>.generate(4, (_) => const [-1, -1, -1, -1]),
          'currentSeat': 0,
          'phase': 'awaitMove',
          'roll': null,
          'queue': const [4],
          'sixes': 0,
          'winner': null,
          'seq': 0,
          'rngState': 1,
        });
        final rules = (state.toJson()['config']
            as Map<String, Object?>)['rules'] as Map<String, Object?>;
        expect(
          rules.keys.toList(),
          equals(const ['blocks', 'captureBonus', 'rollQueue', 'homeBonus']),
        );
      },
    );

    test(
      'J2: with rollQueue off, both keys are absent from toJson, and '
      'fromJson reads that absence as off and an empty queue',
      () {
        final state = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          roll: 3,
          tokens: const {
            0: <int>[0, -1, -1, -1],
          },
        );
        final json = state.toJson();

        expect(json.containsKey('queue'), isFalse);
        final rules = (json['config'] as Map<String, Object?>)['rules']
            as Map<String, Object?>;
        expect(rules.containsKey('rollQueue'), isFalse);

        final reread = GameState.fromJson(_baseJson());
        expect(reread.config.rules.rollQueue, isFalse);
        expect(reread.queue, equals(const <int>[]));
      },
    );

    test('J3: an explicit rollQueue: false is rejected by fromJson', () {
      expect(
        () => GameState.fromJson(_baseJson(
          rules: const {
            'blocks': true,
            'captureBonus': true,
            'rollQueue': false,
          },
        )),
        throwsFormatException,
      );
    });

    test(
      'J4: a queue key present on a state whose rules lack rollQueue is '
      'rejected by fromJson',
      () {
        expect(
          () => GameState.fromJson(_baseJson(queue: const [3])),
          throwsFormatException,
        );
      },
    );

    test(
      'J5: rollQueue: true with no queue key at all is rejected by '
      'fromJson',
      () {
        expect(
          () => GameState.fromJson(_baseJson(
            rules: const {
              'blocks': true,
              'captureBonus': true,
              'rollQueue': true,
            },
          )),
          throwsFormatException,
        );
      },
    );

    for (final badFace in const [0, 7]) {
      test('J6: a queue face of $badFace is rejected by fromJson', () {
        expect(
          () => GameState.fromJson(_baseJson(
            rules: const {
              'blocks': true,
              'captureBonus': true,
              'rollQueue': true,
            },
            queue: [badFace],
          )),
          throwsFormatException,
          reason: 'face=$badFace',
        );
      });
    }

    test(
      'round trip: toJson then fromJson reproduces an equal state with '
      'rollQueue on',
      () {
        final original = buildState(
          seats: twoPlayerSeats,
          phase: 'awaitMove',
          rollQueue: true,
          queue: const [6, 3, 2],
          currentSeat: 0,
          sixes: 0,
          tokens: const {
            0: <int>[10, -1, -1, -1],
          },
        );
        final roundTripped = GameState.fromJson(original.toJson());

        expect(roundTripped, equals(original));
        expect(stateHash(roundTripped), stateHash(original));
      },
    );

    test(
      'a RulesConfig with rollQueue explicitly false hashes exactly as one '
      'built with the field left at its default',
      () {
        final explicit = newGame(
          GameConfig(
            seats: twoPlayerSeats,
            seed: 7,
            rules: const RulesConfig(rollQueue: false),
          ),
        );
        final implicit = newGame(
          GameConfig(
            seats: twoPlayerSeats,
            seed: 7,
            rules: const RulesConfig(),
          ),
        );

        expect(explicit, equals(implicit));
        expect(stateHash(explicit), equals(stateHash(implicit)));
      },
    );
  });
}
