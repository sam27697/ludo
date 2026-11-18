// C-664: the simulator's verify-record check under the 2026-11 ruleset.
//
// docs/VERIFY.md section 1.1 gives a format-1 record ten keys, and four more
// (`ruleset`, `releases`, `placings`, `retired`) under 2026-11 only
// (docs/PROTOCOL.md section 28 rules 2 and 3). The contract of the order:
//
//   R1  no `ruleset` key: exactly the ten 2026-10 keys.
//   R2  `ruleset == "2026-11"`: exactly those ten plus the four. Any other
//       `ruleset` value fails with a message naming it.
//   R3  under 2026-11: `placings` is a non-empty list of distinct seats of
//       the game with `placings[0] == winner`; `retired` is a list of
//       distinct seats of the game; `releases` is a strictly ascending list
//       of ints, each in 1 .. rolls.length. Each failure names the key and
//       the value.
//   R4  the room frame carries `rules.ruleset` under 2026-11 and omits it
//       under 2026-10 (docs/PROTOCOL.md section 28 rule 1); a caller that
//       saw it hands it to `fetchAndVerifyRecord(wireRuleset:)`, and the
//       record must agree.
//
// Every case runs `fetchAndVerifyRecord` itself against a real HttpServer on
// loopback that serves the record at `<verify_url>.json` and a page at
// `<verify_url>`: the check is exercised through the same fetch the
// simulator uses, with no stand-in for the network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/sim/game.dart' show SeenRoll;
import '../../tool/sim/record_check.dart';
import '../../tool/sim/scenario.dart' show ScenarioFailure;

const String _gameId = '0123456789abcdef';
const String _chainCommit =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const String _clientSeeds = 'seed-a|seed-b';

/// The four keys docs/VERIFY.md section 1.1 adds under 2026-11.
const List<String> _newKeys = <String>[
  'ruleset',
  'releases',
  'placings',
  'retired',
];

late HttpServer _server;
String _body = '{}';

String get _verifyUrl => 'http://127.0.0.1:${_server.port}/v/$_gameId';

/// A four-seat finished game of five rolls: seat 2 wins, seat 0 is second,
/// seat 3 is third and seat 1 left early. Seats and roll count are what the
/// R3 checks measure against.
Map<String, Object?> _record2610({int seats = 4, int rolls = 5}) {
  return <String, Object?>{
    'format': 1,
    'game_id': _gameId,
    'chain_commit': _chainCommit,
    'chain_index': 3,
    'chain_length': 1000,
    'client_seeds': _clientSeeds,
    'seeds': <Object?>[
      for (int s = 0; s < seats; s++)
        <String, Object?>{
          'seat': s,
          'seed': 'seed-$s',
          'origin': s == 0 ? 'player' : 'server',
        },
    ],
    'rolls': <Object?>[
      for (int k = 1; k <= rolls; k++)
        <String, Object?>{
          'k': k,
          'seat': (k - 1) % seats,
          'reveal': _reveal(k),
          'die': (k % 6) + 1,
        },
    ],
    'winner': seats - 2,
    'finished_at': '2026-11-17T09:30:00Z',
  };
}

String _reveal(int k) => k.toRadixString(16).padLeft(64, '0');

/// [_record2610] plus the four 2026-11 keys, with values that satisfy R3.
Map<String, Object?> _record2611({int seats = 4, int rolls = 5}) {
  final Map<String, Object?> record = _record2610(seats: seats, rolls: rolls);
  final int winner = record['winner']! as int;
  record['ruleset'] = '2026-11';
  record['releases'] = <int>[2, rolls];
  record['placings'] = <int>[
    winner,
    for (int s = 0; s < seats; s++)
      if (s != winner) s,
  ];
  record['retired'] = seats > 2 ? <int>[1] : <int>[];
  return record;
}

List<SeenRoll> _seen(Map<String, Object?> record) {
  final List<Object?> rolls = record['rolls']! as List<Object?>;
  return <SeenRoll>[
    for (final Object? r in rolls)
      SeenRoll(
        k: (r! as Map<String, Object?>)['k']! as int,
        seat: (r as Map<String, Object?>)['seat']! as int,
        reveal: r['reveal']! as String,
        die: r['die']! as int,
      ),
  ];
}

/// A value as a failure message may fairly print it: Dart's own rendering
/// or JSON. Either names the value.
Set<String> _val(Object? value) => <String>{'$value', jsonEncode(value)};

/// Serves [record] and runs the check. Returns the failure message, or null
/// when the check passed.
Future<String?> _run(
  Map<String, Object?> record, {
  String? wireRuleset,
}) async {
  _body = jsonEncode(record);
  try {
    await fetchAndVerifyRecord(
      verifyUrl: _verifyUrl,
      gameId: _gameId,
      chainCommit: _chainCommit,
      clientSeeds: _clientSeeds,
      winner: record['winner']! as int,
      rolls: _seen(record),
      wireRuleset: wireRuleset,
    );
    return null;
  } on ScenarioFailure catch (error) {
    return error.message;
  }
}

Future<void> _expectPass(
  String scenario,
  Map<String, Object?> record, {
  String? wireRuleset,
}) async {
  final String? failure = await _run(record, wireRuleset: wireRuleset);
  expect(
    failure,
    isNull,
    reason: 'scenario "$scenario": expected the check to pass, but it '
        'failed with: $failure; record served: ${jsonEncode(record)}',
  );
}

/// Expects a failure whose message contains every string in [mentions].
Future<void> _expectFail(
  String scenario,
  Map<String, Object?> record,
  List<Object> mentions, {
  String? wireRuleset,
  bool keySetBroken = false,
}) async {
  final String? failure = await _run(record, wireRuleset: wireRuleset);
  expect(
    failure,
    isNotNull,
    reason: 'scenario "$scenario": expected the check to FAIL naming '
        '$mentions, but it passed; record served: ${jsonEncode(record)}',
  );
  if (!keySetBroken) {
    // The key set of these records is right, so a "key set" complaint
    // would name the wrong problem and could satisfy a loose match on a
    // key name by accident.
    expect(
      failure,
      isNot(contains('key set')),
      reason: 'scenario "$scenario": the record has exactly the keys it '
          'should, so the failure must be about the value, not the key '
          'set; got: $failure',
    );
  }
  for (final Object m in mentions) {
    final Set<String> accepted = m is Set<String> ? m : <String>{'$m'};
    expect(
      accepted.any((String a) => failure!.contains(a)),
      isTrue,
      reason: 'scenario "$scenario": the failure must name one of '
          '$accepted so the operator can see which key and value broke; '
          'got: $failure; record served: ${jsonEncode(record)}',
    );
  }
}

void main() {
  setUpAll(() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      if (path == '/v/$_gameId.json') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(_body);
      } else if (path == '/v/$_gameId') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html></html>');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await _server.close(force: true);
  });

  group('R1: a record without ruleset has exactly the ten 2026-10 keys', () {
    test('a 2026-10 record passes', () async {
      await _expectPass('2026-10 record, four seats', _record2610());
      await _expectPass(
        '2026-10 record, two seats',
        _record2610(seats: 2, rolls: 3),
      );
    });

    for (final String key in _newKeys) {
      test('a 2026-10 record plus "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2610();
        record[key] = switch (key) {
          'ruleset' => '2026-11',
          'releases' => <int>[1],
          'placings' => <int>[2],
          _ => <int>[],
        };
        // A lone `ruleset: "2026-11"` is a 2026-11 record missing three
        // keys; the others are keys that must not exist without it.
        await _expectFail(
          '2026-10 record plus $key',
          record,
          <String>[key],
          keySetBroken: true,
        );
      });
    }

    test('a record with releases, placings and retired but no ruleset fails',
        () async {
      final Map<String, Object?> record = _record2611()..remove('ruleset');
      await _expectFail(
        '2026-11 body with ruleset removed',
        record,
        <String>['releases', 'placings', 'retired'],
        keySetBroken: true,
      );
    });

    for (final String key in recordKeys) {
      test('a 2026-10 record missing "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2610()..remove(key);
        // `winner` and `rolls` feed the harness itself, so keep the
        // expectations independent of the removed key.
        _body = jsonEncode(record);
        String? failure;
        try {
          await fetchAndVerifyRecord(
            verifyUrl: _verifyUrl,
            gameId: _gameId,
            chainCommit: _chainCommit,
            clientSeeds: _clientSeeds,
            winner: 2,
            rolls: _seen(_record2610()),
          );
        } on ScenarioFailure catch (error) {
          failure = error.message;
        }
        expect(
          failure,
          allOf(isNotNull, contains(key)),
          reason: 'scenario "2026-10 record minus $key": expected a FAIL '
              'naming "$key", got: $failure',
        );
      });
    }
  });

  group('R2: a 2026-11 record has the ten keys plus the four', () {
    test('a 2026-11 record passes', () async {
      await _expectPass('2026-11 record, four seats', _record2611());
    });

    test('a 2026-11 record with no releases, no retirements passes', () async {
      final Map<String, Object?> record = _record2611(seats: 2, rolls: 3)
        ..['releases'] = <int>[]
        ..['placings'] = <int>[0, 1]
        ..['retired'] = <int>[];
      await _expectPass(
          '2026-11 two seats, empty releases and retired', record);
    });

    for (final String key in _newKeys.skip(1)) {
      test('a 2026-11 record minus "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2611()..remove(key);
        await _expectFail(
          '2026-11 record minus $key',
          record,
          <String>[key],
          keySetBroken: true,
        );
      });
    }

    for (final Object? bad in <Object?>[
      '2026-13',
      '2026-10',
      '2026-1',
      '2026-11 ',
      '',
      'abc',
      null,
      202611,
      true,
      <String>['2026-11'],
    ]) {
      test('ruleset value ${jsonEncode(bad)} fails naming ruleset and value',
          () async {
        final Map<String, Object?> record = _record2611()..['ruleset'] = bad;
        await _expectFail(
          'ruleset=${jsonEncode(bad)} with all fourteen keys present',
          record,
          <Object>['ruleset', _val(bad)],
        );
      });
    }

    test('a 2026-11 record with an unknown extra key fails naming it',
        () async {
      final Map<String, Object?> record = _record2611()..['room_code'] = 'ABCD';
      await _expectFail(
        '2026-11 plus room_code',
        record,
        <String>['room_code'],
        keySetBroken: true,
      );
    });
  });

  group('R3: placings, retired and releases under 2026-11', () {
    test('placings: boundaries that pass', () async {
      final Map<String, Object?> record = _record2611()
        ..['placings'] = <int>[2];
      await _expectPass('placings holds only the winner', record);

      final Map<String, Object?> two = _record2611(seats: 2, rolls: 3)
        ..['placings'] = <int>[0, 1];
      await _expectPass('two-seat game, winner is seat 0', two);
    });

    final Map<String, List<Object?>> badPlacings = <String, List<Object?>>{
      'empty': <Object?>[],
      'duplicate seat': <Object?>[2, 0, 0],
      'duplicate winner': <Object?>[2, 2],
      'seat not in the game': <Object?>[2, 7],
      'negative seat': <Object?>[2, -1],
      'first is not the winner': <Object?>[0, 2, 3],
      'winner last': <Object?>[0, 3, 1, 2],
      'string seat': <Object?>[2, '0'],
      'null seat': <Object?>[2, null],
      'fractional seat': <Object?>[2, 0.5],
    };
    badPlacings.forEach((String name, List<Object?> value) {
      test('placings $name fails naming placings and the value', () async {
        final Map<String, Object?> record = _record2611()..['placings'] = value;
        await _expectFail(
          'placings $name = ${jsonEncode(value)}',
          record,
          <Object>['placings', _val(value)],
        );
      });
    });

    test('placings that is not a list fails naming placings and the value',
        () async {
      for (final Object? value in <Object?>[
        '2',
        2,
        null,
        <String, Object?>{}
      ]) {
        final Map<String, Object?> record = _record2611()..['placings'] = value;
        await _expectFail(
          'placings = ${jsonEncode(value)}',
          record,
          <Object>['placings', _val(value)],
        );
      }
    });

    test('placings naming a seat outside a two-seat game fails', () async {
      final Map<String, Object?> record = _record2611(seats: 2, rolls: 3)
        ..['placings'] = <int>[0, 2]
        ..['retired'] = <int>[];
      await _expectFail(
        'two-seat game, placings [0, 2]',
        record,
        <String>['placings', '2'],
      );
    });

    test('retired: boundaries that pass', () async {
      for (final List<int> value in <List<int>>[
        <int>[],
        <int>[0],
        <int>[3, 1],
        <int>[0, 1, 3],
      ]) {
        final Map<String, Object?> record = _record2611()..['retired'] = value;
        await _expectPass('retired = $value', record);
      }
    });

    final Map<String, Object?> badRetired = <String, Object?>{
      'duplicate seat': <Object?>[1, 1],
      'seat not in the game': <Object?>[9],
      'negative seat': <Object?>[-1],
      'string seat': <Object?>['1'],
      'null seat': <Object?>[null],
      'not a list: string': '1',
      'not a list: int': 1,
      'not a list: null': null,
    };
    badRetired.forEach((String name, Object? value) {
      test('retired $name fails naming retired and the value', () async {
        final Map<String, Object?> record = _record2611()..['retired'] = value;
        await _expectFail(
          'retired $name = ${jsonEncode(value)}',
          record,
          <Object>['retired', _val(value)],
        );
      });
    });

    test('retired naming a seat outside a two-seat game fails', () async {
      final Map<String, Object?> record = _record2611(seats: 2, rolls: 3)
        ..['placings'] = <int>[0, 1]
        ..['retired'] = <int>[3];
      await _expectFail(
        'two-seat game, retired [3]',
        record,
        <String>['retired', '3'],
      );
    });

    test('releases: boundaries that pass (1 and rolls.length)', () async {
      for (final List<int> value in <List<int>>[
        <int>[],
        <int>[1],
        <int>[5],
        <int>[1, 5],
        <int>[1, 2, 3, 4, 5],
      ]) {
        final Map<String, Object?> record = _record2611()..['releases'] = value;
        await _expectPass('releases = $value in a five-roll game', record);
      }
    });

    final Map<String, Object?> badReleases = <String, Object?>{
      'zero': <Object?>[0],
      'below range, then valid': <Object?>[0, 2],
      'above range by one': <Object?>[6],
      'far above range': <Object?>[2, 100],
      'negative': <Object?>[-3, 2],
      'duplicate': <Object?>[2, 2],
      'descending': <Object?>[4, 2],
      'not strictly ascending in the middle': <Object?>[1, 3, 2, 5],
      'string entry': <Object?>['2'],
      'fractional entry': <Object?>[1.5],
      'null entry': <Object?>[null],
      'not a list: string': '2',
      'not a list: int': 2,
      'not a list: null': null,
    };
    badReleases.forEach((String name, Object? value) {
      test('releases $name fails naming releases and the value', () async {
        final Map<String, Object?> record = _record2611()..['releases'] = value;
        await _expectFail(
          'releases $name = ${jsonEncode(value)}',
          record,
          <Object>['releases', _val(value)],
        );
      });
    });

    test('releases above rolls.length of a short game fails', () async {
      final Map<String, Object?> record = _record2611(seats: 2, rolls: 3)
        ..['releases'] = <int>[4]
        ..['placings'] = <int>[0, 1]
        ..['retired'] = <int>[];
      await _expectFail(
        'three-roll game, releases [4]',
        record,
        <String>['releases', '4'],
      );
    });
  });

  group('R4: the ruleset the room frame showed must match the record', () {
    test('a 2026-11 room frame and a 2026-11 record pass', () async {
      await _expectPass(
        'wire 2026-11, record 2026-11',
        _record2611(),
        wireRuleset: '2026-11',
      );
    });

    test('a 2026-10 room frame (no rules.ruleset) and a 2026-10 record pass',
        () async {
      await _expectPass(
        'wire 2026-10, record 2026-10',
        _record2610(),
        wireRuleset: '2026-10',
      );
    });

    test('wire 2026-11 against a 2026-10 record fails naming both', () async {
      await _expectFail(
        'wire 2026-11, record has no ruleset',
        _record2610(),
        <String>['2026-11', '2026-10', 'ruleset'],
        wireRuleset: '2026-11',
      );
    });

    test('wire 2026-10 against a 2026-11 record fails naming both', () async {
      await _expectFail(
        'wire 2026-10, record ruleset 2026-11',
        _record2611(),
        <String>['2026-11', '2026-10', 'ruleset'],
        wireRuleset: '2026-10',
      );
    });

    test('no wire ruleset given: the check is skipped for either record',
        () async {
      await _expectPass('wire not captured, 2026-10 record', _record2610());
      await _expectPass('wire not captured, 2026-11 record', _record2611());
    });
  });

  group('R5: the rest of the record check is unchanged under 2026-11', () {
    test('a wrong winner still fails naming winner', () async {
      final Map<String, Object?> record = _record2611();
      _body = jsonEncode(record);
      String? failure;
      try {
        await fetchAndVerifyRecord(
          verifyUrl: _verifyUrl,
          gameId: _gameId,
          chainCommit: _chainCommit,
          clientSeeds: _clientSeeds,
          winner: 3,
          rolls: _seen(record),
        );
      } on ScenarioFailure catch (error) {
        failure = error.message;
      }
      expect(
        failure,
        allOf(isNotNull, contains('winner')),
        reason: 'scenario "2026-11 record, wire winner 3, record winner 2": '
            'expected a FAIL naming winner, got: $failure',
      );
    });

    test('a roll that differs from the wire still fails naming the roll',
        () async {
      final Map<String, Object?> record = _record2611();
      final List<SeenRoll> seen = _seen(record);
      _body = jsonEncode(record);
      final List<SeenRoll> altered = <SeenRoll>[
        for (final SeenRoll r in seen)
          if (r.k == 3)
            SeenRoll(k: r.k, seat: r.seat, reveal: r.reveal, die: r.die % 6 + 1)
          else
            r,
      ];
      String? failure;
      try {
        await fetchAndVerifyRecord(
          verifyUrl: _verifyUrl,
          gameId: _gameId,
          chainCommit: _chainCommit,
          clientSeeds: _clientSeeds,
          winner: 2,
          rolls: altered,
        );
      } on ScenarioFailure catch (error) {
        failure = error.message;
      }
      expect(
        failure,
        allOf(isNotNull, contains('k=3'), contains('die')),
        reason: 'scenario "2026-11 record, die of k=3 differs from the '
            'wire": expected a FAIL naming k=3 and die, got: $failure',
      );
    });
  });
}
