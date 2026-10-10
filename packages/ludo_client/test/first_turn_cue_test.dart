// Route tests for C-293 rule 3: the first turn's your_turn is not lost
// when game_started and the standalone turn (PROTOCOL 13.1) both arrive
// before GameScreen mounts.
//
// Same mount as test/room_route_test.dart: RoomRoute over a real
// RoomController and FakeTransport (test/net/fake_transport.dart,
// read-only). The fake FeedbackService is the one the feedback tests
// inject, a FeedbackScope above the route that records every play. One
// mount per case. No pumpAndSettle (the lobby, then the countdown, are
// live) and no pumpEventQueue inside the test body.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://first-turn-cue.invalid/ws';
const String _code = 'ABC234';
const String _gameId = 'aaaaaaaaaaaaaaaa';

const Key _startKey = Key('lobby-start-button');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c293-cue-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required int seq,
  required List<Map<String, Object?>> seats,
}) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
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
  'seats': seats,
  'turn': null,
  'winner': null,
  'rematch': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: connect() has no transport queued');
    }
    return _queue.removeAt(0);
  }
}

class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

class _Table {
  _Table(this.controller, this.transport, this.feedback);

  final RoomController controller;
  final FakeTransport transport;
  final _FakeFeedbackService feedback;
  int seq = 0;
}

Widget _harness(Widget child, _FakeFeedbackService feedback) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: FeedbackScope(
      settings: FeedbackSettings.forTest(),
      service: feedback,
      child: child,
    ),
  );
}

Future<void> _finish(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

int _yourTurnCount(_FakeFeedbackService feedback) {
  return feedback.recorded
      .where((FeedbackCue cue) => cue == FeedbackCue.yourTurn)
      .length;
}

Future<_Table> _mountLobby(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _FakeFeedbackService feedback = _FakeFeedbackService();
  final _Table table = _Table(controller, transport, feedback);

  await tester.pumpWidget(
    _harness(
      RoomRoute(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 2,
      ),
      feedback,
    ),
  );
  await tester.pump();
  final String createId = _idOf(transport.sentRaw.last);
  expect(_typeOf(transport.sentRaw.last), 'create_room');

  table.seq = 1;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
        seq: table.seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  table.seq = 2;
  transport.pushText(
    _frame(
      type: 'player_joined',
      data: <String, Object?>{'seat': 1, 'name': 'Bob', 'seq': table.seq},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(controller.room!.state, RoomState.lobby);
  expect(find.byType(GameScreen), findsNothing);
  return table;
}

Future<String> _tapStart(WidgetTester tester, _Table table) async {
  final Finder start = find.byKey(_startKey);
  expect(start, findsOneWidget);
  await tester.ensureVisible(start);
  await tester.tap(start);
  await tester.pump();
  final List<String> starts = table.transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'start_game')
      .toList();
  expect(starts, hasLength(1));
  return _idOf(starts.single);
}

String _gameStarted(_Table table, {required int turnSeat, required String re}) {
  table.seq += 1;
  return _frame(
    type: 'game_started',
    re: re,
    data: <String, Object?>{
      'turn': turnSeat,
      'game_id': _gameId,
      'client_seeds': '0:seed',
      'seq': table.seq,
    },
  );
}

String _turn(_Table table, {required int seat, String? re}) {
  table.seq += 1;
  return _frame(
    type: 'turn',
    re: re,
    data: <String, Object?>{
      'seat': seat,
      'deadline_ms': 45000,
      'seq': table.seq,
    },
  );
}

void _expectYourTurns(
  _FakeFeedbackService feedback,
  int expected, {
  required String reason,
}) {
  expect(
    _yourTurnCount(feedback),
    expected,
    reason: '$reason; recorded ${feedback.recorded}',
  );
}

void main() {
  testWidgets(
    '5. game_started and the host turn arrive before the game screen: '
    'your_turn once',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        final String startId = await _tapStart(tester, table);

        // No pump between these two. Both are queued before GameScreen
        // exists, which is what one socket read does with PROTOCOL 13.1.
        table.transport.pushText(_gameStarted(table, turnSeat: 0, re: startId));
        table.transport.pushText(_turn(table, seat: 0, re: startId));
        await tester.pump();
        await tester.pump();
        expect(find.byType(GameScreen), findsOneWidget);
        expect(find.byType(LobbyScreen), findsNothing);
        // A post-frame read of the transcript, if that is where the cue
        // is played, runs on the pump that mounted the screen. One more
        // bounded pump covers a callback parked for the frame after that.
        await tester.pump();

        _expectYourTurns(
          table.feedback,
          1,
          reason:
              'your_turn must be recorded exactly once for the host\'s '
              'first turn when both frames land before the mount',
        );
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets(
    '6. control: the host turn arrives after GameScreen is up: your_turn once',
    (WidgetTester tester) async {
      RoomController? controller;
      try {
        final _Table table = await _mountLobby(tester);
        controller = table.controller;
        final String startId = await _tapStart(tester, table);

        table.transport.pushText(_gameStarted(table, turnSeat: 0, re: startId));
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'the turn is delivered only once GameScreen is on screen',
        );

        table.transport.pushText(_turn(table, seat: 0));
        await tester.pump();
        await tester.pump();

        _expectYourTurns(
          table.feedback,
          1,
          reason:
              'your_turn must be recorded exactly once when the host\'s '
              'first turn arrives after the screen has subscribed',
        );
      } finally {
        if (controller != null) {
          await _finish(tester, controller);
        }
      }
    },
  );

  testWidgets('7. the first turn is the guest\'s, delivered before the mount: '
      'your_turn never', (WidgetTester tester) async {
    RoomController? controller;
    try {
      final _Table table = await _mountLobby(tester);
      controller = table.controller;
      final String startId = await _tapStart(tester, table);

      // Host is seat 0. The opening turn names seat 1, and both frames
      // are queued before the game screen mounts.
      table.transport.pushText(_gameStarted(table, turnSeat: 1, re: startId));
      table.transport.pushText(_turn(table, seat: 1, re: startId));
      await tester.pump();
      await tester.pump();
      expect(find.byType(GameScreen), findsOneWidget);
      expect(table.controller.room!.turn!.seat, 1);
      await tester.pump();

      _expectYourTurns(
        table.feedback,
        0,
        reason:
            'your_turn must not play for the host when the first turn '
            'is the guest\'s',
      );
    } finally {
      if (controller != null) {
        await _finish(tester, controller);
      }
    }
  });
}
