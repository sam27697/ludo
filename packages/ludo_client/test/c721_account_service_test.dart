// Proof for order 721 (optional Google sign-in), the service half. Written from
// docs/PROTOCOL.md sections 36.4 and 36.6 and the interfaces and keys order 721
// pins, not from the service's code.
//
// The service runs over a fake Google token source and a fake HTTP function
// that records every call. Every failure names the scenario and the command
// that reruns it. Nothing waits on a real clock: the ten second and config
// timeouts run on the test binding's fake clock.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/account.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/c721_fakes.dart';

const String _file = 'c721_account_service_test.dart';
const String _signedInKey = 'account.signed_in';
const String _nameKey = 'account.name';
const String _savedNameKey = 'session.lastName';

String _repro(String name) =>
    'scenario "$name"; rerun: cd packages/ludo_client && flutter test '
    'test/$_file --plain-name "$name"';

Future<Map<String, Object?>> _stored() async {
  final SharedPreferences p = await SharedPreferences.getInstance();
  return <String, Object?>{for (final String k in p.getKeys()) k: p.get(k)};
}

void _expectNoTokenStored(Map<String, Object?> stored, String repro) {
  for (final MapEntry<String, Object?> e in stored.entries) {
    expect(
      '${e.key}=${e.value}'.contains('SECRET'),
      isFalse,
      reason:
          'expected the ID token never to be stored; SharedPreferences key '
          '"${e.key}" holds "${e.value}". $repro',
    );
  }
}

/// Registers a plain test whose reasons carry the scenario.
void _case(String name, Future<void> Function(String repro) body) {
  test(name, () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await body(_repro(name));
  });
}

/// Same, on the fake clock, for the timeout paths.
void _timed(
  String name,
  Future<void> Function(String repro, WidgetTester tester) body,
) {
  testWidgets(name, (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await body(_repro(name), tester);
  });
}

Future<C721Parts> _ready(
  String repro, {
  String? clientId = kC721ClientId,
}) async {
  final C721Parts p = C721Parts(clientId: clientId);
  await p.service.load();
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('config', () {
    _case('config null is not available and signIn makes no POST', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro, clientId: null);
      expect(
        p.service.available,
        isFalse,
        reason:
            'config {"google_client_id":null} must not be available. $repro',
      );
      final AccountOutcome o = await p.service.signIn();
      expect(
        o,
        AccountOutcome.unavailable,
        reason:
            'signIn with sign-in off must answer unavailable, got $o. $repro',
      );
      expect(
        p.http.posts,
        isEmpty,
        reason:
            'signIn made a POST while unavailable: ${p.http.describe()}. $repro',
      );
      expect(
        p.google.clientIds,
        isEmpty,
        reason: 'Google was asked for a token while unavailable. $repro',
      );
      expect(p.service.signedIn, isFalse, reason: 'signedIn changed. $repro');
    });

    _case('config set is available and asked once on the https origin', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      expect(
        p.service.available,
        isTrue,
        reason: 'config with a client id must be available. $repro',
      );
      final List<HttpCall> asked = p.http.to('/auth/config');
      expect(
        asked.length,
        1,
        reason:
            'expected one GET /auth/config, saw ${p.http.describe()}. $repro',
      );
      expect(
        asked.single.method,
        'GET',
        reason: 'config must be a GET. $repro',
      );
      expect(
        '${asked.single.url.scheme}://${asked.single.url.host}',
        'https://c721-test.invalid',
        reason:
            'config was not asked on the https origin: ${asked.single.url}. $repro',
      );
      expect(
        asked.single.jsonBody,
        isNull,
        reason: 'GET /auth/config must carry no body. $repro',
      );
    });

    for (final MapEntry<String, ({int status, String body})> bad
        in <String, ({int status, String body})>{
          'a 500': (status: 500, body: '{"code":"X"}'),
          'a 503': (status: 503, body: '{"code":"SIGN_IN_OFF"}'),
          'a 404': (status: 404, body: ''),
          'a 200 that is not json': (status: 200, body: '<html>nope</html>'),
          'a 200 that is a list': (status: 200, body: '[]'),
          'a 200 without the key': (status: 200, body: '{}'),
          'a 200 with an empty id': (
            status: 200,
            body: '{"google_client_id":""}',
          ),
          'a 200 with a numeric id': (
            status: 200,
            body: '{"google_client_id":5}',
          ),
          'a 200 with an empty body': (status: 200, body: ''),
        }.entries) {
      _case('config answered by ${bad.key} is not available', (
        String repro,
      ) async {
        final C721Parts p = C721Parts();
        p.http.setRoute('/auth/config', bad.value.status, bad.value.body);
        await p.service.load();
        expect(
          p.service.available,
          isFalse,
          reason:
              'config ${bad.key} (${bad.value.status} "${bad.value.body}") '
              'must leave sign-in off. $repro',
        );
        expect(
          await p.service.signIn(),
          AccountOutcome.unavailable,
          reason: 'signIn after ${bad.key} must be unavailable. $repro',
        );
        expect(p.http.posts, isEmpty, reason: 'a POST was made. $repro');
      });
    }

    _case('config that throws is not available and load does not throw', (
      String repro,
    ) async {
      final C721Parts p = C721Parts();
      p.http.throwOn.add('/auth/config');
      await p.service.load();
      expect(
        p.service.available,
        isFalse,
        reason: 'a throwing config call must leave sign-in off. $repro',
      );
      expect(
        await p.service.signIn(),
        AccountOutcome.unavailable,
        reason: 'signIn after a failed config must be unavailable. $repro',
      );
    });

    _timed('config that never answers is not available once time passes', (
      String repro,
      WidgetTester tester,
    ) async {
      final C721Parts p = C721Parts();
      p.http.hang.add('/auth/config');
      bool done = false;
      final Future<void> loading = p.service.load().whenComplete(
        () => done = true,
      );
      await tester.pump(const Duration(seconds: 60));
      expect(
        done,
        isTrue,
        reason:
            'load() still waiting after 60 s of an unanswered config call; it '
            'must give up. $repro',
      );
      await loading;
      expect(
        p.service.available,
        isFalse,
        reason: 'an unanswered config call must leave sign-in off. $repro',
      );
    });

    _case('signIn before load is unavailable and makes no call', (
      String repro,
    ) async {
      final C721Parts p = C721Parts();
      final AccountOutcome o = await p.service.signIn();
      expect(
        o,
        AccountOutcome.unavailable,
        reason: 'signIn before load() must be unavailable, got $o. $repro',
      );
      expect(
        p.http.calls,
        isEmpty,
        reason: 'HTTP used before load(): ${p.http.describe()}. $repro',
      );
    });
  });

  group('signIn', () {
    _case('ok stores signed_in and name, nothing new, never the token', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _savedNameKey: 'Typed',
        'session.lastSeats': 4,
      });
      final C721Parts p = await _ready(repro);
      final Set<String> before = (await _stored()).keys.toSet();
      final AccountOutcome o = await p.service.signIn();
      expect(o, AccountOutcome.ok, reason: 'signIn must be ok, got $o. $repro');
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'signedIn false after ok. $repro',
      );
      expect(
        p.service.name,
        'Layla Google',
        reason: 'name must be the server name, is "${p.service.name}". $repro',
      );
      final Map<String, Object?> after = await _stored();
      expect(
        after.keys.toSet().difference(before),
        <String>{_signedInKey, _nameKey},
        reason:
            'expected exactly account.signed_in and account.name to be new, '
            'new keys are ${after.keys.toSet().difference(before)}. $repro',
      );
      expect(
        after[_signedInKey],
        true,
        reason: 'signed_in must be true. $repro',
      );
      expect(
        after[_nameKey],
        'Layla Google',
        reason: 'account.name must be the server name. $repro',
      );
      expect(
        after[_savedNameKey],
        'Layla Google',
        reason:
            'the saved player name (session.lastName, the one home loads) '
            'must become the Google name, is "${after[_savedNameKey]}". $repro',
      );
      _expectNoTokenStored(after, repro);
    });

    _case('ok posts exactly the token to /auth/google with the client id', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      await p.service.signIn();
      expect(
        p.google.clientIds,
        <String>[kC721ClientId],
        reason:
            'Google must be asked once with the configured id, was asked '
            'with ${p.google.clientIds}. $repro',
      );
      final List<HttpCall> posts = p.http.to('/auth/google');
      expect(
        posts.length,
        1,
        reason:
            'expected one POST /auth/google, saw ${p.http.describe()}. $repro',
      );
      expect(posts.single.method, 'POST', reason: 'must be a POST. $repro');
      expect(
        posts.single.url.scheme,
        'https',
        reason: 'must be https, was ${posts.single.url}. $repro',
      );
      expect(
        posts.single.decoded,
        <String, Object?>{'id_token': kC721Token},
        reason:
            'body must be exactly {"id_token": <token>} (an unknown key is '
            'a 400 on the server), was ${posts.single.jsonBody == null ? 'null' : 'a different body'}. $repro',
      );
      expect(
        p.http.posts.length,
        1,
        reason: 'signIn made other POSTs: ${p.http.describe()}. $repro',
      );
    });

    _case('ok on a fresh store writes only account keys and the saved name', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      await p.service.signIn();
      final Map<String, Object?> after = await _stored();
      expect(
        after.keys.toSet().difference(<String>{
          _signedInKey,
          _nameKey,
          _savedNameKey,
        }),
        isEmpty,
        reason:
            'unexpected keys written by signIn: ${after.keys.toList()}. $repro',
      );
      _expectNoTokenStored(after, repro);
    });

    _case('cancelled makes no POST and changes nothing', (String repro) async {
      final C721Parts p = await _ready(repro);
      p.google.cancel = true;
      final Map<String, Object?> before = await _stored();
      int notified = 0;
      p.service.addListener(() => notified += 1);
      final AccountOutcome o = await p.service.signIn();
      expect(
        o,
        AccountOutcome.cancelled,
        reason: 'player backed out: expected cancelled, got $o. $repro',
      );
      expect(
        p.http.posts,
        isEmpty,
        reason: 'a POST was made after the player backed out. $repro',
      );
      expect(
        p.service.signedIn,
        isFalse,
        reason: 'signedIn became true. $repro',
      );
      expect(
        await _stored(),
        before,
        reason: 'SharedPreferences changed after a cancel. $repro',
      );
      expect(
        notified,
        0,
        reason: 'listeners were told of a change that did not happen. $repro',
      );
    });

    final Map<String, void Function(C721Parts)> failures =
        <String, void Function(C721Parts)>{
          '401 BAD_TOKEN': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 401, 'BAD_TOKEN'),
          '503 SIGN_IN_OFF': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 503, 'SIGN_IN_OFF'),
          '503 SIGN_IN_UNAVAILABLE': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 503, 'SIGN_IN_UNAVAILABLE'),
          '500 STORE_FAILED': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 500, 'STORE_FAILED'),
          '429 RATE_LIMITED': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 429, 'RATE_LIMITED'),
          '413 TOO_LARGE': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 413, 'TOO_LARGE'),
          '400 BAD_REQUEST': (C721Parts p) =>
              p.http.errorAnswer('/auth/google', 400, 'BAD_REQUEST'),
          'a thrown http error': (C721Parts p) =>
              p.http.throwOn.add('/auth/google'),
          'a thrown Google error': (C721Parts p) =>
              p.google.throwOnToken = StateError('google refused'),
          'a 200 that is not json': (C721Parts p) =>
              p.http.setRoute('/auth/google', 200, 'garbage'),
          'a 200 without a name key': (C721Parts p) =>
              p.http.setRoute('/auth/google', 200, '{}'),
          'a 200 whose name is a number': (C721Parts p) =>
              p.http.setRoute('/auth/google', 200, '{"name":7}'),
        };
    for (final MapEntry<String, void Function(C721Parts)> f
        in failures.entries) {
      for (final bool wasIn in <bool>[false, true]) {
        _case(
          'failed on ${f.key}, device ${wasIn ? 'was signed in as Old' : 'was signed out'}, is unchanged',
          (String repro) async {
            SharedPreferences.setMockInitialValues(<String, Object>{
              _savedNameKey: 'Typed',
              if (wasIn) _signedInKey: true,
              if (wasIn) _nameKey: 'Old',
            });
            final C721Parts p = await _ready(repro);
            f.value(p);
            final Map<String, Object?> before = await _stored();
            final AccountOutcome o = await p.service.signIn();
            expect(
              o,
              AccountOutcome.failed,
              reason: 'expected failed on ${f.key}, got $o. $repro',
            );
            expect(
              p.service.signedIn,
              wasIn,
              reason: 'signedIn changed on ${f.key}. $repro',
            );
            expect(
              p.service.name,
              wasIn ? 'Old' : '',
              reason: 'name changed on ${f.key}: "${p.service.name}". $repro',
            );
            expect(
              await _stored(),
              before,
              reason: 'SharedPreferences changed on ${f.key}. $repro',
            );
          },
        );
      }
    }

    _timed('failed when the server never answers within ten seconds', (
      String repro,
      WidgetTester tester,
    ) async {
      final C721Parts p = C721Parts();
      await p.service.load();
      p.http.hang.add('/auth/google');
      final Map<String, Object?> before = await _stored();
      AccountOutcome? o;
      final Future<void> running = p.service.signIn().then(
        (AccountOutcome v) => o = v,
      );
      await tester.pump(const Duration(seconds: 9));
      expect(
        o,
        isNull,
        reason: 'signIn gave up before its ten second limit, after 9 s. $repro',
      );
      await tester.pump(const Duration(seconds: 3));
      await running;
      expect(
        o,
        AccountOutcome.failed,
        reason: 'expected failed 12 s after an unanswered POST, got $o. $repro',
      );
      expect(
        p.service.signedIn,
        isFalse,
        reason: 'signedIn became true. $repro',
      );
      expect(
        await _stored(),
        before,
        reason: 'SharedPreferences changed after a timeout. $repro',
      );
    });

    _case('empty name from the server keeps the typed name', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _savedNameKey: 'Typed',
      });
      final C721Parts p = C721Parts();
      p.http.signInAnswers(name: '');
      await p.service.load();
      final AccountOutcome o = await p.service.signIn();
      expect(
        o,
        AccountOutcome.ok,
        reason: 'an empty name is still ok, got $o. $repro',
      );
      expect(p.service.signedIn, isTrue, reason: 'must be signed in. $repro');
      expect(
        p.service.name,
        '',
        reason:
            'name must be empty when Google gave none, is "${p.service.name}". $repro',
      );
      final Map<String, Object?> after = await _stored();
      expect(
        after[_savedNameKey],
        'Typed',
        reason:
            'the typed name must be kept, session.lastName is '
            '"${after[_savedNameKey]}". $repro',
      );
    });

    _case('sign in twice posts twice and stays consistent', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      expect(
        await p.service.signIn(),
        AccountOutcome.ok,
        reason: 'first. $repro',
      );
      p.http.signInAnswers(name: 'Layla Two');
      expect(
        await p.service.signIn(),
        AccountOutcome.ok,
        reason: 'second. $repro',
      );
      expect(
        p.http.to('/auth/google').length,
        2,
        reason: 'expected two POSTs, saw ${p.http.describe()}. $repro',
      );
      expect(
        p.service.name,
        'Layla Two',
        reason: 'name must follow the latest answer. $repro',
      );
    });

    _case('listeners are told when sign in succeeds', (String repro) async {
      final C721Parts p = await _ready(repro);
      int notified = 0;
      p.service.addListener(() => notified += 1);
      await p.service.signIn();
      expect(
        notified,
        greaterThan(0),
        reason: 'home would not repaint: no notification after ok. $repro',
      );
    });
  });

  group('deleteAccount', () {
    for (final bool deleted in <bool>[true, false]) {
      _case('deleted $deleted is ok, signs out, asks Google for a fresh token', (
        String repro,
      ) async {
        final C721Parts p = await _ready(repro);
        p.google.tokens = <String>[kC721Token, 'tok.SECRET-c721-second'];
        await p.service.signIn();
        p.http.deleteAnswers(deleted: deleted);
        final AccountOutcome o = await p.service.deleteAccount();
        expect(
          o,
          AccountOutcome.ok,
          reason: 'deleted:$deleted must be ok, got $o. $repro',
        );
        expect(
          p.service.signedIn,
          isFalse,
          reason:
              'still signed in after a delete answered deleted:$deleted. $repro',
        );
        expect(
          p.service.name,
          '',
          reason: 'name kept after delete: "${p.service.name}". $repro',
        );
        expect(
          p.google.clientIds.length,
          2,
          reason:
              'delete must ask Google for a fresh token, Google was asked '
              '${p.google.clientIds.length} times in all. $repro',
        );
        final List<HttpCall> dels = p.http.to('/account/delete');
        expect(
          dels.length,
          1,
          reason:
              'expected one POST /account/delete, saw ${p.http.describe()}. $repro',
        );
        expect(dels.single.method, 'POST', reason: 'must be a POST. $repro');
        expect(dels.single.decoded, <String, Object?>{
          'id_token': 'tok.SECRET-c721-second',
        }, reason: 'delete must send the fresh token, and only it. $repro');
        final Map<String, Object?> after = await _stored();
        expect(
          after[_signedInKey] ?? false,
          false,
          reason: 'account.signed_in still true on the device. $repro',
        );
        expect(
          after[_nameKey] ?? '',
          '',
          reason:
              'account.name kept on the device: "${after[_nameKey]}". $repro',
        );
        expect(
          p.google.signOutCalls,
          greaterThan(0),
          reason: 'Google session was not signed out after delete. $repro',
        );
        _expectNoTokenStored(after, repro);
      });
    }

    for (final MapEntry<String, void Function(C721Parts)> f
        in <String, void Function(C721Parts)>{
          '401 BAD_TOKEN': (C721Parts p) =>
              p.http.errorAnswer('/account/delete', 401, 'BAD_TOKEN'),
          '500 STORE_FAILED': (C721Parts p) =>
              p.http.errorAnswer('/account/delete', 500, 'STORE_FAILED'),
          '503 SIGN_IN_OFF': (C721Parts p) =>
              p.http.errorAnswer('/account/delete', 503, 'SIGN_IN_OFF'),
          '429 RATE_LIMITED': (C721Parts p) =>
              p.http.errorAnswer('/account/delete', 429, 'RATE_LIMITED'),
          'a thrown http error': (C721Parts p) =>
              p.http.throwOn.add('/account/delete'),
          'a thrown Google error': (C721Parts p) =>
              p.google.throwOnToken = StateError('google refused'),
          'a 200 that is not json': (C721Parts p) =>
              p.http.setRoute('/account/delete', 200, 'garbage'),
        }.entries) {
      _case('delete failed on ${f.key} keeps the device signed in', (
        String repro,
      ) async {
        final C721Parts p = await _ready(repro);
        await p.service.signIn();
        // The Google failure applies to the fresh token only.
        f.value(p);
        final Map<String, Object?> before = await _stored();
        final AccountOutcome o = await p.service.deleteAccount();
        expect(
          o,
          AccountOutcome.failed,
          reason: 'expected failed on ${f.key}, got $o. $repro',
        );
        expect(
          p.service.signedIn,
          isTrue,
          reason: 'a failed delete signed the device out. $repro',
        );
        expect(
          p.service.name,
          'Layla Google',
          reason: 'name lost after a failed delete. $repro',
        );
        expect(
          await _stored(),
          before,
          reason: 'SharedPreferences changed after a failed delete. $repro',
        );
      });
    }

    _case('delete cancelled at the Google step sends nothing and stays in', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      await p.service.signIn();
      p.google.cancel = true;
      final AccountOutcome o = await p.service.deleteAccount();
      expect(
        o,
        AccountOutcome.cancelled,
        reason: 'player backed out of the fresh token, got $o. $repro',
      );
      expect(
        p.http.to('/account/delete'),
        isEmpty,
        reason: 'a delete was sent anyway. $repro',
      );
      expect(p.service.signedIn, isTrue, reason: 'signed out anyway. $repro');
    });

    _timed('delete failed when the server never answers within ten seconds', (
      String repro,
      WidgetTester tester,
    ) async {
      final C721Parts p = C721Parts();
      await p.service.load();
      await p.service.signIn();
      p.http.hang.add('/account/delete');
      AccountOutcome? o;
      final Future<void> running = p.service.deleteAccount().then(
        (AccountOutcome v) => o = v,
      );
      await tester.pump(const Duration(seconds: 12));
      await running;
      expect(
        o,
        AccountOutcome.failed,
        reason: 'expected failed after an unanswered delete, got $o. $repro',
      );
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'signed out on a timeout. $repro',
      );
    });
  });

  group('signOut and load', () {
    _case('signOut touches no server and signs out Google', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      await p.service.signIn();
      final int callsBefore = p.http.calls.length;
      await p.service.signOut();
      expect(
        p.http.calls.length,
        callsBefore,
        reason: 'signOut made an HTTP call: ${p.http.describe()}. $repro',
      );
      expect(
        p.google.signOutCalls,
        1,
        reason: 'google.signOut must be called once. $repro',
      );
      expect(p.service.signedIn, isFalse, reason: 'still signed in. $repro');
      expect(
        p.service.name,
        '',
        reason: 'name kept: "${p.service.name}". $repro',
      );
      final Map<String, Object?> after = await _stored();
      expect(
        after[_signedInKey] ?? false,
        false,
        reason: 'account.signed_in still true. $repro',
      );
      expect(
        after[_nameKey] ?? '',
        '',
        reason: 'account.name kept on the device. $repro',
      );
      _expectNoTokenStored(after, repro);
    });

    _case('signOut while signed out is harmless and silent on the wire', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      await p.service.signOut();
      expect(p.http.posts, isEmpty, reason: 'a POST was made. $repro');
      expect(p.service.signedIn, isFalse, reason: 'signedIn true. $repro');
    });

    _case('load restores the device record', (String repro) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: true,
        _nameKey: 'Zed',
      });
      final C721Parts p = await _ready(repro);
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'signed_in not restored. $repro',
      );
      expect(
        p.service.name,
        'Zed',
        reason: 'name not restored, is "${p.service.name}". $repro',
      );
    });

    _case('load restores the device record when the server is unreachable', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: true,
        _nameKey: 'Zed',
      });
      final C721Parts p = C721Parts();
      p.http.throwOn.add('/auth/config');
      await p.service.load();
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'an offline start lost the device record. $repro',
      );
      expect(p.service.name, 'Zed', reason: 'name lost offline. $repro');
      expect(p.service.available, isFalse, reason: 'available offline. $repro');
    });

    _case('load with signed_in but no name gives an empty name', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: true,
      });
      final C721Parts p = await _ready(repro);
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'signed_in not restored. $repro',
      );
      expect(p.service.name, '', reason: 'name must be empty. $repro');
    });

    _case('load with a name but signed_in false is signed out', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: false,
        _nameKey: 'Ghost',
      });
      final C721Parts p = await _ready(repro);
      expect(
        p.service.signedIn,
        isFalse,
        reason: 'signed in from a false flag. $repro',
      );
      expect(
        p.service.name,
        '',
        reason:
            'name must read empty when not signed in, is "${p.service.name}". $repro',
      );
    });

    _case('load with wrongly typed stored values does not throw', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: 'yes',
        _nameKey: 42,
      });
      final C721Parts p = C721Parts();
      await p.service.load();
      expect(
        p.service.signedIn,
        isFalse,
        reason:
            'a string in account.signed_in must not read as signed in. $repro',
      );
      expect(
        p.service.name,
        '',
        reason: 'a number in account.name must read as empty. $repro',
      );
    });

    _case('load twice is harmless', (String repro) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: true,
        _nameKey: 'Zed',
      });
      final C721Parts p = await _ready(repro);
      await p.service.load();
      expect(
        p.service.signedIn,
        isTrue,
        reason: 'second load lost state. $repro',
      );
      expect(
        p.service.available,
        isTrue,
        reason: 'second load lost config. $repro',
      );
    });

    _case('no stored value anywhere ever holds the token, across a full run', (
      String repro,
    ) async {
      final C721Parts p = await _ready(repro);
      p.google.tokens = <String>[kC721Token, 'tok.SECRET-c721-second'];
      await p.service.signIn();
      _expectNoTokenStored(await _stored(), repro);
      await p.service.deleteAccount();
      _expectNoTokenStored(await _stored(), repro);
      p.http.errorAnswer('/auth/google', 401, 'BAD_TOKEN');
      await p.service.signIn();
      _expectNoTokenStored(await _stored(), repro);
      expect(
        jsonEncode(await _stored()).contains('SECRET'),
        isFalse,
        reason: 'the token reached SharedPreferences. $repro',
      );
    });
  });

  group('googleSignedIn', () {
    tearDown(() {
      debugGoogleSignedInOverride = null;
      debugAccountServiceOverride = null;
    });

    _case('the override wins over the service in both directions', (
      String repro,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _signedInKey: true,
        _nameKey: 'Zed',
      });
      final C721Parts p = await _ready(repro);
      debugAccountServiceOverride = p.service;
      expect(
        googleSignedIn,
        isTrue,
        reason:
            'with no override googleSignedIn must follow the service. $repro',
      );
      debugGoogleSignedInOverride = false;
      expect(
        googleSignedIn,
        isFalse,
        reason: 'override false must win over a signed-in service. $repro',
      );
      debugGoogleSignedInOverride = null;
      await p.service.signOut();
      expect(
        googleSignedIn,
        isFalse,
        reason: 'googleSignedIn must follow the service after signOut. $repro',
      );
      debugGoogleSignedInOverride = true;
      expect(
        googleSignedIn,
        isTrue,
        reason: 'override true must win over a signed-out service. $repro',
      );
    });
  });
}
