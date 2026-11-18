// C-677: the simulator's verify-record check under the 2026-12 ruleset.
//
// docs/VERIFY.md section 1.1 and docs/PROTOCOL.md section 30 rule 7: a
// 2026-12 record has the fourteen keys of 2026-11 plus `declined`, `lapsed`
// and `grants` (a 2026-12 room plays everything 2026-11 does, section 30
// rule 1). 2026-10 and 2026-11 records are checked as before, so
// `lapsed`, `declined` and `grants` are foreign to them.
//
// Every case runs `fetchAndVerifyRecord` itself against a real HttpServer on
// loopback, as test/tool/c664_record_check_ruleset_test.dart does. A failure
// message names the scenario and the record served, which is all that is
// needed to reproduce it: the record is built by the fixture functions here.

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

late HttpServer _server;
String _body = '{}';

String get _verifyUrl => 'http://127.0.0.1:${_server.port}/v/$_gameId';

String _reveal(int k) => k.toRadixString(16).padLeft(64, '0');

/// A finished game, no ruleset key: four seats, [rolls] rolls, roll k by
/// seat (k - 1) % seats, winner seat 2.
Map<String, Object?> _record2610({int seats = 4, int rolls = 8}) {
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
          'die': (k % 5) + 1,
        },
    ],
    'winner': 2,
    'finished_at': '2026-11-19T09:30:00Z',
  };
}

/// Adds the four 2026-11 keys.
Map<String, Object?> _record2611({int seats = 4, int rolls = 8}) {
  final Map<String, Object?> record = _record2610(seats: seats, rolls: rolls);
  record['ruleset'] = '2026-11';
  record['releases'] = <int>[2, 5];
  record['placings'] = <int>[2, 0, 3, 1];
  record['retired'] = <int>[1];
  return record;
}

/// A 2026-12 record: roll 2 (seat 1) is a taken release granting a six to
/// seats 0, 2, 3; roll 5 (seat 0) is declined; roll 7 (seat 2) is a lapse.
Map<String, Object?> _record2612({int seats = 4, int rolls = 8}) {
  final Map<String, Object?> record = _record2611(seats: seats, rolls: rolls);
  record['ruleset'] = '2026-12';
  record['releases'] = <int>[2, 5, 7];
  record['declined'] = <int>[5];
  record['lapsed'] = <int>[7];
  record['grants'] = <Object?>[
    <String, Object?>{
      'k': 2,
      'seats': <int>[0, 2, 3],
    },
  ];
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
      winner: 2,
      rolls: _seen(_record2610(
        seats: (record['seeds']! as List<Object?>).length,
        rolls: (record['rolls']! as List<Object?>).length,
      )),
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

Future<void> _expectFail(
  String scenario,
  Map<String, Object?> record,
  List<String> mentions, {
  String? wireRuleset,
}) async {
  final String? failure = await _run(record, wireRuleset: wireRuleset);
  expect(
    failure,
    isNotNull,
    reason: 'scenario "$scenario": expected the check to FAIL naming '
        '$mentions, but it passed; record served: ${jsonEncode(record)}',
  );
  for (final String m in mentions) {
    expect(
      failure!.contains(m),
      isTrue,
      reason: 'scenario "$scenario": the failure must name "$m"; got: '
          '$failure; record served: ${jsonEncode(record)}',
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

  group('a 2026-12 record', () {
    test('with every key passes, with and without the wire ruleset', () async {
      await _expectPass('2026-12 full record', _record2612());
      await _expectPass(
        '2026-12 full record, wire 2026-12',
        _record2612(),
        wireRuleset: '2026-12',
      );
    });

    test('with empty declined, lapsed and grants passes', () async {
      final Map<String, Object?> record = _record2612()
        ..['releases'] = <int>[]
        ..['declined'] = <int>[]
        ..['lapsed'] = <int>[]
        ..['grants'] = <Object?>[];
      await _expectPass('2026-12, nothing offered', record);
    });

    test('with a grant naming no seats passes (nobody else was playing)',
        () async {
      final Map<String, Object?> record = _record2612()
        ..['grants'] = <Object?>[
          <String, Object?>{'k': 2, 'seats': <int>[]},
        ];
      await _expectPass('2026-12, grant with empty seats', record);
    });

    for (final String key in <String>['declined', 'lapsed', 'grants']) {
      test('missing "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2612()..remove(key);
        await _expectFail('2026-12 minus $key', record, <String>[key]);
      });
    }

    test('missing "ruleset" fails naming the keys that need it', () async {
      // Without `ruleset` the record reads as 2026-10, so the 2026-11 and
      // 2026-12 keys are the unexpected ones.
      final Map<String, Object?> record = _record2612()..remove('ruleset');
      await _expectFail('2026-12 minus ruleset', record,
          <String>['declined', 'lapsed', 'grants']);
    });

    for (final String key in <String>[
      'releases',
      'placings',
      'retired',
    ]) {
      test('missing the 2026-11 key "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2612()..remove(key);
        await _expectFail('2026-12 minus $key', record, <String>[key]);
      });
    }

    test('with an unknown extra key fails naming it', () async {
      final Map<String, Object?> record = _record2612()..['room_code'] = 'ABCD';
      await _expectFail(
          '2026-12 plus room_code', record, <String>['room_code']);
    });

    final Map<String, Map<String, Object?>> badValues =
        <String, Map<String, Object?>>{
      'declined': <String, Object?>{
        'not a list': 'x',
        'descending': <Object?>[5, 3],
        'duplicate': <Object?>[5, 5],
        'zero': <Object?>[0],
        'above the roll count': <Object?>[9],
        'string entry': <Object?>['5'],
        'not in releases': <Object?>[3],
        'also lapsed': <Object?>[5, 7],
      },
      'lapsed': <String, Object?>{
        'not a list': null,
        'descending': <Object?>[7, 5],
        'above the roll count': <Object?>[9],
        'not in releases': <Object?>[4],
        'fractional entry': <Object?>[7.5],
      },
      'grants': <String, Object?>{
        'not a list': 'x',
        'entry not an object': <Object?>[2],
        'entry without seats': <Object?>[
          <String, Object?>{'k': 2},
        ],
        'entry with an extra key': <Object?>[
          <String, Object?>{
            'k': 2,
            'seats': <int>[0],
            'by': 1
          },
        ],
        'k not in releases': <Object?>[
          <String, Object?>{
            'k': 3,
            'seats': <int>[0]
          },
        ],
        'k is a declined release': <Object?>[
          <String, Object?>{
            'k': 5,
            'seats': <int>[1]
          },
        ],
        'k is a lapse': <Object?>[
          <String, Object?>{
            'k': 7,
            'seats': <int>[0]
          },
        ],
        'k descending': <Object?>[
          <String, Object?>{
            'k': 5,
            'seats': <int>[1]
          },
          <String, Object?>{
            'k': 2,
            'seats': <int>[0]
          },
        ],
        'seats not a list': <Object?>[
          <String, Object?>{'k': 2, 'seats': 0},
        ],
        'seats descending': <Object?>[
          <String, Object?>{
            'k': 2,
            'seats': <int>[3, 0]
          },
        ],
        'seats duplicate': <Object?>[
          <String, Object?>{
            'k': 2,
            'seats': <int>[0, 0]
          },
        ],
        'seat not in the game': <Object?>[
          <String, Object?>{
            'k': 2,
            'seats': <int>[0, 9]
          },
        ],
        'seat is the roller': <Object?>[
          <String, Object?>{
            'k': 2,
            'seats': <int>[1, 2]
          },
        ],
      },
    };
    badValues.forEach((String key, Map<String, Object?> cases) {
      cases.forEach((String name, Object? value) {
        test('$key $name fails naming $key', () async {
          final Map<String, Object?> record = _record2612()..[key] = value;
          // 'declined also lapsed' needs 5 to stay a release: it does.
          if (key == 'declined' && name == 'also lapsed') {
            record['lapsed'] = <int>[5, 7];
          }
          await _expectFail('2026-12 with $key $name', record, <String>[key]);
        });
      });
    });

    test('the 2026-11 checks still apply: placings[0] must be the winner',
        () async {
      final Map<String, Object?> record = _record2612()
        ..['placings'] = <int>[0, 2, 3, 1];
      await _expectFail(
          '2026-12 with placings[0] != winner', record, <String>['placings']);
    });

    test('a ruleset value past 2026-12 fails naming ruleset and value',
        () async {
      final Map<String, Object?> record = _record2612()
        ..['ruleset'] = '2027-01';
      await _expectFail(
          'ruleset 2027-01', record, <String>['ruleset', '2027-01']);
    });
  });

  group('a 2026-11 record', () {
    test('still passes, alone and against a 2026-11 wire', () async {
      await _expectPass('2026-11 record', _record2611());
      await _expectPass('2026-11 record, wire 2026-11', _record2611(),
          wireRuleset: '2026-11');
    });

    for (final String key in <String>['lapsed', 'declined', 'grants']) {
      test('with "$key" fails naming the key', () async {
        final Map<String, Object?> record = _record2611()
          ..[key] = key == 'grants' ? <Object?>[] : <int>[];
        await _expectFail('2026-11 plus $key', record, <String>[key]);
      });
    }

    test('with all three 2026-12 keys fails naming them', () async {
      final Map<String, Object?> record = _record2611()
        ..['declined'] = <int>[]
        ..['lapsed'] = <int>[]
        ..['grants'] = <Object?>[];
      await _expectFail('2026-11 plus the 2026-12 keys', record,
          <String>['declined', 'lapsed', 'grants']);
    });
  });

  group('a 2026-10 record', () {
    test('still passes', () async {
      await _expectPass('2026-10 record', _record2610());
      await _expectPass('2026-10 record, wire 2026-10', _record2610(),
          wireRuleset: '2026-10');
    });

    test('with lapsed fails naming it', () async {
      final Map<String, Object?> record = _record2610()..['lapsed'] = <int>[];
      await _expectFail('2026-10 plus lapsed', record, <String>['lapsed']);
    });
  });

  group('the ruleset on the wire must equal the record\'s', () {
    final List<String?> rulesets = <String?>['2026-10', '2026-11', '2026-12'];
    final Map<String, Map<String, Object?> Function()> records =
        <String, Map<String, Object?> Function()>{
      '2026-10': _record2610,
      '2026-11': _record2611,
      '2026-12': _record2612,
    };
    for (final String recordRuleset in records.keys) {
      for (final String? wire in rulesets) {
        if (wire == recordRuleset) {
          continue;
        }
        test('record $recordRuleset against wire $wire fails naming both',
            () async {
          await _expectFail(
            'record $recordRuleset, room frame $wire',
            records[recordRuleset]!(),
            <String>[recordRuleset, wire!, 'ruleset'],
            wireRuleset: wire,
          );
        });
      }
    }

    test('the 2026-12 record against an absent wire key (2026-10) fails',
        () async {
      await _expectFail(
        '2026-12 record, room frame without rules.ruleset',
        _record2612(),
        <String>['2026-12', '2026-10'],
        wireRuleset: '2026-10',
      );
    });
  });
}
