// Conformance tests for order 202's RoomToggles and the toggles parameter it
// adds to RoomConnection.createRoom and RoomController.createRoom, written
// from the spec quoted verbatim in work/ludo/orders/201-prove-create-room-
// toggles.md (itself lifted from order 202's own order, which this file's
// author has not read) and from the idiom of test/net/connection_test.dart
// and test/net/room_controller_test.dart. Neither connection.dart nor
// room_controller.dart carries RoomToggles on the branch this file was
// written on.
//
// The spec pins:
//   RoomConnection.createRoom(..., RoomToggles? toggles): with toggles,
//   d.rules == toggles.toJson(); with neither rules nor toggles, d is
//   exactly {name, players}; with both, ArgumentError and nothing sent.
//   RoomController.createRoom(..., RoomToggles toggles = const RoomToggles()).
//   RoomToggles({this.blocks = true, this.captureBonus = true}), value
//   equality, toJson() exactly {'blocks': b, 'capture_bonus': c}.
//
// Each test's name starts with its id (U1..U5), per the order.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers ------------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

/// A server push or reply, encoded exactly as Frame.decode expects.
String _serverFrame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

/// A minimal, valid docs/PROTOCOL.md section 6 room snapshot, enough for
/// RoomSnapshot.fromJson to accept it.
Map<String, Object?> _validRoomJson({
  String code = 'K7M2QP',
  int hostSeat = 0,
  int players = 4,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
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
  'seats': <Object?>[
    <String, Object?>{
      'seat': hostSeat,
      'name': 'Sam',
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
};

/// Builds and opens a RoomConnection against a fresh FakeTransport, the same
/// idiom test/net/connection_test.dart uses.
Future<(RoomConnection, FakeTransport)> _openConnection() async {
  final FakeTransport transport = FakeTransport();
  final RoomConnection connection = RoomConnection(
    url: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  await connection.open();
  return (connection, transport);
}

void main() {
  group('U1: RoomToggles().toJson() key order', () {
    test('the key list is exactly [blocks, capture_bonus], in that order', () {
      final Map<String, Object?> json = const RoomToggles().toJson();
      expect(
        json.keys.toList(),
        <String>['blocks', 'capture_bonus'],
        reason:
            'RoomToggles().toJson() must carry exactly the keys '
            '[blocks, capture_bonus] in that order; got '
            '${json.keys.toList()}',
      );
    });

    test('the default values are both true', () {
      final Map<String, Object?> json = const RoomToggles().toJson();
      expect(
        json,
        equals(<String, Object?>{'blocks': true, 'capture_bonus': true}),
      );
    });

    test('a toggles object with both switches off encodes both as false', () {
      final Map<String, Object?> json = const RoomToggles(
        blocks: false,
        captureBonus: false,
      ).toJson();
      expect(
        json,
        equals(<String, Object?>{'blocks': false, 'capture_bonus': false}),
      );
    });
  });

  group('U2: RoomToggles value equality and hashCode', () {
    test('two instances built from the same values are ==', () {
      const RoomToggles a = RoomToggles(blocks: false, captureBonus: true);
      const RoomToggles b = RoomToggles(blocks: false, captureBonus: true);
      expect(
        a,
        equals(b),
        reason:
            'RoomToggles must be a value type: equal fields, equal '
            'instances',
      );
    });

    test('two instances built from the same values share a hashCode', () {
      const RoomToggles a = RoomToggles(blocks: false, captureBonus: true);
      const RoomToggles b = RoomToggles(blocks: false, captureBonus: true);
      expect(
        a.hashCode,
        equals(b.hashCode),
        reason:
            'equal RoomToggles instances must share a hashCode, or they '
            'cannot be used safely as Map keys or in a Set',
      );
    });

    test('a difference in blocks alone makes two instances unequal', () {
      const RoomToggles a = RoomToggles(blocks: true, captureBonus: true);
      const RoomToggles b = RoomToggles(blocks: false, captureBonus: true);
      expect(a, isNot(equals(b)));
    });

    test('a difference in captureBonus alone makes two instances unequal', () {
      const RoomToggles a = RoomToggles(blocks: true, captureBonus: true);
      const RoomToggles b = RoomToggles(blocks: true, captureBonus: false);
      expect(a, isNot(equals(b)));
    });

    test('the default constructor equals one built with both defaults named '
        'explicitly', () {
      const RoomToggles a = RoomToggles();
      const RoomToggles b = RoomToggles(blocks: true, captureBonus: true);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('U3: RoomConnection.createRoom(toggles: ...) on the wire', () {
    test('toggles: RoomToggles(blocks: false) sends d.rules == '
        '{blocks: false, capture_bonus: true}', () async {
      final (RoomConnection connection, FakeTransport transport) =
          await _openConnection();
      addTearDown(connection.close);

      final Future<RoomSnapshot> future = connection.createRoom(
        name: 'Sam',
        players: 4,
        toggles: const RoomToggles(blocks: false),
      );
      await pumpEventQueue();

      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      final Map<String, Object?> data = sent['d']! as Map<String, Object?>;
      expect(
        data['rules'],
        equals(<String, Object?>{'blocks': false, 'capture_bonus': true}),
        reason:
            'createRoom(toggles: RoomToggles(blocks: false)) must send '
            'exactly the toggles\' own toJson() as d.rules; got '
            '${data['rules']}',
      );

      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id']! as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });

    test('a null toggles and a null rules argument together send d with no '
        'rules key at all', () async {
      final (RoomConnection connection, FakeTransport transport) =
          await _openConnection();
      addTearDown(connection.close);

      final Future<RoomSnapshot> future = connection.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();

      final Map<String, Object?> sent = _decode(transport.sentRaw.last);
      final Map<String, Object?> data = sent['d']! as Map<String, Object?>;
      expect(
        data,
        equals(<String, Object?>{'name': 'Sam', 'players': 4}),
        reason:
            'with neither rules nor toggles supplied, d must be exactly '
            '{name, players}; got $data',
      );

      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id']! as String,
          data: _validRoomJson(),
        ),
      );
      await future;
    });
  });

  group('U4: createRoom(rules: ..., toggles: ...) with both supplied', () {
    test('throws ArgumentError and transport.sentRaw gains nothing', () async {
      final (RoomConnection connection, FakeTransport transport) =
          await _openConnection();
      addTearDown(connection.close);

      final int sentBefore = transport.sentRaw.length;

      await expectLater(
        connection.createRoom(
          name: 'Sam',
          players: 4,
          rules: const RulesConfig(),
          toggles: const RoomToggles(),
        ),
        throwsA(isA<ArgumentError>()),
        reason:
            'createRoom must reject a call that supplies both rules and '
            'toggles with ArgumentError',
      );

      expect(
        transport.sentRaw,
        hasLength(sentBefore),
        reason:
            'a createRoom call rejected for supplying both rules and '
            'toggles must send nothing on the wire; sentRaw grew from '
            '$sentBefore to ${transport.sentRaw.length}',
      );
    });
  });

  group('U5: RoomController.createRoom(name:, players:) with no toggles', () {
    test('sends rules == {blocks: true, capture_bonus: true}', () async {
      final FakeTransport transport = FakeTransport();
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: (Uri url) async => transport,
      );
      addTearDown(controller.dispose);

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 4,
      );
      await pumpEventQueue();

      expect(
        transport.sentRaw,
        hasLength(1),
        reason:
            'fixture is broken: RoomController.createRoom must have sent '
            'exactly one create_room request by now',
      );
      final Map<String, Object?> sent = _decode(transport.sentRaw.single);
      expect(sent['t'], 'create_room');
      final Map<String, Object?> data = sent['d']! as Map<String, Object?>;
      expect(
        data['rules'],
        equals(<String, Object?>{'blocks': true, 'capture_bonus': true}),
        reason:
            'RoomController.createRoom with no toggles argument must '
            'still send the default RoomToggles as d.rules; got '
            '${data['rules']}',
      );

      transport.pushText(
        _serverFrame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
        ),
      );
      transport.pushText(
        _serverFrame(
          type: 'room',
          re: sent['id']! as String,
          data: _validRoomJson(),
        ),
      );
      await future;
      expect(controller.phase, RoomPhase.connected);
    });
  });
}
