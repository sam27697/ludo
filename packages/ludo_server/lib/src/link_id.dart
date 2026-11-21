// docs/PROTOCOL.md section 31 item 1. The room link id: the creation time in
// whole seconds since the epoch in base 36 lowercase, a `-`, then six random
// characters of `[a-z0-9]`. The time part keeps ids unique across the
// server's history, the random part keeps them unguessable. It is never
// derived from the room code, and the code never appears in a link.

import 'dart:math';

/// The 36 symbols of the random part.
const String linkIdAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

const int linkIdRandomLength = 6;

/// Draws a link id for a room created at [createdAt]. Pure: it knows nothing
/// about which ids were already issued; the registry handles collisions.
String generateLinkId(Random secure, DateTime createdAt) {
  final int seconds = createdAt.millisecondsSinceEpoch ~/ 1000;
  final StringBuffer buffer = StringBuffer(seconds.toRadixString(36))
    ..write('-');
  for (int i = 0; i < linkIdRandomLength; i++) {
    buffer.write(linkIdAlphabet[secure.nextInt(linkIdAlphabet.length)]);
  }
  return buffer.toString();
}

final RegExp _linkIdShape = RegExp(r'^[0-9a-z]{4,10}-[0-9a-z]{6}$');

/// Shape only. This does not mean a room with this link id exists.
bool isWellFormedLinkId(String candidate) => _linkIdShape.hasMatch(candidate);
