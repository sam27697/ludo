// Widget tests for GameScreen unique-legal auto-move: after a roll whose
// legal list has exactly one token, the screen must hold for 3 seconds
// before calling controller.move, expose an Undo chip that cancels that
// pending call locally, and announce the pending / committed / undone
// states through the accessibility channel. Nothing here edits the
// protocol; Undo must never put a move on the wire.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real controller sits over FakeTransport, and every
// claim about what the screen sent is checked by decoding sentRaw. The
// 3-second hold is advanced on flutter_test's FakeAsync clock via
// tester.pump, not wall time.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://unique-legal-automove-test.invalid/ws';
const Key _rollKey = Key('game-screen-roll-button');
const Key _undoKey = Key('game-automove-undo');
const int _uniqueToken = 2;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'automove-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
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

Future<(RoomController, FakeTransport)> _connectAwaitingRoll(
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
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
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

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

/// Taps Roll, answers with a `rolled` frame whose legal list is [legal],
/// and returns the sentRaw length after the screen has processed that
/// frame. Further `move` frames are counted from that index.
Future<int> _rollWithLegal(
  WidgetTester tester,
  FakeTransport transport, {
  required List<int> legal,
}) async {
  final int sentBeforeRoll = transport.sentRaw.length;
  await tester.tap(find.byKey(_rollKey));
  await tester.pump();
  final List<String> rollMessages = transport.sentRaw
      .skip(sentBeforeRoll)
      .where((s) => _typeOf(s) == 'roll')
      .toList();
  expect(
    rollMessages,
    hasLength(1),
    reason: 'fixture is broken: tapping Roll must send exactly one roll',
  );
  transport.pushText(
    _frame(
      type: 'rolled',
      re: _idOf(rollMessages.single),
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': legal,
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'b' * 64,
        'seq': 2,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  return transport.sentRaw.length;
}

List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((s) => _typeOf(s) == 'move')
      .toList();
}

List<Map<Object?, Object?>> _listenAccessibility(WidgetTester tester) {
  final List<Map<Object?, Object?>> events = <Map<Object?, Object?>>[];
  tester.binding.defaultBinaryMessenger.setMockMessageHandler(
    SystemChannels.accessibility.name,
    (ByteData? data) async {
      if (data == null) {
        return null;
      }
      final Object? decoded = const StandardMessageCodec().decodeMessage(data);
      if (decoded is Map) {
        events.add(Map<Object?, Object?>.from(decoded));
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.accessibility.name,
      null,
    ),
  );
  return events;
}

List<String> _announceMessages(List<Map<Object?, Object?>> events) {
  final List<String> messages = <String>[];
  for (final Map<Object?, Object?> event in events) {
    if (event['type'] != 'announce') {
      continue;
    }
    final Object? data = event['data'];
    if (data is Map && data['message'] is String) {
      final String message = data['message'] as String;
      if (message.isNotEmpty) {
        messages.add(message);
      }
    }
  }
  return messages;
}

void _enableAnnounce(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(supportsAnnounce: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

void main() {
  testWidgets(
    'after a unique-legal roll, no move is sent before 3s then exactly one '
    'move is sent',
    (tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      final int sentAfterRolled = await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[_uniqueToken],
      );

      expect(
        controller.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason:
            'fixture is broken: a unique-legal rolled frame must leave '
            'the turn in awaitMove',
      );
      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'a unique-legal roll must enter a pending hold: no move '
            'frame on the transport before the 3s window elapses',
      );

      await tester.pump(const Duration(milliseconds: 2999));
      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'controller.move must not run before the 3s hold elapses; '
            'got ${_movesSince(transport, sentAfterRolled).length} move '
            'frame(s) at 2999ms',
      );

      await tester.pump(const Duration(milliseconds: 1));
      final List<String> moves = _movesSince(transport, sentAfterRolled);
      expect(
        moves,
        hasLength(1),
        reason:
            'waiting out the 3s hold without Undo must put exactly one '
            'move on the transport; got ${moves.length}',
      );
      expect(_typeOf(moves.single), 'move');
      expect(
        _dataOf(moves.single),
        <String, Object?>{'token': _uniqueToken},
        reason:
            'the auto-move must name the unique legal token '
            '$_uniqueToken; got ${_dataOf(moves.single)}',
      );
    },
  );

  testWidgets(
    'game-automove-undo cancels a pending unique-legal move and sends '
    'nothing on the transport',
    (tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      final int sentAfterRolled = await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[_uniqueToken],
      );

      expect(
        find.byKey(_undoKey),
        findsOneWidget,
        reason:
            'a unique-legal roll must show the Undo chip keyed '
            'game-automove-undo during the 3s hold',
      );

      await tester.tap(find.byKey(_undoKey));
      await tester.pump();

      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'tapping game-automove-undo must cancel the pending move; no '
            'move frame may reach the transport',
      );
      expect(
        controller.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason:
            'Undo cancels only the client-side hold and must leave the '
            'turn in awaitMove',
      );
      expect(
        find.byKey(_undoKey),
        findsNothing,
        reason: 'after Undo, game-automove-undo must leave the tree',
      );

      await tester.pump(const Duration(seconds: 3));
      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'the cancelled auto-move must not fire after the original '
            '3s window; the transport still has no move frame',
      );

      await tester.tap(
        find.byKey(const Key('game-screen-token-$_uniqueToken')),
      );
      await tester.pump();
      final List<String> moves = _movesSince(transport, sentAfterRolled);
      expect(
        moves,
        hasLength(1),
        reason:
            'after Undo, the player must still be able to move the '
            'unique legal token from awaitMove',
      );
      expect(_dataOf(moves.single), <String, Object?>{'token': _uniqueToken});
    },
  );

  testWidgets(
    'Semantics announce fires when a pending unique-legal auto-move starts '
    'and when it commits',
    (tester) async {
      _enableAnnounce(tester);
      final List<Map<Object?, Object?>> events = _listenAccessibility(tester);
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      await _rollWithLegal(tester, transport, legal: const <int>[_uniqueToken]);

      final List<String> started = _announceMessages(events);
      expect(
        started,
        isNotEmpty,
        reason:
            'a unique-legal pending auto-move must fire a Semantics '
            'announce when the hold starts; got $started',
      );

      await tester.pump(const Duration(seconds: 3));
      final List<String> afterCommit = _announceMessages(events);
      expect(
        afterCommit.length,
        greaterThan(started.length),
        reason:
            'committing the unique-legal auto-move after 3s must fire a '
            'further Semantics announce; started with $started, after '
            'commit $afterCommit',
      );
    },
  );

  testWidgets(
    'Semantics announce fires when a pending unique-legal auto-move is '
    'undone',
    (tester) async {
      _enableAnnounce(tester);
      final List<Map<Object?, Object?>> events = _listenAccessibility(tester);
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      await _rollWithLegal(tester, transport, legal: const <int>[_uniqueToken]);

      final List<String> started = _announceMessages(events);
      expect(
        started,
        isNotEmpty,
        reason:
            'a unique-legal pending auto-move must fire a Semantics '
            'announce when the hold starts; got $started',
      );

      expect(find.byKey(_undoKey), findsOneWidget);
      await tester.tap(find.byKey(_undoKey));
      await tester.pump();

      final List<String> afterUndo = _announceMessages(events);
      expect(
        afterUndo.length,
        greaterThan(started.length),
        reason:
            'tapping game-automove-undo must fire a Semantics announce; '
            'started with $started, after Undo $afterUndo',
      );
    },
  );

  testWidgets('a roll with two legal tokens sends no move after 3s', (
    tester,
  ) async {
    final (controller, transport) = await _connectAwaitingRoll(tester);
    await _mount(tester, controller);

    final int sentAfterRolled = await _rollWithLegal(
      tester,
      transport,
      legal: const <int>[0, _uniqueToken],
    );

    await tester.pump(const Duration(seconds: 3));
    expect(
      _movesSince(transport, sentAfterRolled),
      isEmpty,
      reason:
          'auto-move is only for a unique legal token; two legal '
          'tokens must not put a move on the transport after 3s',
    );
    expect(
      find.byKey(_undoKey),
      findsNothing,
      reason:
          'game-automove-undo must not appear when more than one token '
          'is legal',
    );
  });
}
