// Source scans that keep lobby and game padding on named spacing tokens:
// theme.dart publishes the 4 / 8 / 12 / 16 / 20 / 24 / 32 scale, and
// EdgeInsets arguments in the lobby and game screens reference those names
// instead of literals.

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

String _themeSource() => _readLibSrc(p.join('src', 'theme.dart'));
String _lobbySource() => _readLibSrc(p.join('src', 'lobby_screen.dart'));
String _gameSource() => _readLibSrc(p.join('src', 'game_screen.dart'));

/// Names that count as spacing tokens. Rejects namespace / workspace hits.
bool _isSpaceTokenName(String name) {
  final String lower = name.toLowerCase();
  if (lower.contains('namespace') || lower.contains('workspace')) {
    return false;
  }
  return RegExp(r'k?space(?:ing)?', caseSensitive: false).hasMatch(name);
}

/// const (double|int)? name = number; including static class fields.
final RegExp _constNumberDecl = RegExp(
  r'(?:static\s+)?const\s+(?:double\s+|int\s+)?'
  r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+(?:\.\d+)?)',
);

Map<String, double> _spaceTokenValues(String src) {
  final Map<String, double> found = <String, double>{};
  for (final Match match in _constNumberDecl.allMatches(src)) {
    final String name = match.group(1)!;
    if (!_isSpaceTokenName(name)) {
      continue;
    }
    found[name] = double.parse(match.group(2)!);
  }
  return found;
}

/// Canonical kSpace1..kSpace7 values when those exact names exist.
const Map<String, double> _canonicalSpaceValues = <String, double>{
  'kSpace1': 4,
  'kSpace2': 8,
  'kSpace3': 12,
  'kSpace4': 16,
  'kSpace5': 20,
  'kSpace6': 24,
  'kSpace7': 32,
};

const List<double> _requiredSpaceScale = <double>[4, 8, 12, 16, 20, 24, 32];

class _EdgeInsetsCall {
  const _EdgeInsetsCall({
    required this.fileLabel,
    required this.constructor,
    required this.args,
    required this.line,
  });

  final String fileLabel;
  final String constructor;
  final String args;
  final int line;

  String get preview {
    final String compact = args.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 80
        ? '${compact.substring(0, 80)}…'
        : compact;
    return '$fileLabel:$line $constructor($clipped)';
  }
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

String? _balancedArgs(String src, int openParen) {
  int depth = 0;
  for (int i = openParen; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) {
        return src.substring(openParen + 1, i);
      }
    }
  }
  return null;
}

final RegExp _edgeInsetsCtor = RegExp(r'EdgeInsets(?:Directional)?\.\w+\s*\(');

List<_EdgeInsetsCall> _edgeInsetsCalls(String src, String fileLabel) {
  final List<_EdgeInsetsCall> calls = <_EdgeInsetsCall>[];
  for (final Match match in _edgeInsetsCtor.allMatches(src)) {
    final int open = src.indexOf('(', match.start);
    if (open < 0) {
      continue;
    }
    final String? args = _balancedArgs(src, open);
    if (args == null) {
      continue;
    }
    calls.add(
      _EdgeInsetsCall(
        fileLabel: fileLabel,
        constructor: match.group(0)!.trim().replaceAll(RegExp(r'\s*\($'), ''),
        args: args,
        line: _lineOf(src, match.start),
      ),
    );
  }
  return calls;
}

/// Bare 4 / 8 / 12 / 16 / 20 / 24 / 32 (optional .0) that are not part of
/// an identifier.
final RegExp _bareScaleLiteral = RegExp(
  r'(?<![A-Za-z0-9_])(4|8|12|16|20|24|32)(?:\.0+)?(?![A-Za-z0-9_.])',
);

List<String> _bareScaleHits(List<_EdgeInsetsCall> calls) {
  final List<String> hits = <String>[];
  for (final _EdgeInsetsCall call in calls) {
    for (final Match match in _bareScaleLiteral.allMatches(call.args)) {
      hits.add('${match.group(0)} in ${call.preview}');
    }
  }
  return hits;
}

bool _callsReferenceTokens(
  List<_EdgeInsetsCall> calls,
  Iterable<String> tokenNames,
) {
  if (calls.isEmpty || tokenNames.isEmpty) {
    return false;
  }
  for (final _EdgeInsetsCall call in calls) {
    for (final String name in tokenNames) {
      if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(call.args)) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  test('theme.dart defines spacing constants kSpace1=4 kSpace2=8 kSpace3=12 '
      'kSpace4=16 kSpace5=20 kSpace6=24 kSpace7=32', () {
    final Map<String, double> tokens = _spaceTokenValues(_themeSource());

    for (final MapEntry<String, double> required
        in _canonicalSpaceValues.entries) {
      if (tokens.containsKey(required.key)) {
        expect(
          tokens[required.key],
          required.value,
          reason:
              '${required.key} must equal ${required.value}, found '
              '${tokens[required.key]}',
        );
      }
    }

    expect(
      tokens,
      isNotEmpty,
      reason:
          'theme.dart must declare named spacing constants (kSpace1=4, '
          'kSpace2=8, kSpace3=12, kSpace4=16, kSpace5=20, kSpace6=24, '
          'kSpace7=32, or equivalent space* names)',
    );
    final Set<double> values = tokens.values.toSet();
    for (final double required in _requiredSpaceScale) {
      expect(
        values.contains(required),
        isTrue,
        reason:
            'theme.dart spacing tokens must include value $required; '
            'found $tokens',
      );
    }
  });

  test(
    'lobby_screen and game_screen EdgeInsets have zero bare 4/8/12/16/20/24/32',
    () {
      final Map<String, double> tokens = _spaceTokenValues(_themeSource());
      final Set<String> names = tokens.keys.toSet();

      final String lobby = _lobbySource();
      final String game = _gameSource();
      final List<_EdgeInsetsCall> lobbyCalls = _edgeInsetsCalls(
        lobby,
        'lobby_screen.dart',
      );
      final List<_EdgeInsetsCall> gameCalls = _edgeInsetsCalls(
        game,
        'game_screen.dart',
      );

      expect(
        lobbyCalls,
        isNotEmpty,
        reason: 'lobby_screen.dart must still declare EdgeInsets padding',
      );
      expect(
        gameCalls,
        isNotEmpty,
        reason: 'game_screen.dart must still declare EdgeInsets padding',
      );

      final List<String> bare = <String>[
        ..._bareScaleHits(lobbyCalls),
        ..._bareScaleHits(gameCalls),
      ];
      expect(
        bare,
        isEmpty,
        reason:
            'EdgeInsets arguments in lobby_screen.dart and game_screen.dart '
            'must not use bare 4/8/12/16/20/24/32; found ${bare.length}: '
            '${bare.join('; ')}',
      );

      expect(
        _callsReferenceTokens(lobbyCalls, names),
        isTrue,
        reason:
            'lobby_screen.dart EdgeInsets must reference theme.dart spacing '
            'constants; known tokens: ${names.join(', ')}',
      );
      expect(
        _callsReferenceTokens(gameCalls, names),
        isTrue,
        reason:
            'game_screen.dart EdgeInsets must reference theme.dart spacing '
            'constants; known tokens: ${names.join(', ')}',
      );
    },
  );
}
