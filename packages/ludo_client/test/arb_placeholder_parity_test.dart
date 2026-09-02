import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

/// Every `{word}` substitution the message text itself uses, independent of
/// the `@key.placeholders` metadata block. This is what the runtime
/// `intl`-generated code actually substitutes into, so it is the set that
/// has to match between locales key for key.
final _placeholderPattern = RegExp(r'\{([A-Za-z0-9_]+)\}');

Set<String> _placeholdersIn(String message) =>
    _placeholderPattern.allMatches(message).map((m) => m.group(1)!).toSet();

/// Reads an ARB file into its non-`@`-prefixed message keys, mapped to the
/// set of placeholder names their message text uses. The `@`-prefixed
/// metadata entries (including `@@locale`) describe the messages rather than
/// being messages themselves, so they are not part of this map.
Map<String, Set<String>> _messagePlaceholders(File arbFile) {
  final decoded =
      jsonDecode(arbFile.readAsStringSync()) as Map<String, dynamic>;
  final result = <String, Set<String>>{};
  for (final entry in decoded.entries) {
    if (entry.key.startsWith('@')) continue;
    final value = entry.value;
    expect(
      value,
      isA<String>(),
      reason:
          '${arbFile.path}: expected key "${entry.key}" to hold a string '
          'message, found ${value.runtimeType}',
    );
    result[entry.key] = _placeholdersIn(value as String);
  }
  return result;
}

void main() {
  test('app_ar.arb and app_en.arb declare the same keys with the same '
      'placeholders in each', () {
    final packageRoot = _findPackageRoot();
    final l10nDir = Directory(p.join(packageRoot.path, 'lib', 'l10n'));
    final enFile = File(p.join(l10nDir.path, 'app_en.arb'));
    final arFile = File(p.join(l10nDir.path, 'app_ar.arb'));

    expect(
      enFile.existsSync(),
      isTrue,
      reason: 'expected ${enFile.path} to exist',
    );
    expect(
      arFile.existsSync(),
      isTrue,
      reason: 'expected ${arFile.path} to exist',
    );

    final en = _messagePlaceholders(enFile);
    final ar = _messagePlaceholders(arFile);

    final enOnly = en.keys.toSet().difference(ar.keys.toSet());
    final arOnly = ar.keys.toSet().difference(en.keys.toSet());

    expect(
      enOnly,
      isEmpty,
      reason:
          'app_en.arb has keys missing from app_ar.arb: '
          '${enOnly.toList()..sort()}',
    );
    expect(
      arOnly,
      isEmpty,
      reason:
          'app_ar.arb has keys missing from app_en.arb: '
          '${arOnly.toList()..sort()}',
    );

    final mismatches = <String>[];
    for (final key in en.keys) {
      final enPlaceholders = en[key]!;
      final arPlaceholders = ar[key]!;
      if (enPlaceholders.difference(arPlaceholders).isNotEmpty ||
          arPlaceholders.difference(enPlaceholders).isNotEmpty) {
        mismatches.add('$key: en has $enPlaceholders, ar has $arPlaceholders');
      }
    }

    expect(
      mismatches,
      isEmpty,
      reason: 'placeholder sets differ:\n${mismatches.join('\n')}',
    );
  });
}
