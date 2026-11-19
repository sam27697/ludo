// Proves home and lobby take their die size from a symbol owned by
// die_mark.dart or theme.dart, and that HomeScreen still paints DieMark.
//
// The size pair used to live as duplicated `compact ? 72 : 148` literals in
// both screens. Those literals must be gone. C-678 (X210 item 6) gave home
// its own shorter pair, homeDieMarkSize, so home and lobby no longer share
// one symbol: home must call a die-size symbol owned by die_mark.dart or
// theme.dart (homeDieMarkSize included) and lobby keeps dieMarkSize.

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

/// Public top-level size helpers in [source]: functions or constants named
/// like a die size that return a compact/tall pair of numeric literals.
List<String> _sizeOwningSymbols(String source) {
  final String stripped = _stripLineComments(source);
  final RegExp func = RegExp(
    r'(?:^|\n)\s*(?:double|int|num)\s+(\w*[dD]ie\w*)\s*\([^)]*\)\s*=>\s*'
    r'[^;]*\?\s*\d+(?:\.\d+)?\s*:\s*\d+(?:\.\d+)?\s*;',
  );
  final Set<String> names = <String>{
    for (final Match m in func.allMatches(stripped)) m.group(1)!,
  };
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
  test(
    'home calls a die size owned by die_mark or theme, lobby keeps dieMarkSize',
    () {
      final Directory root = _findPackageRoot();
      final String homePath = p.join(
        root.path,
        'lib',
        'src',
        'home_screen.dart',
      );
      final String lobbyPath = p.join(
        root.path,
        'lib',
        'src',
        'lobby_screen.dart',
      );
      final String dieMarkPath = p.join(
        root.path,
        'lib',
        'src',
        'die_mark.dart',
      );
      final String themePath = p.join(root.path, 'lib', 'src', 'theme.dart');

      final String home = _stripLineComments(File(homePath).readAsStringSync());
      final String lobby = _stripLineComments(
        File(lobbyPath).readAsStringSync(),
      );
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
            'die_mark.dart or theme.dart must declare a public die size '
            'helper that owns a compact/tall literal pair',
      );

      final List<String> homeCalls = owners
          .where((String name) => RegExp('\\b$name\\s*\\(').hasMatch(home))
          .toList();
      expect(
        homeCalls,
        isNotEmpty,
        reason:
            'home_screen.dart must call a die size symbol owned by '
            'die_mark.dart or theme.dart (homeDieMarkSize included); '
            'size-owning symbols found: $owners',
      );

      expect(
        RegExp(r'\bdieMarkSize\s*\(').hasMatch(lobby),
        isTrue,
        reason: 'lobby_screen.dart must keep calling dieMarkSize',
      );
      expect(
        owners,
        contains('dieMarkSize'),
        reason: 'die_mark.dart must still own dieMarkSize for the lobby',
      );
    },
  );

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
