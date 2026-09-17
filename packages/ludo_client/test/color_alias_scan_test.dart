// Source scans that keep board and theme colours on one named paintbox:
// seat fills come from LudoColors.seats, raw Color(0x…) stays out of the
// board painter, Material greys and the warm-cream board fill are gone, and
// the lib-wide distinct-hex ratchet does not rise.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final File pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((String line) => line.trim() == 'name: ludo_client');
  }

  final Directory cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }

  final Directory nested = Directory(
    p.join(cwd.path, 'packages', 'ludo_client'),
  );
  if (isLudoClient(nested)) {
    return nested;
  }

  Directory walker = cwd;
  for (int i = 0; i < 8; i++) {
    final Directory parent = walker.parent;
    if (parent.path == walker.path) {
      break;
    }
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }

  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

String _readLibSrc(String relative) {
  final File file = File(p.join(_findPackageRoot().path, 'lib', relative));
  expect(file.existsSync(), isTrue, reason: '$relative must exist');
  return file.readAsStringSync();
}

String _boardSource() => _readLibSrc(p.join('src', 'board.dart'));
String _themeSource() => _readLibSrc(p.join('src', 'theme.dart'));

final RegExp _colorHexLiteral = RegExp(r'Color\(0x[0-9A-Fa-f]+\)');
final RegExp _hex8 = RegExp(r'0x[0-9A-Fa-f]{8}');

/// Color(0x…) occurrences that sit inside a named token declaration block
/// (`LudoColors`, `LudoColorsDark`, or a similarly named `*Colors` abstract
/// final class). Everything else in theme.dart must use those names.
List<Match> _themeColorLiteralsOutsideTokenBlocks(String src) {
  final List<Match> all = _colorHexLiteral.allMatches(src).toList();
  final List<({int start, int end})> blocks = <({int start, int end})>[];

  final RegExp classRe = RegExp(
    r'(?:abstract\s+)?(?:final\s+)?class\s+(\w*Colors\w*)\b',
  );
  for (final Match classMatch in classRe.allMatches(src)) {
    final int classStart = classMatch.start;
    final int brace = src.indexOf('{', classMatch.end);
    if (brace < 0) {
      continue;
    }
    int depth = 0;
    int end = brace;
    for (int i = brace; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    blocks.add((start: classStart, end: end));
  }

  bool insideBlock(int offset) {
    for (final ({int start, int end}) block in blocks) {
      if (offset >= block.start && offset < block.end) {
        return true;
      }
    }
    return false;
  }

  return all.where((Match m) => !insideBlock(m.start)).toList();
}

Set<String> _distinctHexInLib() {
  final Directory lib = Directory(p.join(_findPackageRoot().path, 'lib'));
  final Set<String> hexes = <String>{};
  for (final File file in lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .where(
        (File f) => !f.path.contains('${p.separator}l10n${p.separator}gen'),
      )) {
    for (final Match m in _hex8.allMatches(file.readAsStringSync())) {
      hexes.add(m.group(0)!.toUpperCase());
    }
  }
  return hexes;
}

void main() {
  test('board.dart seat fills use LudoColors.seats, not a private hex list', () {
    final String src = _boardSource();
    expect(
      RegExp(r'\bLudoColors\.seats\b').hasMatch(src),
      isTrue,
      reason: 'board.dart must paint seat fills from LudoColors.seats',
    );
    expect(
      RegExp(r'\b_seatColors\b').hasMatch(src),
      isFalse,
      reason: 'board.dart must not keep a private duplicate seat colour list',
    );
    expect(
      RegExp(
        r'Color\(0xFFD32F2F\)|Color\(0xFF388E3C\)|'
        r'Color\(0xFFFBC02D\)|Color\(0xFF1976D2\)',
      ).hasMatch(src),
      isFalse,
      reason: 'board.dart must not restate the seat palette as raw hex',
    );
  });

  test(
    'board.dart has zero Color(0x) literals; theme.dart keeps them in token blocks',
    () {
      final String board = _boardSource();
      final List<Match> boardLiterals = _colorHexLiteral.allMatches(board).toList();
      expect(
        boardLiterals,
        isEmpty,
        reason:
            'board.dart must have zero Color(0x…) literals; found '
            '${boardLiterals.length}: '
            '${boardLiterals.map((Match m) => m.group(0)).join(', ')}',
      );

      final String theme = _themeSource();
      final List<Match> outside = _themeColorLiteralsOutsideTokenBlocks(theme);
      expect(
        outside,
        isEmpty,
        reason:
            'theme.dart Color(0x…) literals may appear only inside LudoColors / '
            'named token declaration blocks; found outside: '
            '${outside.map((Match m) => m.group(0)).join(', ')}',
      );
    },
  );

  test('Material chrome greys are absent from board.dart and theme.dart', () {
    const List<String> greys = <String>[
      '0xFF9E9E9E',
      '0xFFBDBDBD',
      '0xFF424242',
    ];
    final String board = _boardSource().toUpperCase();
    final String theme = _themeSource().toUpperCase();
    for (final String grey in greys) {
      final String needle = grey.toUpperCase();
      expect(
        board.contains(needle),
        isFalse,
        reason: 'board.dart must not contain Material grey $grey',
      );
      expect(
        theme.contains(needle),
        isFalse,
        reason: 'theme.dart must not contain Material grey $grey',
      );
    }
  });

  test('board fill and grid inks use named tokens; warm-cream fill is gone', () {
    final String board = _boardSource();
    expect(
      RegExp(r'0xFFF7F3E9', caseSensitive: false).hasMatch(board),
      isFalse,
      reason:
          'warm-cream board fill 0xFFF7F3E9 must be removed or aliased to a '
          'named token outside board.dart',
    );
    expect(
      RegExp(r'\bLudoColors\.\w+\b').hasMatch(board),
      isTrue,
      reason: 'board fill/grid inks must reference named LudoColors tokens',
    );
  });

  test(
    'distinct hex colours in lib ≤ 22 and board.dart hex count is zero',
    () {
      final String board = _boardSource();
      final List<Match> boardHex = _hex8.allMatches(board).toList();
      expect(
        boardHex,
        isEmpty,
        reason:
            'board.dart hex count must move 10→0; found ${boardHex.length}: '
            '${boardHex.map((Match m) => m.group(0)).join(', ')}',
      );

      final Set<String> distinct = _distinctHexInLib();
      expect(
        distinct.length,
        lessThanOrEqualTo(22),
        reason:
            'distinct_hex_colors in packages/ludo_client/lib must stay ≤ 22 '
            '(ratchet); found ${distinct.length}: '
            '${(distinct.toList()..sort()).join(', ')}',
      );
    },
  );
}
