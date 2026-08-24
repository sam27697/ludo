// docs/ENGINE_API.md section 8: FNV-1a, 64-bit, over the UTF-8 bytes of the
// canonical JSON text of toJson() -- keys in the documented order, no
// whitespace, no trailing newline -- as exactly 16 lowercase hex characters.

import 'dart:convert';

import 'game_state.dart';

const int _fnvOffsetBasis = 0xCBF29CE484222325;
const int _fnvPrime = 0x00000100000001B3;
const String _hexDigits = '0123456789abcdef';

String stateHash(GameState state) {
  final canonicalJson = jsonEncode(state.toJson());
  final bytes = utf8.encode(canonicalJson);
  var h = _fnvOffsetBasis;
  for (final b in bytes) {
    h = h ^ b;
    h = h * _fnvPrime;
  }
  return _toHex16(h);
}

/// Renders the 64-bit two's complement bit pattern of [value] as 16
/// lowercase hex characters. Deliberately not `toRadixString`, which on a
/// negative int prints a sign and the magnitude rather than the bit
/// pattern.
String _toHex16(int value) {
  final buffer = StringBuffer();
  for (var shift = 60; shift >= 0; shift -= 4) {
    buffer.write(_hexDigits[(value >>> shift) & 0xF]);
  }
  return buffer.toString();
}
