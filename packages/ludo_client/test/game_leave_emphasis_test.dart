// Widget tests for GameScreen connection-lost Leave emphasis: Leave must be
// secondary (OutlinedButton or TextButton) beside a primary ElevatedButton
// Reconnect, and tapping Leave must still pop the route promptly.

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
const Key _leaveButtonKey = Key('game-screen-leave-button');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-emph-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  'value': null,
  'legal': null,
  'sixes': null,
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

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

Future<(RoomController, FakeTransport)> _mountConnectionLost(
  WidgetTester tester, {
  required Widget Function(RoomController controller) homeBuilder,
}) async {
  final List<Map<String, Object?>> seats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];
  final Map<String, Object?> turn = _turnJson(
    seat: 0,
    phase: 'await_roll',
    deadlineMs: 1000,
    k: 0,
  );
  final (controller, transport) = await _connectPlaying(
    tester,
    seats: seats,
    turn: turn,
  );
  addTearDown(controller.dispose);

  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.closed,
    reason: 'fixture is broken: far-side close must set RoomPhase.closed',
  );

  await tester.pumpWidget(_harness(homeBuilder(controller)));
  await tester.pump();
  return (controller, transport);
}

Widget _keyedButton(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget);
  return tester.widget(find.byKey(key));
}

void main() {
  testWidgets('game-screen-leave-button is OutlinedButton or TextButton, not '
      'ElevatedButton', (WidgetTester tester) async {
    await _mountConnectionLost(
      tester,
      homeBuilder: (controller) => GameScreen(controller: controller),
    );

    final Widget leave = _keyedButton(tester, _leaveButtonKey);
    expect(
      leave is OutlinedButton || leave is TextButton,
      isTrue,
      reason:
          'game-screen-leave-button must be OutlinedButton or TextButton '
          '(secondary next to Reconnect); found ${leave.runtimeType}',
    );
    expect(
      leave,
      isNot(isA<ElevatedButton>()),
      reason:
          'game-screen-leave-button must not be ElevatedButton; found '
          '${leave.runtimeType}',
    );
  });

  testWidgets('Reconnect stays ElevatedButton and Leave still pops within 1s', (
    WidgetTester tester,
  ) async {
    await _mountConnectionLost(
      tester,
      homeBuilder: (controller) => Navigator(
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          builder: (_) => GameScreen(controller: controller),
        ),
      ),
    );

    final Widget reconnect = _keyedButton(tester, _reconnectButtonKey);
    expect(
      reconnect,
      isA<ElevatedButton>(),
      reason:
          'game-screen-reconnect-button must remain ElevatedButton; found '
          '${reconnect.runtimeType}',
    );

    final Widget leave = _keyedButton(tester, _leaveButtonKey);
    expect(
      leave is OutlinedButton || leave is TextButton,
      isTrue,
      reason:
          'game-screen-leave-button must be OutlinedButton or TextButton '
          'so Leave is secondary to Reconnect; found ${leave.runtimeType}',
    );

    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: 'fixture is broken: GameScreen must be on the navigator',
    );
    await tester.tap(find.byKey(_leaveButtonKey));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byType(GameScreen),
      findsNothing,
      reason:
          'tapping game-screen-leave-button must remove GameScreen from '
          'the navigator within one second of pumped time',
    );
  });
}
