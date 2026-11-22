// docs/PROTOCOL.md section 32 items 7 to 12: the strike ladder and the file
// it is kept in.
//
// Every install and every IP held here is held as HMAC-SHA256 under the
// salt, lower-case hex. Nothing else about a person is kept: no name, no
// room, no code. A hash, an IP or an install never reaches a log line or a
// frame; the log says `strike`, and `ban` with the level and length only.
// Time comes from the injected `Clock`, never from `DateTime.now()`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import 'clock.dart';

/// The shortest `LUDO_STRIKE_SALT` the server accepts.
const int minStrikeSaltLength = 32;

/// The file inside `LUDO_STRIKE_DIR`.
const String strikeFileName = 'strikes.json';

const Duration _day = Duration(days: 1);

/// Item 8: a level-0 record forgets a strike this old.
const Duration _levelZeroWindow = Duration(days: 30);

/// Item 8: a record above level 0 with nothing for this long drops to 0.
const Duration _resetAfter = Duration(days: 365);

/// Item 10: an IP block never lasts longer than this.
const Duration _ipBlockCap = Duration(hours: 24);

/// Item 15 (b): strikes kept in one record, and records kept in the store.
const int _maxStrikesPerRecord = 16;
const int _maxRecords = 100000;

/// One rung of the ladder: how many distinct hosts fire a ban, how long it
/// is, and the level the record has afterwards.
class _Rung {
  const _Rung(this.count, this.length, this.nextLevel);
  final int count;
  final Duration length;
  final int nextLevel;
}

const List<_Rung> _ladder = <_Rung>[
  _Rung(6, _day, 1),
  _Rung(3, Duration(days: 7), 2),
  _Rung(3, Duration(days: 30), 3),
  _Rung(5, Duration(days: 730), 4),
  _Rung(5, Duration(days: 730), 4),
];

/// What a `CODE_BANNED` frame, a `knock_failed` and a `kicked` carry as
/// `ban`, section 32 item 12.
class BanInfo {
  const BanInfo({
    required this.scope,
    required this.untilMs,
    required this.level,
    required this.nextMs,
  });

  /// `"device"` or `"network"`.
  final String scope;

  /// Epoch milliseconds.
  final int untilMs;
  final int level;

  /// Length in milliseconds of the ban the device's next step would give; 0
  /// for a network-only block.
  final int nextMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'scope': scope,
        'until_ms': untilMs,
        'level': level,
        'next_ms': nextMs,
      };
}

class _Strike {
  _Strike(this.atMs, this.host);
  final int atMs;
  final String host;
}

class _Record {
  _Record();

  int level = 0;
  int countedFromMs = 0;
  int banUntilMs = 0;

  /// The last strike or, when none follows it, the last ban start.
  int lastMs = 0;
  List<_Strike> strikes = <_Strike>[];

  Map<String, Object?> toJson() => <String, Object?>{
        'level': level,
        'counted_from': countedFromMs,
        'ban_until': banUntilMs,
        'last': lastMs,
        'strikes': <Object?>[
          for (final _Strike s in strikes)
            <String, Object?>{'at': s.atMs, 'host': s.host},
        ],
      };
}

/// The ladder and its store. With a [dir] the store is the file
/// `strikes.json` in it, loaded at construction and rewritten whole
/// (temporary file, then rename) after every change. Without one it lives in
/// memory.
class StrikeStore {
  /// [dir] set without a valid [salt] (at least [minStrikeSaltLength]
  /// characters) throws a [FormatException] naming the variable. Neither set:
  /// an in-memory store with a random salt per process. A [salt] without a
  /// [dir] is used as given, with the same length rule.
  StrikeStore({
    required Clock clock,
    String? salt,
    String? dir,
    Random? random,
    void Function(String line)? log,
  })  : _clock = clock,
        _dir = dir,
        _log = log ?? _printLine,
        _salt = _resolveSalt(salt, dir, random) {
    _hmac = Hmac(sha256, utf8.encode(_salt));
    if (dir != null) {
      _load();
    }
  }

  final Clock _clock;
  final String? _dir;
  final void Function(String line) _log;
  final String _salt;
  late final Hmac _hmac;

  final Map<String, _Record> _records = <String, _Record>{};
  final Map<String, int> _ipBlocks = <String, int>{};

  static void _printLine(String line) {
    // ignore: avoid_print
    print(line);
  }

  static String _resolveSalt(String? salt, String? dir, Random? random) {
    if (salt != null && salt.isNotEmpty) {
      if (salt.length < minStrikeSaltLength) {
        throw const FormatException(
          'LUDO_STRIKE_SALT is too short: it must be at least '
          '$minStrikeSaltLength characters',
        );
      }
      return salt;
    }
    if (dir != null) {
      throw const FormatException(
        'LUDO_STRIKE_SALT is not set: LUDO_STRIKE_DIR needs a salt of at '
        'least $minStrikeSaltLength characters',
      );
    }
    final Random source = random ?? Random.secure();
    return List<String>.generate(
      minStrikeSaltLength,
      (int _) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// The keyed hash of an install or an IP, lower-case hex.
  String key(String value) => _hmac.convert(utf8.encode(value)).toString();

  /// How many device records are held. For tests and housekeeping only.
  int get recordCount => _records.length;

  /// How many IP blocks are held. For tests and housekeeping only.
  int get ipBlockCount => _ipBlocks.length;

  int get _nowMs => _clock.now.millisecondsSinceEpoch;

  /// The ban that stops a typed code from this device or this IP, or null.
  /// The device's own ban wins when both apply (item 12).
  BanInfo? banFor({String? installKey, String? ipKey}) {
    final int now = _nowMs;
    if (installKey != null) {
      final _Record? record = _records[installKey];
      if (record != null) {
        _age(installKey, record, now);
        final _Record? kept = _records[installKey];
        if (kept != null && kept.banUntilMs > now) {
          return BanInfo(
            scope: 'device',
            untilMs: kept.banUntilMs,
            level: kept.level,
            nextMs: _nextMs(kept.level),
          );
        }
      }
    }
    if (ipKey != null) {
      final int? until = _ipBlocks[ipKey];
      if (until != null && until > now) {
        return BanInfo(scope: 'network', untilMs: until, level: 0, nextMs: 0);
      }
    }
    return null;
  }

  /// Records one strike against [installKey] from the host [hostKey]
  /// (item 7). Returns the device ban the strike fired, or null when it
  /// fired none. [ipKey] is the struck socket's IP, blocked when a ban fires
  /// (item 10); empty means no block.
  BanInfo? recordStrike({
    required String installKey,
    required String hostKey,
    required String ipKey,
  }) {
    final int now = _nowMs;
    _log('strike_store event=strike');
    _Record? record = _records[installKey];
    if (record != null) {
      _age(installKey, record, now);
      record = _records[installKey];
    }
    record ??= _records[installKey] = _Record();
    // Item 15 (b): one strike per host IP key, the latest, at most 16.
    record.strikes.removeWhere((_Strike s) => s.host == hostKey);
    record.strikes.add(_Strike(now, hostKey));
    if (record.strikes.length > _maxStrikesPerRecord) {
      record.strikes.removeRange(
        0,
        record.strikes.length - _maxStrikesPerRecord,
      );
    }
    record.lastMs = now;
    _trimRecords();

    final int countedFrom = record.level == 0
        ? now - _levelZeroWindow.inMilliseconds
        : record.countedFromMs;
    final Set<String> hosts = <String>{
      for (final _Strike s in record.strikes)
        if (s.atMs >= countedFrom) s.host,
    };
    final _Rung rung = _ladder[record.level];
    BanInfo? fired;
    if (hosts.length >= rung.count) {
      record.level = rung.nextLevel;
      record.banUntilMs = now + rung.length.inMilliseconds;
      record.countedFromMs = now;
      record.lastMs = now;
      record.strikes = <_Strike>[];
      if (ipKey.isNotEmpty) {
        final Duration block =
            rung.length > _ipBlockCap ? _ipBlockCap : rung.length;
        final int blockUntil = now + block.inMilliseconds;
        final int? held = _ipBlocks[ipKey];
        if (held == null || held < blockUntil) {
          _ipBlocks[ipKey] = blockUntil;
        }
      }
      _log('strike_store event=ban level=${record.level} '
          'length_ms=${rung.length.inMilliseconds}');
      fired = BanInfo(
        scope: 'device',
        untilMs: record.banUntilMs,
        level: record.level,
        nextMs: _nextMs(record.level),
      );
    }
    _save();
    return fired;
  }

  /// Item 15 (b): at most [_maxRecords] records; the oldest level-0 record
  /// goes first.
  void _trimRecords() {
    while (_records.length > _maxRecords) {
      String? oldest;
      int oldestMs = 0;
      for (final MapEntry<String, _Record> e in _records.entries) {
        if (e.value.level != 0) {
          continue;
        }
        if (oldest == null || e.value.lastMs < oldestMs) {
          oldest = e.key;
          oldestMs = e.value.lastMs;
        }
      }
      if (oldest == null) {
        return;
      }
      _records.remove(oldest);
    }
  }

  /// Item 11's housekeeping: the 30-day and 365-day ageing, and the delete of
  /// an IP once its block has run. Rides the registry's one-second sweep.
  void sweep() {
    final int now = _nowMs;
    final int before = _records.length + _ipBlocks.length;
    bool changed = false;
    for (final String k in List<String>.of(_records.keys)) {
      final _Record record = _records[k]!;
      if (_age(k, record, now, save: false)) {
        changed = true;
      }
    }
    final int blocksBefore = _ipBlocks.length;
    _ipBlocks.removeWhere((String _, int until) => until <= now);
    if (_ipBlocks.length != blocksBefore) {
      changed = true;
    }
    if (changed || before != _records.length + _ipBlocks.length) {
      _save();
    }
  }

  /// Item 8's ageing for one record. A record above level 0 whose last
  /// strike or ban start is more than 365 days old, and whose ban has run
  /// out, drops to level 0 with no strikes; a level-0 record forgets strikes
  /// older than 30 days and is deleted when none is left. Returns whether
  /// anything changed.
  bool _age(String k, _Record record, int now, {bool save = true}) {
    bool changed = false;
    if (record.level > 0 &&
        record.banUntilMs <= now &&
        now - record.lastMs > _resetAfter.inMilliseconds) {
      record.level = 0;
      record.strikes = <_Strike>[];
      record.banUntilMs = 0;
      record.countedFromMs = 0;
      changed = true;
    }
    if (record.level == 0) {
      final int cutoff = now - _levelZeroWindow.inMilliseconds;
      final int count = record.strikes.length;
      record.strikes.removeWhere((_Strike s) => s.atMs < cutoff);
      if (record.strikes.length != count) {
        changed = true;
      }
      if (record.strikes.isEmpty) {
        _records.remove(k);
        changed = true;
      }
    }
    if (changed && save) {
      _save();
    }
    return changed;
  }

  int _nextMs(int level) {
    switch (level) {
      case 1:
        return _ladder[1].length.inMilliseconds;
      case 2:
        return _ladder[2].length.inMilliseconds;
      case 3:
      case 4:
        return _ladder[3].length.inMilliseconds;
      default:
        return 0;
    }
  }

  File? get _file => _dir == null ? null : File('$_dir/$strikeFileName');

  void _load() {
    final File file = _file!;
    Directory(_dir!).createSync(recursive: true);
    if (!file.existsSync()) {
      return;
    }
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?> || decoded['v'] != 1) {
        throw const FormatException('unexpected shape');
      }
      final Object? records = decoded['records'];
      final Object? blocks = decoded['ip_blocks'];
      if (records is! Map<String, Object?> || blocks is! Map<String, Object?>) {
        throw const FormatException('unexpected shape');
      }
      final Map<String, _Record> loadedRecords = <String, _Record>{};
      for (final MapEntry<String, Object?> e in records.entries) {
        final Object? raw = e.value;
        if (raw is! Map<String, Object?>) {
          throw const FormatException('unexpected record');
        }
        final Object? level = raw['level'];
        final Object? countedFrom = raw['counted_from'];
        final Object? banUntil = raw['ban_until'];
        final Object? last = raw['last'];
        final Object? strikes = raw['strikes'];
        if (level is! int ||
            level < 0 ||
            level > 4 ||
            countedFrom is! int ||
            banUntil is! int ||
            last is! int ||
            strikes is! List<Object?>) {
          throw const FormatException('unexpected record');
        }
        final _Record record = _Record()
          ..level = level
          ..countedFromMs = countedFrom
          ..banUntilMs = banUntil
          ..lastMs = last;
        for (final Object? s in strikes) {
          if (s is! Map<String, Object?> ||
              s['at'] is! int ||
              s['host'] is! String) {
            throw const FormatException('unexpected strike');
          }
          record.strikes.add(_Strike(s['at']! as int, s['host']! as String));
        }
        loadedRecords[e.key] = record;
      }
      final Map<String, int> loadedBlocks = <String, int>{};
      for (final MapEntry<String, Object?> e in blocks.entries) {
        final Object? until = e.value;
        if (until is! int) {
          throw const FormatException('unexpected block');
        }
        loadedBlocks[e.key] = until;
      }
      _records.addAll(loadedRecords);
      _trimRecords();
      _ipBlocks.addAll(loadedBlocks);
    } on FormatException {
      _moveAside(file);
    } on FileSystemException catch (error) {
      _log('error: strike store unreadable reason=${error.message}');
      rethrow;
    }
  }

  void _moveAside(File file) {
    final String target = '${file.path}.bad-${_nowMs}';
    file.renameSync(target);
    _records.clear();
    _ipBlocks.clear();
    _log('error: strike store did not parse, moved aside to '
        '$strikeFileName.bad-$_nowMs, starting empty');
  }

  void _save() {
    final File? file = _file;
    if (file == null) {
      return;
    }
    final Map<String, Object?> body = <String, Object?>{
      'v': 1,
      'records': <String, Object?>{
        for (final MapEntry<String, _Record> e in _records.entries)
          e.key: e.value.toJson(),
      },
      'ip_blocks': Map<String, Object?>.of(_ipBlocks),
    };
    final File temporary = File('${file.path}.tmp');
    try {
      temporary.writeAsStringSync(jsonEncode(body), flush: true);
      temporary.renameSync(file.path);
    } on FileSystemException catch (error) {
      // The ladder keeps running from memory; the failure is loud, and the
      // next change tries the write again.
      _log('error: strike store write failed reason=${error.message}');
    }
  }
}
