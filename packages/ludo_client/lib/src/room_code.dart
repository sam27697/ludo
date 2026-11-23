/// Room code shape, duplicated from the server's own alphabet because this
/// client cannot depend on the server package.
///
/// Copied from docs/PROTOCOL.md section 32 item 1: 1 to 6 symbols from
/// `0123456789ABCDEFGHJKMNPQRSTUVWXYZ` (33 symbols), the digits and the
/// letters without `I`, `L` and `O`. The server folds `O` to `0` and `I` and
/// `L` to `1` before every lookup (item 4), and so does [normalizeRoomCode].
///
/// This duplication is contained by test/room_code_alphabet_test.dart, which
/// asserts this constant against the documented alphabet. If docs/PROTOCOL.md
/// section 32 ever changes, that test and this constant change together.
const String roomCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTUVWXYZ';

/// The longest a room code can be. The shortest is one symbol.
const int roomCodeLength = 6;

/// Upper-cases a raw room code, strips spaces and dashes, and folds `O` to
/// `0` and `I` and `L` to `1`, so a code dictated over a phone call and typed
/// back with a dash or a look-alike letter still validates.
String normalizeRoomCode(String raw) {
  return raw
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll('O', '0')
      .replaceAll('I', '1')
      .replaceAll('L', '1');
}

/// True if [code] is a syntactically valid room code: 1 to
/// [roomCodeLength] characters, every one of them from [roomCodeAlphabet].
///
/// This is a local shape check only. It says nothing about whether a room
/// with this code exists, is full, or has expired; only the server knows
/// that.
bool isValidRoomCode(String code) {
  if (code.isEmpty || code.length > roomCodeLength) {
    return false;
  }
  for (final char in code.split('')) {
    if (!roomCodeAlphabet.contains(char)) {
      return false;
    }
  }
  return true;
}
