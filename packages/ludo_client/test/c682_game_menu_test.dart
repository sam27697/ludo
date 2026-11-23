// C-682t, re-aimed by C-687t: the approval switch is NOT on the game screen
// (order 687 removed the in-play switch that covered the turn status line;
// order 682 item 2 had put it there).
//
// Replay: flutter test test/c682_game_menu_test.dart --plain-name '<name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

int _n = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _n += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c682g-srv-${_n.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

String _typeOf(String raw) =>
    (jsonDecode(raw) as Map<String, Object?>)['t']! as String;

Map<String, Object?> _room() => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
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
    for (int i = 0; i < 2; i += 1)
      <String, Object?>{
        'seat': i,
        'name': i == 0 ? 'Sam' : 'Bob',
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': i == 0 ? 'host' : 'link',
      },
  ],
  'turn': <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
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

Future<(RoomController, FakeTransport)> _mount(
  WidgetTester tester, {
  required bool host,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(412 * 2.625, 892 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c682-game.invalid/ws'),
    connect: (Uri u) async => transport as WireTransport,
    autoReconnectDelays: const <Duration>[],
  );
  _owned.add(controller);
  final Future<void> pending = host
      ? controller.createRoom(name: 'Sam', players: 2)
      : controller.joinRoom(code: 'K7M2QP', name: 'Bob');
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': host ? 0 : 1,
      'seat_token': 'tok-c682g',
    }),
  );
  transport.pushText(_frame('room', _room(), re: id));
  for (int i = 0; i < 10 && controller.phase != RoomPhase.connected; i += 1) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: expected connected before mounting GameScreen',
  );
  pending.ignore();
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: GameScreen(controller: controller),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return (controller, transport);
}

void main() {
  // A code join waits for the install id (PROTOCOL 32 item 6). Make it once,
  // and give every test a store holding only that id, so a record saved by an
  // earlier test cannot turn the next join into a resume and the join never
  // depends on how the platform-channel failure path resolves under fake async.
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  testWidgets('game.menu.host: the host has no approval switch in play', (
    tester,
  ) async {
    final (RoomController c, FakeTransport t) = await _mount(
      tester,
      host: true,
    );
    expect(
      find.byKey(const Key('approval-switch')),
      findsNothing,
      reason:
          'expected no approval-switch on the game screen for the host in '
          'PLAYING (order 687: it covered the turn status line; no knock can '
          'happen once a game is playing). It was found. scenario '
          'game.menu.host',
    );
    expect(
      find.text('Approve typed codes'),
      findsNothing,
      reason:
          'expected no switch label on the game screen. scenario '
          'game.menu.host',
    );
    expect(
      t.sentRaw.map(_typeOf).where((String s) => s == 'set_guest_approval'),
      isEmpty,
      reason: 'expected no set_guest_approval sent. scenario game.menu.host',
    );
    expect(c.room, isNotNull);
  });

  testWidgets('game.menu.guest: a guest never gets the switch', (tester) async {
    await _mount(tester, host: false);
    expect(
      find.byKey(const Key('approval-switch')),
      findsNothing,
      reason: 'guest must not see approval-switch. scenario game.menu.guest',
    );
    expect(find.text('Approve typed codes'), findsNothing);
  });
}
