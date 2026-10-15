// Acceptance tests for A5 and A1 of
// work/ludo/orders/C-362-roll-queue-client.md: TurnState.fromJson gains
// `queue` and `legal_by_face`, with the same absent-means-today rule the
// rest of this decoder already uses. Written from the contract and from
// docs/PROTOCOL.md section 21.1/21.3, against no implementation of
// lib/src/net/snapshot.dart the author of this file has read.
//
// Case M10 of work/ludo/orders/363-roll-queue-client-model-tests.md: a
// snapshot `turn` with `queue` and `legal_by_face` parses both; without
// them, `queue` is `[]` and `legalByFace` is null; a non-int queue entry
// throws SnapshotFormatException. The type for one `legal_by_face` entry is
// named `FaceLegal`, with fields `face` and `tokens`, per the contract's own
// naming note.
//
// Every other TurnState.fromJson behaviour (seat range, phase enum values,
// value/legal/sixes) is proved in snapshot_test.dart and is not repeated
// here.
//
// Ambiguity found and deliberately not tested either way (reported in the
// run's final message rather than guessed at): the contract says `queue`
// defaults to `[]` and `legalByFace` to null when the wire "sends none",
// which this file reads as "the key is absent". Whether an explicit JSON
// `null` for either key is accepted the same way, or is itself malformed,
// is not said anywhere in C-362 or in docs/PROTOCOL.md section 21, and the
// existing decoder helpers are not a substitute for the contract saying so.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/snapshot.dart';

Map<String, Object?> _validTurn({
  int seat = 1,
  String phase = 'await_move',
  int deadlineMs = 30000,
  int k = 4,
  int? value,
  List<Object?>? legal,
  List<Object?>? queue,
  List<Object?>? legalByFace,
}) {
  final Map<String, Object?> map = <String, Object?>{
    'seat': seat,
    'phase': phase,
    'deadline_ms': deadlineMs,
    'k': k,
  };
  if (value != null) map['value'] = value;
  if (legal != null) map['legal'] = legal;
  if (queue != null) map['queue'] = queue;
  if (legalByFace != null) map['legal_by_face'] = legalByFace;
  return map;
}

Map<String, Object?> _faceLegalJson(Object? face, Object? tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

void main() {
  group('M10: TurnState.fromJson, queue and legal_by_face both present', () {
    test('parses queue and legal_by_face, wire order kept', () {
      final TurnState turn = TurnState.fromJson(
        _validTurn(
          phase: 'await_move',
          value: 6,
          legal: <int>[0, 2],
          queue: <int>[6, 3],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(6, <int>[0, 2]),
            _faceLegalJson(3, <int>[1]),
          ],
        ),
      );

      expect(turn.queue, <int>[6, 3]);
      expect(turn.legalByFace, isNotNull);
      expect(turn.legalByFace, hasLength(2));
      expect(
        turn.legalByFace![0].face,
        6,
        reason: 'wire order must be kept: face 6 was queued first',
      );
      expect(turn.legalByFace![0].tokens, <int>[0, 2]);
      expect(turn.legalByFace![1].face, 3);
      expect(turn.legalByFace![1].tokens, <int>[1]);
    });

    test('a single legal_by_face entry decodes to a list of length one', () {
      final TurnState turn = TurnState.fromJson(
        _validTurn(
          phase: 'await_move',
          value: 3,
          legal: <int>[1],
          queue: <int>[3],
          legalByFace: <Map<String, Object?>>[
            _faceLegalJson(3, <int>[1]),
          ],
        ),
      );
      expect(turn.legalByFace, hasLength(1));
      expect(turn.legalByFace!.single.face, 3);
      expect(turn.legalByFace!.single.tokens, <int>[1]);
    });
  });

  group('M10: queue and legal_by_face both absent', () {
    test('queue defaults to the empty list, not null', () {
      final TurnState turn = TurnState.fromJson(
        _validTurn(phase: 'await_roll'),
      );
      expect(turn.queue, isNotNull);
      expect(turn.queue, isEmpty);
    });

    test('legal_by_face defaults to null', () {
      final TurnState turn = TurnState.fromJson(
        _validTurn(phase: 'await_move', value: 6, legal: <int>[0]),
      );
      expect(turn.legalByFace, isNull);
    });

    test('await_roll with queue present and legal_by_face absent still '
        'decodes legalByFace to null (a bonus roll owed mid-turn, '
        'docs/PROTOCOL.md 21.1)', () {
      final TurnState turn = TurnState.fromJson(
        _validTurn(phase: 'await_roll', queue: <int>[6]),
      );
      expect(turn.queue, <int>[6]);
      expect(turn.legalByFace, isNull);
    });
  });

  group('M10: malformed queue', () {
    test('a non-int queue entry throws SnapshotFormatException', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(phase: 'await_roll', queue: <Object?>[6, 'three']),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('queue that is not a list at all throws SnapshotFormatException', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(phase: 'await_roll')..['queue'] = 'not-a-list',
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('M10: malformed legal_by_face', () {
    test('an entry missing face throws SnapshotFormatException', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(
            phase: 'await_move',
            value: 6,
            legal: <int>[0],
            queue: <int>[6],
            legalByFace: <Map<String, Object?>>[
              <String, Object?>{
                'tokens': <int>[0],
              },
            ],
          ),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('an entry missing tokens throws SnapshotFormatException', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(
            phase: 'await_move',
            value: 6,
            legal: <int>[0],
            queue: <int>[6],
            legalByFace: <Map<String, Object?>>[
              <String, Object?>{'face': 6},
            ],
          ),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test(
      "an entry whose face is not an int throws SnapshotFormatException",
      () {
        expect(
          () => TurnState.fromJson(
            _validTurn(
              phase: 'await_move',
              value: 6,
              legal: <int>[0],
              queue: <int>[6],
              legalByFace: <Map<String, Object?>>[
                _faceLegalJson('six', <int>[0]),
              ],
            ),
          ),
          throwsA(isA<SnapshotFormatException>()),
        );
      },
    );

    test("an entry whose tokens contains a non-int element throws "
        'SnapshotFormatException', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(
            phase: 'await_move',
            value: 6,
            legal: <int>[0],
            queue: <int>[6],
            legalByFace: <Map<String, Object?>>[
              _faceLegalJson(6, <Object?>[0, 'two']),
            ],
          ),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('legal_by_face that is not a list at all throws', () {
      expect(
        () => TurnState.fromJson(
          _validTurn(phase: 'await_move', value: 6, legal: <int>[0])
            ..['legal_by_face'] = 'not-a-list',
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });
}
