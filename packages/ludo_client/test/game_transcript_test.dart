// RoomController.gameTranscript, C-293 rule 1. The controller alone, over
// FakeTransport (test/net/fake_transport.dart, read-only). No widget.
//
// On this base RoomController has no gameTranscript getter, so this file
// does not compile. The reads go through _transcriptOf so that missing
// getter is the one error. The reconnect case follows
// test/net/room_controller_test.dart: end the transport from the far side,
// then reconnect() on the same controller onto a second FakeTransport.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://game-transcript.invalid/ws';
const String _code = 'K7M2QP';
const String _gameA = 'aaaaaaaaaaaaaaaa';
const String _gameB = 'bbbbbbbbbbbbbbbb';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c293-trn-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat) => <String, Object?>{
  'seat': seat,
  'name': 'Sam',
  'connected': true,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  required int seq,
  String state = 'LOBBY',
  String? gameId,
  String? clientSeeds,
  Map<String, Object?>? turn,
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': <Map<String, Object?>>[_seatJson(0)],
  'turn': turn,
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

class _Open {
  _Open(this.controller, this.transport, this.connector);

  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;
  int seq = 1;
}

/// The one read of the getter. It is not on RoomController on this base.
List<Frame> _transcriptOf(RoomController controller) {
  return controller.gameTranscript;
}

List<String> _types(RoomController controller) {
  return _transcriptOf(controller).map((Frame frame) => frame.type).toList();
}

Future<_Open> _connectLobby() async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await pumpEventQueue();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson(seq: 1)));
  await future;
  await pumpEventQueue();
  expect(controller.phase, RoomPhase.connected);
  expect(controller.room!.state, RoomState.lobby);
  return _Open(controller, transport, connector);
}

Future<void> _push(
  FakeTransport transport,
  String type,
  Map<String, Object?> data,
) async {
  transport.pushText(_frame(type: type, data: data));
  await pumpEventQueue();
}

Future<void> _pushGameStarted(_Open open, {required String gameId}) async {
  open.seq += 1;
  await _push(open.transport, 'game_started', <String, Object?>{
    'turn': 0,
    'game_id': gameId,
    'client_seeds': '0:seed',
    'seq': open.seq,
  });
}

Future<void> _pushTurn(_Open open, {required int seat}) async {
  open.seq += 1;
  await _push(open.transport, 'turn', <String, Object?>{
    'seat': seat,
    'deadline_ms': 45000,
    'seq': open.seq,
  });
}

Future<void> _pushRolled(_Open open, {required int value}) async {
  open.seq += 1;
  await _push(open.transport, 'rolled', <String, Object?>{
    'seat': 0,
    'value': value,
    'legal': <int>[0, 1],
    'deadline_ms': 45000,
    'k': 1,
    'reveal': 'a' * 64,
    'seq': open.seq,
  });
}

void main() {
  test('8. empty before any game_started', () async {
    final _Open open = await _connectLobby();
    try {
      expect(open.controller.room, isNotNull);
      expect(_transcriptOf(open.controller), isEmpty);
    } finally {
      open.controller.dispose();
    }
  });

  test('9. opens on game_started, later frames follow in order', () async {
    final _Open open = await _connectLobby();
    try {
      await _pushGameStarted(open, gameId: _gameA);
      await _pushTurn(open, seat: 0);
      await _pushRolled(open, value: 6);

      expect(_types(open.controller), <String>[
        'game_started',
        'turn',
        'rolled',
      ]);
      expect(_transcriptOf(open.controller).first.type, 'game_started');
      expect(_transcriptOf(open.controller).first.data['game_id'], _gameA);
    } finally {
      open.controller.dispose();
    }
  });

  test('10. a second game_started with the same game_id appends', () async {
    final _Open open = await _connectLobby();
    try {
      await _pushGameStarted(open, gameId: _gameA);
      await _pushTurn(open, seat: 0);
      await _pushRolled(open, value: 4);
      final int before = _transcriptOf(open.controller).length;

      await _pushGameStarted(open, gameId: _gameA);

      final List<Frame> transcript = _transcriptOf(open.controller);
      expect(transcript, hasLength(before + 1));
      expect(transcript.first.type, 'game_started');
      expect(transcript.first.data['game_id'], _gameA);
      expect(transcript[1].type, 'turn');
      expect(transcript[2].type, 'rolled');
      expect(transcript.last.type, 'game_started');
      expect(transcript.last.data['game_id'], _gameA);
    } finally {
      open.controller.dispose();
    }
  });

  test(
    '11. a game_started with a new game_id clears and starts over',
    () async {
      final _Open open = await _connectLobby();
      try {
        await _pushGameStarted(open, gameId: _gameA);
        await _pushTurn(open, seat: 0);
        await _pushRolled(open, value: 3);
        expect(_transcriptOf(open.controller), hasLength(3));

        await _pushGameStarted(open, gameId: _gameB);

        final List<Frame> transcript = _transcriptOf(open.controller);
        expect(transcript, hasLength(1));
        expect(transcript.single.type, 'game_started');
        expect(transcript.single.data['game_id'], _gameB);
      } finally {
        open.controller.dispose();
      }
    },
  );

  test('12. frames after a drop and reconnect on the same controller are '
      'appended', () async {
    final _Open open = await _connectLobby();
    try {
      await _pushGameStarted(open, gameId: _gameA);
      await _pushTurn(open, seat: 0);
      expect(_types(open.controller), <String>['game_started', 'turn']);

      open.transport.endFromFarSide();
      await pumpEventQueue();
      expect(open.controller.phase, RoomPhase.closed);

      final FakeTransport transport2 = FakeTransport();
      open.connector.enqueue(transport2);
      final Future<void> reconnectFuture = open.controller.reconnect();
      await pumpEventQueue();
      expect(transport2.sentRaw, isNotEmpty);
      final String resumeId = _idOf(transport2.sentRaw.last);

      // The resume reply is itself a frame on the new connection, so it
      // belongs in the transcript. Its seq continues, so the reducer
      // does not open a second resume.
      open.seq += 1;
      transport2.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(
            state: 'PLAYING',
            gameId: _gameA,
            clientSeeds: '0:seed',
            turn: _turnJson(seat: 0, deadlineMs: 45000, k: 0),
            seq: open.seq,
          ),
        ),
      );
      await reconnectFuture;
      await pumpEventQueue();
      expect(open.controller.phase, RoomPhase.connected);

      open.seq += 1;
      transport2.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 2,
            'legal': <int>[0, 1],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': open.seq,
          },
        ),
      );
      await pumpEventQueue();

      final List<Frame> transcript = _transcriptOf(open.controller);
      expect(transcript.map((Frame frame) => frame.type).toList(), <String>[
        'game_started',
        'turn',
        'room',
        'rolled',
      ]);
      expect(transcript.first.data['game_id'], _gameA);
      expect(transcript.last.data['value'], 2);
    } finally {
      open.controller.dispose();
    }
  });

  test('13. the returned list is unmodifiable', () async {
    final _Open open = await _connectLobby();
    try {
      await _pushGameStarted(open, gameId: _gameA);
      final List<Frame> transcript = _transcriptOf(open.controller);
      final int before = transcript.length;
      expect(before, greaterThan(0));
      expect(
        () => transcript.add(
          const Frame(
            type: 'rolled',
            id: 'c293-trn-extra1',
            data: <String, Object?>{},
          ),
        ),
        throwsA(anything),
      );
      expect(_transcriptOf(open.controller), hasLength(before));
    } finally {
      open.controller.dispose();
    }
  });
}
