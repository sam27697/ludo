// docs/PROTOCOL.md section 2. The room code: short, dictatable, and drawn
// from an alphabet with the visually confusable characters removed: no
// 0/O, no 1/I. L is kept on purpose -- with 1 gone there is nothing left for
// it to be confused with, and dropping it would leave 31 symbols, not 32.

import 'dart:math';

/// 32 symbols. No `0`/`O`, no `1`/`I`. `L` is deliberate, see above.
const String roomCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const int roomCodeLength = 6;

/// Draws a fresh room code from [secure]. This is a pure draw: it knows
/// nothing about which codes are already live or quarantined. Collision
/// handling against the registry's own state is the registry's job.
String generateRoomCode(Random secure) {
  final buffer = StringBuffer();
  for (var i = 0; i < roomCodeLength; i++) {
    buffer.write(roomCodeAlphabet[secure.nextInt(roomCodeAlphabet.length)]);
  }
  return buffer.toString();
}

/// Length and alphabet only. This does not mean a room with this code
/// exists.
bool isWellFormedRoomCode(String candidate) {
  if (candidate.length != roomCodeLength) {
    return false;
  }
  for (var i = 0; i < candidate.length; i++) {
    if (!roomCodeAlphabet.contains(candidate[i])) {
      return false;
    }
  }
  return true;
}
