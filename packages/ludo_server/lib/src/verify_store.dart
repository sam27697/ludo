// docs/VERIFY.md section 2: the store behind `/v/<game_id>`. One record per
// finished game, written once and read many times, never mutated after it is
// written. Nothing here knows what a room, a seat or a roll is -- it stores
// and loads an opaque JSON string under a game id, and nothing more.

import 'dart:io';

import 'clock.dart';

/// How long a verification record is kept before `purgeOlderThan` is free to
/// delete it. `docs/VERIFY.md` section 8: the retention period, stated
/// publicly on the not-found page and honoured here.
const Duration verifyRetention = Duration(days: 90);

/// The `verify_url` prefix used when nothing overrides it.
/// `docs/VERIFY.md` section 8.
const String defaultVerifyUrlBase = 'https://provefair.app/v/';

/// Exactly 16 lowercase hex characters: the shape of a `game_id` this server
/// could have issued. Every route and every store method checks a caller-
/// supplied id against this before it is trusted for anything -- in
/// particular, before it is ever used to build a filesystem path.
final RegExp _gameIdPattern = RegExp(r'^[0-9a-f]{16}$');

/// True if [s] is a game id this server could have issued: exactly 16
/// lowercase hex characters, nothing more and nothing less.
bool isWellFormedGameId(String s) => _gameIdPattern.hasMatch(s);

/// Where a finished game's verification record lives. One record per game
/// id, written once at the moment the game is won and never changed after.
abstract class VerifyStore {
  /// Stores [json] under [gameId]. Returns false and changes nothing if a
  /// record for [gameId] already exists. Throws on an I/O failure.
  bool save(String gameId, String json);

  /// The exact string [save] was given, or null. Null, never a throw, for an
  /// id that fails [isWellFormedGameId].
  String? load(String gameId);

  /// Deletes every record saved before [cutoff]; returns how many.
  int purgeOlderThan(DateTime cutoff);
}

/// A record held only in process memory. The default: records are lost on
/// restart, which is why `bin/server.dart` prints a warning when this is
/// what a running server ends up using.
class MemoryVerifyStore implements VerifyStore {
  MemoryVerifyStore(this._clock);

  final Clock _clock;
  final Map<String, _StoredRecord> _records = <String, _StoredRecord>{};

  @override
  bool save(String gameId, String json) {
    if (_records.containsKey(gameId)) {
      return false;
    }
    _records[gameId] = _StoredRecord(json: json, savedAt: _clock.now);
    return true;
  }

  @override
  String? load(String gameId) {
    if (!isWellFormedGameId(gameId)) {
      return null;
    }
    return _records[gameId]?.json;
  }

  @override
  int purgeOlderThan(DateTime cutoff) {
    final List<String> stale = <String>[
      for (final MapEntry<String, _StoredRecord> entry in _records.entries)
        if (entry.value.savedAt.isBefore(cutoff)) entry.key,
    ];
    for (final String gameId in stale) {
      _records.remove(gameId);
    }
    return stale.length;
  }
}

class _StoredRecord {
  _StoredRecord({required this.json, required this.savedAt});
  final String json;
  final DateTime savedAt;
}

/// A record held as a file on disk, one `<game_id>.json` per game, in a
/// single flat directory. Survives a restart; `bin/server.dart` builds this
/// instead of [MemoryVerifyStore] when `LUDO_VERIFY_DIR` is set.
class DirectoryVerifyStore implements VerifyStore {
  /// Creates [path] (and any missing parent) if it does not already exist.
  DirectoryVerifyStore(String path) : _path = path {
    Directory(_path).createSync(recursive: true);
  }

  final String _path;

  @override
  bool save(String gameId, String json) {
    // `isWellFormedGameId` runs before any path is built from [gameId], so a
    // caller that somehow reaches this with a malformed id never causes a
    // traversal outside `_path` -- there is simply no file operation for it.
    if (!isWellFormedGameId(gameId)) {
      return false;
    }
    final File target = File(_recordPath(gameId));
    if (target.existsSync()) {
      return false;
    }
    // Write to a temporary file in the same directory and rename it over the
    // final name, so a concurrent reader never observes a half-written file:
    // `rename` on the same filesystem is atomic, a plain write is not.
    final File tmp = File('${target.path}.tmp');
    tmp.writeAsStringSync(json, flush: true);
    tmp.renameSync(target.path);
    return true;
  }

  @override
  String? load(String gameId) {
    if (!isWellFormedGameId(gameId)) {
      return null;
    }
    final File file = File(_recordPath(gameId));
    if (!file.existsSync()) {
      return null;
    }
    return file.readAsStringSync();
  }

  @override
  int purgeOlderThan(DateTime cutoff) {
    final Directory dir = Directory(_path);
    if (!dir.existsSync()) {
      return 0;
    }
    var purged = 0;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File) {
        continue;
      }
      final String name =
          entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;
      // A file that is not `<16 hex>.json` -- a stray `.tmp` left by a crash
      // mid-write, or anything else that ended up in this directory -- is
      // left alone, never deleted, per docs/VERIFY.md section 2.
      if (!_recordFileNamePattern.hasMatch(name)) {
        continue;
      }
      final DateTime modified = entity.statSync().modified;
      if (modified.isBefore(cutoff)) {
        entity.deleteSync();
        purged++;
      }
    }
    return purged;
  }

  String _recordPath(String gameId) => '$_path/$gameId.json';
}

final RegExp _recordFileNamePattern = RegExp(r'^[0-9a-f]{16}\.json$');
