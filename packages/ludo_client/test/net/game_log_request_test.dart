// Connection cases for C-304 rule 1, driven through
// RoomController.fetchGameLog. The method collects every part of one
// game_log, in part order, and completes with an error when the answer
// is not a clean 1..parts run.
//
// fetchGameLog does not exist on the base this file was written against.
// That is the one analyzer error expected here.
//
// An out-of-sequence part and a mismatched game_id complete with
// FrameFormatException, before the request timeout. An error reply and a
// close are the same outcomes request() already has:
// ProtocolErrorException and ConnectionClosedException.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://game-log-request.invalid/ws';
const String _gameOne = 'aaaaaaaaaaaaaaaa';
const String _gameTwo = 'bbbbbbbbbbbbbbbb';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c304-log-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _entry(String type, Map<String, Object?> data) =>
    <String, Object?>{'t': type, 'd': data};

/// Three entries, two parts. Part 1 is seq 1 then seq 2. Part 2 is seq 3.
/// The collected list has to come back in that order.
final List<Map<String, Object?>> _partOneEntries = <Map<String, Object?>>[
  _entry('game_started', <String, Object?>{
    'turn': 0,
    'game_id': _gameOne,
    'seq': 1,
  }),
  _entry('rolled', <String, Object?>{'seat': 0, 'value': 6, 'seq': 2}),
];

final List<Map<String, Object?>> _partTwoEntries = <Map<String, Object?>>[
  _entry('moved', <String, Object?>{'seat': 0, 'token': 0, 'to': 57, 'seq': 3}),
];

List<Map<String, Object?>> get _expectedData => <Map<String, Object?>>[
  _partOneEntries[0]['d']! as Map<String, Object?>,
  _partOneEntries[1]['d']! as Map<String, Object?>,
  _partTwoEntries[0]['d']! as Map<String, Object?>,
];

String _part({
  required String requestId,
  required String gameId,
  required int part,
  required int parts,
  required List<Map<String, Object?>> frames,
}) => _frame(
  type: 'game_log',
  re: requestId,
  data: <String, Object?>{
    'game_id': gameId,
    'part': part,
    'parts': parts,
    'frames': frames,
  },
);

List<String> _twoParts(String requestId) => <String>[
  _part(
    requestId: requestId,
    gameId: _gameOne,
    part: 1,
    parts: 2,
    frames: _partOneEntries,
  ),
  _part(
    requestId: requestId,
    gameId: _gameOne,
    part: 2,
    parts: 2,
    frames: _partTwoEntries,
  ),
];

Map<String, Object?> _roomJson() => <String, Object?>{
  'code': 'ABC234',
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
  'seats': <Map<String, Object?>>[
    <String, Object?>{
      'seat': 0,
      'name': 'Sam',
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    },
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
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

/// send() pushes the game_log parts before it returns, the case a
/// registration that happens after the send would miss.
class _SyncPartsTransport extends FakeTransport {
  List<String> Function(String requestId)? onGameLog;

  @override
  void send(String text) {
    super.send(text);
    final List<String> Function(String requestId)? hook = onGameLog;
    if (hook == null) {
      return;
    }
    final Map<String, Object?> sent = jsonDecode(text) as Map<String, Object?>;
    if (sent['t'] != 'game_log') {
      return;
    }
    onGameLog = null;
    final String id = sent['id']! as String;
    for (final String part in hook(id)) {
      pushText(part);
    }
  }
}

Future<List<Frame>> _fetchGameLog(RoomController controller) {
  return controller.fetchGameLog();
}

Future<(RoomController, FakeTransport)> _connected(
  FakeTransport transport,
) async {
  final _Connector connector = _Connector();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await pumpEventQueue();
  expect(_typeOf(transport.sentRaw.last), 'create_room');
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
  await future;
  expect(controller.phase, RoomPhase.connected);
  return (controller, transport);
}

String _gameLogId(FakeTransport transport) {
  final List<String> logs = transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'game_log')
      .toList();
  expect(logs, hasLength(1), reason: 'fetchGameLog must send one game_log');
  expect(
    _decode(logs.single)['d'],
    <String, Object?>{},
    reason: 'game_log is sent as {}',
  );
  return _idOf(logs.single);
}

void _expectFrames(List<Frame> frames) {
  expect(frames.map((Frame frame) => frame.type).toList(), <String>[
    'game_started',
    'rolled',
    'moved',
  ]);
  expect(frames.map((Frame frame) => frame.seq).toList(), <int>[1, 2, 3]);
  for (int i = 0; i < frames.length; i++) {
    expect(frames[i].data, _expectedData[i]);
  }
}

/// Attaches before the reply so a synchronous completeError is observed,
/// and does not elapse the request timeout. A future that only fails by
/// timing out stays unfinished here.
Future<Object?> _errorWithoutTimeout(
  Future<List<Frame>> future,
  void Function() deliver,
) async {
  Object? failure;
  var completed = false;
  unawaited(
    future.then(
      (List<Frame> _) {
        completed = true;
      },
      onError: (Object error, StackTrace _) {
        completed = true;
        failure = error;
      },
    ),
  );
  deliver();
  await pumpEventQueue();
  expect(
    completed,
    isTrue,
    reason:
        'the future must already have completed with an error, not still '
        'be waiting out the request timeout',
  );
  expect(failure, isNotNull, reason: 'the future completed with a list');
  return failure;
}

void main() {
  test('parts are collected in part order', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connected(FakeTransport());
    addTearDown(controller.dispose);

    final Future<List<Frame>> future = _fetchGameLog(controller);
    await pumpEventQueue();
    final String id = _gameLogId(transport);
    for (final String part in _twoParts(id)) {
      transport.pushText(part);
    }

    _expectFrames(await future);
  });

  test(
    'a part sent synchronously by the fake transport is not missed',
    () async {
      final _SyncPartsTransport transport = _SyncPartsTransport();
      final (RoomController controller, _) = await _connected(transport);
      addTearDown(controller.dispose);

      transport.onGameLog = _twoParts;
      final List<Frame> frames = await _fetchGameLog(controller).timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail(
          'a part pushed synchronously from send() was missed; '
          'fetchGameLog did not complete',
        ),
      );
      _expectFrames(frames);
    },
  );

  test('an out-of-sequence part completes with an error', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connected(FakeTransport());
    addTearDown(controller.dispose);

    final Future<List<Frame>> future = _fetchGameLog(controller);
    await pumpEventQueue();
    final String id = _gameLogId(transport);

    // Part 1 of 3 is in sequence, so the request stays open. The check
    // under test is the next part's number against the last one plus 1,
    // not the check that the first part is part 1.
    var settled = false;
    unawaited(
      future.then(
        (List<Frame> _) {
          settled = true;
        },
        onError: (Object _, StackTrace _) {
          settled = true;
        },
      ),
    );
    transport.pushText(
      _part(
        requestId: id,
        gameId: _gameOne,
        part: 1,
        parts: 3,
        frames: _partOneEntries,
      ),
    );
    await pumpEventQueue();
    expect(
      settled,
      isFalse,
      reason: 'part 1 of 3 is in sequence, so the request is still open',
    );

    // Part 3, with part 2 never sent. parts and game_id match part 1,
    // so the only failing check is the part sequence. No pump below
    // reaches the request timeout: the error is already in hand.
    final Object? failure = await _errorWithoutTimeout(future, () {
      transport.pushText(
        _part(
          requestId: id,
          gameId: _gameOne,
          part: 3,
          parts: 3,
          frames: _partTwoEntries,
        ),
      );
    });
    expect(failure, isA<FrameFormatException>());
  });

  test('a mismatched game_id completes with an error', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connected(FakeTransport());
    addTearDown(controller.dispose);

    final Future<List<Frame>> future = _fetchGameLog(controller);
    await pumpEventQueue();
    final String id = _gameLogId(transport);

    transport.pushText(
      _part(
        requestId: id,
        gameId: _gameOne,
        part: 1,
        parts: 2,
        frames: _partOneEntries,
      ),
    );
    await pumpEventQueue();

    // Part 1 was in sequence. Part 2 names a different game. parts still
    // matches, and 2 is the next part number, so the only failing check
    // is game_id. No pump below reaches the request timeout.
    final Object? failure = await _errorWithoutTimeout(future, () {
      transport.pushText(
        _part(
          requestId: id,
          gameId: _gameTwo,
          part: 2,
          parts: 2,
          frames: _partTwoEntries,
        ),
      );
    });
    expect(failure, isA<FrameFormatException>());
  });

  test('an error reply completes with an error', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connected(FakeTransport());
    addTearDown(controller.dispose);

    final Future<List<Frame>> future = _fetchGameLog(controller);
    await pumpEventQueue();
    final String id = _gameLogId(transport);

    final Object? failure = await _errorWithoutTimeout(future, () {
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{
            'code': 'RATE_LIMITED',
            'message': 'game_log',
          },
        ),
      );
    });
    expect(failure, isA<ProtocolErrorException>());
    expect((failure! as ProtocolErrorException).code, 'RATE_LIMITED');
  });

  test('the connection closing completes with an error', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connected(FakeTransport());
    addTearDown(controller.dispose);

    final Future<List<Frame>> future = _fetchGameLog(controller);
    await pumpEventQueue();
    _gameLogId(transport);

    final Object? failure = await _errorWithoutTimeout(future, () {
      transport.endFromFarSide();
    });
    expect(failure, isA<ConnectionClosedException>());
  });
}
