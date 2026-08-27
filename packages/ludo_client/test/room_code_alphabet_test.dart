import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/room_code.dart';

void main() {
  test('room code alphabet matches docs/PROTOCOL.md section 2 exactly', () {
    // Copied by hand from docs/PROTOCOL.md, section 2, "Identity and the two
    // secrets": "6 characters from the alphabet
    // `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` -- 32 symbols. `0`, `O`, `1` and `I`
    // are all excluded. `L` is kept deliberately."
    //
    // This is the one place the client's alphabet is checked against the
    // spec rather than against itself. If docs/PROTOCOL.md section 2 ever
    // changes, this literal and lib/src/room_code.dart change together, on
    // purpose, in the same change.
    const documentedAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    expect(roomCodeAlphabet, documentedAlphabet);
    expect(roomCodeAlphabet.length, 32);
    expect(roomCodeAlphabet.contains('0'), isFalse);
    expect(roomCodeAlphabet.contains('O'), isFalse);
    expect(roomCodeAlphabet.contains('1'), isFalse);
    expect(roomCodeAlphabet.contains('I'), isFalse);
    expect(roomCodeAlphabet.contains('L'), isTrue);
  });
}
