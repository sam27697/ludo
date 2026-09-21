// Durable last-create defaults and recent join codes for HomeScreen.
// SharedPreferences is the store (D-C1-02): last name, seat count, and
// recent room codes survive a process kill so a returning host or joiner
// is not asked to type them again. Nothing here talks to the server or
// records analytics.

import 'package:shared_preferences/shared_preferences.dart';

/// On-device memory of the last successful Create Room and recent
/// successful Join codes.
///
/// [load], [recordSuccessfulCreate] and [recordSuccessfulJoin] are the
/// writers and readers. A later [load] on a fresh instance returns the
/// name and seats the previous [recordSuccessfulCreate] wrote, and the
/// recent codes [recordSuccessfulJoin] wrote (newest first, at most 3).
class SessionMemory {
  const SessionMemory({
    this.lastName,
    this.lastSeats,
    this.recentCodes = const <String>[],
  });

  static const String _nameKey = 'session.lastName';
  static const String _seatsKey = 'session.lastSeats';
  static const String _codesKey = 'session.recentCodes';
  static const int _maxRecentCodes = 3;

  /// Name sent on the last successful create. Null when nothing is stored.
  final String? lastName;

  /// Seat count sent on the last successful create. Null when nothing is
  /// stored.
  final int? lastSeats;

  /// Room codes of recent successful joins, newest first, at most 3.
  /// Empty when nothing is stored.
  final List<String> recentCodes;

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
      );
    } on Object {
      return const SessionMemory();
    }
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
