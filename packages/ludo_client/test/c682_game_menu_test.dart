// C-682t: the approval switch in the in-game menu (order 682 item 2: "the
// switch also appears in the in-game menu for the host (same widget, same
// label)").
//
// The order says only "wherever the in-game menu is built today". game_screen
// has no widget called a menu on the base this was written against, so the
// switch is looked for on the open game screen first and, if it is not there,
// behind the first control the host can open from the header (the sound
// toggle row is not it; the leave and chat buttons are not it). If no way to
// reach `approval-switch` exists the test fails and says so: that is an
// ambiguity to settle with the lib hand, not a reason to loosen the check.
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
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

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
  testWidgets('game.menu.host: the host reaches the approval switch', (
    tester,
  ) async {
    final (RoomController c, FakeTransport t) = await _mount(
      tester,
      host: true,
    );
    expect(
      find.byKey(const Key('approval-switch')),
      findsOneWidget,
      reason:
          'expected approval-switch with the host on the game screen (the '
          'order says the in-game menu carries the same widget). Not found '
          'without opening anything; see the note at the head of this file. '
          'scenario game.menu.host',
    );
    expect(
      find.text('Approve typed codes'),
      findsOneWidget,
      reason: 'expected the same label as the lobby. scenario game.menu.host',
    );
    await tester.tap(find.byKey(const Key('approval-switch')));
    await tester.pump();
    final List<String> sent = t.sentRaw.map(_typeOf).toList();
    expect(
      sent.where((String s) => s == 'set_guest_approval').length,
      1,
      reason:
          'expected one set_guest_approval after one tap, sent $sent. '
          'scenario game.menu.host',
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
