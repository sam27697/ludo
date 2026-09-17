// Proves home and lobby share one die-size helper (or constants) from
// die_mark.dart or theme.dart, and that HomeScreen still paints DieMark.
//
// The size pair used to live as duplicated `compact ? 72 : 148` literals in
// both screens. Those literals must be gone, and both screens must call the
// same public symbol that owns the sizes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';
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

/// Strip // line comments so commented-out sizes do not satisfy the check.
String _stripLineComments(String source) {
  return source
      .split('\n')
      .map((String line) {
        final int idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}

/// Public top-level names in [source] whose declaration body mentions both
/// size literals 72 and 148 (the shared compact/tall die sizes).
List<String> _sizeOwningSymbols(String source) {
  final String stripped = _stripLineComments(source);
  final RegExp decl = RegExp(
    r'(?:^|\n)\s*(?:const\s+|final\s+)?(?:double|int|num)\s+(\w+)\s*[=\(]([^;{]*)',
    multiLine: true,
  );
  final RegExp func = RegExp(
    r'(?:^|\n)\s*(?:double|int|num)\s+(\w+)\s*\([^)]*\)\s*(?:=>|{)([^}]*)}?',
    multiLine: true,
  );

  final Set<String> names = <String>{};
  void consider(String name, String body) {
    if (body.contains('72') && body.contains('148')) {
      names.add(name);
    }
  }

  for (final Match m in decl.allMatches(stripped)) {
    consider(m.group(1)!, m.group(2)!);
  }
  for (final Match m in func.allMatches(stripped)) {
    consider(m.group(1)!, m.group(2)!);
  }
  return names.toList()..sort();
}

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://die-mark-shared-size-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'die_mark_shared_size_test.dart: connector must never open a '
        'transport; HomeScreen only needs a factory that fails closed',
      );
    },
  );
}

Widget _homeScreenApp({
  RoomControllerFactory controllerFactory = _neverConnectsControllerFactory,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

void main() {
  test('home_screen and lobby_screen call a shared die size from die_mark or theme', () {
    final Directory root = _findPackageRoot();
    final String homePath = p.join(root.path, 'lib', 'src', 'home_screen.dart');
    final String lobbyPath = p.join(
      root.path,
      'lib',
      'src',
      'lobby_screen.dart',
    );
    final String dieMarkPath = p.join(root.path, 'lib', 'src', 'die_mark.dart');
    final String themePath = p.join(root.path, 'lib', 'src', 'theme.dart');

    final String home = _stripLineComments(File(homePath).readAsStringSync());
    final String lobby = _stripLineComments(File(lobbyPath).readAsStringSync());
    final String dieMark = File(dieMarkPath).readAsStringSync();
    final String theme = File(themePath).readAsStringSync();

    final RegExp forbidden = RegExp(r'72\s*:\s*148|compact\s*\?\s*72');
    final List<String> homeHits = forbidden
        .allMatches(home)
        .map((Match m) => m.group(0)!)
        .toList();
    final List<String> lobbyHits = forbidden
        .allMatches(lobby)
        .map((Match m) => m.group(0)!)
        .toList();

    expect(
      homeHits,
      isEmpty,
      reason:
          'home_screen.dart must not contain compact ? 72 / 72 : 148 '
          'literals; found $homeHits',
    );
    expect(
      lobbyHits,
      isEmpty,
      reason:
          'lobby_screen.dart must not contain compact ? 72 / 72 : 148 '
          'literals; found $lobbyHits',
    );

    final List<String> fromDieMark = _sizeOwningSymbols(dieMark);
    final List<String> fromTheme = _sizeOwningSymbols(theme);
    final List<String> owners = <String>[...fromDieMark, ...fromTheme];

    expect(
      owners,
      isNotEmpty,
      reason:
          'die_mark.dart or theme.dart must declare a public size helper '
          'or constant that owns both 72 and 148',
    );

    final List<String> shared = owners
        .where(
          (String name) =>
              RegExp('\\b$name\\b').hasMatch(home) &&
              RegExp('\\b$name\\b').hasMatch(lobby),
        )
        .toList();

    expect(
      shared,
      isNotEmpty,
      reason:
          'home_screen.dart and lobby_screen.dart must both call the same '
          'die size symbol from die_mark.dart or theme.dart; size-owning '
          'symbols found: $owners',
    );
  });

  testWidgets('HomeScreen shows DieMark', (WidgetTester tester) async {
    await tester.pumpWidget(_homeScreenApp());
    await tester.pump();

    expect(
      find.byType(DieMark),
      findsWidgets,
      reason: 'HomeScreen must paint at least one DieMark',
    );
  });
}
