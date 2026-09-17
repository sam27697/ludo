// Theme token foundation: ThemeExtension brand fields, radius roles, type
// tokens, and a dark colour factory with AA contrast on sample pairs.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/theme.dart';
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

String _themeSource() {
  final File file = File(
    p.join(_findPackageRoot().path, 'lib', 'src', 'theme.dart'),
  );
  expect(file.existsSync(), isTrue, reason: 'theme.dart must exist');
  return file.readAsStringSync();
}

List<File> _libDartFiles() {
  final Directory lib = Directory(p.join(_findPackageRoot().path, 'lib'));
  return lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .where((File f) => !f.path.contains('${p.separator}l10n${p.separator}gen'))
      .toList();
}

double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrastRatio(Color a, Color b) {
  final double lumA = _relativeLuminance(a);
  final double lumB = _relativeLuminance(b);
  final double lighter = lumA > lumB ? lumA : lumB;
  final double darker = lumA > lumB ? lumB : lumA;
  return (lighter + 0.05) / (darker + 0.05);
}

Color? _parseColorLiteral(String expression) {
  final Match? hex = RegExp(
    r'Color\(0x([0-9A-Fa-f]{8})\)',
  ).firstMatch(expression);
  if (hex != null) {
    return Color(int.parse(hex.group(1)!, radix: 16));
  }
  return null;
}

/// Pulls ink / paper / action Color(...) literals from a dark factory block.
Map<String, Color> _darkRoleColors(String src) {
  final Map<String, Color> found = <String, Color>{};
  final RegExp blockStart = RegExp(
    r'(?:abstract\s+)?(?:final\s+)?class\s+LudoColorsDark\b|'
    r'(?:ColorScheme\s+)?buildDarkColorScheme\s*\(',
  );
  final Match? start = blockStart.firstMatch(src);
  if (start == null) {
    return found;
  }

  final String region = src.substring(start.start);
  for (final String role in <String>['ink', 'paper', 'action']) {
    final Match? roleMatch = RegExp(
      '$role\\s*[=:]\\s*([^,\\n;]+)',
    ).firstMatch(region);
    if (roleMatch == null) {
      continue;
    }
    final Color? color = _parseColorLiteral(roleMatch.group(1)!);
    if (color != null) {
      found[role] = color;
    }
  }
  return found;
}

bool _themeExtensionDeclaresBrandMotion(String src) {
  final RegExp classRe = RegExp(
    r'class\s+(\w+)\s+extends\s+ThemeExtension\s*<\s*\1\s*>',
  );
  final Match? classMatch = classRe.firstMatch(src);
  if (classMatch == null) {
    return false;
  }

  final int classStart = classMatch.start;
  final int nextClass = src.indexOf(RegExp(r'\nclass\s+'), classStart + 1);
  final String body =
      nextClass < 0 ? src.substring(classStart) : src.substring(classStart, nextClass);

  const List<String> required = <String>[
    'action',
    'ink',
    'paper',
    'felt',
    'motionShort',
    'motionLong',
  ];
  for (final String name in required) {
    if (!RegExp('\\b$name\\b').hasMatch(body)) {
      return false;
    }
  }
  return true;
}

bool _radiiAcceptable(String src) {
  final List<String> args = RegExp(r'BorderRadius\.circular\(([^)]+)\)')
      .allMatches(src)
      .map((Match m) => m.group(1)!.trim())
      .toList();
  if (args.isEmpty) {
    return false;
  }

  final bool onlyTwelve = args.every(
    (String a) => a == '12' || a == '12.0',
  );
  if (onlyTwelve) {
    return true;
  }

  final bool hasTen = args.any((String a) => a == '10' || a == '10.0');
  if (hasTen) {
    return false;
  }

  final Set<String> named = args
      .where((String a) => !RegExp(r'^\d').hasMatch(a))
      .toSet();
  final Set<String> numeric = args
      .where((String a) => RegExp(r'^\d').hasMatch(a))
      .toSet();
  return numeric.isEmpty && named.isNotEmpty && named.length <= 2;
}

Set<String> _fontSizeLiteralsIn(String src) {
  return RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)')
      .allMatches(src)
      .map((Match m) => m.group(1)!)
      .toSet();
}

bool _themeFontSizesAreNamedTokens(String src) {
  final Iterable<Match> matches = RegExp(r'fontSize:\s*([^\n,]+)').allMatches(src);
  if (matches.isEmpty) {
    return false;
  }
  for (final Match m in matches) {
    final String value = m.group(1)!.trim();
    if (RegExp(r'^\d').hasMatch(value)) {
      return false;
    }
  }
  return true;
}

void main() {
  test('theme.dart ThemeExtension declares brand colours and motion', () {
    final String src = _themeSource();
    expect(
      _themeExtensionDeclaresBrandMotion(src),
      isTrue,
      reason:
          'theme.dart must declare a ThemeExtension with action, ink, paper, '
          'felt, motionShort, and motionLong',
    );
  });

  testWidgets('Theme.of carries the brand ThemeExtension', (tester) async {
    late ThemeData readTheme;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (BuildContext context) {
            readTheme = Theme.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(
      readTheme.extensions.isNotEmpty,
      isTrue,
      reason: 'buildAppTheme must register a ThemeExtension on ThemeData',
    );
    expect(
      _themeExtensionDeclaresBrandMotion(_themeSource()),
      isTrue,
      reason: 'registered extension must expose brand and motion fields',
    );
  });

  test('theme.dart uses one radius 12 or two named roles without 10', () {
    expect(
      _radiiAcceptable(_themeSource()),
      isTrue,
      reason:
          'theme.dart must use only BorderRadius.circular(12), or at most two '
          'named radius roles with circular(10) removed',
    );
  });

  test('theme.dart fontSizes are named type-token constants', () {
    final String src = _themeSource();
    expect(
      _themeFontSizesAreNamedTokens(src),
      isTrue,
      reason:
          'every fontSize in theme.dart must reference a named type-token '
          'constant, not a numeric literal',
    );

    final Set<String> libLiterals = <String>{};
    for (final File file in _libDartFiles()) {
      libLiterals.addAll(_fontSizeLiteralsIn(file.readAsStringSync()));
    }
    if (libLiterals.length > 2) {
      fail(
        'distinct fontSize literals in lib rose to ${libLiterals.length} '
        '(${libLiterals.join(', ')}); record a B1 trade-off naming the gain',
      );
    }
  });

  test('dark colour factory exists with AA sample pairs', () {
    final String src = _themeSource();
    final bool hasFactory =
        RegExp(r'\bLudoColorsDark\b').hasMatch(src) ||
        RegExp(r'\bbuildDarkColorScheme\s*\(').hasMatch(src);
    expect(
      hasFactory,
      isTrue,
      reason:
          'theme.dart must declare LudoColorsDark or buildDarkColorScheme() '
          'with dark ink/paper/action',
    );

    final Map<String, Color> roles = _darkRoleColors(src);
    expect(
      roles.keys,
      containsAll(<String>['ink', 'paper', 'action']),
      reason: 'dark factory must define ink, paper, and action colours',
    );

    final double inkOnPaper = _contrastRatio(roles['ink']!, roles['paper']!);
    final double actionOnPaper =
        _contrastRatio(roles['action']!, roles['paper']!);
    expect(
      inkOnPaper,
      greaterThanOrEqualTo(4.5),
      reason: 'dark ink on paper contrast was $inkOnPaper',
    );
    expect(
      actionOnPaper,
      greaterThanOrEqualTo(4.5),
      reason: 'dark action on paper contrast was $actionOnPaper',
    );
  });
}
