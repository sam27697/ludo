// Widget tests for GameScreen's AppBar leave control: the control must show
// the localised leave verb as visible text, must not use a logout icon, must
// stay at least 48x48, must still pop the route, and must keep an Arabic
// AppBar in rtl.
//
// GameScreen is driven the same way test/game_screen_connection_lost_test.dart
// drives RoomController: a real RoomController over FakeTransport, no real
// sockets. Room snapshots arrive as protocol frames, never as hand-built
// RoomSnapshot objects.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _appbarLeaveKey = Key('game-screen-appbar-leave');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-lbl-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  // pumpEventQueue() uses real Timers via Future.delayed and never fires
  // under testWidgets' fake-async clock. runAsync() steps out of that zone
  // so the connect handshake can complete.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

final List<Map<String, Object?>> _midGameSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _midGameTurn() =>
    _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0);

void main() {
  testWidgets(
    'game-screen-appbar-leave descendant text equals gameLeaveButton',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        seats: _midGameSeats,
        turn: _midGameTurn(),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      final Finder leave = find.byKey(_appbarLeaveKey);
      expect(
        leave,
        findsOneWidget,
        reason: 'fixture is broken: game-screen-appbar-leave must be present',
      );

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final Finder leaveText = find.descendant(
        of: leave,
        matching: find.text(loc.gameLeaveButton),
      );
      expect(
        leaveText,
        findsOneWidget,
        reason:
            'game-screen-appbar-leave must have visible descendant text '
            'equal to gameLeaveButton; a tooltip is not descendant text',
      );
    },
  );

  testWidgets('find.byIcon Icons.logout finds nothing on GameScreen', (
    tester,
  ) async {
    final (controller, _) = await _connectPlaying(
      tester,
      seats: _midGameSeats,
      turn: _midGameTurn(),
    );
    addTearDown(controller.dispose);

    await _mount(tester, controller);

    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: 'fixture is broken: GameScreen must be mounted',
    );
    expect(
      find.descendant(
        of: find.byType(GameScreen),
        matching: find.byIcon(Icons.logout),
      ),
      findsNothing,
      reason:
          'GameScreen must not contain Icons.logout; leave is a verb, '
          'not an account-logout glyph',
    );
  });

  testWidgets('game-screen-appbar-leave is at least 48 by 48', (tester) async {
    final (controller, _) = await _connectPlaying(
      tester,
      seats: _midGameSeats,
      turn: _midGameTurn(),
    );
    addTearDown(controller.dispose);

    await _mount(tester, controller);

    final Finder leave = find.byKey(_appbarLeaveKey);
    expect(
      leave,
      findsOneWidget,
      reason: 'fixture is broken: game-screen-appbar-leave must be present',
    );
    final Size size = tester.getSize(leave);
    expect(
      size.width,
      greaterThanOrEqualTo(48.0),
      reason:
          'game-screen-appbar-leave width must be at least 48, was '
          '${size.width}',
    );
    expect(
      size.height,
      greaterThanOrEqualTo(48.0),
      reason:
          'game-screen-appbar-leave height must be at least 48, was '
          '${size.height}',
    );
  });

  testWidgets(
    'tapping game-screen-appbar-leave pops GameScreen within one second',
    (tester) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        seats: _midGameSeats,
        turn: _midGameTurn(),
      );
      addTearDown(controller.dispose);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken',
      );

      final int sentBefore = transport.sentRaw.length;

      await tester.pumpWidget(
        _harness(
          Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                key: const Key('previous-route'),
                body: Builder(
                  builder: (innerContext) => ElevatedButton(
                    key: const Key('open-game-screen'),
                    onPressed: () {
                      Navigator.of(innerContext).push(
                        MaterialPageRoute<void>(
                          builder: (_) => GameScreen(controller: controller),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('open-game-screen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'fixture is broken: GameScreen must have been pushed',
      );

      expect(
        find.byKey(_appbarLeaveKey),
        findsOneWidget,
        reason: 'game-screen-appbar-leave must be present to tap',
      );
      await tester.tap(find.byKey(_appbarLeaveKey));

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'GameScreen must be gone from the navigator within one '
            'second of pumped time after tapping game-screen-appbar-leave, '
            'even though transport.sentRaw grew by only '
            '${transport.sentRaw.length - sentBefore} message(s) and none '
            'was ever answered',
      );
    },
  );

  testWidgets('Arabic locale GameScreen AppBar Directionality is rtl', (
    tester,
  ) async {
    final (controller, _) = await _connectPlaying(
      tester,
      seats: <Map<String, Object?>>[
        _seatJson(0, name: 'سام'),
        _seatJson(1, name: 'بوب'),
      ],
      turn: _midGameTurn(),
    );
    addTearDown(controller.dispose);

    await _mount(tester, controller, locale: const Locale('ar'));

    final Finder appBar = find.descendant(
      of: find.byType(GameScreen),
      matching: find.byType(AppBar),
    );
    expect(
      appBar,
      findsOneWidget,
      reason: 'fixture is broken: GameScreen must build an AppBar',
    );
    expect(
      Directionality.of(tester.element(appBar)),
      TextDirection.rtl,
      reason:
          'pumping GameScreen in Locale(ar) must resolve the AppBar '
          'Directionality to rtl',
    );
  });
}
