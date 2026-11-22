// C-687t: the host's turn status line is not covered during play (order 687).
//
// Host in PLAYING, en and ar, 320 and 393 dp, text scale 1.0 and 2.0:
//   - no `approval-switch` on the game screen;
//   - the turn banner is the top-most hit at its own centre;
// and the lobby still shows the switch for the host and not for a guest.
//
// Replay: flutter test test/c687_status_line_clear_test.dart --plain-name '<id>'
// The id of every case is its combination, e.g. 'host.play en w320 s2.0'.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

int _n = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _n += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c687-srv-${_n.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _room({required String state, required int players}) =>
    <String, Object?>{
      'code': 'K7M2QP',
      'state': state,
      'host_seat': 0,
      'players': players,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'a' * 64,
      'chain_index': 0,
      'game_id': null,
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        for (int i = 0; i < players; i += 1)
          <String, Object?>{
            'seat': i,
            'name': i == 0 ? 'Sam' : 'Bob$i',
            'connected': true,
            'tokens': const <int>[-1, -1, -1, -1],
            'client_seed': null,
            'seed_origin': null,
            'via': i == 0 ? 'host' : 'link',
          },
      ],
      'turn': state == 'PLAYING'
          ? <String, Object?>{
              'seat': 0,
              'phase': 'await_roll',
              'deadline_ms': 45000,
              'k': 0,
            }
          : null,
      'winner': null,
      'seq': 5,
      'link_id': 't5k2q9a-x7m3pd',
      'guest_approval': false,
      'knocks': const <Object?>[],
    };

final List<RoomController> _owned = <RoomController>[];

void testWidgets(String d, Future<void> Function(WidgetTester t) body) {
  ft.testWidgets(d, (WidgetTester tester) async {
    _owned.clear();
    try {
      await body(tester);
    } finally {
      for (final RoomController c in _owned) {
        c.dispose();
      }
      _owned.clear();
      await tester.pump(const Duration(seconds: 11));
    }
  });
}

Widget _app(Locale locale, double scale, Widget home) => MaterialApp(
  locale: locale,
  supportedLocales: appSupportedLocales,
  localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  builder: (BuildContext context, Widget? child) {
    final MediaQueryData data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    );
  },
  home: home,
);

void _size(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width * 2, 800 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Connects a controller as host or guest and feeds it one room snapshot.
Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester, {
  required bool host,
  required String state,
  required int players,
  required Future<void> Function(RoomController) mount,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c687.invalid/ws'),
    connect: (Uri u) async => transport as WireTransport,
    autoReconnectDelays: const <Duration>[],
  );
  _owned.add(controller);
  final Future<void> pending = host
      ? controller.createRoom(name: 'Sam', players: players)
      : controller.joinRoom(code: 'K7M2QP', name: 'Bob1');
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': host ? 0 : 1,
      'seat_token': 'tok-c687',
    }),
  );
  transport.pushText(
    _frame(
      'room',
      _room(state: state, players: players),
      re: id,
    ),
  );
  for (int i = 0; i < 10 && controller.phase != RoomPhase.connected; i += 1) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: expected connected before mounting',
  );
  pending.ignore();
  await mount(controller);
  return (controller, transport);
}

String _why(String id) =>
    "scenario '$id'. reproduce: flutter test "
    "test/c687_status_line_clear_test.dart --plain-name '$id'";

void main() {
  const Key switchKey = Key('approval-switch');
  const Key bannerKey = Key('game-screen-turn-banner');

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final double width in const <double>[320, 393]) {
      for (final double scale in const <double>[1.0, 2.0]) {
        final String id =
            'host.play ${locale.languageCode} w${width.toInt()} s$scale';

        testWidgets('$id: no approval switch', (tester) async {
          _size(tester, width);
          await _connect(
            tester,
            host: true,
            state: 'PLAYING',
            players: 4,
            mount: (RoomController c) async {
              await tester.pumpWidget(
                _app(locale, scale, GameScreen(controller: c)),
              );
              await tester.pump();
              await tester.pump(const Duration(seconds: 1));
            },
          );

          expect(
            find.byKey(switchKey),
            findsNothing,
            reason:
                'expected no approval-switch on the game screen as host in '
                'PLAYING; found one. ${_why(id)}',
          );
        });

        testWidgets('$id: turn banner is top-most', (tester) async {
          _size(tester, width);
          await _connect(
            tester,
            host: true,
            state: 'PLAYING',
            players: 4,
            mount: (RoomController c) async {
              await tester.pumpWidget(
                _app(locale, scale, GameScreen(controller: c)),
              );
              await tester.pump();
              await tester.pump(const Duration(seconds: 1));
            },
          );

          expect(
            find.byKey(bannerKey),
            findsOneWidget,
            reason: 'expected one turn banner. ${_why(id)}',
          );
          final RenderObject banner = tester.renderObject(
            find.byKey(bannerKey),
          );
          final Offset centre = tester.getCenter(find.byKey(bannerKey));
          final HitTestResult hit = tester.hitTestOnBinding(centre);
          final List<RenderObject> objects = <RenderObject>[
            for (final HitTestEntry e in hit.path)
              if (e.target is RenderObject) e.target as RenderObject,
          ];
          final int bannerAt = objects.indexOf(banner);
          expect(
            bannerAt,
            isNot(-1),
            reason:
                'expected the banner render object in the hit path at its '
                'centre $centre; path was '
                '${objects.map((RenderObject o) => o.runtimeType).toList()}. '
                '${_why(id)}',
          );
          // Everything hit before the banner would be drawn over it.
          final List<RenderObject> above = objects.sublist(0, bannerAt);
          final List<String> textAbove = <String>[
            for (final RenderObject o in above)
              if (o is RenderParagraph) o.text.toPlainText(),
          ];
          expect(
            textAbove,
            isEmpty,
            reason:
                'expected no other text-bearing widget above the banner at '
                '$centre; found $textAbove. ${_why(id)}',
          );
          expect(
            above.whereType<RenderParagraph>(),
            isEmpty,
            reason: 'expected the banner first. ${_why(id)}',
          );
        });
      }
    }
  }

  for (final bool host in const <bool>[true, false]) {
    final String id = 'lobby.${host ? 'host_sees' : 'guest_blind'}';
    testWidgets('$id: the lobby switch is for the host only', (tester) async {
      _size(tester, 393);
      await _connect(
        tester,
        host: host,
        state: 'LOBBY',
        players: 4,
        mount: (RoomController c) async {
          await tester.pumpWidget(
            _app(
              const Locale('en'),
              1.0,
              LobbyScreen(
                controller: c,
                action: host ? LobbyAction.create : LobbyAction.join,
                code: host ? null : 'K7M2QP',
                playerName: host ? 'Sam' : 'Bob1',
                players: 4,
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
        },
      );
      expect(
        find.byKey(switchKey),
        host ? findsOneWidget : findsNothing,
        reason:
            'expected the lobby switch ${host ? 'present for the host' : 'absent for a guest'}. ${_why(id)}',
      );
      expect(
        find.text('Approve typed codes'),
        host ? findsOneWidget : findsNothing,
        reason: 'expected the switch label to match. ${_why(id)}',
      );
    });
  }
}
