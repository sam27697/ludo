// Asserts the A1-T10 result record lists every changed product path and names
// the implementation commit, while still recording STATUS DONE and a GATE path.

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

String _readT10Result() {
  final Directory packageRoot = _findPackageRoot();
  final File result = File(
    p.join(
      packageRoot.path,
      '..',
      '..',
      '.uxprogram',
      'track-A',
      'cycle-1',
      'tasks',
      'T10.result.md',
    ),
  );
  expect(
    result.existsSync(),
    isTrue,
    reason: 'missing T10.result.md at ${result.path}',
  );
  return result.readAsStringSync();
}

String? _lineValue(String text, String key) {
  final RegExp pattern = RegExp(
    r'^' + RegExp.escape(key) + r':\s*(.*)$',
    multiLine: true,
  );
  final Match? match = pattern.firstMatch(text);
  return match?.group(1)?.trim();
}

void main() {
  test('T10.result.md FILES lists all four changed paths', () {
    final String text = _readT10Result();
    final String files = _lineValue(text, 'FILES') ?? '';
    const List<String> required = <String>[
      'die_mark.dart',
      'home_screen.dart',
      'lobby_screen.dart',
      'die_mark_shared_size_test.dart',
    ];
    for (final String path in required) {
      expect(
        files.contains(path),
        isTrue,
        reason: 'FILES must list $path; got: $files',
      );
    }
  });

  test('T10.result.md names implementation commit 1690791', () {
    final String text = _readT10Result();
    final String commit = _lineValue(text, 'COMMIT') ?? '';
    final String deviations = _lineValue(text, 'DEVIATIONS') ?? '';
    final String combined = '$commit\n$deviations';
    expect(
      combined.contains('1690791'),
      isTrue,
      reason:
          'COMMIT or DEVIATIONS must name 1690791; COMMIT=$commit DEVIATIONS=$deviations',
    );
  });

  test('T10.result.md still records STATUS DONE and GATE evidence', () {
    final String text = _readT10Result();
    expect(
      RegExp(r'^STATUS:\s*DONE\s*$', multiLine: true).hasMatch(text),
      isTrue,
      reason: 'STATUS: DONE line must be present',
    );
    expect(
      RegExp(r'^GATE:\s*\S+', multiLine: true).hasMatch(text),
      isTrue,
      reason: 'GATE: evidence path line must be present',
    );
  });
}
