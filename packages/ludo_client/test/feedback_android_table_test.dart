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
// C-468 D6 (order 469): `die_land` and `gloat` are sound only. They are
// keys of `soundResources` and of neither haptic table; every other id
// keeps the rule above. The three-table cross-check still reads its ids
// from `FeedbackCue.values`; the two sound-only ids are named from the
// contract and also asserted to be Dart cue ids, so one side gaining them
// without the other is caught.
//
// C-588 D1: `capture_seen` joins them as a third sound-only id. Its
// soundResources entry points at the existing fb_captured_other clip (no new
// sound file) and MainActivity.kt plays it at half volume (0.5f on both
// channels); every other id keeps volume 1f.
//
// C-599 D1: `friend_joined` is a full three-channel cue, not sound only. Its
// haptic is one medium tap (timings 0, 40; amplitudes 0, 160), its clip is
// the new R.raw.fb_friend_joined, and it plays at the default volume, so it
// has no soundVolumes entry. The cross-checks above read the Dart enum and
// stay as they were: with friend_joined in both places they treat it like
// every other full cue. The group at the end pins the numbers.
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

/// The text between the `mapOf(` and the closing paren of the flat map
/// declared under [declarationName].
String _mapBody(String source, String declarationName) {
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
  return match.group(1)!;
}

/// The quoted string keys of the `mapOf(...)` block declared under
/// [declarationName] (e.g. `hapticTimings`), in source order. Matches from
/// the declaration's own `mapOf(` through the first line that is exactly
/// four spaces and a closing paren -- this file's three tables are all
/// flat (no nested `mapOf`), so that line is always the map literal's own
/// close, never one of the `longArrayOf(...)`/`intArrayOf(...)` calls
/// nested one level deeper inside each entry.
Set<String> _mapKeys(String source, String declarationName) {
  final String body = _mapBody(source, declarationName);
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

  // C-468 D4, D5 and D6: sound only. They are keys of soundResources and
  // of neither haptic table; every other cue id keeps the C-422 rule.
  // C-588 D1 adds capture_seen to the same set.
  const Set<String> soundOnly = <String>{'die_land', 'gloat', 'capture_seen'};

  test('die_land, gloat and capture_seen are FeedbackCue ids (C-468 D6, '
      'C-588 D1)', () {
    for (final String id in soundOnly) {
      expect(
        dartIds.contains(id),
        isTrue,
        reason:
            'C-468 D6 and C-588 D1 add the cue id "$id" to FeedbackCue; the '
            'ids are '
            '${dartIds.toList()..sort()}',
      );
    }
  });

  test('every FeedbackCue id except die_land, gloat and capture_seen is a '
      'key of hapticTimings in MainActivity.kt; those three are not', () {
    for (final String id in dartIds) {
      if (soundOnly.contains(id)) {
        expect(
          hapticTimingKeys.contains(id),
          isFalse,
          reason:
              'FeedbackCue id "$id" is sound only (C-468 D6, C-588 D1) and must not '
              'be a key of hapticTimings; hapticTimings carries '
              '${hapticTimingKeys.toList()..sort()}',
        );
      } else {
        expect(
          hapticTimingKeys.contains(id),
          isTrue,
          reason:
              'FeedbackCue id "$id" must be a key of hapticTimings in '
              'MainActivity.kt; hapticTimings carries '
              '${hapticTimingKeys.toList()..sort()}',
        );
      }
    }
    for (final String id in soundOnly) {
      expect(
        hapticTimingKeys.contains(id),
        isFalse,
        reason: '"$id" must not be a key of hapticTimings (C-468 D6)',
      );
    }
  });

  test('every FeedbackCue id except die_land, gloat and capture_seen is a '
      'key of hapticAmplitudes in MainActivity.kt; those three are not', () {
    for (final String id in dartIds) {
      if (soundOnly.contains(id)) {
        expect(
          hapticAmplitudeKeys.contains(id),
          isFalse,
          reason:
              'FeedbackCue id "$id" is sound only (C-468 D6, C-588 D1) and must not '
              'be a key of hapticAmplitudes; hapticAmplitudes carries '
              '${hapticAmplitudeKeys.toList()..sort()}',
        );
      } else {
        expect(
          hapticAmplitudeKeys.contains(id),
          isTrue,
          reason:
              'FeedbackCue id "$id" must be a key of hapticAmplitudes in '
              'MainActivity.kt; hapticAmplitudes carries '
              '${hapticAmplitudeKeys.toList()..sort()}',
        );
      }
    }
    for (final String id in soundOnly) {
      expect(
        hapticAmplitudeKeys.contains(id),
        isFalse,
        reason: '"$id" must not be a key of hapticAmplitudes (C-468 D6)',
      );
    }
  });

  test('every FeedbackCue id except invalid_tap and tap is a key of '
      'soundResources; invalid_tap and tap are not; die_land, gloat and '
      'capture_seen are', () {
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
    for (final String id in soundOnly) {
      expect(
        soundResourceKeys.contains(id),
        isTrue,
        reason:
            '"$id" must be a key of soundResources (C-468 D6, C-588 D1); '
            'soundResources carries ${soundResourceKeys.toList()..sort()}',
      );
    }
  });

  test('capture_seen plays the existing fb_captured_other clip and adds no '
      'sound file (C-588 D1)', () {
    final String body = _mapBody(source, 'soundResources');
    final Match? entry = RegExp(r'"capture_seen"\s+to\s+R\.raw\.(\w+)')
        .firstMatch(body);
    expect(
      entry,
      isNotNull,
      reason:
          'soundResources must map "capture_seen" to an R.raw clip; the '
          'block is:\n$body',
    );
    expect(
      entry!.group(1),
      'fb_captured_other',
      reason:
          'C-588 D1: capture_seen reuses R.raw.fb_captured_other; got '
          'R.raw.${entry.group(1)}',
    );
    final Directory raw = Directory(
      p.join(
        _findPackageRoot().path,
        'android',
        'app',
        'src',
        'main',
        'res',
        'raw',
      ),
    );
    expect(
      File(p.join(raw.path, 'fb_captured_other.wav')).existsSync(),
      isTrue,
      reason: 'the reused clip fb_captured_other.wav must exist in ${raw.path}',
    );
    expect(
      raw.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      isNot(contains('fb_capture_seen.wav')),
      reason: 'C-588 D1: no new sound file; res/raw must not gain a clip',
    );
  });

  // The source does not say how the half volume is carried (a map, a `when`,
  // an `if`), so this reads only what any shape must contain: a 0.5f literal
  // outside the soundResources block, the id "capture_seen" in the same
  // statement or entry as it, and a playSound whose volume arguments are no
  // longer the bare literal 1f pair for every id.
  test(
    'capture_seen is played at 0.5f and every other id at 1f (C-588 D1)',
    () {
      final String body = _mapBody(source, 'soundResources');
      final String rest = source.replaceFirst(body, '');
      final RegExp nearHalf = RegExp(
        r'capture_seen[^\n]*0\.5f|0\.5f[^\n]*capture_seen|'
        r'capture_seen[\s\S]{0,160}?0\.5f',
      );
      expect(
        nearHalf.hasMatch(rest),
        isTrue,
        reason:
            'C-588 D1: MainActivity.kt must tie "capture_seen" to a 0.5f '
            'volume outside the soundResources map; no such pairing found',
      );
      final RegExpMatch? play = RegExp(
        r'soundPool\?\.play\(\s*soundId\s*,\s*([^,]+?)\s*,\s*([^,]+?)\s*,',
      ).firstMatch(rest);
      expect(
        play,
        isNotNull,
        reason:
            'playSound must still call soundPool?.play(soundId, left, right,',
      );
      expect(
        <String>[play!.group(1)!, play.group(2)!],
        isNot(equals(<String>['1f', '1f'])),
        reason:
            'C-588 D1: the volume arguments of soundPool.play cannot both be '
            'the literal 1f any more, or capture_seen could not be quieter; '
            'got ${play.group(1)}, ${play.group(2)}',
      );
      expect(
        rest.contains('1f'),
        isTrue,
        reason: 'every other id keeps volume 1f; no 1f remains in the source',
      );
    },
  );

  test(
    'the comment above soundResources names the build script (C-468 D6)',
    () {
      final int at = source.indexOf(RegExp(r'val\s+soundResources'));
      expect(at, greaterThanOrEqualTo(0), reason: 'soundResources not found');
      final String before = source.substring(0, at);
      final String lastBlock = before.substring(
        before.lastIndexOf('\n\n') < 0 ? 0 : before.lastIndexOf('\n\n'),
      );
      expect(
        lastBlock.contains('build_feedback_sounds.py'),
        isTrue,
        reason:
            'the comment directly above soundResources must name '
            'tool/build_feedback_sounds.py; the text above it was:\n$lastBlock',
      );
    },
  );
  // C-599 D1: the numbers. Read from the Kotlin source by id, so the group
  // fails on its own assertion on a tree that has no friend_joined entry
  // yet, and stays independent of the enum cross-checks above.
  group('friend_joined (C-599 D1)', () {
    List<int>? numbersOf(String declaration, String id, String maker) {
      final String body = _mapBody(source, declaration);
      final RegExpMatch? m = RegExp('"$id"\\s+to\\s+$maker\\(([^)]*)\\)')
          .firstMatch(body);
      if (m == null) {
        return null;
      }
      return m
          .group(1)!
          .split(',')
          .map((String part) => int.parse(part.trim()))
          .toList();
    }

    test('hapticTimings: longArrayOf(0, 40), one medium tap', () {
      expect(
        numbersOf('hapticTimings', 'friend_joined', 'longArrayOf'),
        equals(<int>[0, 40]),
        reason:
            'C-599 D1: hapticTimings needs "friend_joined" to '
            'longArrayOf(0, 40); keys present are '
            '${(hapticTimingKeys.toList()..sort())}',
      );
    });

    test('hapticAmplitudes: intArrayOf(0, 160)', () {
      expect(
        numbersOf('hapticAmplitudes', 'friend_joined', 'intArrayOf'),
        equals(<int>[0, 160]),
        reason:
            'C-599 D1: hapticAmplitudes needs "friend_joined" to '
            'intArrayOf(0, 160); keys present are '
            '${(hapticAmplitudeKeys.toList()..sort())}',
      );
    });

    test('its timings differ from your_turn and from can_move, and it is '
        'one pulse, longer than your_turn', () {
      final List<int>? mine = numbersOf(
        'hapticTimings',
        'friend_joined',
        'longArrayOf',
      );
      final List<int>? yourTurn = numbersOf(
        'hapticTimings',
        'your_turn',
        'longArrayOf',
      );
      final List<int>? canMove = numbersOf(
        'hapticTimings',
        'can_move',
        'longArrayOf',
      );
      expect(mine, isNotNull, reason: 'friend_joined has no hapticTimings');
      expect(yourTurn, isNotNull, reason: 'your_turn has no hapticTimings');
      expect(canMove, isNotNull, reason: 'can_move has no hapticTimings');
      expect(
        mine,
        isNot(equals(yourTurn)),
        reason: 'C-599 D1: distinct from your_turn $yourTurn; got $mine',
      );
      expect(
        mine,
        isNot(equals(canMove)),
        reason: 'C-599 D1: distinct from can_move $canMove; got $mine',
      );
      expect(
        mine!.length,
        2,
        reason: 'C-599 D1: a single pulse (delay, vibrate); got $mine',
      );
      expect(
        mine[1],
        greaterThan(yourTurn![1]),
        reason: 'C-599 D1: longer than your_turn ($yourTurn); got $mine',
      );
      final List<int>? mineAmp = numbersOf(
        'hapticAmplitudes',
        'friend_joined',
        'intArrayOf',
      );
      final List<int>? yourTurnAmp = numbersOf(
        'hapticAmplitudes',
        'your_turn',
        'intArrayOf',
      );
      expect(mineAmp, isNotNull, reason: 'friend_joined has no amplitudes');
      expect(
        mineAmp![1],
        greaterThan(yourTurnAmp![1]),
        reason: 'C-599 D1: firmer than your_turn ($yourTurnAmp); got $mineAmp',
      );
    });

    test('timings and amplitudes have the same length (one amplitude per '
        'segment)', () {
      final List<int>? timings = numbersOf(
        'hapticTimings',
        'friend_joined',
        'longArrayOf',
      );
      final List<int>? amps = numbersOf(
        'hapticAmplitudes',
        'friend_joined',
        'intArrayOf',
      );
      expect(timings, isNotNull, reason: 'friend_joined has no timings');
      expect(amps, isNotNull, reason: 'friend_joined has no amplitudes');
      expect(amps!.length, timings!.length);
    });

    test('soundResources maps it to R.raw.fb_friend_joined, its own clip', () {
      final String body = _mapBody(source, 'soundResources');
      final RegExpMatch? entry = RegExp(r'"friend_joined"\s+to\s+R\.raw\.(\w+)')
          .firstMatch(body);
      expect(
        entry,
        isNotNull,
        reason:
            'C-599 D1: soundResources must map "friend_joined" to an R.raw '
            'clip; the block is:\n$body',
      );
      expect(
        entry!.group(1),
        'fb_friend_joined',
        reason:
            'C-599 D1: friend_joined plays R.raw.fb_friend_joined; got '
            'R.raw.${entry.group(1)}',
      );
    });

    test('it is not in the sound-only set: it is a key of both haptic '
        'tables and of soundResources', () {
      expect(
        hapticTimingKeys,
        contains('friend_joined'),
        reason: 'C-599 D1: a haptic cue, so a key of hapticTimings',
      );
      expect(
        hapticAmplitudeKeys,
        contains('friend_joined'),
        reason: 'C-599 D1: a haptic cue, so a key of hapticAmplitudes',
      );
      expect(
        soundResourceKeys,
        contains('friend_joined'),
        reason: 'C-599 D1: a sound cue, so a key of soundResources',
      );
      expect(
        soundOnly,
        isNot(contains('friend_joined')),
        reason: 'friend_joined must not be added to the sound-only set',
      );
    });

    test('soundVolumes has no friend_joined entry: it plays at volume 1f, '
        'and capture_seen keeps its 0.5f', () {
      final Set<String> volumeKeys = _mapKeys(source, 'soundVolumes');
      expect(
        volumeKeys,
        isNot(contains('friend_joined')),
        reason:
            'C-599 D1: sound at volume 1f means no soundVolumes entry; '
            'soundVolumes carries ${volumeKeys.toList()..sort()}',
      );
      expect(
        volumeKeys,
        equals(<String>{'capture_seen'}),
        reason: 'C-599 D6: every existing volume stays; got $volumeKeys',
      );
      expect(
        RegExp(r'"capture_seen"\s+to\s+0\.5f')
            .hasMatch(_mapBody(source, 'soundVolumes')),
        isTrue,
        reason: 'C-588 D1: capture_seen stays at 0.5f',
      );
    });

    test('the Dart enum carries the id the Kotlin tables key on', () {
      expect(
        dartIds,
        contains('friend_joined'),
        reason:
            'C-599 D1: FeedbackCue gains the wire id friend_joined; the '
            'Dart ids are ${dartIds.toList()..sort()}',
      );
    });

    test('every existing id keeps its timings and amplitudes', () {
      const Map<String, List<int>> timings = <String, List<int>>{
        'your_turn': <int>[0, 18],
        'can_move': <int>[0, 20, 60, 20],
        'no_move': <int>[0, 220],
        'step': <int>[0, 8],
        'captured_other': <int>[0, 30, 40, 30],
        'captured_me': <int>[0, 180, 60, 50],
        'home': <int>[0, 30, 50, 40, 50, 60],
        'win': <int>[0, 60, 60, 80, 60, 120, 60, 260],
        'game_over': <int>[0, 90],
        'invalid_tap': <int>[0, 10],
        'tap': <int>[0, 14],
      };
      const Map<String, List<int>> amplitudes = <String, List<int>>{
        'your_turn': <int>[0, 90],
        'can_move': <int>[0, 120, 0, 120],
        'no_move': <int>[0, 200],
        'step': <int>[0, 60],
        'captured_other': <int>[0, 255, 0, 255],
        'captured_me': <int>[0, 200, 0, 140],
        'home': <int>[0, 90, 0, 160, 0, 240],
        'win': <int>[0, 80, 0, 130, 0, 190, 0, 255],
        'game_over': <int>[0, 70],
        'invalid_tap': <int>[0, 50],
        'tap': <int>[0, 80],
      };
      for (final MapEntry<String, List<int>> e in timings.entries) {
        expect(
          numbersOf('hapticTimings', e.key, 'longArrayOf'),
          equals(e.value),
          reason: 'C-599 D6: ${e.key} keeps its hapticTimings ${e.value}',
        );
      }
      for (final MapEntry<String, List<int>> e in amplitudes.entries) {
        expect(
          numbersOf('hapticAmplitudes', e.key, 'intArrayOf'),
          equals(e.value),
          reason: 'C-599 D6: ${e.key} keeps its hapticAmplitudes ${e.value}',
        );
      }
    });
  });
}
