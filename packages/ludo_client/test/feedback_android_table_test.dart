// Conformance test for work/ludo/orders/C-422-every-play-tap-answers.md's
// T3: a source scan proving `android/app/src/main/kotlin/app/fayad/ludo/
// MainActivity.kt`'s three cue tables (`hapticTimings`, `hapticAmplitudes`,
// `soundResources`) never drift from `lib/src/feedback.dart`'s own
// `FeedbackCue` enum. Written from C-422's own text alone (run 102, order
// 422); order 423 builds D1's Kotlin side in a tree this file's author has
// not read.
//
// Every id this file checks against Kotlin comes from `FeedbackCue.values`
// and its `.id` extension, never a copied list (the order's own
// instruction): this file can never itself drift from the Dart enum, by
// construction.
//
// A consequence worth stating plainly, since it bears on this file's own
// red/green status on this order's base (origin/main bddc551): this is a
// cross-consistency scan between two tables that are, on this base,
// already consistent with each other (`FeedbackCue.values` has its ten
// C-225 ids, with no `tap`; `MainActivity.kt`'s three maps have exactly
// those same ten keys, with no `tap` either). Reading ids only from
// `FeedbackCue.values`, as instructed, means this file has no way to
// notice that an eleventh id is *missing from both sides at once* -- it
// can only catch one side drifting away from the other. So, unlike T1,
// T2, T4, T5 and T6-T9, this file is expected to pass on bddc551 already,
// not fail: there is nothing inconsistent yet for it to catch. It will
// still pass once order 423 adds `FeedbackCue.tap` and `MainActivity.kt`'s
// matching `"tap"` entries together, and it would fail if either side
// gained its entry without the other.
//
// `path`'s `Directory`/`File` walk to the package root, and down to the
// Kotlin file, is copied by hand from test/color_alias_scan_test.dart's
// own `_findPackageRoot`, per this project's standing instruction never to
// import across test files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
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

/// Reads MainActivity.kt's source, or throws a plain [StateError] naming
/// the path. Not [expect]: this runs from top-level `main()` code, outside
/// any `test()` body, where flutter_test's `expect` throws
/// `OutsideTestException` instead of reporting the usual matcher failure.
String _mainActivitySource() {
  final File file = File(
    p.join(
      _findPackageRoot().path,
      'android',
      'app',
      'src',
      'main',
      'kotlin',
      'app',
      'fayad',
      'ludo',
      'MainActivity.kt',
    ),
  );
  if (!file.existsSync()) {
    throw StateError(
      'MainActivity.kt must exist for this scan to mean anything; looked '
      'at ${file.path}',
    );
  }
  return file.readAsStringSync();
}

/// The quoted string keys of the `mapOf(...)` block declared under
/// [declarationName] (e.g. `hapticTimings`), in source order. Matches from
/// the declaration's own `mapOf(` through the first line that is exactly
/// four spaces and a closing paren -- this file's three tables are all
/// flat (no nested `mapOf`), so that line is always the map literal's own
/// close, never one of the `longArrayOf(...)`/`intArrayOf(...)` calls
/// nested one level deeper inside each entry.
Set<String> _mapKeys(String source, String declarationName) {
  final RegExp block = RegExp(
    '$declarationName\\s*:[^=]*=\\s*mapOf\\(\\n([\\s\\S]*?)\\n {4}\\)',
  );
  final RegExpMatch? match = block.firstMatch(source);
  if (match == null) {
    throw StateError(
      'MainActivity.kt must declare a flat mapOf(...) block for '
      '$declarationName; none was found by this scan\'s own pattern',
    );
  }
  final String body = match.group(1)!;
  final RegExp entryKey = RegExp(r'"([a-z_]+)"\s+to\b');
  return entryKey.allMatches(body).map((Match m) => m.group(1)!).toSet();
}

void main() {
  final String source = _mainActivitySource();
  final Set<String> hapticTimingKeys = _mapKeys(source, 'hapticTimings');
  final Set<String> hapticAmplitudeKeys = _mapKeys(source, 'hapticAmplitudes');
  final Set<String> soundResourceKeys = _mapKeys(source, 'soundResources');

  final Set<String> dartIds = FeedbackCue.values
      .map((FeedbackCue cue) => cue.id)
      .toSet();

  test('every FeedbackCue id is a key of hapticTimings in MainActivity.kt', () {
    for (final String id in dartIds) {
      expect(
        hapticTimingKeys.contains(id),
        isTrue,
        reason:
            'FeedbackCue id "$id" must be a key of hapticTimings in '
            'MainActivity.kt; hapticTimings carries '
            '${hapticTimingKeys.toList()..sort()}',
      );
    }
  });

  test(
    'every FeedbackCue id is a key of hapticAmplitudes in MainActivity.kt',
    () {
      for (final String id in dartIds) {
        expect(
          hapticAmplitudeKeys.contains(id),
          isTrue,
          reason:
              'FeedbackCue id "$id" must be a key of hapticAmplitudes in '
              'MainActivity.kt; hapticAmplitudes carries '
              '${hapticAmplitudeKeys.toList()..sort()}',
        );
      }
    },
  );

  test('every FeedbackCue id except invalid_tap and tap is a key of '
      'soundResources; invalid_tap and tap are not', () {
    const Set<String> hapticOnly = <String>{'invalid_tap', 'tap'};
    for (final String id in dartIds) {
      if (hapticOnly.contains(id)) {
        expect(
          soundResourceKeys.contains(id),
          isFalse,
          reason:
              'FeedbackCue id "$id" is haptic-only (doctrine\'s table: '
              'none) and must not be a key of soundResources; '
              'soundResources carries ${soundResourceKeys.toList()..sort()}',
        );
      } else {
        expect(
          soundResourceKeys.contains(id),
          isTrue,
          reason:
              'FeedbackCue id "$id" must be a key of soundResources in '
              'MainActivity.kt; soundResources carries '
              '${soundResourceKeys.toList()..sort()}',
        );
      }
    }
  });
}
