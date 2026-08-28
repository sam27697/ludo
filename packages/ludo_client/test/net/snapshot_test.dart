// Conformance tests for lib/src/net/snapshot.dart, written from
// docs/PROTOCOL.md sections 5, 6 and 14, from packages/ludo_server's
// buildRoomSnapshot (the reference producer of everything decoded here),
// and from the frozen interface in work order 067, against no
// implementation the author of this file has read.
//
// Every negative test asserts the exception TYPE, never just "throws":
// throwsA(isA<SnapshotFormatException>()), never throwsException.
//
// Two ambiguities in the frozen interface / rules text were found while
// writing this file and are deliberately NOT resolved by a guess here; see
// the final report for detail. In short:
//   1. Whether the seat-index range 0..3 applies to TurnState.seat, in
//      addition to the explicitly named SeatState.seat and
//      RoomSnapshot.hostSeat, is not tested either way.
//   2. Whether a JSON key that is entirely absent (as opposed to present
//      with an explicit JSON null) throws for a field that is `required`
//      in its constructor but nullable in its type (SeatState.clientSeed,
//      SeatState.seedOrigin, RoomSnapshot.gameId, RoomSnapshot.clientSeeds,
//      RoomSnapshot.turn, RoomSnapshot.winner) is not tested either way.
//      Only "explicit null is accepted" and "wrong type throws" are tested
//      for those six fields.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/snapshot.dart';

// 64 characters, docs/PROTOCOL.md section 11.2. Adjacent string literals
// concatenate at compile time, which keeps this usable as a default
// parameter value below.
const _hex64 =
    '4b871c474b871c474b871c474b871c47'
    '4b871c474b871c474b871c474b871c47';
const _hex16 = 'a1b2c3d4e5f60718'; // 16 characters, section 11.2 game_id

const _lobbyTokens = <Object?>[-1, -1, -1, -1];
const _playingTokensA = <Object?>[0, 5, 14, 57];
const _legalAB = <Object?>[0, 2];

Map<String, Object?> _without(Map<String, Object?> json, String key) {
  final copy = Map<String, Object?>.from(json);
  copy.remove(key);
  return copy;
}

Map<String, Object?> _replacing(
  Map<String, Object?> json,
  String key,
  Object? value,
) {
  final copy = Map<String, Object?>.from(json);
  copy[key] = value;
  return copy;
}

Map<String, Object?> _validRules({
  bool blocks = true,
  bool captureBonus = true,
  int turnSeconds = 45,
}) => <String, Object?>{
  'blocks': blocks,
  'capture_bonus': captureBonus,
  'turn_seconds': turnSeconds,
};

Map<String, Object?> _validSeat({
  int seat = 0,
  String name = 'Sam',
  bool connected = true,
  List<Object?> tokens = _lobbyTokens,
  String? clientSeed,
  String? seedOrigin,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': clientSeed,
  'seed_origin': seedOrigin,
};

Map<String, Object?> _validTurn({
  int seat = 1,
  String phase = 'await_roll',
  int deadlineMs = 30000,
  int k = 0,
  int? value,
  List<Object?>? legal,
  int? sixes,
}) {
  final map = <String, Object?>{
    'seat': seat,
    'phase': phase,
    'deadline_ms': deadlineMs,
    'k': k,
  };
  if (value != null) map['value'] = value;
  if (legal != null) map['legal'] = legal;
  if (sixes != null) map['sixes'] = sixes;
  return map;
}

Map<String, Object?> _validRoom({
  String code = 'K7M2QP',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  Map<String, Object?>? rules,
  String chainCommit = _hex64,
  int chainIndex = 0,
  String? gameId,
  String? clientSeeds,
  List<Object?>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': rules ?? _validRules(),
  'chain_commit': chainCommit,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': seats ?? <Object?>[_validSeat()],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

void main() {
  group('RulesConfig.fromJson', () {
    test('an empty map gives the documented defaults', () {
      final rules = RulesConfig.fromJson(<String, Object?>{});
      expect(rules.blocks, isTrue);
      expect(rules.captureBonus, isTrue);
      expect(rules.turnSeconds, 45);
    });

    test('defaults blocks individually when only capture_bonus is given', () {
      final rules = RulesConfig.fromJson(<String, Object?>{
        'capture_bonus': false,
      });
      expect(rules.blocks, isTrue);
      expect(rules.captureBonus, isFalse);
      expect(rules.turnSeconds, 45);
    });

    test('defaults capture_bonus individually when only blocks is given', () {
      final rules = RulesConfig.fromJson(<String, Object?>{'blocks': false});
      expect(rules.blocks, isFalse);
      expect(rules.captureBonus, isTrue);
      expect(rules.turnSeconds, 45);
    });

    test(
      'defaults turn_seconds individually when it is the only key absent',
      () {
        final rules = RulesConfig.fromJson(<String, Object?>{
          'blocks': false,
          'capture_bonus': false,
        });
        expect(rules.turnSeconds, 45);
      },
    );

    test('a fully explicit map overrides every default', () {
      final rules = RulesConfig.fromJson(
        _validRules(blocks: false, captureBonus: false, turnSeconds: 20),
      );
      expect(rules.blocks, isFalse);
      expect(rules.captureBonus, isFalse);
      expect(rules.turnSeconds, 20);
    });

    test('unknown keys are ignored', () {
      final rules = RulesConfig.fromJson(<String, Object?>{
        'blocks': false,
        'unheard_of_future_key': 'junk',
      });
      expect(rules.blocks, isFalse);
    });

    test('blocks explicit null throws; only absence defaults', () {
      expect(
        () => RulesConfig.fromJson(<String, Object?>{'blocks': null}),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('blocks of the wrong runtime type throws', () {
      expect(
        () => RulesConfig.fromJson(<String, Object?>{'blocks': 'true'}),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('capture_bonus of the wrong runtime type throws', () {
      expect(
        () => RulesConfig.fromJson(<String, Object?>{'capture_bonus': 1}),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('turn_seconds of the wrong runtime type throws', () {
      expect(
        () => RulesConfig.fromJson(<String, Object?>{'turn_seconds': '45'}),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test(
      'turn_seconds as a double with a zero fraction (45.0) is rejected',
      () {
        expect(
          () => RulesConfig.fromJson(<String, Object?>{'turn_seconds': 45.0}),
          throwsA(isA<SnapshotFormatException>()),
        );
      },
    );

    group('turn_seconds range 15..120', () {
      test('14, just under the minimum, throws', () {
        expect(
          () => RulesConfig.fromJson(_validRules(turnSeconds: 14)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('15, the minimum, is accepted', () {
        expect(
          RulesConfig.fromJson(_validRules(turnSeconds: 15)).turnSeconds,
          15,
        );
      });
      test('120, the maximum, is accepted', () {
        expect(
          RulesConfig.fromJson(_validRules(turnSeconds: 120)).turnSeconds,
          120,
        );
      });
      test('121, just over the maximum, throws', () {
        expect(
          () => RulesConfig.fromJson(_validRules(turnSeconds: 121)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    });
  });

  group('SeatState.fromJson', () {
    test('decodes a fully populated seat', () {
      final seat = SeatState.fromJson(
        _validSeat(
          seat: 2,
          name: 'Priya',
          connected: true,
          tokens: _playingTokensA,
          clientSeed: 'priya-seed',
          seedOrigin: 'player',
        ),
      );
      expect(seat.seat, 2);
      expect(seat.name, 'Priya');
      expect(seat.connected, isTrue);
      expect(seat.tokens, [0, 5, 14, 57]);
      expect(seat.clientSeed, 'priya-seed');
      expect(seat.seedOrigin, SeedOrigin.player);
    });

    test('a seat that has not set a seed has client_seed and seed_origin both null', () {
      final seat = SeatState.fromJson(_validSeat());
      expect(seat.clientSeed, isNull);
      expect(seat.seedOrigin, isNull);
    });

    for (final field in ['seat', 'name', 'connected', 'tokens']) {
      test('$field missing throws', () {
        expect(
          () => SeatState.fromJson(_without(_validSeat(), field)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('$field explicit null throws', () {
        expect(
          () => SeatState.fromJson(_replacing(_validSeat(), field, null)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    }

    test('seat of the wrong runtime type (a string) throws', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'seat', '0')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('seat as a double with a zero fraction (0.0) is rejected', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'seat', 0.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('name of the wrong runtime type (an int) throws', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'name', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('connected of the wrong runtime type (a string) throws', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'connected', 'true')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('tokens of the wrong runtime type (a map) throws', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'tokens', <String, Object?>{'a': 1}),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('tokens with three entries throws', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'tokens', const <Object?>[0, 1, 2]),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('tokens with five entries throws', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'tokens', const <Object?>[0, 1, 2, 3, 4]),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('tokens with four strings throws', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'tokens', const <Object?>[
            'a',
            'b',
            'c',
            'd',
          ]),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('a token as a double with a zero fraction (0.0) is rejected', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'tokens', const <Object?>[0.0, 1, 2, 3]),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    group('seat range 0..3', () {
      test('-1, just under the minimum, throws', () {
        expect(
          () => SeatState.fromJson(_validSeat(seat: -1)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('0, the minimum, is accepted', () {
        expect(SeatState.fromJson(_validSeat(seat: 0)).seat, 0);
      });
      test('3, the maximum, is accepted', () {
        expect(SeatState.fromJson(_validSeat(seat: 3)).seat, 3);
      });
      test('4, just over the maximum, throws', () {
        expect(
          () => SeatState.fromJson(_validSeat(seat: 4)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    });

    // Ambiguity: whether a missing key (as opposed to an explicit null)
    // throws for these two fields is not tested; see the file header.
    test('client_seed explicit null is accepted', () {
      final seat = SeatState.fromJson(
        _replacing(_validSeat(), 'client_seed', null),
      );
      expect(seat.clientSeed, isNull);
    });
    test('seed_origin explicit null is accepted', () {
      final seat = SeatState.fromJson(
        _replacing(_validSeat(), 'seed_origin', null),
      );
      expect(seat.seedOrigin, isNull);
    });

    test('client_seed of the wrong runtime type (an int) throws', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'client_seed', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('SeatState.fromJson: seed_origin', () {
    test('player decodes to SeedOrigin.player', () {
      final seat = SeatState.fromJson(_validSeat(seedOrigin: 'player'));
      expect(seat.seedOrigin, SeedOrigin.player);
    });
    test('server decodes to SeedOrigin.server', () {
      final seat = SeatState.fromJson(_validSeat(seedOrigin: 'server'));
      expect(seat.seedOrigin, SeedOrigin.server);
    });
    test('null decodes to null', () {
      final seat = SeatState.fromJson(_validSeat(seedOrigin: null));
      expect(seat.seedOrigin, isNull);
    });
    test('uppercase PLAYER throws', () {
      expect(
        () => SeatState.fromJson(
          _replacing(_validSeat(), 'seed_origin', 'PLAYER'),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('an unrecognised string throws', () {
      expect(
        () =>
            SeatState.fromJson(_replacing(_validSeat(), 'seed_origin', 'bot')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('the wrong runtime type throws', () {
      expect(
        () => SeatState.fromJson(_replacing(_validSeat(), 'seed_origin', 7)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('TurnState.fromJson', () {
    test('decodes an await_roll turn with no value, legal or sixes', () {
      final turn = TurnState.fromJson(_validTurn(phase: 'await_roll'));
      expect(turn.seat, 1);
      expect(turn.phase, TurnPhase.awaitRoll);
      expect(turn.deadlineMs, 30000);
      expect(turn.k, 0);
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
    });

    test('decodes an await_move turn with value, legal and sixes present', () {
      final turn = TurnState.fromJson(
        _validTurn(
          phase: 'await_move',
          value: 6,
          legal: _legalAB,
          sixes: 1,
          k: 12,
        ),
      );
      expect(turn.phase, TurnPhase.awaitMove);
      expect(turn.value, 6);
      expect(turn.legal, [0, 2]);
      expect(turn.sixes, 1);
      expect(turn.k, 12);
    });

    test('decodes a finished turn with no value, legal or sixes', () {
      final turn = TurnState.fromJson(
        _validTurn(phase: 'finished', deadlineMs: 0, k: 57),
      );
      expect(turn.phase, TurnPhase.finished);
      expect(turn.deadlineMs, 0);
      expect(turn.k, 57);
      expect(turn.value, isNull);
      expect(turn.legal, isNull);
      expect(turn.sixes, isNull);
    });

    for (final field in ['seat', 'phase', 'deadline_ms', 'k']) {
      test('$field missing throws', () {
        expect(
          () => TurnState.fromJson(_without(_validTurn(), field)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('$field explicit null throws', () {
        expect(
          () => TurnState.fromJson(_replacing(_validTurn(), field, null)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    }

    test('seat of the wrong runtime type throws', () {
      expect(
        () => TurnState.fromJson(_replacing(_validTurn(), 'seat', 'one')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('deadline_ms of the wrong runtime type throws', () {
      expect(
        () => TurnState.fromJson(
          _replacing(_validTurn(), 'deadline_ms', '30000'),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('deadline_ms as a double with a zero fraction is rejected', () {
      expect(
        () => TurnState.fromJson(
          _replacing(_validTurn(), 'deadline_ms', 30000.0),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('k of the wrong runtime type throws', () {
      expect(
        () => TurnState.fromJson(_replacing(_validTurn(), 'k', '0')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('k as a double with a zero fraction is rejected', () {
      expect(
        () => TurnState.fromJson(_replacing(_validTurn(), 'k', 12.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test(
      'value, legal and sixes are all absent when only phase is await_roll',
      () {
        final turn = TurnState.fromJson(_validTurn(phase: 'await_roll'));
        expect(turn.value, isNull);
        expect(turn.legal, isNull);
        expect(turn.sixes, isNull);
      },
    );

    test('value present but of the wrong runtime type throws', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(_replacing(base, 'value', 'six')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('value as a double with a zero fraction (6.0) is rejected', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(_replacing(base, 'value', 6.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('legal present but of the wrong runtime type throws', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(_replacing(base, 'legal', 'nope')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('legal containing a non-int element throws', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(
          _replacing(base, 'legal', const <Object?>['a', 'b']),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('sixes present but of the wrong runtime type throws', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(_replacing(base, 'sixes', 'one')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('sixes as a double with a zero fraction (1.0) is rejected', () {
      final base = _validTurn(
        phase: 'await_move',
        value: 6,
        legal: _legalAB,
        sixes: 1,
      );
      expect(
        () => TurnState.fromJson(_replacing(base, 'sixes', 1.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('TurnState.fromJson: phase', () {
    test('await_roll decodes to TurnPhase.awaitRoll', () {
      expect(
        TurnState.fromJson(_validTurn(phase: 'await_roll')).phase,
        TurnPhase.awaitRoll,
      );
    });
    test('await_move decodes to TurnPhase.awaitMove', () {
      expect(
        TurnState.fromJson(
          _validTurn(
            phase: 'await_move',
            value: 1,
            legal: const <Object?>[0],
            sixes: 0,
          ),
        ).phase,
        TurnPhase.awaitMove,
      );
    });
    test('finished decodes to TurnPhase.finished, the third value section 14.1 adds', () {
      expect(
        TurnState.fromJson(_validTurn(phase: 'finished')).phase,
        TurnPhase.finished,
      );
    });
    test('camelCase awaitRoll throws even though it looks correct', () {
      expect(
        () => TurnState.fromJson(_validTurn(phase: 'awaitRoll')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('an unrecognised phase string throws', () {
      expect(
        () => TurnState.fromJson(_validTurn(phase: 'idle')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('phase of the wrong runtime type throws', () {
      expect(
        () => TurnState.fromJson(_replacing(_validTurn(), 'phase', 7)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group('RoomSnapshot.fromJson', () {
    test('decodes a minimal LOBBY room', () {
      final room = RoomSnapshot.fromJson(_validRoom());
      expect(room.code, 'K7M2QP');
      expect(room.state, RoomState.lobby);
      expect(room.hostSeat, 0);
      expect(room.players, 4);
      expect(room.rules.blocks, isTrue);
      expect(room.chainCommit, _hex64);
      expect(room.chainIndex, 0);
      expect(room.gameId, isNull);
      expect(room.clientSeeds, isNull);
      expect(room.seats, hasLength(1));
      expect(room.turn, isNull);
      expect(room.winner, isNull);
      expect(room.seq, 1);
    });

    final nonNullableFields = [
      'code',
      'state',
      'host_seat',
      'players',
      'rules',
      'chain_commit',
      'chain_index',
      'seats',
      'seq',
    ];
    for (final field in nonNullableFields) {
      test('$field missing throws', () {
        expect(
          () => RoomSnapshot.fromJson(_without(_validRoom(), field)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('$field explicit null throws', () {
        expect(
          () => RoomSnapshot.fromJson(_replacing(_validRoom(), field, null)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    }

    test('code of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'code', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('host_seat of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'host_seat', '0')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('host_seat as a double with a zero fraction is rejected', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'host_seat', 0.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('players of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'players', '4')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('rules of the wrong runtime type (not an object) throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'rules', 'nope')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('an invalid nested rules value propagates as a throw', () {
      expect(
        () => RoomSnapshot.fromJson(
          _replacing(_validRoom(), 'rules', <String, Object?>{
            'turn_seconds': 200,
          }),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('chain_commit of the wrong runtime type throws', () {
      expect(
        () =>
            RoomSnapshot.fromJson(_replacing(_validRoom(), 'chain_commit', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('chain_index of the wrong runtime type throws', () {
      expect(
        () =>
            RoomSnapshot.fromJson(_replacing(_validRoom(), 'chain_index', '0')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('chain_index as a double with a zero fraction is rejected', () {
      expect(
        () =>
            RoomSnapshot.fromJson(_replacing(_validRoom(), 'chain_index', 0.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('seats of the wrong runtime type (not a list) throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'seats', 'nope')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('seats containing a non-object element throws', () {
      expect(
        () => RoomSnapshot.fromJson(
          _replacing(_validRoom(), 'seats', const <Object?>['not a seat']),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('seq of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'seq', '1')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    test('seq as a double with a zero fraction is rejected', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'seq', 1.0)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    group('host_seat range 0..3', () {
      test('-1, just under the minimum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(hostSeat: -1)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('0, the minimum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(hostSeat: 0)).hostSeat, 0);
      });
      test('3, the maximum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(hostSeat: 3)).hostSeat, 3);
      });
      test('4, just over the maximum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(hostSeat: 4)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    });

    group('players range 2..4', () {
      test('1, just under the minimum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(players: 1)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('2, the minimum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(players: 2)).players, 2);
      });
      test('4, the maximum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(players: 4)).players, 4);
      });
      test('5, just over the maximum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(players: 5)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    });

    // Ambiguity: whether a missing key (as opposed to an explicit null)
    // throws for game_id, client_seeds, turn and winner is not tested; see
    // the file header.
    test('game_id explicit null is accepted', () {
      expect(RoomSnapshot.fromJson(_validRoom(gameId: null)).gameId, isNull);
    });
    test('game_id of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'game_id', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('client_seeds explicit null is accepted', () {
      expect(
        RoomSnapshot.fromJson(_validRoom(clientSeeds: null)).clientSeeds,
        isNull,
      );
    });
    test('client_seeds of the wrong runtime type throws', () {
      expect(
        () =>
            RoomSnapshot.fromJson(_replacing(_validRoom(), 'client_seeds', 5)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('turn explicit null is accepted', () {
      expect(RoomSnapshot.fromJson(_validRoom(turn: null)).turn, isNull);
    });
    test('turn of the wrong runtime type (not an object) throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'turn', 'nope')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('an invalid nested turn value propagates as a throw', () {
      expect(
        () => RoomSnapshot.fromJson(
          _replacing(_validRoom(), 'turn', _without(_validTurn(), 'phase')),
        ),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('winner explicit null is accepted', () {
      expect(RoomSnapshot.fromJson(_validRoom(winner: null)).winner, isNull);
    });
    test('winner of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'winner', 'zero')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });

    group('winner range 0..3 when non-null', () {
      test('-1, just under the minimum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(winner: -1)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
      test('0, the minimum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(winner: 0)).winner, 0);
      });
      test('3, the maximum, is accepted', () {
        expect(RoomSnapshot.fromJson(_validRoom(winner: 3)).winner, 3);
      });
      test('4, just over the maximum, throws', () {
        expect(
          () => RoomSnapshot.fromJson(_validRoom(winner: 4)),
          throwsA(isA<SnapshotFormatException>()),
        );
      });
    });

    test('unknown top-level keys are ignored', () {
      final json = _replacing(_validRoom(), 'unexpected_future_field', 'junk');
      final room = RoomSnapshot.fromJson(json);
      expect(room.code, 'K7M2QP');
    });
  });

  group('RoomSnapshot.fromJson: state', () {
    test('LOBBY decodes to RoomState.lobby', () {
      expect(
        RoomSnapshot.fromJson(_validRoom(state: 'LOBBY')).state,
        RoomState.lobby,
      );
    });
    test('PLAYING decodes to RoomState.playing', () {
      final room = RoomSnapshot.fromJson(
        _validRoom(
          state: 'PLAYING',
          turn: _validTurn(phase: 'await_roll'),
        ),
      );
      expect(room.state, RoomState.playing);
    });
    test('FINISHED decodes to RoomState.finished', () {
      final room = RoomSnapshot.fromJson(
        _validRoom(
          state: 'FINISHED',
          turn: _validTurn(phase: 'finished'),
          winner: 0,
        ),
      );
      expect(room.state, RoomState.finished);
    });
    test('lowercase lobby throws', () {
      expect(
        () => RoomSnapshot.fromJson(_validRoom(state: 'lobby')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('an unknown state string throws', () {
      expect(
        () => RoomSnapshot.fromJson(_validRoom(state: 'PENDING')),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
    test('state of the wrong runtime type throws', () {
      expect(
        () => RoomSnapshot.fromJson(_replacing(_validRoom(), 'state', 3)),
        throwsA(isA<SnapshotFormatException>()),
      );
    });
  });

  group(
    'cross-field consistency is deliberately not enforced by the decoder',
    () {
      // docs/PROTOCOL.md section 10, and the work order: the server is
      // authoritative and a client that refuses to render a snapshot over a
      // discrepancy it could have rendered through shows its player a blank
      // screen. These are positive tests, so a later hand cannot add the
      // rejection without a red test.

      test('value, legal and sixes present under await_roll are recorded as given, not stripped', () {
        final turn = TurnState.fromJson(
          _validTurn(phase: 'await_roll', value: 6, legal: _legalAB, sixes: 1),
        );
        expect(turn.phase, TurnPhase.awaitRoll);
        expect(turn.value, 6);
        expect(turn.legal, [0, 2]);
        expect(turn.sixes, 1);
      });

      test('a non-null turn in state LOBBY decodes without rejection', () {
        final room = RoomSnapshot.fromJson(
          _validRoom(
            state: 'LOBBY',
            turn: _validTurn(phase: 'await_roll'),
          ),
        );
        expect(room.state, RoomState.lobby);
        expect(room.turn, isNotNull);
      });

      test('winner left null in state FINISHED decodes without rejection', () {
        final room = RoomSnapshot.fromJson(
          _validRoom(
            state: 'FINISHED',
            turn: _validTurn(phase: 'finished'),
            winner: null,
          ),
        );
        expect(room.state, RoomState.finished);
        expect(room.winner, isNull);
      });
    },
  );

  group('the three snapshots that matter most', () {
    // Shaped like packages/ludo_server/lib/src/snapshot.dart's
    // buildRoomSnapshot, field for field.

    test('LOBBY: turn null, winner null, game_id null, client_seeds null, '
        'a seat with client_seed and seed_origin null, tokens all -1', () {
      final json = _validRoom(
        code: 'K7M2QP',
        state: 'LOBBY',
        hostSeat: 0,
        players: 4,
        rules: _validRules(blocks: true, captureBonus: true, turnSeconds: 45),
        chainCommit: _hex64,
        chainIndex: 0,
        gameId: null,
        clientSeeds: null,
        seats: <Object?>[
          _validSeat(
            seat: 0,
            name: 'Sam',
            connected: true,
            tokens: _lobbyTokens,
            clientSeed: null,
            seedOrigin: null,
          ),
          _validSeat(
            seat: 1,
            name: 'Ada',
            connected: true,
            tokens: _lobbyTokens,
            clientSeed: null,
            seedOrigin: null,
          ),
        ],
        turn: null,
        winner: null,
        seq: 1,
      );

      final room = RoomSnapshot.fromJson(json);

      expect(room.code, 'K7M2QP');
      expect(room.state, RoomState.lobby);
      expect(room.hostSeat, 0);
      expect(room.players, 4);
      expect(room.rules.blocks, isTrue);
      expect(room.rules.captureBonus, isTrue);
      expect(room.rules.turnSeconds, 45);
      expect(room.chainCommit, _hex64);
      expect(room.chainIndex, 0);
      expect(room.gameId, isNull);
      expect(room.clientSeeds, isNull);
      expect(room.seats, hasLength(2));
      expect(room.seats[0].seat, 0);
      expect(room.seats[0].name, 'Sam');
      expect(room.seats[0].connected, isTrue);
      expect(room.seats[0].tokens, [-1, -1, -1, -1]);
      expect(room.seats[0].clientSeed, isNull);
      expect(room.seats[0].seedOrigin, isNull);
      expect(room.turn, isNull);
      expect(room.winner, isNull);
      expect(room.seq, 1);
    });

    test('PLAYING: turn.phase await_move with value, legal and sixes '
        'present, k non-zero, game_id and client_seeds non-null, a second '
        'seat with connected: false', () {
      final json = _validRoom(
        code: 'AB2345',
        state: 'PLAYING',
        hostSeat: 0,
        players: 2,
        rules: _validRules(blocks: true, captureBonus: false, turnSeconds: 30),
        chainCommit: _hex64,
        chainIndex: 0,
        gameId: _hex16,
        clientSeeds: '0:alice-seed|1:bob-seed',
        seats: <Object?>[
          _validSeat(
            seat: 0,
            name: 'Alice',
            connected: true,
            tokens: _playingTokensA,
            clientSeed: 'alice-seed',
            seedOrigin: 'player',
          ),
          _validSeat(
            seat: 1,
            name: 'Bob',
            connected: false,
            tokens: _lobbyTokens,
            clientSeed: 'bob-seed',
            seedOrigin: 'server',
          ),
        ],
        turn: _validTurn(
          seat: 1,
          phase: 'await_move',
          value: 6,
          legal: _legalAB,
          deadlineMs: 41200,
          sixes: 1,
          k: 12,
        ),
        winner: null,
        seq: 118,
      );

      final room = RoomSnapshot.fromJson(json);

      expect(room.state, RoomState.playing);
      expect(room.gameId, _hex16);
      expect(room.clientSeeds, '0:alice-seed|1:bob-seed');
      expect(room.seats, hasLength(2));
      expect(room.seats[1].connected, isFalse);
      expect(room.seats[1].seedOrigin, SeedOrigin.server);
      expect(room.turn, isNotNull);
      expect(room.turn!.seat, 1);
      expect(room.turn!.phase, TurnPhase.awaitMove);
      expect(room.turn!.value, 6);
      expect(room.turn!.legal, [0, 2]);
      expect(room.turn!.sixes, 1);
      expect(room.turn!.k, 12);
      expect(room.turn!.deadlineMs, 41200);
      expect(room.winner, isNull);
      expect(room.seq, 118);
    });

    test('FINISHED: turn non-null with phase finished and no value, legal '
        'or sixes, winner an integer seat', () {
      final json = _validRoom(
        code: 'ZZ9999',
        state: 'FINISHED',
        hostSeat: 0,
        players: 2,
        chainCommit: _hex64,
        chainIndex: 0,
        gameId: _hex16,
        clientSeeds: '0:alice-seed|1:bob-seed',
        seats: <Object?>[
          _validSeat(
            seat: 0,
            name: 'Alice',
            connected: true,
            tokens: const <Object?>[57, 57, 57, 40],
            clientSeed: 'alice-seed',
            seedOrigin: 'player',
          ),
          _validSeat(
            seat: 1,
            name: 'Bob',
            connected: true,
            tokens: const <Object?>[57, 30, -1, -1],
            clientSeed: 'bob-seed',
            seedOrigin: 'server',
          ),
        ],
        turn: _validTurn(seat: 0, phase: 'finished', deadlineMs: 0, k: 57),
        winner: 0,
        seq: 250,
      );

      final room = RoomSnapshot.fromJson(json);

      expect(room.state, RoomState.finished);
      expect(room.turn, isNotNull);
      expect(room.turn!.phase, TurnPhase.finished);
      expect(room.turn!.value, isNull);
      expect(room.turn!.legal, isNull);
      expect(room.turn!.sixes, isNull);
      expect(room.winner, 0);
      expect(room.seq, 250);
    });
  });

  group('integration: a real room frame end to end', () {
    test('Frame.decode then RoomSnapshot.fromJson reproduces a realistic PLAYING snapshot', () {
      final snapshotJson = _validRoom(
        state: 'PLAYING',
        players: 2,
        gameId: _hex16,
        clientSeeds: '0:alice-seed|1:bob-seed',
        seats: <Object?>[
          _validSeat(
            seat: 0,
            name: 'Alice',
            tokens: _playingTokensA,
            clientSeed: 'alice-seed',
            seedOrigin: 'player',
          ),
          _validSeat(
            seat: 1,
            name: 'Bob',
            connected: false,
            clientSeed: 'bob-seed',
            seedOrigin: 'server',
          ),
        ],
        turn: _validTurn(
          seat: 1,
          phase: 'await_move',
          value: 6,
          legal: _legalAB,
          sixes: 1,
          deadlineMs: 41200,
          k: 12,
        ),
        seq: 118,
      );
      final wireText = jsonEncode(<String, Object?>{
        'v': 1,
        't': 'room',
        'id': 'A' * 22,
        'd': snapshotJson,
      });

      final frame = Frame.decode(wireText);
      expect(frame.type, 'room');
      expect(frame.seq, 118);

      final room = RoomSnapshot.fromJson(frame.data);
      expect(room.state, RoomState.playing);
      expect(room.seats[1].connected, isFalse);
      expect(room.turn?.phase, TurnPhase.awaitMove);
      expect(room.turn?.k, 12);
      expect(room.seq, 118);
    });
  });
}
