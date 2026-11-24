// C-704t: the fair source seam must be dead in a release build. A widget
// test cannot build release mode, so this reads lib/src/game_screen.dart as
// text and checks one rule: every use of `debugFairSourceOverride` sits
// inside an `assert(() { ... return true; }())` block, which the compiler
// drops from a release build. A shipped app can then never be told a game
// is fair by a variable.
//
// What counts as a use: every occurrence outside comments and outside the
// `import ... show ...;` directive that names the symbol. A block is found by
// its `assert(() {` opener and closed by matching braces; the blocks in
// game_screen.dart hold no braces inside string literals around the seam.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _seam = 'debugFairSourceOverride';

/// Offsets of uses of [_seam] in [source] that are not inside an assert
/// block, comment or import directive.
List<int> usesOutsideAssert(String source) {
  final List<(int, int)> blocks = <(int, int)>[];
  final RegExp opener = RegExp(r'assert\(\s*\(\)\s*\{');
  for (final RegExpMatch m in opener.allMatches(source)) {
    int depth = 1;
    int i = m.end;
    while (i < source.length && depth > 0) {
      final String c = source[i];
      if (c == '{') {
        depth += 1;
      } else if (c == '}') {
        depth -= 1;
      }
      i += 1;
    }
    blocks.add((m.start, i));
  }

  final List<(int, int)> skipped = <(int, int)>[];
  for (final RegExpMatch m in RegExp(
    r'^\s*//.*$',
    multiLine: true,
  ).allMatches(source)) {
    skipped.add((m.start, m.end));
  }
  for (final RegExpMatch m in RegExp(
    r'^\s*import\b[^;]*;',
    multiLine: true,
  ).allMatches(source)) {
    skipped.add((m.start, m.end));
  }

  final List<int> bad = <int>[];
  int from = 0;
  while (true) {
    final int at = source.indexOf(_seam, from);
    if (at == -1) {
      break;
    }
    from = at + _seam.length;
    final bool inSkipped = skipped.any(
      ((int, int) r) => at >= r.$1 && at < r.$2,
    );
    if (inSkipped) {
      continue;
    }
    final bool inAssert = blocks.any(((int, int) r) => at >= r.$1 && at < r.$2);
    if (!inAssert) {
      bad.add(at);
    }
  }
  return bad;
}

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

void main() {
  group('the checker itself', () {
    test('flags a bare read and accepts one inside assert(() { ... })', () {
      const String bare = 'void f() { final s = debugFairSourceOverride; }';
      const String guarded =
          'void f() { assert(() { final s = debugFairSourceOverride; '
          'if (s != null) { s(); } return true; }()); }';
      const String mixed =
          'void f() { assert(() { final a = debugFairSourceOverride; '
          'return true; }()); final b = debugFairSourceOverride; }';
      const String commented = '// debugFairSourceOverride\nvoid f() {}';
      const String imported =
          "import 'x.dart' show A, debugFairSourceOverride, B;\nvoid f() {}";
      expect(usesOutsideAssert(bare), hasLength(1));
      expect(usesOutsideAssert(guarded), isEmpty);
      expect(usesOutsideAssert(mixed), hasLength(1));
      expect(usesOutsideAssert(commented), isEmpty);
      expect(usesOutsideAssert(imported), isEmpty);
    });
  });

  group('release safety of debugFairSourceOverride', () {
    final String path = 'lib/src/game_screen.dart';

    test('game_screen.dart reads the seam, and only inside an assert block', () {
      final String source = File(path).readAsStringSync();
      expect(
        source.contains(_seam),
        isTrue,
        reason:
            '$path no longer mentions $_seam; the seam test has nothing to guard',
      );
      final List<int> bad = usesOutsideAssert(source);
      expect(
        bad.map((int at) => _lineOf(source, at)).toList(),
        isEmpty,
        reason:
            'every use of $_seam in $path must sit inside assert(() { ... '
            'return true; }()) so a release build never reads it; uses '
            'outside one are at these lines',
      );
    });

    test('no other file under lib/ reads the seam but its definition', () {
      final List<String> readers = <String>[];
      for (final FileSystemEntity e in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) {
          continue;
        }
        if (e.path.endsWith('lib/src/fair_check.dart') ||
            e.path.endsWith('lib/src/game_screen.dart')) {
          continue;
        }
        if (e.readAsStringSync().contains(_seam)) {
          readers.add(e.path);
        }
      }
      expect(
        readers,
        isEmpty,
        reason:
            '$_seam is defined in fair_check.dart and read in game_screen.dart '
            'only; these files also mention it',
      );
    });
  });
}
