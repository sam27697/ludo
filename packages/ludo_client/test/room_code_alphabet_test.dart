import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/room_code.dart';

void main() {
  test('room code alphabet matches docs/PROTOCOL.md section 32 exactly', () {
    // Copied by hand from docs/PROTOCOL.md, section 32 item 1: "33 symbols,
    // `0123456789ABCDEFGHJKMNPQRSTUVWXYZ`: the digits and the letters without
    // `I`, `L` and `O`." This replaces section 2's 32-symbol alphabet.
    //
    // This is the one place the client's alphabet is checked against the
    // spec rather than against itself. If docs/PROTOCOL.md ever changes it,
    // this literal and lib/src/room_code.dart change together, on purpose.
    const documentedAlphabet = '0123456789ABCDEFGHJKMNPQRSTUVWXYZ';

    expect(roomCodeAlphabet, documentedAlphabet);
    expect(roomCodeAlphabet.length, 33);
    expect(roomCodeAlphabet.contains('0'), isTrue);
    expect(roomCodeAlphabet.contains('1'), isTrue);
    expect(roomCodeAlphabet.contains('O'), isFalse);
    expect(roomCodeAlphabet.contains('I'), isFalse);
    expect(roomCodeAlphabet.contains('L'), isFalse);
  });
}
