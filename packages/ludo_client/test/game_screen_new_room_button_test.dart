// Widget tests for the finished-game next-table control: when the room is
// finished, game-screen-new-room-button must be on screen, and tapping it
// must leave the finished room and then create a fresh one. That path is
// not the AppBar leave control, which still pops and must not send
// create_room.
//
// Drive RoomController over FakeTransport the same way
// test/composed_play_test.dart and test/game_screen_test.dart do. Room
// snapshots arrive as protocol frames. HomeScreen is pumped with an
// injected controllerFactory so a second create_room is visible on the
// wire (or as a new LobbyAction.create with a new controller).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _appbarLeaveKey = Key('game-screen-appbar-leave');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'new-room-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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
  String state = 'FINISHED',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner = 0,
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
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ],
  'turn': turn,
  'winner': winner,
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

class _RecordingControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

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
}

Future<(RoomController, FakeTransport)> _connectFinished(
  WidgetTester tester,
) async {
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
      data: _roomJson(
        turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
      ),
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

Widget _homeScreenApp(RoomControllerFactory controllerFactory) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// RoomConnection's request timeout is ten seconds. Advance past it so a
/// leave_room or create_room that this test never answers does not leave a
/// pending timer for flutter_test to fail the tear-down over.
Future<void> _flushOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

List<String> _sentOfType(List<FakeTransport> transports, String type) {
  return <String>[
    for (final FakeTransport transport in transports)
      ...transport.sentRaw.where((String raw) => _typeOf(raw) == type),
  ];
}

List<String> _allTypes(List<FakeTransport> transports) {
  return <String>[
    for (final FakeTransport transport in transports)
      ...transport.sentRaw.map(_typeOf),
  ];
}

Future<void> _answerOpenLeaveRooms(
  WidgetTester tester,
  List<FakeTransport> transports,
) async {
  for (final FakeTransport transport in transports) {
    if (transport.isClosed) {
      continue;
    }
    for (final String raw in transport.sentRaw) {
      if (_typeOf(raw) != 'leave_room') {
        continue;
      }
      transport.pushText(
        _frame(
          type: 'player_left',
          re: _idOf(raw),
          data: <String, Object?>{'seat': 0, 'seq': 99},
        ),
      );
    }
  }
  await tester.pump();
}

/// Create from HomeScreen and land on a finished GameScreen, using the
/// server's finished snapshot as the create_room reply so RoomRoute latches
/// without a protocol rematch.
Future<_RecordingControllerFactory> _reachFinishedGameFromHome(
  WidgetTester tester,
) async {
  final _RecordingControllerFactory factory = _RecordingControllerFactory();
  await tester.pumpWidget(_homeScreenApp(factory.call));
  await tester.pumpAndSettle();

  await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

  expect(
    factory.controllers,
    hasLength(1),
    reason: 'fixture is broken: Create Room must build exactly one controller',
  );
  final FakeTransport transport = factory.transports.single;
  final List<String> createMessages = _sentOfType(
    factory.transports,
    'create_room',
  );
  expect(
    createMessages,
    hasLength(1),
    reason:
        'fixture is broken: expected exactly one create_room after tapping '
        'Create Room; sent ${_allTypes(factory.transports)}',
  );

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-home-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: _idOf(createMessages.single),
      data: _roomJson(
        turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    factory.controllers.single.room!.state,
    RoomState.finished,
    reason: 'fixture is broken: the room reply must be RoomState.finished',
  );
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason:
        'fixture is broken: a finished room must latch RoomRoute onto '
        'GameScreen',
  );
  return factory;
}

void main() {
  testWidgets('finished GameScreen shows game-screen-new-room-button', (
    tester,
  ) async {
    final (controller, _) = await _connectFinished(tester);
    addTearDown(controller.dispose);
    expect(
      controller.room!.state,
      RoomState.finished,
      reason: 'fixture is broken',
    );

    await tester.pumpWidget(_harness(GameScreen(controller: controller)));
    await tester.pump();

    expect(
      find.byKey(_newRoomKey),
      findsOneWidget,
      reason:
          'when room.state is finished, game-screen-new-room-button must '
          'be present',
    );
  });

  testWidgets(
    'tapping game-screen-new-room-button leaves then creates a fresh room',
    (tester) async {
      final _RecordingControllerFactory factory =
          await _reachFinishedGameFromHome(tester);
      final RoomController firstController = factory.controllers.single;
      addTearDown(() {
        for (final RoomController controller in factory.controllers) {
          try {
            controller.dispose();
          } catch (_) {}
        }
      });

      expect(
        find.byKey(_appbarLeaveKey),
        findsOneWidget,
        reason: 'fixture is broken: game-screen-appbar-leave must still exist',
      );
      expect(
        find.byKey(_newRoomKey),
        findsOneWidget,
        reason:
            'game-screen-new-room-button must be present on the finished '
            'board before it can be tapped; it is not the AppBar leave key',
      );
      expect(
        tester.widget(find.byKey(_newRoomKey)),
        isNot(same(tester.widget(find.byKey(_appbarLeaveKey)))),
        reason:
            'game-screen-new-room-button and game-screen-appbar-leave must '
            'be different widgets, not one control with two keys',
      );

      final int createBefore = _sentOfType(
        factory.transports,
        'create_room',
      ).length;
      expect(createBefore, 1, reason: 'fixture is broken');

      await tester.tap(find.byKey(_newRoomKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _answerOpenLeaveRooms(tester, factory.transports);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        _allTypes(factory.transports).where(
          (String type) =>
              type.contains('rematch') ||
              type == 'restart_game' ||
              type == 'new_game',
        ),
        isEmpty,
        reason:
            'the next table must not use a protocol rematch; create a '
            'fresh room instead',
      );

      final bool leftFinishedRoom =
          _sentOfType(factory.transports, 'leave_room').isNotEmpty ||
          firstController.phase == RoomPhase.closed;
      expect(
        leftFinishedRoom,
        isTrue,
        reason:
            'tapping game-screen-new-room-button must leave() the finished '
            'room (leave_room on the wire, or the first controller closed) '
            'before a new table is created; sent '
            '${_allTypes(factory.transports)}',
      );

      final List<String> createAfter = _sentOfType(
        factory.transports,
        'create_room',
      );
      LobbyScreen? createLobby;
      final Finder lobbyFinder = find.byType(LobbyScreen);
      if (lobbyFinder.evaluate().length == 1) {
        final LobbyScreen lobby = tester.widget<LobbyScreen>(lobbyFinder);
        if (lobby.action == LobbyAction.create &&
            !identical(lobby.controller, firstController)) {
          createLobby = lobby;
        }
      }
      expect(
        createAfter.length >= 2 || createLobby != null,
        isTrue,
        reason:
            'tapping game-screen-new-room-button must then create a fresh '
            'room: a second create_room on the wire, or LobbyAction.create '
            'pushed with a new controller. create_room count was '
            '${createAfter.length}; controllers: '
            '${factory.controllers.length}; sent '
            '${_allTypes(factory.transports)}',
      );

      await _flushOutstandingRequestTimeout(tester);
    },
  );

  testWidgets(
    'tapping game-screen-appbar-leave on a finished game pops without '
    'sending create_room',
    (tester) async {
      final _RecordingControllerFactory factory =
          await _reachFinishedGameFromHome(tester);
      addTearDown(() {
        for (final RoomController controller in factory.controllers) {
          try {
            controller.dispose();
          } catch (_) {}
        }
      });

      expect(
        find.byKey(_appbarLeaveKey),
        findsOneWidget,
        reason: 'fixture is broken: game-screen-appbar-leave must be present',
      );

      final int createBefore = _sentOfType(
        factory.transports,
        'create_room',
      ).length;
      expect(createBefore, 1, reason: 'fixture is broken');

      await tester.tap(find.byKey(_appbarLeaveKey));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byType(GameScreen),
        findsNothing,
        reason:
            'tapping game-screen-appbar-leave on a finished game must pop '
            'GameScreen',
      );

      await _answerOpenLeaveRooms(tester, factory.transports);
      await tester.pump();
      await _flushOutstandingRequestTimeout(tester);

      expect(
        _sentOfType(factory.transports, 'create_room'),
        hasLength(createBefore),
        reason:
            'game-screen-appbar-leave must not send create_room; saw '
            '${_allTypes(factory.transports)}',
      );
    },
  );
}
