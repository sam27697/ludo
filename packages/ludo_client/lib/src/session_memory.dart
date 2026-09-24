// Durable last-create defaults, recent join codes and the current seat for
// HomeScreen and the room controller. SharedPreferences is the store
// (D-C1-02): last name, seat count, recent room codes and the seat record
// survive a process kill so a returning host or joiner is not asked to
// type them again and a resumed session is not asked to rejoin from
// scratch. The seat record is a short-lived capability for one friends'
// room; it stays on this device, in app-private storage, and is sent only
// back to the server that issued it. Nothing here talks to the server or
// records analytics.

import 'package:shared_preferences/shared_preferences.dart';

import 'room_code.dart';

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

/// On-device memory of the last successful Create Room, recent successful
/// Join codes, and the currently held seat.
///
/// [load], [recordSuccessfulCreate] and [recordSuccessfulJoin] are the
/// writers and readers. A later [load] on a fresh instance returns the
/// name and seats the previous [recordSuccessfulCreate] wrote, and the
/// recent codes [recordSuccessfulJoin] wrote (newest first, at most 3).
/// [recordSeat] and [clearSeat] write and remove the seat record that a
/// later [load] returns as [seatRecord].
class SessionMemory {
  const SessionMemory({
    this.lastName,
    this.lastSeats,
    this.recentCodes = const <String>[],
    this.seatRecord,
  });

  static const String _nameKey = 'session.lastName';
  static const String _seatsKey = 'session.lastSeats';
  static const String _codesKey = 'session.recentCodes';
  static const String _seatKey = 'session.seat';
  static const int _maxRecentCodes = 3;

  /// Name sent on the last successful create. Null when nothing is stored.
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
  static Future<SessionMemory> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return SessionMemory(
        lastName: prefs.getString(_nameKey),
        lastSeats: prefs.getInt(_seatsKey),
        recentCodes: _cappedRecentCodes(
          prefs.getStringList(_codesKey) ?? const <String>[],
        ),
        seatRecord: _seatRecordFrom(prefs.getStringList(_seatKey)),
      );
    } on Object {
      return const SessionMemory();
    }
  }

  /// Writes [record] under the single seat key, replacing any previous
  /// record. Never throws: an unusable store is swallowed, same as
  /// [recordSuccessfulCreate].
  static Future<void> recordSeat(SeatRecord record) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_seatKey, <String>[
        record.code,
        record.seat.toString(),
        record.seatToken,
      ]);
    } on Object {
      return;
    }
  }

  /// Removes the stored seat record, if any. Never throws, and clearing
  /// when nothing is stored is not an error.
  static Future<void> clearSeat() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_seatKey);
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
  static Future<void> recordSuccessfulJoin(String code) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> next = prependRecentCode(
        prefs.getStringList(_codesKey) ?? const <String>[],
        code,
      );
      await prefs.setStringList(_codesKey, next);
    } on Object {
      return;
    }
  }

  /// [existing] with [code] first, duplicates removed, length at most 3.
  static List<String> prependRecentCode(List<String> existing, String code) {
    return _cappedRecentCodes(<String>[code, ...existing]);
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
