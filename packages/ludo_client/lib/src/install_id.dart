// docs/PROTOCOL.md section 31 item 2: the random id this install sends as
// `install` on every `join_room`, so the server can bar a kicked or refused
// install without ever learning who it is. Made on first use, kept in
// SharedPreferences, never logged, never shown.

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// The SharedPreferences key the id is kept under.
const String kInstallIdKey = 'install_id';

const String _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';

/// Section 31 item 2: 16 to 64 characters of `[A-Za-z0-9_-]`.
final RegExp _installShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// The id once this process has read or made it. [installIdIfReady] hands it
/// out without waiting. When the platform store is unusable this is the
/// process-only id and is never written anywhere.
String? _known;

String _newInstallId() {
  final Random random = Random.secure();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < 32; i++) {
    buffer.write(_alphabet[random.nextInt(_alphabet.length)]);
  }
  return buffer.toString();
}

/// The install id: read from the store, or made (32 random characters from
/// `Random.secure()`) and stored on first use. A stored value of the wrong
/// shape is replaced. When the platform store cannot be used at all, the id
/// lives for the process only, the same way [SessionMemory] treats an unusable
/// store: the id is optional on the wire, so a join must not fail for it.
Future<String> installId() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? stored = prefs.getString(kInstallIdKey);
    if (stored != null && _installShape.hasMatch(stored)) {
      return _known = stored;
    }
    final String made = _newInstallId();
    _known = made;
    await prefs.setString(kInstallIdKey, made);
    return made;
  } on Object {
    return _known ??= _newInstallId();
  }
}

/// The id when this process has already read or made it, otherwise null.
/// Never waits on the platform store: a join must not hang behind a store
/// that never answers. [installId] is called early (at startup and when a
/// room controller is made) so that this is set long before any join.
String? installIdIfReady() => _known;
