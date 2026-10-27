// Durable last-create defaults, recent join codes and the current seat for
// HomeScreen. SharedPreferences is the store
// (D-C1-02): last name, seat count, recent room codes and the seat record
// survive a process kill so a returning host or joiner is not asked to
// type them again and a resumed session is not asked to rejoin from
// scratch. The seat record is a short-lived capability for one friends'
// room; it stays on this device, in app-private storage, and is sent only
// back to the server that issued it. Nothing here talks to the server or
// records analytics.

import 'package:shared_preferences/shared_preferences.dart';

import 'room_code.dart';

/// How long a finished game's verify link survives on the device (C-322
/// rule 4). Matches docs/VERIFY.md `verifyRetention`: "records are kept
/// for 90 days" on the server side; home follows the same window so it
/// never offers a link the server has already reaped.
const Duration kVerifyRetention = Duration(days: 90);

/// How often Home rewrites an unchanged seat record while connected (C-451
/// D6): a controller notification arriving at least this long after Home's
/// last write refreshes the saved time. Nothing else writes more often.
const Duration kSeatRecordRefresh = Duration(minutes: 1);

/// How long a stored seat record is trusted (C-447 D2, C-451 D7). The age is
/// the time since this phone last held the seat while connected: Home
/// rewrites the record at least every [kSeatRecordRefresh] while its
/// controller is connected to a room that is not finished, so the saved time
/// stays within a minute of the last moment the seat was held.
/// [SessionMemory.load] treats a record at least this old as absent and
/// clears it. Sixty minutes because a phone away from a live game for an hour
/// has had every turn played by the server's timer, and a record that old is
/// far more likely to name a room the server has reaped than a live one.
const Duration kSeatRecordMaxAge = Duration(minutes: 60);

/// A seat held on the server, kept so a killed and relaunched app can send
/// `resume` for it. [seatToken] is a capability, so [toString] omits it.
class SeatRecord {
  const SeatRecord({
    required this.code,
    required this.seat,
    required this.seatToken,
  });

  /// The room this seat was taken in.
  final String code;

  /// The seat index within the room, `0..3`.
  final int seat;

  /// The capability `resume` is sent with. Never printed.
  final String seatToken;

  @override
  bool operator ==(Object other) {
    return other is SeatRecord &&
        other.code == code &&
        other.seat == seat &&
        other.seatToken == seatToken;
  }

  @override
  int get hashCode => Object.hash(code, seat, seatToken);

  @override
  String toString() => 'SeatRecord(code: $code, seat: $seat)';
}

/// The device's memory of the last finished game's verify link (C-322).
/// Equality and [hashCode] are value based on all four fields; the url is
/// already public by design (a permalink for strangers), so unlike
/// [SeatRecord] nothing here is omitted from [toString].
class LastGame {
  const LastGame({
    required this.gameId,
    required this.verifyUrl,
    required this.finishedAt,
    required this.won,
  });

  /// The finished game this verify link belongs to.
  final String gameId;

  /// The server's permalink to this game's rolls.
  final String verifyUrl;

  /// When this screen observed the game as finished, from the clock
  /// [HomeScreen] was built with.
  final DateTime finishedAt;

  /// Whether the player who held this device won that game.
  final bool won;

  @override
  bool operator ==(Object other) {
    return other is LastGame &&
        other.gameId == gameId &&
        other.verifyUrl == verifyUrl &&
        other.finishedAt == finishedAt &&
        other.won == won;
  }

  @override
  int get hashCode => Object.hash(gameId, verifyUrl, finishedAt, won);

  @override
  String toString() =>
      'LastGame(gameId: $gameId, verifyUrl: $verifyUrl, '
      'finishedAt: $finishedAt, won: $won)';
}

/// On-device memory of the last successful Create Room, recent successful
/// Join codes, the currently held seat, and the last finished game's
/// verify link.
///
/// [load], [recordSuccessfulCreate] and [recordSuccessfulJoin] are the
/// writers and readers. A later [load] on a fresh instance returns the
/// name and seats the previous [recordSuccessfulCreate] wrote, the name
/// a previous [recordSuccessfulJoin] wrote when it was given one, and the
/// recent codes [recordSuccessfulJoin] wrote (newest first, at most 3).
/// [recordSeat] and [clearSeat] write and remove the seat record that a
/// later [load] returns as [seatRecord]; [recordSeat] also stamps the time it
/// wrote, which a later [load] returns as [seatSavedAt]. [recordLastGame] writes the one
/// record a later [load] returns as [lastGame]; clearing the seat does not
/// touch it. [recordHintUsed] stores the one game id whose hint was spent;
/// [hintUsedGameId] reads it. Unreadable storage reads as not used and
/// never throws (C-471 D5).
class SessionMemory {
  const SessionMemory({
    this.lastName,
    this.lastSeats,
    this.recentCodes = const <String>[],
    this.seatRecord,
    this.seatSavedAt,
    this.lastGame,
  });

  static const String _nameKey = 'session.lastName';
  static const String _seatsKey = 'session.lastSeats';
  static const String _codesKey = 'session.recentCodes';
  static const String _seatKey = 'session.seat';
  static const String _seatSavedAtKey = 'session.seatSavedAt';
  static const String _lastGameKey = 'session.lastGame';

  /// C-471 D5: the last game id the one hint was spent in.
  static const String _hintUsedGameKey = 'session.hintUsedGame';
  static const int _maxRecentCodes = 3;

  /// Name sent on the last successful create, or on the last successful
  /// join that was given a name. Null when nothing is stored.
  final String? lastName;

  /// Seat count sent on the last successful create. Null when nothing is
  /// stored.
  final int? lastSeats;

  /// Room codes of recent successful joins, newest first, at most 3.
  /// Empty when nothing is stored.
  final List<String> recentCodes;

  /// The seat currently held, if the stored value is well formed. Null
  /// when nothing is stored or the stored value cannot be trusted.
  final SeatRecord? seatRecord;

  /// When [recordSeat] wrote [seatRecord], as the clock [recordSeat] was
  /// given read it. Null when the key is absent or not an integer, which is
  /// the case for a record written by v1.18.0 or older (C-447 D1, D2).
  final DateTime? seatSavedAt;

  /// The last finished game's verify link, if the stored value is well
  /// formed. Null when nothing is stored or the stored value cannot be
  /// trusted.
  final LastGame? lastGame;

  /// True when Home can show `home-last-table-chip` from this snapshot.
  bool get hasLastTable {
    final String? name = lastName;
    final int? seats = lastSeats;
    return name != null &&
        name.isNotEmpty &&
        seats != null &&
        seats >= 2 &&
        seats <= 4;
  }

  /// Reads the store. Missing or unusable platform storage returns an
  /// empty snapshot rather than throwing, so Home still paints.
  ///
  /// C-447 D2: a seat record whose saved time is at least
  /// [kSeatRecordMaxAge] before [clock]'s "now" (the wall clock when null)
  /// is returned as absent and removed from the store, both keys. A record
  /// with no saved time is kept as it is.
  static Future<SessionMemory> load({DateTime Function()? clock}) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      SeatRecord? seatRecord = _readSeatRecord(prefs);
      DateTime? seatSavedAt = _readSeatSavedAt(prefs);
      if (seatRecord != null && seatSavedAt != null) {
        final DateTime now = (clock ?? DateTime.now)();
        if (now.difference(seatSavedAt) >= kSeatRecordMaxAge) {
          await prefs.remove(_seatKey);
          await prefs.remove(_seatSavedAtKey);
          seatRecord = null;
          seatSavedAt = null;
        }
      }
      return SessionMemory(
        lastName: prefs.getString(_nameKey),
        lastSeats: prefs.getInt(_seatsKey),
        recentCodes: _cappedRecentCodes(
          prefs.getStringList(_codesKey) ?? const <String>[],
        ),
        seatRecord: seatRecord,
        seatSavedAt: seatSavedAt,
        lastGame: _readLastGame(prefs),
      );
    } on Object {
      return const SessionMemory();
    }
  }

  /// The stored seat time, isolated the same way [_readSeatRecord] is. A
  /// value that is absent or not an integer yields null.
  static DateTime? _readSeatSavedAt(SharedPreferences prefs) {
    try {
      final Object? raw = prefs.get(_seatSavedAtKey);
      if (raw is! int) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(raw);
    } on Object {
      return null;
    }
  }

  /// The stored seat record, if any, isolated so that a stored value of the
  /// wrong type (which makes the platform's own `getStringList` throw)
  /// yields `null` here without disturbing the rest of [load].
  static SeatRecord? _readSeatRecord(SharedPreferences prefs) {
    try {
      return _seatRecordFrom(prefs.getStringList(_seatKey));
    } on Object {
      return null;
    }
  }

  /// Writes [record] under the single seat key, replacing any previous
  /// record, and the time it wrote (milliseconds since epoch, read from
  /// [clock], the wall clock when null) under a second key (C-447 D1). The
  /// seat key keeps exactly `[code, seat, seatToken]`. Never throws: an
  /// unusable store is swallowed, same as [recordSuccessfulCreate].
  static Future<void> recordSeat(
    SeatRecord record, {
    DateTime Function()? clock,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_seatKey, <String>[
        record.code,
        record.seat.toString(),
        record.seatToken,
      ]);
      await prefs.setInt(
        _seatSavedAtKey,
        (clock ?? DateTime.now)().millisecondsSinceEpoch,
      );
    } on Object {
      return;
    }
  }

  /// The stored last game, if any, isolated the same way [_readSeatRecord]
  /// is: a stored value of the wrong type (which makes the platform's own
  /// `getStringList` throw) yields `null` here without disturbing the rest
  /// of [load].
  static LastGame? _readLastGame(SharedPreferences prefs) {
    try {
      return _lastGameFrom(prefs.getStringList(_lastGameKey));
    } on Object {
      return null;
    }
  }

  /// Writes [game] under the single last-game key, replacing any previous
  /// record (C-322 rule 1: only one is kept). Never throws, same as
  /// [recordSeat].
  static Future<void> recordLastGame(LastGame game) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_lastGameKey, <String>[
        game.gameId,
        game.verifyUrl,
        game.finishedAt.millisecondsSinceEpoch.toString(),
        game.won ? 'won' : 'lost',
      ]);
    } on Object {
      return;
    }
  }

  /// A [LastGame] from [raw] when it is exactly four strings shaped as
  /// `[gameId, verifyUrl, finishedAtMillis, 'won' or 'lost']`, with a
  /// non-empty gameId and verifyUrl and a finishedAtMillis that parses as
  /// an integer. Anything else (wrong length, non-integer time, another
  /// outcome word, empty id or url) is not trusted and yields null.
  static LastGame? _lastGameFrom(List<String>? raw) {
    if (raw == null || raw.length != 4) {
      return null;
    }
    final String gameId = raw[0];
    final String verifyUrl = raw[1];
    final String finishedAtText = raw[2];
    final String outcomeText = raw[3];
    if (gameId.isEmpty || verifyUrl.isEmpty) {
      return null;
    }
    final int? millis = int.tryParse(finishedAtText);
    if (millis == null) {
      return null;
    }
    final bool won;
    if (outcomeText == 'won') {
      won = true;
    } else if (outcomeText == 'lost') {
      won = false;
    } else {
      return null;
    }
    return LastGame(
      gameId: gameId,
      verifyUrl: verifyUrl,
      finishedAt: DateTime.fromMillisecondsSinceEpoch(millis),
      won: won,
    );
  }

  /// Removes the stored seat record and its saved time, if any. Never
  /// throws, and clearing when nothing is stored is not an error.
  static Future<void> clearSeat() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_seatKey);
      await prefs.remove(_seatSavedAtKey);
    } on Object {
      return;
    }
  }

  /// A [SeatRecord] from [raw] when it is exactly three strings shaped as
  /// `[code, seat, seatToken]` with a valid room code, a seat in `0..3`
  /// written with no sign, space or extra leading zero, and a non-empty
  /// token. Anything else is not trusted and yields null.
  static SeatRecord? _seatRecordFrom(List<String>? raw) {
    if (raw == null || raw.length != 3) {
      return null;
    }
    final String code = raw[0];
    final String seatText = raw[1];
    final String seatToken = raw[2];
    if (!isValidRoomCode(code)) {
      return null;
    }
    if (seatToken.isEmpty) {
      return null;
    }
    if (!RegExp(r'^(0|[1-3])$').hasMatch(seatText)) {
      return null;
    }
    final int? seat = int.tryParse(seatText);
    if (seat == null || seat < 0 || seat > 3) {
      return null;
    }
    return SeatRecord(code: code, seat: seat, seatToken: seatToken);
  }

  /// Writes [name] and [seats] so a later [load] can restore them.
  static Future<void> recordSuccessfulCreate({
    required String name,
    required int seats,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_nameKey, name);
      await prefs.setInt(_seatsKey, seats);
    } on Object {
      return;
    }
  }

  /// Writes [code] to the front of the recent list so a later [load]
  /// restores it newest-first, unique, and at most [_maxRecentCodes].
  /// When [name] is given, also stores it as [lastName]. Never writes or
  /// clears the stored seat count. Callers that omit [name] leave whatever
  /// name is already stored untouched.
  static Future<void> recordSuccessfulJoin(String code, {String? name}) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> next = prependRecentCode(
        prefs.getStringList(_codesKey) ?? const <String>[],
        code,
      );
      await prefs.setStringList(_codesKey, next);
      if (name != null) {
        await prefs.setString(_nameKey, name);
      }
    } on Object {
      return;
    }
  }

  /// [existing] with [code] first, duplicates removed, length at most 3.
  static List<String> prependRecentCode(List<String> existing, String code) {
    return _cappedRecentCodes(<String>[code, ...existing]);
  }

  /// Writes [gameId] as the game whose hint was spent, replacing any
  /// previous id (C-471 D5). Never throws: an unusable store is swallowed,
  /// same as [recordSeat].
  static Future<void> recordHintUsed(String gameId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hintUsedGameKey, gameId);
    } on Object {
      return;
    }
  }

  /// The game id [recordHintUsed] last wrote, or null when the key is
  /// absent or the store cannot be read (C-471 D5). A value of the wrong
  /// type reads as not used and does not throw.
  static Future<String?> hintUsedGameId() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Object? raw = prefs.get(_hintUsedGameKey);
      if (raw is! String) {
        return null;
      }
      return raw;
    } on Object {
      return null;
    }
  }

  static List<String> _cappedRecentCodes(List<String> raw) {
    final List<String> next = <String>[];
    for (final String code in raw) {
      if (code.isEmpty || next.contains(code)) {
        continue;
      }
      next.add(code);
      if (next.length >= _maxRecentCodes) {
        break;
      }
    }
    return next;
  }
}
