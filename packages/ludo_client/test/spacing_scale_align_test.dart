// Spacing scale alignment: theme.dart must publish kSpace1..kSpace7 as
// 4 / 8 / 12 / 16 / 20 / 24 / 32, and SeatPipStrip padding must use those
// names instead of bare 8 / 16.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_mark.dart';
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

String _readLibSrc(String relative) {
  final File file = File(p.join(_findPackageRoot().path, 'lib', relative));
  expect(file.existsSync(), isTrue, reason: '$relative must exist');
  return file.readAsStringSync();
}

String _themeSource() => _readLibSrc(p.join('src', 'theme.dart'));
String _dieMarkSource() => _readLibSrc(p.join('src', 'die_mark.dart'));

final RegExp _constNumberDecl = RegExp(
  r'(?:static\s+)?const\s+(?:double\s+|int\s+)?'
  r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+(?:\.\d+)?)',
);

Map<String, double> _kSpaceValues(String src) {
  final Map<String, double> found = <String, double>{};
  for (final Match match in _constNumberDecl.allMatches(src)) {
    final String name = match.group(1)!;
    if (!RegExp(r'^kSpace\d+$').hasMatch(name)) {
      continue;
    }
    found[name] = double.parse(match.group(2)!);
  }
  return found;
}

/// Full 4 / 8 scale published as kSpace1..kSpace7.
const Map<String, double> _requiredKSpace = <String, double>{
  'kSpace1': 4,
  'kSpace2': 8,
  'kSpace3': 12,
  'kSpace4': 16,
  'kSpace5': 20,
  'kSpace6': 24,
  'kSpace7': 32,
};

String _classBody(String src, String className) {
  final Match? classMatch = RegExp('class\\s+$className\\b').firstMatch(src);
  expect(classMatch, isNotNull, reason: 'class $className must exist');
  final int brace = src.indexOf('{', classMatch!.end);
  expect(brace, greaterThan(0), reason: '$className must have a body');
  int depth = 0;
  for (int i = brace; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return src.substring(brace + 1, i);
      }
    }
  }
  fail('could not find the end of class $className');
}

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

class _EdgeInsetsCall {
  const _EdgeInsetsCall({
    required this.constructor,
    required this.args,
    required this.line,
  });

  final String constructor;
  final String args;
  final int line;

  String get preview {
    final String compact = args.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 80
        ? '${compact.substring(0, 80)}…'
        : compact;
    return 'SeatPipStrip:$line $constructor($clipped)';
  }
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

List<_EdgeInsetsCall> _edgeInsetsCalls(String src) {
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
        constructor: match.group(0)!.trim().replaceAll(RegExp(r'\s*\($'), ''),
        args: args,
        line: _lineOf(src, match.start),
      ),
    );
  }
  return calls;
}

/// Bare 8 / 16 (optional .0) that are not part of an identifier.
final RegExp _bareEightOrSixteen = RegExp(
  r'(?<![A-Za-z0-9_])(8|16)(?:\.0+)?(?![A-Za-z0-9_.])',
);

void main() {
  test('theme.dart defines kSpace1=4 kSpace2=8 kSpace3=12 kSpace4=16 '
      'kSpace5=20 kSpace6=24 kSpace7=32', () {
    final Map<String, double> tokens = _kSpaceValues(_themeSource());
    final List<String> problems = <String>[];
    for (final MapEntry<String, double> required in _requiredKSpace.entries) {
      if (!tokens.containsKey(required.key)) {
        problems.add('${required.key} missing');
      } else if (tokens[required.key] != required.value) {
        problems.add(
          '${required.key}=${tokens[required.key]} '
          '(want ${required.value})',
        );
      }
    }
    expect(
      problems,
      isEmpty,
      reason:
          'theme.dart must define kSpace1=4, kSpace2=8, kSpace3=12, '
          'kSpace4=16, kSpace5=20, kSpace6=24, kSpace7=32; '
          'found $tokens; ${problems.join('; ')}',
    );

    expect(kSpace1, 4);
    expect(kSpace2, 8);
    expect(kSpace3, 12, reason: 'kSpace3 must equal 12, found $kSpace3');
    expect(kSpace4, 16, reason: 'kSpace4 must equal 16, found $kSpace4');
  });

  testWidgets(
    'theme kSpace1=4 kSpace2=8 kSpace3=12 kSpace4=16 resolve in layout',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: <Widget>[
              SizedBox(key: Key('space-1'), height: kSpace1),
              SizedBox(key: Key('space-2'), height: kSpace2),
              SizedBox(key: Key('space-3'), height: kSpace3),
              SizedBox(key: Key('space-4'), height: kSpace4),
            ],
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('space-1'))).height, 4);
      expect(tester.getSize(find.byKey(const Key('space-2'))).height, 8);
      expect(
        tester.getSize(find.byKey(const Key('space-3'))).height,
        12,
        reason:
            'kSpace3 layout height must be 12, found '
            '${tester.getSize(find.byKey(const Key('space-3'))).height}',
      );
      expect(
        tester.getSize(find.byKey(const Key('space-4'))).height,
        16,
        reason:
            'kSpace4 layout height must be 16, found '
            '${tester.getSize(find.byKey(const Key('space-4'))).height}',
      );
    },
  );

  test('SeatPipStrip EdgeInsets use kSpace tokens with zero bare 8/16', () {
    final String body = _classBody(_dieMarkSource(), 'SeatPipStrip');
    final List<_EdgeInsetsCall> calls = _edgeInsetsCalls(body);
    expect(
      calls,
      isNotEmpty,
      reason: 'SeatPipStrip must declare EdgeInsets padding',
    );

    final List<String> bare = <String>[];
    final List<String> missingToken = <String>[];
    for (final _EdgeInsetsCall call in calls) {
      for (final Match match in _bareEightOrSixteen.allMatches(call.args)) {
        bare.add('${match.group(0)} in ${call.preview}');
      }
      if (!RegExp(r'\bkSpace\d+\b').hasMatch(call.args)) {
        missingToken.add(call.preview);
      }
    }
    expect(
      bare,
      isEmpty,
      reason:
          'SeatPipStrip EdgeInsets must not use bare 8/16; found '
          '${bare.length}: ${bare.join('; ')}',
    );
    expect(
      missingToken,
      isEmpty,
      reason:
          'SeatPipStrip EdgeInsets must reference kSpace* tokens; '
          'calls without a token: ${missingToken.join('; ')}',
    );
  });

  testWidgets(
    'SeatPipStrip padding geometry is kSpace4 horizontal and kSpace2 vertical',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(alignment: Alignment.topCenter, child: SeatPipStrip()),
        ),
      );

      final Finder strip = find.byType(SeatPipStrip);
      expect(strip, findsOneWidget);

      final List<Padding> directPadding = <Padding>[];
      tester.element(strip).visitChildren((Element child) {
        if (child.widget is Padding) {
          directPadding.add(child.widget as Padding);
        }
      });
      expect(
        directPadding,
        hasLength(1),
        reason: 'SeatPipStrip must wrap its pips in one Padding',
      );
      final Padding padding = directPadding.single;
      final EdgeInsets resolved = padding.padding.resolve(TextDirection.ltr);
      expect(
        resolved.left,
        kSpace4,
        reason:
            'SeatPipStrip start padding must be kSpace4 ($kSpace4), '
            'found ${resolved.left}',
      );
      expect(
        resolved.right,
        kSpace4,
        reason:
            'SeatPipStrip end padding must be kSpace4 ($kSpace4), '
            'found ${resolved.right}',
      );
      expect(
        resolved.top,
        kSpace2,
        reason:
            'SeatPipStrip top padding must be kSpace2 ($kSpace2), '
            'found ${resolved.top}',
      );
      expect(
        resolved.bottom,
        kSpace2,
        reason:
            'SeatPipStrip bottom padding must be kSpace2 ($kSpace2), '
            'found ${resolved.bottom}',
      );

      final Finder paddingFinder = find.byWidget(padding);
      final Rect padRect = tester.getRect(paddingFinder);
      final Rect rowRect = tester.getRect(
        find.descendant(of: strip, matching: find.byType(Row)),
      );
      expect(
        rowRect.left - padRect.left,
        kSpace4,
        reason:
            'SeatPipStrip start padding must equal kSpace4 ($kSpace4), '
            'found ${rowRect.left - padRect.left}',
      );
      expect(
        padRect.right - rowRect.right,
        kSpace4,
        reason:
            'SeatPipStrip end padding must equal kSpace4 ($kSpace4), '
            'found ${padRect.right - rowRect.right}',
      );
      expect(
        rowRect.top - padRect.top,
        kSpace2,
        reason:
            'SeatPipStrip top padding must equal kSpace2 ($kSpace2), '
            'found ${rowRect.top - padRect.top}',
      );
      expect(
        padRect.bottom - rowRect.bottom,
        kSpace2,
        reason:
            'SeatPipStrip bottom padding must equal kSpace2 ($kSpace2), '
            'found ${padRect.bottom - rowRect.bottom}',
      );
    },
  );
}
