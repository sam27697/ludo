// Order 576: the Dart copy of the recorded real-games fixture
// (integration_test/fixtures/real_games_fixture.dart, which the store
// captures carry to an emulator) must be the recorded file and nothing else.
// A re-record of real_games.json that forgets the wrapper goes red here.
//
// Host side only: it reads the JSON with dart:io, which the emulator run of
// the captures cannot do.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/fixtures/real_games_fixture.dart';

const String _regenerate =
    'cd packages/ludo_server && dart run tool/wrap_real_games_fixture.dart';

/// The path of the first difference between [a] and [b], or null when they
/// are deeply equal. Maps compare by key set and value, lists by length and
/// element, scalars with `==`.
String? _firstDifference(Object? a, Object? b, String path) {
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    for (final String key in a.keys) {
      if (!b.containsKey(key)) {
        return '$path.$key is in the wrapped copy only';
      }
    }
    for (final String key in b.keys) {
      if (!a.containsKey(key)) {
        return '$path.$key is in real_games.json only';
      }
    }
    for (final String key in a.keys) {
      final String? inner = _firstDifference(a[key], b[key], '$path.$key');
      if (inner != null) {
        return inner;
      }
    }
    return null;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) {
      return '$path has ${a.length} elements in the wrapped copy and '
          '${b.length} in real_games.json';
    }
    for (var i = 0; i < a.length; i++) {
      final String? inner = _firstDifference(a[i], b[i], '$path[$i]');
      if (inner != null) {
        return inner;
      }
    }
    return null;
  }
  if (a.runtimeType != b.runtimeType || a != b) {
    return '$path is ${jsonEncode(a)} (${a.runtimeType}) in the wrapped copy '
        'and ${jsonEncode(b)} (${b.runtimeType}) in real_games.json';
  }
  return null;
}

void main() {
  // `flutter test` runs with the package root as the working directory.
  final File source = File('integration_test/fixtures/real_games.json');

  test('real_games.json is present where the wrapper reads it', () {
    expect(
      source.existsSync(),
      isTrue,
      reason:
          'expected ${source.absolute.path} to exist; run this test from '
          'packages/ludo_client',
    );
  });

  test('realGamesJson decodes to exactly what real_games.json decodes to', () {
    final Object? wrapped = jsonDecode(realGamesJson);
    final Object? recorded = jsonDecode(source.readAsStringSync());
    final String? difference = _firstDifference(wrapped, recorded, r'$');
    expect(
      difference,
      isNull,
      reason:
          'the wrapped fixture differs from the recorded one: $difference. '
          'Re-run the wrapper and commit its output: $_regenerate',
    );
  });

  test('realGamesJson is the bytes of real_games.json, unchanged', () {
    final String recorded = source.readAsStringSync();
    var at = -1;
    final int common = realGamesJson.length < recorded.length
        ? realGamesJson.length
        : recorded.length;
    for (var i = 0; i < common; i++) {
      if (realGamesJson.codeUnitAt(i) != recorded.codeUnitAt(i)) {
        at = i;
        break;
      }
    }
    if (at < 0 && realGamesJson.length != recorded.length) {
      at = common;
    }
    expect(
      at,
      -1,
      reason:
          'the wrapped text and real_games.json first differ at character '
          '$at (wrapped length ${realGamesJson.length}, file length '
          '${recorded.length}). Re-run the wrapper and commit its output: '
          '$_regenerate',
    );
  });

  test('the fixture names the two games the captures replay', () {
    final Map<String, Object?> decoded =
        jsonDecode(realGamesJson) as Map<String, Object?>;
    final List<Object?> games = decoded['games']! as List<Object?>;
    final List<String> names = <String>[
      for (final Object? game in games)
        (game! as Map<String, Object?>)['name']! as String,
    ];
    expect(
      names,
      containsAll(<String>['host_wins_1', 'guest_wins_1']),
      reason:
          'screenshots_test.dart replays host_wins_1 and guest_wins_1; the '
          'wrapped fixture holds $names. A re-record that renames games '
          'needs the captures moved with it.',
    );
  });
}
