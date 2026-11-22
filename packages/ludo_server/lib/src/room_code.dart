// docs/PROTOCOL.md section 32 items 1, 2 and 4. The room code is a numeral in
// a 33-symbol alphabet (the digits and the letters without I, L and O), most
// significant symbol first, with no leading `0` except the code `0` itself.
// The codes in order are `0` .. `Z`, then `10` .. `ZZ`, then `100` and so on.

/// 33 symbols, in numeral order.
const String roomCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTUVWXYZ';

/// The longest code a typed `code` may be and still reach the lookup.
const int roomCodeLength = 6;

/// The code that is the [index]th in order, counting from 0: `0` is index 0,
/// `Z` is 32, `10` is 33. [index] must not be negative.
String roomCodeForIndex(int index) {
  if (index < 0) {
    throw ArgumentError.value(index, 'index', 'must not be negative');
  }
  final int base = roomCodeAlphabet.length;
  if (index == 0) {
    return roomCodeAlphabet[0];
  }
  final List<String> symbols = <String>[];
  int rest = index;
  while (rest > 0) {
    symbols.add(roomCodeAlphabet[rest % base]);
    rest ~/= base;
  }
  return symbols.reversed.join();
}

/// Section 32 item 4: surrounding whitespace dropped, letters upper-cased,
/// `O` read as `0`, `I` and `L` read as `1`. The result may still be
/// malformed; the lookup answers that the same way it answers absence.
String foldRoomCode(String raw) {
  final String upper = raw.trim().toUpperCase();
  final StringBuffer out = StringBuffer();
  for (final int unit in upper.codeUnits) {
    final String ch = String.fromCharCode(unit);
    switch (ch) {
      case 'O':
        out.write('0');
      case 'I':
      case 'L':
        out.write('1');
      default:
        out.write(ch);
    }
  }
  return out.toString();
}

/// Length (1 to [roomCodeLength]) and alphabet only. This does not mean a room
/// with this code exists, and a leading `0` before another symbol is
/// well-formed here though never issued.
bool isWellFormedRoomCode(String candidate) {
  if (candidate.isEmpty || candidate.length > roomCodeLength) {
    return false;
  }
  for (var i = 0; i < candidate.length; i++) {
    if (!roomCodeAlphabet.contains(candidate[i])) {
      return false;
    }
  }
  return true;
}
