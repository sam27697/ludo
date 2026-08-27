import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Scans lib/ for the shapes of hardcoded, user-visible English text that
/// this codebase is not allowed to contain: a string literal passed
/// straight to Text(), or a string literal assigned to a widget property
/// that Flutter renders to the user (labelText, hintText, errorText,
/// helperText, tooltip/message, semanticLabel).
///
/// This is a shape check over source text, not a full parse, so it can miss
/// something creative and it can in principle flag a legitimate non-visible
/// use of one of these property names on a class this codebase does not use
/// yet. What it cannot do is pass vacuously: every user-visible string this
/// app currently shows is produced by exactly the two patterns below, and a
/// developer who writes `Text('Create Room')` instead of
/// `Text(loc.homeCreateRoomButton)` makes this test fail.
///
/// The generated localization delegate under lib/l10n/gen is excluded: it is
/// the source of truth for the strings themselves, generated from the ARB
/// files, not app code that puts text in front of a user through a widget.

/// Finds this package's own root directory regardless of where `flutter
/// test` was invoked from: directly inside packages/ludo_client (the normal
/// case) or from the repository root with `packages/ludo_client` given as
/// the test target (Flutter then leaves the working directory at the
/// invocation root, not the package root).
Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((line) => line.trim() == 'name: ludo_client');
  }

  final cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }

  final nested = Directory(p.join(cwd.path, 'packages', 'ludo_client'));
  if (isLudoClient(nested)) {
    return nested;
  }

  var walker = cwd;
  for (var i = 0; i < 8; i++) {
    final parent = walker.parent;
    if (parent.path == walker.path) break;
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }

  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

void main() {
  test('no widget in lib/ carries a hardcoded string literal', () {
    final packageRoot = _findPackageRoot();
    final libDir = Directory(p.join(packageRoot.path, 'lib'));
    expect(
      libDir.existsSync(),
      isTrue,
      reason: 'expected ${libDir.path} to exist',
    );

    final genDir = p.join(libDir.path, 'l10n', 'gen');

    final dartFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !p.isWithin(genDir, f.path) && f.path != genDir)
        .toList();

    expect(
      dartFiles,
      isNotEmpty,
      reason: 'expected at least one lib/**.dart file to scan',
    );

    // Text(<optional whitespace/newlines>'literal' or "literal"
    final textLiteral = RegExp(
      r'''Text\s*\(\s*['"]''',
      multiLine: true,
      dotAll: true,
    );

    // A widget property Flutter renders to the user, assigned a string
    // literal instead of a value sourced from AppLocalizations.
    final visiblePropertyLiteral = RegExp(
      r'''\b(labelText|hintText|errorText|helperText|tooltip|message|semanticLabel|title)\s*:\s*['"]''',
      multiLine: true,
      dotAll: true,
    );

    final violations = <String>[];
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      // Strip // line comments so a comment mentioning these shapes does not
      // trip the check.
      final stripped = source
          .split('\n')
          .map((line) {
            final idx = line.indexOf('//');
            return idx == -1 ? line : line.substring(0, idx);
          })
          .join('\n');

      for (final match in textLiteral.allMatches(stripped)) {
        violations.add(
          '${p.relative(file.path, from: libDir.path)}: '
          'hardcoded Text() literal near offset ${match.start}',
        );
      }
      for (final match in visiblePropertyLiteral.allMatches(stripped)) {
        violations.add(
          '${p.relative(file.path, from: libDir.path)}: '
          'hardcoded literal for a user-visible property near offset ${match.start}',
        );
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
