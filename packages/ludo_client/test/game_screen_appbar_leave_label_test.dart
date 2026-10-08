// Widget tests for GameScreen's corner leave control. The key
// game-screen-appbar-leave is the old AppBar action's key, kept. The control
// is an IconButton with Icons.close, tooltip gameLeaveButton, at least
// 48x48, and it must not use Icons.logout. In a playing game with my seat a
// tap opens game-leave-confirm, and Leave in that sheet pops the route
// within one second. The control sits in the left half in en and the right
// half in ar.
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
const Key _confirmKey = Key('game-leave-confirm');
const Key _confirmLeaveKey = Key('game-leave-confirm-leave');

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
    'game-screen-appbar-leave tooltip equals gameLeaveButton and the icon '
    'is Icons.close',
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

      final Widget widget = tester.widget(leave);
      expect(
        widget,
        isA<IconButton>(),
        reason:
            'game-screen-appbar-leave must be an IconButton, found '
            '${widget.runtimeType}',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        (widget as IconButton).tooltip,
        loc.gameLeaveButton,
        reason:
            'game-screen-appbar-leave tooltip must equal gameLeaveButton, '
            'which reads "${loc.gameLeaveButton}"',
      );
      expect(
        find.descendant(of: leave, matching: find.byIcon(Icons.close)),
        findsOneWidget,
        reason: 'game-screen-appbar-leave must show Icons.close',
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
    'tapping game-screen-appbar-leave opens game-leave-confirm and Leave '
    'there pops GameScreen within one second',
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
      // Sheet enter is 250ms. Bounded pumps, not pumpAndSettle: the turn
      // countdown's ticker would keep settle from returning.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'the screen popped; the corner tap must open the confirm',
      );
      expect(find.byKey(_confirmKey), findsOneWidget, reason: 'no sheet shown');
      expect(
        find.byKey(_confirmLeaveKey),
        findsOneWidget,
        reason: 'game-leave-confirm-leave must be present to tap',
      );
      await tester.tap(find.byKey(_confirmLeaveKey));

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'GameScreen must be gone from the navigator within one '
            'second of pumped time after tapping game-leave-confirm-leave, '
            'even though transport.sentRaw grew by only '
            '${transport.sentRaw.length - sentBefore} message(s) and none '
            'was ever answered',
      );
    },
  );

  testWidgets(
    'English locale: game-screen-appbar-leave sits in the left half',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
      final double mid =
          tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;
      final double center = tester.getCenter(leave).dx;
      expect(
        center < mid,
        isTrue,
        reason:
            'en: game-screen-appbar-leave must sit in the left half; '
            'center dx was $center, view midpoint was $mid',
      );
    },
  );

  testWidgets(
    'Arabic locale: game-screen-appbar-leave sits in the right half',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      final Finder leave = find.byKey(_appbarLeaveKey);
      expect(
        leave,
        findsOneWidget,
        reason: 'fixture is broken: game-screen-appbar-leave must be present',
      );
      final double mid =
          tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;
      final double center = tester.getCenter(leave).dx;
      expect(
        center > mid,
        isTrue,
        reason:
            'ar: game-screen-appbar-leave must sit in the right half; '
            'center dx was $center, view midpoint was $mid',
      );
    },
  );
}
