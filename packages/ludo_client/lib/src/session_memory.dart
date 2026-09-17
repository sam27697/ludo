// Durable last-create defaults for HomeScreen. SharedPreferences is the
// store (D-C1-02): last name and seat count survive a process kill so a
// returning host is not asked to type them again. Nothing here talks to
// the server or records analytics.

import 'package:shared_preferences/shared_preferences.dart';

/// On-device memory of the last successful Create Room.
///
/// [load] and [recordSuccessfulCreate] are the only writers and readers.
/// A later [load] on a fresh instance returns the name and seats the
/// previous [recordSuccessfulCreate] wrote.
class SessionMemory {
  const SessionMemory({this.lastName, this.lastSeats});

  static const String _nameKey = 'session.lastName';
  static const String _seatsKey = 'session.lastSeats';

  /// Name sent on the last successful create. Null when nothing is stored.
  final String? lastName;

  /// Seat count sent on the last successful create. Null when nothing is
  /// stored.
  final int? lastSeats;

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
}
