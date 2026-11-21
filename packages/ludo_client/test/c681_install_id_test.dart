// C-681t: the install id (order 681 "Interface frozen", docs/PROTOCOL.md
// section 31 item 2): 32 random characters of [A-Za-z0-9_-] made on first
// use, kept in SharedPreferences under `install_id`, never logged.
//
// Written from the order alone. The accessor is `installId()`, a top-level
// async function returning Future<String>, imported from install_id.dart
// (the order allows it there or beside session_memory.dart: if it moves,
// that one import line is the only edit). Until order 681's lib lands this
// file does not compile (unresolved name), by design.
//
// Random.secure cannot be observed from outside; what is pinned is what a
// CSPRNG source gives and a constant or counter does not: ids from fresh
// stores differ, and across many ids every character of the alphabet shows
// up in every position class. The log check scans print and debugPrint.
//
// Replay: flutter test test/c681_install_id_test.dart --plain-name '<case>'

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

final RegExp _shape = RegExp(r'^[A-Za-z0-9_-]{32}$');

String _why(String id, String wanted, Object? saw) =>
    "$id: expected $wanted; saw $saw. reproduce: flutter test "
    "test/c681_install_id_test.dart --plain-name '$id'";

Future<String> _fresh() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return installId();
}

void main() {
  tearDown(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('first use makes a 32 character id of the allowed alphabet', () async {
    final String id = await _fresh();
    expect(
      _shape.hasMatch(id),
      isTrue,
      reason: _why(
        'shape',
        '32 chars of [A-Za-z0-9_-]',
        '"$id" (${id.length})',
      ),
    );
  });

  test('first use stores the id under the key install_id', () async {
    final String id = await _fresh();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('install_id'),
      id,
      reason: _why(
        'stored',
        'prefs install_id == returned id',
        prefs.getString('install_id'),
      ),
    );
  });

  test('later reads return the same id, many times over', () async {
    final String first = await _fresh();
    for (int i = 0; i < 25; i += 1) {
      final String again = await installId();
      expect(
        again,
        first,
        reason: _why('stable', 'the first id on read $i', again),
      );
    }
  });

  test('an id already in the store is returned, not replaced', () async {
    const String kept = 'abcdefghijklmnopqrstuvwxyz012345';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': kept,
    });
    final String id = await installId();
    expect(id, kept, reason: _why('kept', kept, id));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('install_id'),
      kept,
      reason: _why('kept_store', kept, prefs.getString('install_id')),
    );
  });

  test('two reads in flight at once agree on one id', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final List<String> ids = await Future.wait(<Future<String>>[
      installId(),
      installId(),
      installId(),
    ]);
    expect(
      ids.toSet().length,
      1,
      reason: _why(
        'concurrent',
        'one id for three simultaneous first reads',
        ids,
      ),
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('install_id'),
      ids.first,
      reason: _why(
        'concurrent_store',
        'the stored id is the returned one',
        prefs.getString('install_id'),
      ),
    );
  });

  test('a stored value of the wrong shape is never handed out', () async {
    for (final String bad in <String>[
      '',
      'short',
      'x' * 31,
      'x' * 33,
      'has space inside the id of 32 chars!',
      'a' * 31 + '+',
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'install_id': bad,
      });
      final String id = await installId();
      expect(
        _shape.hasMatch(id),
        isTrue,
        reason: _why(
          'badstore',
          'a valid 32 char id for stored "$bad"',
          '"$id"',
        ),
      );
    }
  });

  test(
    'fresh stores give different ids and every alphabet class appears',
    () async {
      final Set<String> ids = <String>{};
      final Set<String> seen = <String>{};
      for (int i = 0; i < 200; i += 1) {
        final String id = await _fresh();
        ids.add(id);
        seen.addAll(id.split(''));
      }
      expect(
        ids.length,
        200,
        reason: _why(
          'distinct',
          '200 distinct ids from 200 fresh stores',
          ids.length,
        ),
      );
      // 200 * 32 = 6400 draws over 64 symbols: a missing symbol is a
      // probability below 1e-40 for a uniform source.
      final bool lower = seen.any((String c) => RegExp('[a-z]').hasMatch(c));
      final bool upper = seen.any((String c) => RegExp('[A-Z]').hasMatch(c));
      final bool digit = seen.any((String c) => RegExp('[0-9]').hasMatch(c));
      final bool dash = seen.contains('-');
      final bool under = seen.contains('_');
      expect(
        <bool>[lower, upper, digit, dash, under],
        everyElement(isTrue),
        reason: _why(
          'alphabet',
          'lower, upper, digit, dash and underscore all seen over 6400 draws',
          'lower=$lower upper=$upper digit=$digit dash=$dash underscore=$under',
        ),
      );
    },
  );

  test('the id is never written to print or debugPrint', () async {
    final List<String> printed = <String>[];
    final DebugPrintCallback oldDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      printed.add(message ?? '');
    };
    addTearDown(() => debugPrint = oldDebugPrint);

    final List<String> ids = <String>[];
    await runZoned(
      () async {
        ids.add(await _fresh());
        ids.add(await installId());
        ids.add(await installId());
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          printed.add(line);
        },
      ),
    );
    final String all = printed.join('\n');
    expect(
      all.contains(ids.first),
      isFalse,
      reason: _why('not_logged', 'no log line containing the install id', all),
    );
  });
}
