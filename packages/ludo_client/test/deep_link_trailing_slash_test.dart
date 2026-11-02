// Proof for contract C-529 D7 (work/ludo/orders/C-529-dead-rooms-and-first-launch.md):
// a room link with a trailing slash is a room link.
//
// `https://ludo.provefair.app/r/ABC234/` carries the same room as the link
// without the slash. One trailing empty path segment is accepted and nothing
// else about the predicate moves: scheme, host and the leading `r` are still
// exact, more segments are still refused, and the query and the fragment are
// still never read.
//
// The pure cases need no widgets. The two widget cases mount HomeScreen the
// way test/link_join_test.dart does and show that the slash makes no
// difference to what Home does with the link: a first-time player gets the
// code filled in, a known player joins.
//
// Cases whose id ends in "+" are red on a base without D7; the rest hold on
// the base and guard the edges D7 must not move.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _codeKey = Key('room-code-field');

const String _testUrl = 'wss://trailing-slash-test.invalid/ws';
const String _code = 'ABC234';

Uri _u(String text) => Uri.parse(text);

void _expectRoomLink(String text, {required String code, required String id}) {
  final Uri uri = _u(text);
  expect(
    isAppRoomLinkUri(uri),
    isTrue,
    reason: '$id: isAppRoomLinkUri("$text") must be true; was false',
  );
  expect(
    roomCodeFromUri(uri),
    code,
    reason:
        '$id: roomCodeFromUri("$text") must be "$code"; was '
        '${roomCodeFromUri(uri)} (path segments ${uri.pathSegments})',
  );
}

void _expectNotRoomLink(String text, {required String id}) {
  final Uri uri = _u(text);
  expect(
    roomCodeFromUri(uri),
    isNull,
    reason:
        '$id: "$text" must not yield a room code; got '
        '${roomCodeFromUri(uri)} (path segments ${uri.pathSegments})',
  );
}

class _Rig {
  final List<FakeTransport> transports = <FakeTransport>[];
  final List<RoomController> controllers = <RoomController>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }

  List<String> sentTypes() => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        (jsonDecode(s) as Map<String, Object?>)['t']! as String,
  ];

  Map<String, Object?> firstJoinData() {
    for (final FakeTransport t in transports) {
      for (final String s in t.sentRaw) {
        final Map<String, Object?> frame =
            jsonDecode(s) as Map<String, Object?>;
        if (frame['t'] == 'join_room') {
          return frame['d']! as Map<String, Object?>;
        }
      }
    }
    return const <String, Object?>{};
  }
}

Future<void> _mountWithColdLink(WidgetTester tester, _Rig rig, Uri link) async {
  final StreamController<Uri> stream = StreamController<Uri>.broadcast();
  addTearDown(stream.close);
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: rig.call,
        initialLinkReader: () => Future<Uri?>.value(link),
        linkStream: () => stream.stream,
      ),
    ),
  );
  for (int i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _finish(WidgetTester tester, _Rig rig) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  for (final RoomController controller in rig.controllers) {
    controller.dispose();
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('D7 the predicate', () {
    test('D7a+: /r/ABC234/ is a room link with code ABC234', () {
      _expectRoomLink(
        'https://ludo.provefair.app/r/ABC234/',
        code: _code,
        id: 'D7a+',
      );
    });

    test('D7b+: a lower-case code and a trailing slash still normalises', () {
      _expectRoomLink(
        'https://ludo.provefair.app/r/abc234/',
        code: _code,
        id: 'D7b+',
      );
    });

    test(
      'D7c+: the query and the fragment are still ignored with the slash',
      () {
        _expectRoomLink(
          'https://ludo.provefair.app/r/ABC234/?utm=x',
          code: _code,
          id: 'D7c+ query',
        );
        _expectRoomLink(
          'https://ludo.provefair.app/r/ABC234/#frag',
          code: _code,
          id: 'D7c+ fragment',
        );
      },
    );

    test('D7d: the form without the slash is unchanged', () {
      _expectRoomLink(
        'https://ludo.provefair.app/r/ABC234',
        code: _code,
        id: 'D7d',
      );
    });

    test('D7e: more than one trailing empty segment is still refused', () {
      _expectNotRoomLink('https://ludo.provefair.app/r/ABC234//', id: 'D7e //');
      _expectNotRoomLink(
        'https://ludo.provefair.app/r/ABC234///',
        id: 'D7e ///',
      );
      expect(
        isAppRoomLinkUri(_u('https://ludo.provefair.app/r/ABC234//')),
        isFalse,
        reason: 'D7e: two empty trailing segments are not a room link',
      );
    });

    test('D7f: a segment after the code is still refused', () {
      _expectNotRoomLink('https://ludo.provefair.app/r/ABC234/x', id: 'D7f x');
      _expectNotRoomLink(
        'https://ludo.provefair.app/r/ABC234/x/',
        id: 'D7f x/',
      );
      expect(
        isAppRoomLinkUri(_u('https://ludo.provefair.app/r/ABC234/x')),
        isFalse,
        reason: 'D7f: three segments are not a room link',
      );
    });

    test('D7g: /r/ and /r with no code never yield a code', () {
      _expectNotRoomLink('https://ludo.provefair.app/r/', id: 'D7g /r/');
      _expectNotRoomLink('https://ludo.provefair.app/r', id: 'D7g /r');
      _expectNotRoomLink('https://ludo.provefair.app/r//', id: 'D7g /r//');
    });

    test('D7h: another scheme, another host, another first segment', () {
      _expectNotRoomLink('http://ludo.provefair.app/r/ABC234/', id: 'D7h http');
      _expectNotRoomLink(
        'https://evil.ludo.provefair.app/r/ABC234/',
        id: 'D7h suffix host',
      );
      _expectNotRoomLink('https://example.com/r/ABC234/', id: 'D7h host');
      _expectNotRoomLink(
        'https://ludo.provefair.app/room/ABC234/',
        id: 'D7h segment',
      );
      for (final String text in <String>[
        'http://ludo.provefair.app/r/ABC234/',
        'https://example.com/r/ABC234/',
        'https://ludo.provefair.app/room/ABC234/',
      ]) {
        expect(
          isAppRoomLinkUri(_u(text)),
          isFalse,
          reason: 'D7h: "$text" is not a room link of this app',
        );
      }
    });

    test('D7i: a bad code with the slash is still a bad code', () {
      _expectNotRoomLink('https://ludo.provefair.app/r/AB0234/', id: 'D7i 0');
      _expectNotRoomLink(
        'https://ludo.provefair.app/r/AB23C/',
        id: 'D7i short',
      );
      _expectNotRoomLink(
        'https://ludo.provefair.app/r/AB23CDE/',
        id: 'D7i long',
      );
    });
  });

  group('D7 Home', () {
    testWidgets(
      'D7j+: a first-time player opened by /r/ABC234/ finds the code filled in',
      (tester) async {
        final _Rig rig = _Rig();
        await _mountWithColdLink(
          tester,
          rig,
          _u('https://ludo.provefair.app/r/ABC234/'),
        );
        final String text = tester
            .widget<TextField>(find.byKey(_codeKey))
            .controller!
            .text;
        expect(
          text,
          _code,
          reason:
              'D7j+: the link with a trailing slash must fill the code field '
              'like the link without one; field holds "$text"',
        );
        expect(
          rig.controllers,
          isEmpty,
          reason: 'D7j+: a first-time player is not pushed into a room',
        );
        await _finish(tester, rig);
      },
    );

    testWidgets('D7k+: a known player opened by /r/ABC234/ joins that room', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session.lastName': 'Nour',
        'session.lastSeats': 4,
      });
      final _Rig rig = _Rig();
      await _mountWithColdLink(
        tester,
        rig,
        _u('https://ludo.provefair.app/r/ABC234/'),
      );
      expect(
        rig.sentTypes(),
        <String>['join_room'],
        reason:
            'D7k+: the link must send one join_room and nothing else; '
            'sent ${rig.sentTypes()}',
      );
      expect(
        rig.firstJoinData(),
        <String, Object?>{'code': _code, 'name': 'Nour'},
        reason: 'D7k+: join_room must carry the link code and the stored name',
      );
      await _finish(tester, rig);
    });
  });
}
