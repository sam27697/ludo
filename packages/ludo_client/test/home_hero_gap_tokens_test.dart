// Home screen hero-to-form gaps (afterBrand, afterDie, sectionGap) must
// assign named kSpace* tokens (kSpace1=4 .. kSpace7=32) instead of bare
// 12/14/16/28/32. Off-scale 14 maps to kSpace3 or kSpace4; off-scale 28
// maps to kSpace6 or kSpace7.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:path/path.dart' as p;

const List<String> _gapVars = <String>['afterBrand', 'afterDie', 'sectionGap'];

final RegExp _kSpaceToken = RegExp(r'^kSpace[1-7]$');

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

String _homeScreenSource() {
  final File file = File(
    p.join(_findPackageRoot().path, 'lib', 'src', 'home_screen.dart'),
  );
  expect(file.existsSync(), isTrue, reason: 'home_screen.dart must exist');
  return file.readAsStringSync();
}

String _stripComments(String src) {
  final String withoutBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return withoutBlock.replaceAll(RegExp(r'//[^\n]*'), '');
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

String? _rhsUntilSemicolon(String src, int equalsAt) {
  int depth = 0;
  for (int i = equalsAt + 1; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    } else if (ch == ';' && depth == 0) {
      return src.substring(equalsAt + 1, i);
    }
  }
  return null;
}

class _GapAssign {
  const _GapAssign({required this.name, required this.rhs, required this.line});

  final String name;
  final String rhs;
  final int line;

  String get preview {
    final String compact = rhs.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 80
        ? '${compact.substring(0, 80)}…'
        : compact;
    return 'home_screen.dart:$line $name = $clipped';
  }
}

List<_GapAssign> _gapAssignments(String src) {
  final String stripped = _stripComments(src);
  final List<_GapAssign> out = <_GapAssign>[];
  for (final String name in _gapVars) {
    final RegExp assign = RegExp('\\b$name\\s*=(?!=)');
    for (final Match match in assign.allMatches(stripped)) {
      final int eq = stripped.indexOf('=', match.start);
      final String? rhs = _rhsUntilSemicolon(stripped, eq);
      if (rhs == null) {
        continue;
      }
      out.add(
        _GapAssign(name: name, rhs: rhs, line: _lineOf(stripped, match.start)),
      );
    }
  }
  return out;
}

String _normalizedRhs(String rhs) {
  return rhs.replaceAll(RegExp(r'[\s()]'), '');
}

bool _isAllowedCompactTernary(
  String normalized, {
  required Set<String> compactTokens,
  required Set<String> tallTokens,
}) {
  final List<String> parts = normalized.split('?');
  if (parts.length != 2 || parts[0] != 'compact') {
    return false;
  }
  final List<String> branches = parts[1].split(':');
  if (branches.length != 2) {
    return false;
  }
  return compactTokens.contains(branches[0]) &&
      _kSpaceToken.hasMatch(branches[0]) &&
      tallTokens.contains(branches[1]) &&
      _kSpaceToken.hasMatch(branches[1]);
}

Widget _homeApp() {
  return MaterialApp(
    theme: buildAppTheme(),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: HomeScreen(
            onToggleLocale: () {},
            controllerFactory: () {
              return RoomController(
                serverUrl: Uri.parse('wss://home-hero-gap-test.invalid/ws'),
                connect: (Uri url) async {
                  throw StateError(
                    'home_hero_gap_tokens_test: connector must not open '
                    'a transport',
                  );
                },
              );
            },
          ),
        );
      },
    ),
  );
}

Future<void> _pumpHome(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_homeApp());
  await tester.pump();
}

void _expectGapIn(double gap, Set<double> allowed, String label) {
  expect(
    allowed.contains(gap),
    isTrue,
    reason: '$label must be one of ${allowed.join(' | ')}, found $gap',
  );
}

double _heroBottom(WidgetTester tester, AppLocalizations loc) {
  final double dieBottom = tester.getRect(find.byType(DieMark)).bottom;
  final double titleBottom = tester.getRect(find.text(loc.appTitle)).bottom;
  final double taglineBottom = tester
      .getRect(find.text(loc.homeTagline))
      .bottom;
  return math.max(dieBottom, math.max(titleBottom, taglineBottom));
}

void main() {
  test('home afterBrand/afterDie/sectionGap assignments use kSpace* with no '
      'bare 12/14/16/28/32', () {
    expect(kSpace1, 4);
    expect(kSpace2, 8);
    expect(kSpace3, 12);
    expect(kSpace4, 16);
    expect(kSpace5, 20);
    expect(kSpace6, 24);
    expect(kSpace7, 32);

    final String src = _homeScreenSource();
    final List<_GapAssign> assigns = _gapAssignments(src);
    expect(
      assigns.map((_GapAssign a) => a.name).toSet(),
      _gapVars.toSet(),
      reason:
          'home_screen.dart must still assign afterBrand, afterDie, and '
          'sectionGap so those hero gaps stay named',
    );

    final List<String> problems = <String>[];
    final Map<String, Set<String>> compactTokens = <String, Set<String>>{
      'afterBrand': <String>{'kSpace3'},
      'afterDie': <String>{'kSpace4'},
      'sectionGap': <String>{'kSpace3', 'kSpace4'},
    };
    final Map<String, Set<String>> tallTokens = <String, Set<String>>{
      'afterBrand': <String>{'kSpace6', 'kSpace7'},
      'afterDie': <String>{'kSpace7'},
      'sectionGap': <String>{'kSpace6', 'kSpace7'},
    };

    for (final _GapAssign assign in assigns) {
      final String normalized = _normalizedRhs(assign.rhs);
      if (!_isAllowedCompactTernary(
        normalized,
        compactTokens: compactTokens[assign.name]!,
        tallTokens: tallTokens[assign.name]!,
      )) {
        problems.add(
          '${assign.preview} must be compact ? '
          '${compactTokens[assign.name]!.join('|')} : '
          '${tallTokens[assign.name]!.join('|')} with no bare '
          '12/14/16/28/32; normalized "$normalized"',
        );
      }
    }

    for (final String name in _gapVars) {
      final RegExp used = RegExp(
        'SizedBox\\s*\\(\\s*height:\\s*$name\\s*,?\\s*\\)',
      );
      if (!used.hasMatch(src)) {
        problems.add(
          'home_screen.dart must still pass $name into '
          'SizedBox(height: $name)',
        );
      }
    }

    expect(
      problems,
      isEmpty,
      reason:
          'afterBrand/afterDie/sectionGap must use only kSpace* '
          '(14→kSpace3|kSpace4, 28→kSpace6|kSpace7); '
          'found ${problems.length}: ${problems.join('; ')}',
    );
  });

  testWidgets(
    'tall home tagline-to-die gap is kSpace6 or kSpace7, die-to-name is '
    'kSpace7, create-to-code is kSpace6 or kSpace7',
    (WidgetTester tester) async {
      await _pumpHome(tester, size: const Size(390, 844));

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(HomeScreen)),
      );
      final Rect tagline = tester.getRect(find.text(loc.homeTagline));
      final Rect die = tester.getRect(find.byType(DieMark));
      final Rect name = tester.getRect(
        find.byKey(const Key('home-name-field')),
      );
      final Rect create = tester.getRect(
        find.byKey(const Key('create-room-button')),
      );
      final Rect code = tester.getRect(
        find.byKey(const Key('room-code-field')),
      );

      _expectGapIn(die.top - tagline.bottom, <double>{
        kSpace6,
        kSpace7,
      }, 'tall HomeScreen tagline-to-die gap (afterBrand)');
      _expectGapIn(name.top - _heroBottom(tester, loc), <double>{
        kSpace7,
      }, 'tall HomeScreen die-to-name gap (afterDie)');
      _expectGapIn(code.top - create.bottom, <double>{
        kSpace6,
        kSpace7,
      }, 'tall HomeScreen create-to-code gap (sectionGap)');
    },
  );

  testWidgets(
    'compact home hero-to-name gap is kSpace4 and create-to-code gap is '
    'kSpace3 or kSpace4',
    (WidgetTester tester) async {
      await _pumpHome(tester, size: const Size(390, 600));

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(HomeScreen)),
      );
      final Rect name = tester.getRect(
        find.byKey(const Key('home-name-field')),
      );
      final Rect create = tester.getRect(
        find.byKey(const Key('create-room-button')),
      );
      final Rect code = tester.getRect(
        find.byKey(const Key('room-code-field')),
      );

      _expectGapIn(name.top - _heroBottom(tester, loc), <double>{
        kSpace4,
      }, 'compact HomeScreen hero-to-name gap (afterDie)');
      _expectGapIn(code.top - create.bottom, <double>{
        kSpace3,
        kSpace4,
      }, 'compact HomeScreen create-to-code gap (sectionGap)');
    },
  );
}
