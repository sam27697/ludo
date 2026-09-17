// Home screen scroll padding must use named spacing tokens from theme.dart
// (kSpace1=4, kSpace2=8, kSpace5=20, kSpace6=24, kSpace7=32) instead of
// bare 4 / 8 / 20 / 24 / 32 in EdgeInsets.fromLTRB.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
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

String _homeScreenSource() {
  final File file = File(
    p.join(_findPackageRoot().path, 'lib', 'src', 'home_screen.dart'),
  );
  expect(file.existsSync(), isTrue, reason: 'home_screen.dart must exist');
  return file.readAsStringSync();
}

class _FromLtrbCall {
  const _FromLtrbCall({required this.args, required this.line});

  final String args;
  final int line;

  String get preview {
    final String compact = args.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 100
        ? '${compact.substring(0, 100)}…'
        : compact;
    return 'home_screen.dart:$line EdgeInsets.fromLTRB($clipped)';
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

final RegExp _fromLtrbCtor = RegExp(r'EdgeInsets\.fromLTRB\s*\(');

List<_FromLtrbCall> _fromLtrbCalls(String src) {
  final List<_FromLtrbCall> calls = <_FromLtrbCall>[];
  for (final Match match in _fromLtrbCtor.allMatches(src)) {
    final int open = src.indexOf('(', match.start);
    if (open < 0) {
      continue;
    }
    final String? args = _balancedArgs(src, open);
    if (args == null) {
      continue;
    }
    calls.add(_FromLtrbCall(args: args, line: _lineOf(src, match.start)));
  }
  return calls;
}

List<String> _topLevelArgs(String args) {
  final List<String> out = <String>[];
  final StringBuffer buf = StringBuffer();
  int depth = 0;
  for (int i = 0; i < args.length; i++) {
    final String ch = args[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    }
    if (ch == ',' && depth == 0) {
      final String piece = buf.toString().trim();
      if (piece.isNotEmpty) {
        out.add(piece);
      }
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  final String last = buf.toString().trim();
  if (last.isNotEmpty) {
    out.add(last);
  }
  return out;
}

/// Bare 4 / 8 / 20 / 24 / 32 (optional .0) that are not part of an identifier.
final RegExp _bareHomeScaleLiteral = RegExp(
  r'(?<![A-Za-z0-9_])(4|8|20|24|32)(?:\.0+)?(?![A-Za-z0-9_.])',
);

final RegExp _kSpaceToken = RegExp(r'\bkSpace\d+\b');

Widget _homeApp() {
  return MaterialApp(
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
          child: HomeScreen(onToggleLocale: () {}),
        );
      },
    ),
  );
}

Future<EdgeInsets> _scrollPadding(
  WidgetTester tester, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_homeApp());
  await tester.pump();

  final Finder scroll = find.byType(SingleChildScrollView);
  expect(
    scroll,
    findsOneWidget,
    reason: 'HomeScreen must wrap its body in one SingleChildScrollView',
  );
  final SingleChildScrollView view = tester.widget<SingleChildScrollView>(
    scroll,
  );
  expect(
    view.padding,
    isA<EdgeInsets>(),
    reason: 'HomeScreen scroll padding must be an EdgeInsets fromLTRB',
  );
  return view.padding as EdgeInsets;
}

void main() {
  test(
    'home_screen EdgeInsets.fromLTRB uses kSpace* with no bare 4/8/20/24/32',
    () {
      final List<_FromLtrbCall> calls = _fromLtrbCalls(_homeScreenSource());
      expect(
        calls,
        isNotEmpty,
        reason:
            'home_screen.dart must still declare EdgeInsets.fromLTRB padding',
      );

      final List<String> bare = <String>[];
      final List<String> missingToken = <String>[];
      for (final _FromLtrbCall call in calls) {
        for (final Match match in _bareHomeScaleLiteral.allMatches(call.args)) {
          bare.add('${match.group(0)} in ${call.preview}');
        }
        final List<String> args = _topLevelArgs(call.args);
        expect(
          args,
          hasLength(4),
          reason:
              'EdgeInsets.fromLTRB must have four arguments; found '
              '${args.length} in ${call.preview}',
        );
        for (final String arg in args) {
          if (!_kSpaceToken.hasMatch(arg)) {
            missingToken.add('$arg in ${call.preview}');
          }
        }
      }

      expect(
        bare,
        isEmpty,
        reason:
            'home_screen.dart EdgeInsets.fromLTRB must not use bare '
            '4/8/20/24/32; found ${bare.length}: ${bare.join('; ')}',
      );
      expect(
        missingToken,
        isEmpty,
        reason:
            'home_screen.dart EdgeInsets.fromLTRB arguments must reference '
            'kSpace* tokens; arguments without a token: '
            '${missingToken.join('; ')}',
      );
    },
  );

  testWidgets('home scroll padding is kSpace6 / kSpace1|kSpace2 / kSpace6 / '
      'kSpace5|kSpace7', (WidgetTester tester) async {
    final EdgeInsets compact = await _scrollPadding(
      tester,
      size: const Size(390, 600),
    );
    expect(
      compact.left,
      kSpace6,
      reason:
          'compact start padding must be kSpace6 ($kSpace6), '
          'found ${compact.left}',
    );
    expect(
      compact.top,
      kSpace1,
      reason:
          'compact top padding must be kSpace1 ($kSpace1), '
          'found ${compact.top}',
    );
    expect(
      compact.right,
      kSpace6,
      reason:
          'compact end padding must be kSpace6 ($kSpace6), '
          'found ${compact.right}',
    );
    expect(
      compact.bottom,
      kSpace5,
      reason:
          'compact bottom padding must be kSpace5 ($kSpace5), '
          'found ${compact.bottom}',
    );

    await tester.pumpWidget(const SizedBox.shrink());

    final EdgeInsets comfortable = await _scrollPadding(
      tester,
      size: const Size(390, 844),
    );
    expect(
      comfortable.left,
      kSpace6,
      reason:
          'tall start padding must be kSpace6 ($kSpace6), '
          'found ${comfortable.left}',
    );
    expect(
      comfortable.top,
      kSpace2,
      reason:
          'tall top padding must be kSpace2 ($kSpace2), '
          'found ${comfortable.top}',
    );
    expect(
      comfortable.right,
      kSpace6,
      reason:
          'tall end padding must be kSpace6 ($kSpace6), '
          'found ${comfortable.right}',
    );
    expect(
      comfortable.bottom,
      kSpace7,
      reason:
          'tall bottom padding must be kSpace7 ($kSpace7), '
          'found ${comfortable.bottom}',
    );
  });
}
