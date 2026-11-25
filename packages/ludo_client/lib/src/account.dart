// The optional Google sign-in (docs/PROTOCOL.md section 36.6). The app plays
// the same without it. This service asks the server whether sign-in is
// offered at all, takes an ID token from Google when the player asks for
// one, hands it to the server, and keeps on the device only "signed in" and
// the name. It never keeps, logs or shows a token, and it decides nothing:
// the server says whether a token is good.
//
// Home shows the last-game card only to a signed-in player.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen.dart' show kNameMaxUnits;
import 'server_config.dart' as server_config;
import 'session_memory.dart';

/// Where an ID token comes from. The real one is over the `google_sign_in`
/// plugin (google_id_token.dart); tests give their own.
abstract class GoogleIdTokenSource {
  /// An ID token whose `aud` is [serverClientId], or null when the player
  /// backed out. Throws on any other failure.
  Future<String?> idToken(String serverClientId);

  Future<void> signOut();
}

/// One HTTPS call to the game server's origin.
typedef AccountHttp = Future<({int status, String body})> Function(
  String method,
  Uri url, {
  String? jsonBody,
});

/// How a sign-in or a deletion ended.
enum AccountOutcome { ok, cancelled, failed, unavailable }

/// The longest an account call may take before it counts as failed.
const Duration kAccountTimeout = Duration(seconds: 10);

/// SharedPreferences keys. Nothing else is stored, and never a token.
const String kAccountSignedInKey = 'account.signed_in';
const String kAccountNameKey = 'account.name';

/// The real [AccountHttp]: dart:io, no body logged, [kAccountTimeout] on the
/// whole call.
Future<({int status, String body})> defaultAccountHttp(
  String method,
  Uri url, {
  String? jsonBody,
}) async {
  final HttpClient client = HttpClient()..connectionTimeout = kAccountTimeout;
  try {
    final HttpClientRequest request = await client
        .openUrl(method, url)
        .timeout(kAccountTimeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonBody));
    }
    final HttpClientResponse response = await request.close().timeout(
      kAccountTimeout,
    );
    final String body = await utf8
        .decodeStream(response)
        .timeout(kAccountTimeout);
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

class AccountService extends ChangeNotifier {
  AccountService({
    required this._origin,
    required this._google,
    required this._http,
  });

  final Uri _origin;
  final GoogleIdTokenSource _google;
  final AccountHttp _http;

  String? _clientId;
  bool _signedIn = false;
  String _name = '';

  /// True when the config answered a non-empty client id.
  bool get available => _clientId != null;

  bool get signedIn => _signedIn;

  /// The Google name; '' when not signed in, or when Google gave none.
  String get name => _name;

  /// Reads the device record and asks the server's config. Never throws: an
  /// unreadable record reads as signed out, and a config that fails, is null
  /// or does not answer reads as "not offered".
  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _signedIn = prefs.getBool(kAccountSignedInKey) ?? false;
      _name = _signedIn ? (prefs.getString(kAccountNameKey) ?? '') : '';
    } on Object {
      _signedIn = false;
      _name = '';
    }
    notifyListeners();
    String? id;
    ({int status, String body})? answer;
    try {
      answer = await _http(
        'GET',
        _origin.resolve('/auth/config'),
      ).timeout(kAccountTimeout);
    } on Object {
      // Whatever the call itself threw (network, timeout, a broken transport)
      // reads as "not offered".
      answer = null;
    }
    if (answer != null && answer.status == 200) {
      try {
        final Object? decoded = jsonDecode(answer.body);
        if (decoded is Map<String, Object?>) {
          final Object? value = decoded['google_client_id'];
          if (value is String && value.trim().isNotEmpty) {
            id = value.trim();
          }
        }
      } on Object catch (error, stack) {
        id = null;
        // A body that is not JSON is an expected "not offered". Anything else
        // is a bug in reading the answer and is reported, not eaten.
        if (error is! FormatException) {
          _reportAccountError(error, stack, 'reading the sign-in config');
        }
      }
    }
    _clientId = id;
    notifyListeners();
  }

  /// Asks Google for a token, sends it to the server, and on 200 keeps
  /// "signed in" and the name. Any other end leaves the device as it was.
  Future<AccountOutcome> signIn() async {
    final String? id = _clientId;
    if (id == null) {
      return AccountOutcome.unavailable;
    }
    final String? token;
    try {
      token = await _google.idToken(id).timeout(kAccountTimeout * 6);
    } on Object {
      return AccountOutcome.failed;
    }
    if (token == null) {
      return AccountOutcome.cancelled;
    }
    final ({int status, String body})? answer = await _post(
      '/auth/google',
      token,
    );
    if (answer == null || answer.status != 200) {
      return AccountOutcome.failed;
    }
    final String name;
    try {
      final Object? decoded = jsonDecode(answer.body);
      if (decoded is! Map<String, Object?> || decoded['name'] is! String) {
        return AccountOutcome.failed;
      }
      name = (decoded['name']! as String).trim();
    } on FormatException {
      return AccountOutcome.failed;
    }
    _signedIn = true;
    _name = name;
    await _writeRecord();
    if (name.isNotEmpty) {
      await SessionMemory.recordName(clipPlayerName(name));
    }
    notifyListeners();
    return AccountOutcome.ok;
  }

  /// Asks Google for a fresh token and has the server delete the account.
  /// `deleted` true or false both leave nothing on the server, so both are
  /// [AccountOutcome.ok] and both sign out on the device.
  Future<AccountOutcome> deleteAccount() async {
    final String? id = _clientId;
    if (id == null) {
      return AccountOutcome.unavailable;
    }
    final String? token;
    try {
      token = await _google.idToken(id).timeout(kAccountTimeout * 6);
    } on Object {
      return AccountOutcome.failed;
    }
    if (token == null) {
      return AccountOutcome.cancelled;
    }
    final ({int status, String body})? answer = await _post(
      '/account/delete',
      token,
    );
    if (answer == null || answer.status != 200) {
      return AccountOutcome.failed;
    }
    try {
      final Object? decoded = jsonDecode(answer.body);
      if (decoded is! Map<String, Object?> || decoded['deleted'] is! bool) {
        return AccountOutcome.failed;
      }
    } on FormatException {
      return AccountOutcome.failed;
    }
    await signOut();
    return AccountOutcome.ok;
  }

  /// Signs out on this device only; the server is not called.
  Future<void> signOut() async {
    _signedIn = false;
    _name = '';
    await _writeRecord();
    notifyListeners();
    await _google.signOut();
  }

  /// A POST with the token as its only field; null when the call threw or
  /// timed out. The token is never kept.
  Future<({int status, String body})?> _post(String path, String token) async {
    try {
      return await _http(
        'POST',
        _origin.resolve(path),
        jsonBody: jsonEncode(<String, String>{'id_token': token}),
      ).timeout(kAccountTimeout);
    } on Object {
      return null;
    }
  }

  Future<void> _writeRecord() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_signedIn) {
        await prefs.setBool(kAccountSignedInKey, true);
        await prefs.setString(kAccountNameKey, _name);
      } else {
        await prefs.remove(kAccountSignedInKey);
        await prefs.remove(kAccountNameKey);
      }
    } on Object catch (error, stack) {
      // The record is a convenience; this run still holds the true answer in
      // memory, and the next run reads signed out. The failure is reported.
      _reportAccountError(error, stack, 'writing the account record');
    }
  }

  void _reportAccountError(Object error, StackTrace stack, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'account service',
        context: ErrorDescription(context),
      ),
    );
  }
}

/// [name] cut to what the server takes as a player name, never inside a
/// surrogate pair.
String clipPlayerName(String name) {
  final String trimmed = name.trim();
  if (trimmed.length <= kNameMaxUnits) {
    return trimmed;
  }
  int end = kNameMaxUnits;
  final int last = trimmed.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    end -= 1;
  }
  return trimmed.substring(0, end).trim();
}

AccountService? _realAccountService;

/// Set by `main()` once: the service the app runs on.
set realAccountService(AccountService? service) {
  _realAccountService = service;
}

/// Set by tests to stand in for the app's service; null leaves the real one.
AccountService? debugAccountServiceOverride;

// A widget test never calls main(). Its home then sees a service that was
// never loaded: sign-in is not offered and nobody is signed in.
final AccountService _unloaded = AccountService(
  origin: server_config.accountOrigin(),
  google: const _NoGoogle(),
  http: defaultAccountHttp,
);

/// The override, else the one `main()` built, else an unloaded service.
AccountService get accountService =>
    debugAccountServiceOverride ?? _realAccountService ?? _unloaded;

class _NoGoogle implements GoogleIdTokenSource {
  const _NoGoogle();

  @override
  Future<String?> idToken(String serverClientId) async => null;

  @override
  Future<void> signOut() async {}
}

/// Set by tests to stand in for a Google sign-in; null leaves the real answer.
bool? debugGoogleSignedInOverride;

/// True when the player is signed in with Google.
bool get googleSignedIn =>
    debugGoogleSignedInOverride ?? accountService.signedIn;
