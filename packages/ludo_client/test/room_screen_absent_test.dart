// Guards against resurrecting the dead RoomScreen widget and its orphan
// roomScreen* localization keys. RoomScreen is not on any live route;
// RoomRoute builds LobbyScreen or GameScreen instead.

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

/// Matches Dart imports (and exports / parts) that pull in room_screen.dart.
final RegExp _roomScreenImport = RegExp(
  r"""(?:import|export)\s+['"][^'"]*room_screen\.dart['"]""",
);

Iterable<File> _dartFilesUnder(Directory root) {
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'));
}

void main() {
  test('room_screen.dart is absent from lib/src', () {
    final Directory packageRoot = _findPackageRoot();
    final File banned = File(
      p.join(packageRoot.path, 'lib', 'src', 'room_screen.dart'),
    );
    expect(
      banned.existsSync(),
      isFalse,
      reason:
          '${banned.path} must not exist: RoomScreen is dead and must be '
          'removed from the client package',
    );
  });

  test('no import of room_screen.dart under packages/ludo_client', () {
    final Directory packageRoot = _findPackageRoot();
    final List<String> hits = <String>[];
    for (final File file in _dartFilesUnder(packageRoot)) {
      final String contents = file.readAsStringSync();
      for (final Match match in _roomScreenImport.allMatches(contents)) {
        hits.add(
          '${p.relative(file.path, from: packageRoot.path)}: '
          '${match.group(0)}',
        );
      }
    }
    expect(
      hits,
      isEmpty,
      reason:
          'no Dart file under ludo_client may import or export '
          'room_screen.dart; found:\n${hits.join('\n')}',
    );
  });

  test(
    'room_screen_test.dart and room_screen_presentation_test.dart are absent',
    () {
      final Directory packageRoot = _findPackageRoot();
      final File suite = File(
        p.join(packageRoot.path, 'test', 'room_screen_test.dart'),
      );
      final File presentation = File(
        p.join(packageRoot.path, 'test', 'room_screen_presentation_test.dart'),
      );
      expect(
        suite.existsSync(),
        isFalse,
        reason:
            '${suite.path} must not exist: RoomScreen acceptance coverage '
            'lives in room_screen_absent_test.dart',
      );
      expect(
        presentation.existsSync(),
        isFalse,
        reason:
            '${presentation.path} must not exist: RoomScreen presentation '
            'coverage is retired with the widget',
      );
    },
  );

  test('no roomScreen keys in app_en.arb or app_ar.arb', () {
    final Directory packageRoot = _findPackageRoot();
    final List<String> hits = <String>[];
    for (final String name in <String>['app_en.arb', 'app_ar.arb']) {
      final File arb = File(p.join(packageRoot.path, 'lib', 'l10n', name));
      expect(arb.existsSync(), isTrue, reason: '${arb.path} must exist');
      final List<String> lines = arb.readAsStringSync().split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (line.contains('roomScreen')) {
          hits.add('$name:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      hits,
      isEmpty,
      reason:
          'app_en.arb and app_ar.arb must not declare roomScreen* keys; '
          'found:\n${hits.join('\n')}',
    );
  });

  test('flutter gen-l10n succeeds without roomScreen getters', () async {
    final Directory packageRoot = _findPackageRoot();
    final ProcessResult result = await Process.run(
      'flutter',
      <String>['gen-l10n'],
      workingDirectory: packageRoot.path,
      runInShell: false,
    );
    expect(
      result.exitCode,
      0,
      reason:
          'flutter gen-l10n must succeed; exit ${result.exitCode}\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );

    final Directory genDir = Directory(
      p.join(packageRoot.path, 'lib', 'l10n', 'gen'),
    );
    expect(genDir.existsSync(), isTrue, reason: '${genDir.path} missing');

    final List<String> hits = <String>[];
    for (final File file in _dartFilesUnder(genDir)) {
      final List<String> lines = file.readAsStringSync().split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        if (line.contains('roomScreen')) {
          hits.add(
            '${p.relative(file.path, from: packageRoot.path)}:${i + 1}: '
            '${line.trim()}',
          );
        }
      }
    }
    expect(
      hits,
      isEmpty,
      reason:
          'generated AppLocalizations must not expose roomScreen* getters; '
          'found:\n${hits.join('\n')}',
    );
  });
}
