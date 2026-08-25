// docs/PROTOCOL.md section 2. The seat token: long, opaque, never shown to
// a human, and the only thing that reclaims a seat after a disconnect.

import 'dart:convert';
import 'dart:math';

/// A base64url string with no padding, encoding 32 CSPRNG bytes. That is
/// 43 characters from `[A-Za-z0-9_-]`.
const int _seatTokenBytes = 32;
const int _seatTokenLength = 43;

/// Draws a fresh seat token from [secure]. 32 bytes, base64url, unpadded.
String generateSeatToken(Random secure) {
  final bytes = List<int>.generate(
    _seatTokenBytes,
    (int _) => secure.nextInt(256),
  );
  final encoded = base64Url.encode(bytes);
  final padStart = encoded.indexOf('=');
  return padStart == -1 ? encoded : encoded.substring(0, padStart);
}

final RegExp _seatTokenPattern = RegExp(r'^[A-Za-z0-9_-]+$');

/// Shape only: length and alphabet. This does not mean the token matches a
/// live seat.
bool isWellFormedSeatToken(String candidate) {
  if (candidate.length != _seatTokenLength) {
    return false;
  }
  return _seatTokenPattern.hasMatch(candidate);
}
