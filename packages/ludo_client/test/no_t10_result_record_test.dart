// Guards the client test suite against reintroducing a tracked file that
// reads paths outside the package and fails on a clean checkout.

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

void main() {
  test('client suite does not ship t10_result_record_test.dart', () {
    final Directory packageRoot = _findPackageRoot();
    final File banned = File(
      p.join(packageRoot.path, 'test', 't10_result_record_test.dart'),
    );
    expect(
      banned.existsSync(),
      isFalse,
      reason:
          '${banned.path} must not exist: it reads files outside this package '
          'and fails flutter test on a clean clone',
    );
  });
}
