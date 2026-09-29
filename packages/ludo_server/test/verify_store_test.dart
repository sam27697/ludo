// Tests for docs/VERIFY.md section 2, the verify store: MemoryVerifyStore,
// DirectoryVerifyStore and isWellFormedGameId. Written from that section
// alone -- none of lib/src/verify_store.dart exists on this branch yet, so
// nothing here compiles until another worker's branch lands. Every symbol
// this file imports is on the pinned interface list in
// work/ludo/orders/212-verify-tests.md.
//
// A note on the traversal-style malformed ids used below: docs/VERIFY.md's
// own example of a malformed id is the literal string "../../etc/passwd".
// That string is exercised against isWellFormedGameId directly (a pure,
// in-memory string check with no filesystem involvement, so it is
// completely safe to use verbatim). It is deliberately NOT used as an
// argument to DirectoryVerifyStore.save/load in this file: if a future
// implementation ever forgot the shape check before building a path (the
// exact bug this file's own directory-listing tests exist to catch), a
// literal "../../etc/passwd" could resolve outside the test's own temporary
// directory and attempt a real write against the host filesystem -- for
// example "/etc/passwd.json" one level up, sibling-not-overwrite, but a real
// file outside anything this test owns or cleans up, and one that would
// actually be created if this suite is ever run with elevated privileges.
// The filesystem-facing tests below instead use a traversal payload aimed at
// a sibling directory this test itself creates, controls and deletes, which
// proves the identical "no traversal, whatever the id" property without any
// possibility of touching anything outside this test's own temp hierarchy.

import 'dart:io';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// A handful of distinct, well-formed (16 lowercase hex) game ids, used
/// wherever a test needs more than one record in a store at once. Chosen so
/// their differences are easy to eyeball in a failure message.
const String _id1 = 'a1b2c3d4e5f60718';
const String _id2 = 'b1b2c3d4e5f60718';
const String _id3 = 'c1b2c3d4e5f60718';

const String _json1 = '{"format":1,"game_id":"$_id1","n":1}';
const String _json2 = '{"format":1,"game_id":"$_id2","n":2}';
const String _json3 = '{"format":1,"game_id":"$_id3","n":3}';

/// Malformed ids that are always safe to hand to a pure, in-memory check
/// (isWellFormedGameId) or to MemoryVerifyStore (which never touches a
/// filesystem regardless of what string it is given). Deliberately includes
/// the exact "../../etc/passwd" example from docs/VERIFY.md, since neither
/// consumer here can turn it into a real filesystem write.
const List<String> _malformedIds = <String>[
  'A1B2C3D4E5F60718', // 16 chars, but upper case
  'a1b2c3d4e5f6071', // 15 chars
  'a1b2c3d4e5f607188', // 17 chars
  '../../etc/passwd',
  '0123456789abcde/', // 16 chars, but the last one is not hex
  '',
];

/// The basename of [entity]'s path, without depending on package:path
/// (not a dependency of this package).
String _basename(FileSystemEntity entity) =>
    entity.path.split(Platform.pathSeparator).last;

void main() {
  group('isWellFormedGameId', () {
    test('accepts 16 lowercase hex', () {
      expect(isWellFormedGameId(_id1), isTrue);
    });

    test('refuses upper case', () {
      expect(isWellFormedGameId(_id1.toUpperCase()), isFalse);
    });

    test('refuses 15 characters', () {
      expect(isWellFormedGameId(_id1.substring(0, 15)), isFalse);
    });

    test('refuses 17 characters', () {
      expect(isWellFormedGameId('${_id1}f'), isFalse);
    });

    test('refuses "../../etc/passwd"', () {
      expect(isWellFormedGameId('../../etc/passwd'), isFalse);
    });

    test('refuses "0123456789abcde/" (16 characters, but not all hex)', () {
      const String candidate = '0123456789abcde/';
      expect(candidate.length, 16,
          reason: 'test setup error: this fixture '
              'must itself be 16 characters long, or it is not exercising '
              '"right length, wrong shape" at all');
      expect(isWellFormedGameId(candidate), isFalse);
    });

    test('refuses the empty string', () {
      expect(isWellFormedGameId(''), isFalse);
    });
  });

  group('MemoryVerifyStore', () {
    late FakeClock clock;
    late MemoryVerifyStore store;

    setUp(() {
      clock = FakeClock(DateTime.utc(2026, 1, 1));
      store = MemoryVerifyStore(clock);
    });

    test('save then load gives the exact string back', () {
      expect(store.save(_id1, _json1), isTrue,
          reason: 'the first save of a fresh id must succeed');
      expect(store.load(_id1), _json1);
    });

    test(
        'a second save of the same id returns false and the first content '
        'survives', () {
      expect(store.save(_id1, _json1), isTrue);
      expect(store.save(_id1, _json2), isFalse,
          reason: 'a second save of the same id must return false and '
              'change nothing, per the pinned VerifyStore.save doc comment');
      expect(store.load(_id1), _json1,
          reason: 'the first save\'s content must survive a rejected '
              'second save');
    });

    test('load of an unknown id is null', () {
      expect(store.load(_id2), isNull);
    });

    test('load of a malformed id is null, never a throw', () {
      for (final String bad in _malformedIds) {
        expect(store.load(bad), isNull,
            reason: 'load(${_describe(bad)}) must be null, not a throw, '
                'per the pinned VerifyStore.load doc comment: "Null, never '
                'a throw, for an id that fails isWellFormedGameId"');
      }
    });

    test('save of a malformed id refuses (returns false) and stores nothing',
        () {
      for (final String bad in _malformedIds) {
        expect(store.save(bad, _json1), isFalse,
            reason: 'save(${_describe(bad)}, ...) must refuse a malformed '
                'id (docs/VERIFY.md section 2: "load and save refuse an id '
                'that fails isWellFormedGameId")');
        expect(store.load(bad), isNull);
      }
    });

    test(
        'purgeOlderThan deletes records saved before the cutoff, keeps the '
        'rest, and returns the count', () {
      store.save(_id1, _json1); // saved at clock.now == 2026-01-01T00:00:00Z
      clock.advance(const Duration(hours: 1));
      store.save(_id2, _json2); // saved at +1h
      clock.advance(const Duration(hours: 1));
      store.save(_id3, _json3); // saved at +2h

      // Exactly id2's own save time: id1 was saved strictly before this,
      // id2 was saved exactly at it (not "before" it), id3 after it.
      final DateTime cutoff = DateTime.utc(2026, 1, 1, 1);
      final int purged = store.purgeOlderThan(cutoff);

      expect(purged, 1,
          reason: 'only $_id1 was saved strictly before the cutoff');
      expect(store.load(_id1), isNull,
          reason: '$_id1 was saved before the cutoff and must be gone');
      expect(store.load(_id2), _json2,
          reason: '$_id2 was saved exactly at the cutoff, which is not '
              '"before" it, and must survive');
      expect(store.load(_id3), _json3,
          reason: '$_id3 was saved after the cutoff and must survive');
    });
  });

  group('DirectoryVerifyStore', () {
    test('creates the directory if missing', () {
      final Directory parent =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final String subPath =
            '${parent.path}${Platform.pathSeparator}does_not_exist_yet';
        expect(Directory(subPath).existsSync(), isFalse,
            reason: 'test setup error: this path must not already exist');
        DirectoryVerifyStore(subPath);
        expect(Directory(subPath).existsSync(), isTrue,
            reason: 'the pinned constructor doc comment says '
                '"creates the directory if missing"');
      } finally {
        parent.deleteSync(recursive: true);
      }
    });

    test('save then load gives the exact string back', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        expect(store.save(_id1, _json1), isTrue);
        expect(store.load(_id1), _json1);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'a second save of the same id returns false and the first content '
        'survives, on disk as well as through load()', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        expect(store.save(_id1, _json1), isTrue);
        expect(store.save(_id1, _json2), isFalse,
            reason: 'a second save of the same id must return false and '
                'change nothing');
        expect(store.load(_id1), _json1);
        final File onDisk =
            File('${dir.path}${Platform.pathSeparator}$_id1.json');
        expect(onDisk.readAsStringSync(), _json1,
            reason: 'the file on disk, not only load(), must still hold '
                'the first save\'s content');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('load of an unknown id is null', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        expect(store.load(_id2), isNull);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('no .tmp file is left after a save', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        expect(store.save(_id1, _json1), isTrue);
        final Set<String> names = dir.listSync().map(_basename).toSet();
        expect(names, <String>{'$_id1.json'},
            reason: 'expected exactly one file, $_id1.json, with no '
                'leftover <id>.json.tmp; got $names');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'load and save with a malformed id create no file anywhere in the '
        'store directory', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        for (final String bad in _malformedIds) {
          expect(store.load(bad), isNull,
              reason: 'load(${_describe(bad)}) must be null');
          expect(store.save(bad, _json1), isFalse,
              reason: 'save(${_describe(bad)}, ...) must refuse');
        }
        expect(dir.listSync(), isEmpty,
            reason: 'a malformed id must never create a file anywhere in '
                'the store directory; found '
                '${dir.listSync().map((FileSystemEntity e) => e.path).toList()}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'a traversal id creates no file outside the store directory either '
        '(no traversal, whatever the id)', () {
      // A parent this test fully owns, with the store directory as one
      // child and a sibling ("outside") directory as another. If the store
      // ever built a path from an unchecked id, "../outside/pwned" would
      // resolve to a location inside this same parent -- still fully
      // contained, still cleaned up below -- rather than anywhere on the
      // real filesystem outside this test's own control.
      final Directory parent =
          Directory.systemTemp.createTempSync('verify_store_test_parent_');
      try {
        final Directory storeDir =
            Directory('${parent.path}${Platform.pathSeparator}store')
              ..createSync();
        final Directory outsideDir =
            Directory('${parent.path}${Platform.pathSeparator}outside')
              ..createSync();
        final DirectoryVerifyStore store = DirectoryVerifyStore(storeDir.path);

        const String traversalId = '../outside/pwned';
        expect(isWellFormedGameId(traversalId), isFalse,
            reason: 'test setup error: this id must itself be malformed '
                'or this case is not testing traversal rejection at all');

        expect(store.load(traversalId), isNull);
        expect(store.save(traversalId, _json1), isFalse);

        expect(storeDir.listSync(), isEmpty,
            reason: 'the store\'s own directory must hold nothing after a '
                'traversal id');
        expect(outsideDir.listSync(), isEmpty,
            reason: 'a traversal id must not create any file in the '
                'sibling directory it points at either; found '
                '${outsideDir.listSync().map((FileSystemEntity e) => e.path).toList()}');
      } finally {
        parent.deleteSync(recursive: true);
      }
    });

    test(
        'purgeOlderThan deletes records saved before the cutoff, keeps the '
        'rest, and returns the count (mtimes set explicitly, since this '
        'store has no injected clock)', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        expect(store.save(_id1, _json1), isTrue);
        expect(store.save(_id2, _json2), isTrue);
        expect(store.save(_id3, _json3), isTrue);

        File file(String id) =>
            File('${dir.path}${Platform.pathSeparator}$id.json');
        file(_id1).setLastModifiedSync(DateTime.utc(2026, 1, 1));
        file(_id2).setLastModifiedSync(DateTime.utc(2026, 1, 1, 1));
        file(_id3).setLastModifiedSync(DateTime.utc(2026, 1, 1, 2));

        final int purged = store.purgeOlderThan(DateTime.utc(2026, 1, 1, 1));

        expect(purged, 1,
            reason: 'only $_id1 (mtime strictly before the cutoff) should '
                'be purged');
        expect(store.load(_id1), isNull);
        expect(store.load(_id2), _json2,
            reason: '$_id2\'s mtime equals the cutoff exactly, which is '
                'not "before" it');
        expect(store.load(_id3), _json3);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'purgeOlderThan never deletes a file whose name is not '
        '<16 hex>.json, however old', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('verify_store_test_');
      try {
        final DirectoryVerifyStore store = DirectoryVerifyStore(dir.path);
        final File notes = File('${dir.path}${Platform.pathSeparator}notes.txt')
          ..writeAsStringSync('not a record');
        final File upperCase = File(
          '${dir.path}${Platform.pathSeparator}ABCDEF0123456789.json',
        )..writeAsStringSync('{"not":"lowercase-named"}');

        final DateTime ancient = DateTime.utc(1970, 1, 2);
        notes.setLastModifiedSync(ancient);
        upperCase.setLastModifiedSync(ancient);

        // A cutoff far in the future: if this store purged by age alone,
        // both fixtures above -- ancient by any measure -- would be
        // deleted. The property under test is that neither one's name
        // matches <16 hex>.json, which must protect them regardless of
        // age.
        final int purged = store.purgeOlderThan(DateTime.utc(2100, 1, 1));

        expect(purged, 0,
            reason: 'neither fixture file is a real <16 hex>.json record, '
                'so nothing should have been counted as purged');
        expect(notes.existsSync(), isTrue,
            reason: 'notes.txt must survive purgeOlderThan regardless of '
                'its age');
        expect(upperCase.existsSync(), isTrue,
            reason: 'ABCDEF0123456789.json must survive purgeOlderThan: '
                'its hex is upper case, so its name does not match '
                '<16 hex>.json (lowercase only)');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

/// A short, printable description of [id] for a failure message -- some of
/// [_malformedIds] are awkward to read inline (the empty string, one full
/// of slashes).
String _describe(String id) => id.isEmpty ? '<empty string>' : '"$id"';
