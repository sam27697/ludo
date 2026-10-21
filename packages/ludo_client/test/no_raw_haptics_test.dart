// Conformance test for work/ludo/orders/C-422-every-play-tap-answers.md's
// T5: "After this order no file under lib/src/ other than feedback.dart
// mentions HapticFeedback" (D2's own closing clause). Written from C-422's
// own text alone (run 102, order 422); order 423 removes game_screen.dart's
// raw call in a tree this file's author has not read.
//
// On this order's base, origin/main bddc551, game_screen.dart still calls
// `HapticFeedback.lightImpact()` directly at the die tap (C-236 rule 5,
// which C-422 D2 replaces), so this file is expected to fail there, naming
// lib/src/game_screen.dart.
//
// `path`'s `Directory`/`File` walk to the package root is copied by hand
// from test/color_alias_scan_test.dart's own `_findPackageRoot`, per this
// project's standing instruction never to import across test files.

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

  throw StateError(
    'could not locate the ludo_client package root from cwd ${cwd.path}',
  );
}

void main() {
  test('no file under lib/src/ other than feedback.dart mentions '
      'HapticFeedback (C-422 D2)', () {
    final Directory libSrc = Directory(
      p.join(_findPackageRoot().path, 'lib', 'src'),
    );
    expect(
      libSrc.existsSync(),
      isTrue,
      reason: 'lib/src must exist for this scan to mean anything',
    );

    final List<File> dartFiles = libSrc
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList();
    expect(
      dartFiles,
      isNotEmpty,
      reason:
          'fixture is broken: lib/src must carry at least one .dart '
          'file for this scan to mean anything',
    );

    final List<String> offenders = <String>[];
    for (final File file in dartFiles) {
      if (p.basename(file.path) == 'feedback.dart') {
        continue;
      }
      if (file.readAsStringSync().contains('HapticFeedback')) {
        offenders.add(p.relative(file.path, from: libSrc.path));
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'C-422 D2: after this order, no file under lib/src/ other '
          'than feedback.dart may mention HapticFeedback; found it in '
          '${offenders.map((String f) => 'lib/src/$f').toList()}',
    );
  });
}
