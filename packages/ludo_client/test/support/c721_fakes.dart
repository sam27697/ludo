// Fakes shared by the C-721 account tests and the 721t captures.
//
// Written from order 721 (the interfaces and keys it pins) and docs/PROTOCOL.md
// sections 36.4 and 36.6. The Google side is a fake [GoogleIdTokenSource]; the
// server side is a fake [AccountHttp] that records every call and answers the
// three routes of section 36.4 from a script the test sets.

import 'dart:async';
import 'dart:convert';

import 'package:ludo_client/src/account.dart';

/// The token the fake Google hands out first. Distinctive on purpose: the
/// tests scan every stored value for it.
const String kC721Token = 'tok.SECRET-c721-AbCdEf0123';
const String kC721ClientId = '1234-c721.apps.googleusercontent.com';
final Uri kC721Origin = Uri.parse('https://c721-test.invalid');

/// A scripted [GoogleIdTokenSource].
class FakeGoogle implements GoogleIdTokenSource {
  /// Tokens handed out in order; the last one repeats.
  List<String> tokens = <String>[kC721Token];

  /// When true [idToken] returns null (the player backed out).
  bool cancel = false;

  /// When set, [idToken] throws it.
  Object? throwOnToken;

  /// When set, [idToken] waits on it (a hung Google sheet).
  Completer<void>? gate;

  final List<String> clientIds = <String>[];
  int signOutCalls = 0;

  @override
  Future<String?> idToken(String serverClientId) async {
    clientIds.add(serverClientId);
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    final Object? t = throwOnToken;
    if (t != null) throw t;
    if (cancel) return null;
    final int i = clientIds.length - 1;
    return tokens[i < tokens.length ? i : tokens.length - 1];
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
  }
}

/// One recorded call of the fake server.
class HttpCall {
  HttpCall(this.method, this.url, this.jsonBody);

  final String method;
  final Uri url;
  final String? jsonBody;

  Map<String, Object?>? get decoded {
    final String? b = jsonBody;
    if (b == null) return null;
    return jsonDecode(b) as Map<String, Object?>;
  }

  @override
  String toString() =>
      '$method ${url.path}${jsonBody == null ? '' : ' <body>'}';
}

/// A scripted [AccountHttp] recording every call. Each route has a status and
/// a body; [throwOn] and [hang] turn a route into a thrown error or a request
/// that never answers.
class FakeAccountHttp {
  FakeAccountHttp({String? clientId = kC721ClientId}) {
    setConfig(clientId);
  }

  final List<HttpCall> calls = <HttpCall>[];
  final Map<String, ({int status, String body})> routes =
      <String, ({int status, String body})>{};
  final Set<String> throwOn = <String>{};
  final Set<String> hang = <String>{};

  void setConfig(String? clientId) {
    routes['/auth/config'] = (
      status: 200,
      body: jsonEncode(<String, Object?>{'google_client_id': clientId}),
    );
  }

  void setRoute(String path, int status, String body) {
    routes[path] = (status: status, body: body);
  }

  void signInAnswers({String name = 'Layla Google'}) => setRoute(
    '/auth/google',
    200,
    jsonEncode(<String, Object?>{'name': name}),
  );

  void deleteAnswers({bool deleted = true}) => setRoute(
    '/account/delete',
    200,
    jsonEncode(<String, Object?>{'deleted': deleted}),
  );

  void errorAnswer(String path, int status, String code) =>
      setRoute(path, status, jsonEncode(<String, Object?>{'code': code}));

  List<HttpCall> to(String path) =>
      calls.where((HttpCall c) => c.url.path == path).toList();

  List<HttpCall> get posts =>
      calls.where((HttpCall c) => c.method != 'GET').toList();

  Future<({int status, String body})> call(
    String method,
    Uri url, {
    String? jsonBody,
  }) async {
    calls.add(HttpCall(method, url, jsonBody));
    final String path = url.path;
    if (hang.contains(path)) {
      return Completer<({int status, String body})>().future;
    }
    if (throwOn.contains(path)) {
      throw StateError('c721 fake http: $path refused by the test');
    }
    final ({int status, String body})? r = routes[path];
    if (r == null) {
      return (status: 404, body: '{"code":"NOT_FOUND"}');
    }
    return r;
  }

  String describe() => calls.isEmpty ? '(no calls)' : calls.join(', ');
}

/// A service over the two fakes, as the tests build it.
class C721Parts {
  C721Parts({String? clientId = kC721ClientId})
    : http = FakeAccountHttp(clientId: clientId),
      google = FakeGoogle() {
    http.signInAnswers();
    http.deleteAnswers();
    service = AccountService(
      origin: kC721Origin,
      google: google,
      http: http.call,
    );
  }

  final FakeAccountHttp http;
  final FakeGoogle google;
  late final AccountService service;
}

/// A service whose [signIn] and [deleteAccount] answer a fixed outcome, to
/// reach the home paths the real service reaches only by a race (for example
/// `unavailable` after the control was already shown).
class ScriptedAccountService extends AccountService {
  ScriptedAccountService({
    required super.origin,
    required super.google,
    required super.http,
    this.signInOutcome,
    this.deleteOutcome,
  });

  AccountOutcome? signInOutcome;
  AccountOutcome? deleteOutcome;

  @override
  Future<AccountOutcome> signIn() async =>
      signInOutcome ?? await super.signIn();

  @override
  Future<AccountOutcome> deleteAccount() async =>
      deleteOutcome ?? await super.deleteAccount();
}
