// Order 721: the account service against fake Google and a fake server.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/account.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeGoogle implements GoogleIdTokenSource {
  String? token = 'tok-1';
  Object? error;
  int signOuts = 0;
  final List<String> asked = <String>[];

  @override
  Future<String?> idToken(String serverClientId) async {
    asked.add(serverClientId);
    final Object? e = error;
    if (e != null) {
      throw e;
    }
    return token;
  }

  @override
  Future<void> signOut() async {
    signOuts += 1;
  }
}

class _Call {
  _Call(this.method, this.url, this.body);
  final String method;
  final Uri url;
  final String? body;
}

class _FakeServer {
  Object? configBody = <String, Object?>{'google_client_id': 'web-id'};
  int configStatus = 200;
  int googleStatus = 200;
  Object googleBody = <String, Object?>{'name': 'Lina Haddad'};
  int deleteStatus = 200;
  Object deleteBody = <String, Object?>{'deleted': true};
  bool hang = false;
  Object? throwOn;
  final List<_Call> calls = <_Call>[];

  Future<({int status, String body})> call(
    String method,
    Uri url, {
    String? jsonBody,
  }) async {
    calls.add(_Call(method, url, jsonBody));
    if (hang) {
      return Completer<({int status, String body})>().future;
    }
    if (throwOn != null) {
      throw throwOn!;
    }
    switch (url.path) {
      case '/auth/config':
        return (status: configStatus, body: jsonEncode(configBody));
      case '/auth/google':
        return (status: googleStatus, body: jsonEncode(googleBody));
      case '/account/delete':
        return (status: deleteStatus, body: jsonEncode(deleteBody));
    }
    return (status: 404, body: '{}');
  }
}

AccountService _service(_FakeGoogle google, _FakeServer server) =>
    AccountService(
      origin: Uri.parse('https://example.invalid'),
      google: google,
      http: server.call,
    );

void main() {
  late _FakeGoogle google;
  late _FakeServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    google = _FakeGoogle();
    server = _FakeServer();
    debugGoogleSignedInOverride = null;
    debugAccountServiceOverride = null;
  });

  tearDown(() {
    debugGoogleSignedInOverride = null;
    debugAccountServiceOverride = null;
  });

  test('the account origin is the https origin of the server url', () {
    expect(accountOrigin().toString(), 'https://ludo.provefair.app');
  });

  group('load', () {
    test('a non-empty client id makes sign-in available', () async {
      final AccountService s = _service(google, server);
      await s.load();
      expect(s.available, isTrue);
      expect(s.signedIn, isFalse);
      expect(server.calls.single.method, 'GET');
      expect(server.calls.single.url.path, '/auth/config');
    });

    test(
      'a null id, an empty id, an error status and a throw all read as off',
      () async {
        for (final Object? body in <Object?>[
          <String, Object?>{'google_client_id': null},
          <String, Object?>{'google_client_id': ''},
          <String, Object?>{},
          'not a map',
        ]) {
          server.configBody = body;
          final AccountService s = _service(google, server);
          await s.load();
          expect(s.available, isFalse, reason: '$body');
        }
        server
          ..configBody = <String, Object?>{'google_client_id': 'web-id'}
          ..configStatus = 503;
        final AccountService errored = _service(google, server);
        await errored.load();
        expect(errored.available, isFalse);
        server
          ..configStatus = 200
          ..throwOn = StateError('offline');
        final AccountService thrown = _service(google, server);
        await thrown.load();
        expect(thrown.available, isFalse);
      },
    );

    test('a config that never answers reads as off after ten seconds', () {
      fakeAsync((FakeAsync async) {
        server.hang = true;
        final AccountService s = _service(google, server);
        bool done = false;
        s.load().then((_) => done = true);
        async.elapse(const Duration(seconds: 9));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(s.available, isFalse);
      });
    });

    test('the device record is read back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'account.signed_in': true,
        'account.name': 'Lina Haddad',
      });
      final AccountService s = _service(google, server);
      await s.load();
      expect(s.signedIn, isTrue);
      expect(s.name, 'Lina Haddad');
    });
  });

  group('signIn', () {
    test(
      'ok stores the record and the saved player name, never the token',
      () async {
        final AccountService s = _service(google, server);
        await s.load();
        expect(await s.signIn(), AccountOutcome.ok);
        expect(s.signedIn, isTrue);
        expect(s.name, 'Lina Haddad');
        expect(google.asked, <String>['web-id']);
        final _Call post = server.calls.last;
        expect(post.method, 'POST');
        expect(post.url.path, '/auth/google');
        expect(jsonDecode(post.body!), <String, Object?>{'id_token': 'tok-1'});
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('account.signed_in'), isTrue);
        expect(prefs.getString('account.name'), 'Lina Haddad');
        expect(prefs.getString('session.lastName'), 'Lina Haddad');
        for (final String key in prefs.getKeys()) {
          expect(prefs.get(key).toString(), isNot(contains('tok-1')));
        }
      },
    );

    test('an empty name leaves the typed one', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session.lastName': 'Typed',
      });
      server.googleBody = <String, Object?>{'name': ''};
      final AccountService s = _service(google, server);
      await s.load();
      expect(await s.signIn(), AccountOutcome.ok);
      expect(s.name, '');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session.lastName'), 'Typed');
    });

    test('a long Google name is cut to the player name limit', () async {
      server.googleBody = <String, Object?>{'name': 'A' * 40};
      final AccountService s = _service(google, server);
      await s.load();
      await s.signIn();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session.lastName'), 'A' * 24);
    });

    test('backing out is cancelled and changes nothing', () async {
      google.token = null;
      final AccountService s = _service(google, server);
      await s.load();
      expect(await s.signIn(), AccountOutcome.cancelled);
      expect(s.signedIn, isFalse);
      expect(server.calls.where((c) => c.method == 'POST'), isEmpty);
    });

    test('no config answer is unavailable and asks Google nothing', () async {
      server.configBody = <String, Object?>{'google_client_id': null};
      final AccountService s = _service(google, server);
      await s.load();
      expect(await s.signIn(), AccountOutcome.unavailable);
      expect(google.asked, isEmpty);
    });

    test(
      '401, 503, a throw from Google and a throw from http are failed',
      () async {
        for (final int status in <int>[401, 503]) {
          server.googleStatus = status;
          final AccountService s = _service(google, server);
          await s.load();
          expect(await s.signIn(), AccountOutcome.failed, reason: '$status');
          expect(s.signedIn, isFalse);
        }
        server.googleStatus = 200;
        google.error = StateError('no credential');
        final AccountService g = _service(google, server);
        await g.load();
        expect(await g.signIn(), AccountOutcome.failed);
        google.error = null;
        final AccountService h = _service(google, server);
        await h.load();
        server.throwOn = StateError('offline');
        expect(await h.signIn(), AccountOutcome.failed);
        expect(h.signedIn, isFalse);
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('account.signed_in'), isNull);
      },
    );
  });

  group('deleteAccount', () {
    Future<AccountService> signedIn() async {
      final AccountService s = _service(google, server);
      await s.load();
      await s.signIn();
      return s;
    }

    test('deleted true and false are both ok and sign out here', () async {
      for (final bool deleted in <bool>[true, false]) {
        server.deleteBody = <String, Object?>{'deleted': deleted};
        final AccountService s = await signedIn();
        google.token = 'fresh-token';
        expect(await s.deleteAccount(), AccountOutcome.ok);
        expect(s.signedIn, isFalse);
        expect(s.name, '');
        expect(jsonDecode(server.calls.last.body!), <String, Object?>{
          'id_token': 'fresh-token',
        });
        expect(server.calls.last.url.path, '/account/delete');
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('account.signed_in'), isNull);
        expect(prefs.getString('account.name'), isNull);
        google.token = 'tok-1';
      }
      expect(google.signOuts, 2);
    });

    test('a refusal leaves the device signed in', () async {
      final AccountService s = await signedIn();
      server.deleteStatus = 500;
      expect(await s.deleteAccount(), AccountOutcome.failed);
      expect(s.signedIn, isTrue);
      google.token = null;
      expect(await s.deleteAccount(), AccountOutcome.cancelled);
      expect(s.signedIn, isTrue);
    });
  });

  test(
    'signOut is local: no server call, record cleared, Google told',
    () async {
      final AccountService s = _service(google, server);
      await s.load();
      await s.signIn();
      final int before = server.calls.length;
      await s.signOut();
      expect(server.calls.length, before);
      expect(s.signedIn, isFalse);
      expect(google.signOuts, 1);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('account.signed_in'), isNull);
    },
  );

  test('googleSignedIn: the override wins, else the service answers', () async {
    final AccountService s = _service(google, server);
    await s.load();
    debugAccountServiceOverride = s;
    expect(googleSignedIn, isFalse);
    await s.signIn();
    expect(googleSignedIn, isTrue);
    debugGoogleSignedInOverride = false;
    expect(googleSignedIn, isFalse);
    debugGoogleSignedInOverride = null;
    debugAccountServiceOverride = null;
    expect(googleSignedIn, isFalse);
  });
}
