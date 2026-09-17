// Button theme padding must reference named spacing tokens from theme.dart
// (kSpace3=12, kSpace4=16, kSpace5=20) instead of bare 20 / 12 on
// ElevatedButtonTheme and bare 16 / 12 on OutlinedButtonTheme.

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

String _themeSource() {
  final File file = File(
    p.join(_findPackageRoot().path, 'lib', 'src', 'theme.dart'),
  );
  expect(file.existsSync(), isTrue, reason: 'theme.dart must exist');
  return file.readAsStringSync();
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

class _PaddingCall {
  const _PaddingCall({
    required this.owner,
    required this.constructor,
    required this.args,
    required this.line,
  });

  final String owner;
  final String constructor;
  final String args;
  final int line;

  String get preview {
    final String compact = args.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 100
        ? '${compact.substring(0, 100)}…'
        : compact;
    return 'theme.dart:$line $owner padding $constructor($clipped)';
  }
}

_PaddingCall _themeButtonPaddingCall(String owner) {
  final String src = _themeSource();
  final RegExp styleFrom = RegExp('$owner\\.styleFrom\\s*\\(');
  final Match? match = styleFrom.firstMatch(src);
  expect(
    match,
    isNotNull,
    reason: 'theme.dart must declare $owner.styleFrom for the button theme',
  );
  final int open = src.indexOf('(', match!.start);
  final String? styleArgs = _balancedArgs(src, open);
  expect(
    styleArgs,
    isNotNull,
    reason: 'could not read $owner.styleFrom arguments in theme.dart',
  );

  final RegExp paddingCtor = RegExp(
    r'padding:\s*(?:const\s+)?(EdgeInsets(?:Directional)?\.\w+)\s*\(',
  );
  final Match? padMatch = paddingCtor.firstMatch(styleArgs!);
  expect(
    padMatch,
    isNotNull,
    reason: '$owner.styleFrom must set padding: EdgeInsets(...) in theme.dart',
  );
  final int padOpen = styleArgs.indexOf('(', padMatch!.end - 1);
  final String? padArgs = _balancedArgs(styleArgs, padOpen);
  expect(
    padArgs,
    isNotNull,
    reason: 'could not read $owner padding EdgeInsets arguments',
  );
  return _PaddingCall(
    owner: owner,
    constructor: padMatch.group(1)!,
    args: padArgs!,
    line: _lineOf(src, match.start + padMatch.start),
  );
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

Map<String, String> _namedArgs(String args) {
  final Map<String, String> named = <String, String>{};
  for (final String piece in _topLevelArgs(args)) {
    final int colon = piece.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    named[piece.substring(0, colon).trim()] = piece.substring(colon + 1).trim();
  }
  return named;
}

RegExp _bareLiteral(List<int> values) {
  final String alt = values.map((int v) => '$v').join('|');
  return RegExp('(?<![A-Za-z0-9_])($alt)(?:\\.0+)?(?![A-Za-z0-9_.])');
}

void _expectTokenPadding({
  required _PaddingCall call,
  required String horizontalToken,
  required String verticalToken,
  required List<int> forbiddenBare,
}) {
  final List<String> problems = <String>[];
  for (final Match match in _bareLiteral(forbiddenBare).allMatches(call.args)) {
    problems.add('bare ${match.group(0)} in ${call.preview}');
  }

  final Map<String, String> named = _namedArgs(call.args);
  if (named.containsKey('horizontal') || named.containsKey('vertical')) {
    final String horizontal = named['horizontal'] ?? '';
    final String vertical = named['vertical'] ?? '';
    if (!RegExp('\\b$horizontalToken\\b').hasMatch(horizontal)) {
      problems.add(
        'horizontal must reference $horizontalToken; found '
        '"$horizontal" in ${call.preview}',
      );
    }
    if (!RegExp('\\b$verticalToken\\b').hasMatch(vertical)) {
      problems.add(
        'vertical must reference $verticalToken; found '
        '"$vertical" in ${call.preview}',
      );
    }
  } else {
    if (!RegExp('\\b$horizontalToken\\b').hasMatch(call.args)) {
      problems.add(
        'padding must reference $horizontalToken; found ${call.preview}',
      );
    }
    if (!RegExp('\\b$verticalToken\\b').hasMatch(call.args)) {
      problems.add(
        'padding must reference $verticalToken; found ${call.preview}',
      );
    }
  }

  expect(
    problems,
    isEmpty,
    reason:
        '${call.owner} padding must use $horizontalToken horizontal and '
        '$verticalToken vertical with no bare ${forbiddenBare.join('/')}; '
        'found ${problems.length}: ${problems.join('; ')}',
  );
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
          child: HomeScreen(onToggleLocale: () {}),
        );
      },
    ),
  );
}

EdgeInsets _resolvedThemePadding(
  WidgetTester tester, {
  required Key key,
  required bool elevated,
}) {
  final Finder finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: '$key must be on screen');
  final BuildContext context = tester.element(finder);
  final ButtonStyle? style = elevated
      ? Theme.of(context).elevatedButtonTheme.style
      : Theme.of(context).outlinedButtonTheme.style;
  expect(
    style,
    isNotNull,
    reason: '${elevated ? 'elevated' : 'outlined'}ButtonTheme.style must exist',
  );
  expect(
    style!.padding,
    isNotNull,
    reason:
        '${elevated ? 'elevated' : 'outlined'}ButtonTheme.style.padding '
        'must be set',
  );
  final EdgeInsetsGeometry? pad = style.padding!.resolve(const <WidgetState>{});
  expect(
    pad,
    isNotNull,
    reason:
        '${elevated ? 'Elevated' : 'Outlined'}Button theme padding '
        'must resolve',
  );
  return pad!.resolve(TextDirection.ltr);
}

Future<EdgeInsets> _measuredPadding(
  WidgetTester tester, {
  required Widget Function(Widget child) buildButton,
}) async {
  const Key childKey = Key('button-pad-child');
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: buildButton(
            const SizedBox(key: childKey, width: 220, height: 90),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final Finder button = find.byWidgetPredicate(
    (Widget widget) => widget is ElevatedButton || widget is OutlinedButton,
  );
  expect(button, findsOneWidget);
  final Rect buttonRect = tester.getRect(button);
  final Rect childRect = tester.getRect(find.byKey(childKey));
  return EdgeInsets.fromLTRB(
    childRect.left - buttonRect.left,
    childRect.top - buttonRect.top,
    buttonRect.right - childRect.right,
    buttonRect.bottom - childRect.bottom,
  );
}

void _expectInsets(
  EdgeInsets padding, {
  required double horizontal,
  required double vertical,
  required String label,
}) {
  expect(
    padding.left,
    horizontal,
    reason: '$label start padding must be $horizontal, found ${padding.left}',
  );
  expect(
    padding.right,
    horizontal,
    reason: '$label end padding must be $horizontal, found ${padding.right}',
  );
  expect(
    padding.top,
    vertical,
    reason: '$label top padding must be $vertical, found ${padding.top}',
  );
  expect(
    padding.bottom,
    vertical,
    reason: '$label bottom padding must be $vertical, found ${padding.bottom}',
  );
}

void main() {
  test('ElevatedButtonTheme padding uses kSpace5 horizontal and kSpace3 '
      'vertical with no bare 20/12', () {
    expect(kSpace5, 20, reason: 'kSpace5 must stay 20');
    expect(kSpace3, 12, reason: 'kSpace3 must stay 12');
    _expectTokenPadding(
      call: _themeButtonPaddingCall('ElevatedButton'),
      horizontalToken: 'kSpace5',
      verticalToken: 'kSpace3',
      forbiddenBare: const <int>[20, 12],
    );
  });

  test('OutlinedButtonTheme padding uses kSpace4 horizontal and kSpace3 '
      'vertical with no bare 16/12', () {
    expect(kSpace4, 16, reason: 'kSpace4 must stay 16');
    expect(kSpace3, 12, reason: 'kSpace3 must stay 12');
    _expectTokenPadding(
      call: _themeButtonPaddingCall('OutlinedButton'),
      horizontalToken: 'kSpace4',
      verticalToken: 'kSpace3',
      forbiddenBare: const <int>[16, 12],
    );
  });

  testWidgets(
    'ElevatedButton theme padding is kSpace5 horizontal and kSpace3 vertical',
    (WidgetTester tester) async {
      await tester.pumpWidget(_homeApp());
      await tester.pump();

      final EdgeInsets themed = _resolvedThemePadding(
        tester,
        key: const Key('create-room-button'),
        elevated: true,
      );
      _expectInsets(
        themed,
        horizontal: kSpace5,
        vertical: kSpace3,
        label: 'Home Create ElevatedButton theme',
      );

      await tester.pumpWidget(const SizedBox.shrink());

      final EdgeInsets measured = await _measuredPadding(
        tester,
        buildButton: (Widget child) =>
            ElevatedButton(onPressed: () {}, child: child),
      );
      _expectInsets(
        measured,
        horizontal: kSpace5,
        vertical: kSpace3,
        label: 'themed ElevatedButton geometry',
      );
    },
  );

  testWidgets(
    'OutlinedButton theme padding is kSpace4 horizontal and kSpace3 vertical',
    (WidgetTester tester) async {
      await tester.pumpWidget(_homeApp());
      await tester.pump();

      final EdgeInsets themed = _resolvedThemePadding(
        tester,
        key: const Key('join-room-button'),
        elevated: false,
      );
      _expectInsets(
        themed,
        horizontal: kSpace4,
        vertical: kSpace3,
        label: 'Home Join OutlinedButton theme',
      );

      await tester.pumpWidget(const SizedBox.shrink());

      final EdgeInsets measured = await _measuredPadding(
        tester,
        buildButton: (Widget child) =>
            OutlinedButton(onPressed: () {}, child: child),
      );
      _expectInsets(
        measured,
        horizontal: kSpace4,
        vertical: kSpace3,
        label: 'themed OutlinedButton geometry',
      );
    },
  );
}
