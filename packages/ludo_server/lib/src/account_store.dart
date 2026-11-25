// docs/PROTOCOL.md section 36.1 and 36.4: one JSON file per account.
//
// The file's name is HMAC-SHA256(key = salt, message = "google:" + sub) as 64
// lowercase hex characters, and that is the account's only id. The file holds
// `name`, `created_ms` and `last_ms` and nothing else. Neither the raw `sub`
// nor the hash is ever written to a log line or an error message here; a
// failure surfaces as the I/O exception the operating system raised, for the
// caller to log by class only.
//
// Every method is synchronous, so two calls never interleave in this isolate.
// Time comes from the injected `Clock`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;

import 'clock.dart';

/// Section 36.2: the shortest `LUDO_ACCOUNT_SALT` the server accepts.
const int minAccountSaltLength = 32;

class AccountStore {
  AccountStore({
    required Directory dir,
    required String salt,
    required Clock clock,
  })  : _dir = dir,
        _hmac = Hmac(sha256, utf8.encode(salt)),
        _clock = clock {
    if (!_dir.existsSync()) {
      _dir.createSync(recursive: true);
      _chmod('700', _dir.path);
    }
  }

  final Directory _dir;
  final Hmac _hmac;
  final Clock _clock;
  final Random _random = Random.secure();

  /// Section 36.1.3: the account's file name, 64 lowercase hex characters.
  String hashOf(String sub) =>
      _hmac.convert(utf8.encode('google:$sub')).toString();

  /// Creates the account, or updates its name and last sign-in time and keeps
  /// its creation time. Writes a temporary file in the same directory and
  /// renames it over the old one, mode 0600. Throws on I/O failure.
  void upsert(String sub, String name) {
    final String hash = hashOf(sub);
    final File target = File('${_dir.path}/$hash');
    final int now = _clock.now.millisecondsSinceEpoch;
    final int created = _createdOf(target) ?? now;
    final String body = jsonEncode(<String, Object?>{
      'name': name,
      'created_ms': created,
      'last_ms': now,
    });
    final File temporary =
        File('${_dir.path}/.tmp-${_random.nextInt(1 << 32).toRadixString(16)}');
    try {
      temporary.writeAsStringSync(body, flush: true);
      _chmod('600', temporary.path);
      temporary.renameSync(target.path);
    } on Object {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      rethrow;
    }
  }

  /// Removes the account's file. True when one was removed, false when there
  /// was none. Throws on I/O failure.
  bool delete(String sub) {
    final File target = File('${_dir.path}/${hashOf(sub)}');
    if (!target.existsSync()) {
      return false;
    }
    target.deleteSync();
    return true;
  }

  /// The `created_ms` of an existing account, or null when there is no file
  /// or it holds no readable one (it is then written afresh).
  int? _createdOf(File file) {
    if (!file.existsSync()) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        final Object? created = decoded['created_ms'];
        if (created is int) {
          return created;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Dart has no chmod of its own; the image carries coreutils. A failure is
  /// an I/O failure like any other.
  void _chmod(String mode, String path) {
    final ProcessResult result = Process.runSync('chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('chmod failed', path);
    }
  }
}
