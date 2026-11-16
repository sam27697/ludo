// Conformance tests for order C-655: PROTOCOL sections 28 and 29 in the
// client's network layer (snapshot.dart, connection.dart, room_controller.dart).
// Written from the order's contract N1-N7 and from the frame shapes of
// docs/PROTOCOL.md sections 28 and 29 only.
//
//   N1  snapshot fields: RoomSnapshot.placings / retired, RulesConfig.ruleset,
//       SeatState.drought, TurnState.release / graceMs, host_seat -1
//   N2  the seq chain: seat_finished and seat_retired, lastRetirement
//   N3  the release: rolled and moved with release true
//   N4  game_over carries placings and retired
//   N5  grace_ms on a turn frame and on a snapshot turn
//   N6  kick: RoomConnection.kick and RoomController.kick
//   N7  everything else unchanged, a 2026-10 room byte for byte
//
// Every test name starts with its contract point so a failure message can be
// replayed with `--plain-name`. Nothing here is random: the scenario named in
// the failure message is the whole reproduction.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/connection.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const String _testFile = 'test/net/c655_ruleset_net_test.dart';

// --- failure messages ------------------------------------------------------

/// Every assertion in this file passes its scenario through here, so a red
/// line names what was expected, what the implementation did (the matcher
/// prints the actual value) and the exact command that replays it.
String _r(String scenario, String expected) =>
    '$scenario: expected $expected. Deterministic, no seed; replay with '
    '`flutter test $_testFile --plain-name "${scenario.split(' ').first}"`';

// --- wire helpers ----------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c655-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

int _resumeCount(FakeTransport transport) =>
    transport.sentRaw.where((String raw) => _typeOf(raw) == 'resume').length;

List<Map<String, Object?>> _sentOfType(FakeTransport transport, String type) =>
    transport.sentRaw
        .map(_decode)
        .where((Map<String, Object?> m) => m['t'] == type)
        .toList();

String _frame({
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

// --- snapshot builders -----------------------------------------------------

Map<String, Object?> _seatJson(
  int seat, {
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
  int? drought,
}) => <String, Object?>{
  'seat': seat,
  'name': 'P$seat',
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
  'drought': ?drought,
};

Map<String, Object?> _turnJson({
  int seat = 0,
  String phase = 'await_roll',
  int deadlineMs = 45000,
  int k = 4,
  int? value,
  List<int>? legal,
  List<int>? queue,
  bool? release,
  int? graceMs,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'queue': ?queue,
  'release': ?release,
  'grace_ms': ?graceMs,
};

/// A section 6 snapshot. [ruleset] null leaves the key out, as a 2026-10 room
/// does; [placings] and [retired] null leave their keys out too.
Map<String, Object?> _roomJson({
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 3,
  String? ruleset,
  List<int>? placings,
  List<int>? retired,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 10,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
    'ruleset': ?ruleset,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'LOBBY' ? null : 'game-1',
  'client_seeds': state == 'LOBBY' ? null : 'cs',
  'seats':
      seats ??
      <Map<String, Object?>>[for (int s = 0; s < players; s++) _seatJson(s)],
  'turn': state == 'LOBBY' ? null : (turn ?? _turnJson()),
  'winner': null,
  'placings': ?placings,
  'retired': ?retired,
  'seq': seq,
};

// --- controller fixtures ---------------------------------------------------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: no transport queued for call #${calls.length}',
      );
    }
    return _queue.removeAt(0);
  }
}

/// A controller in phase connected, seat 0, holding [roomJson] as its room.
Future<(RoomController, FakeTransport, _Connector)> _connected(
  Map<String, Object?> roomJson,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> future = controller.createRoom(
    name: 'P0',
    players: roomJson['players']! as int,
  );
  await pumpEventQueue();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: roomJson));
  await future;
  return (controller, transport, connector);
}

/// A 3-seat room in PLAYING under the 2026-11 ruleset, seq 10, seat 0 on turn.
Future<(RoomController, FakeTransport)> _hand({
  String? ruleset = '2026-11',
  int hostSeat = 0,
  int seq = 10,
  Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
  List<int>? placings,
  List<int>? retired,
}) async {
  final (RoomController c, FakeTransport t, _) = await _connected(
    _roomJson(
      ruleset: ruleset,
      hostSeat: hostSeat,
      seq: seq,
      turn: turn,
      seats: seats,
      placings: ruleset == null ? null : (placings ?? <int>[]),
      retired: ruleset == null ? null : (retired ?? <int>[]),
    ),
  );
  addTearDown(c.dispose);
  return (c, t);
}

Future<void> _push(
  FakeTransport transport,
  String type,
  Map<String, Object?> data,
) async {
  transport.pushText(_frame(type: type, data: data));
  await pumpEventQueue();
}

/// Pushes [type] with `seq` = the controller's current seq + 1.
Future<void> _pushNext(
  RoomController controller,
  FakeTransport transport,
  String type,
  Map<String, Object?> data,
) => _push(transport, type, <String, Object?>{
  ...data,
  'seq': controller.room!.seq + 1,
});

Map<String, Object?> _moved({
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  bool extraRoll = false,
  bool? release,
  int? face,
}) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
  'release': ?release,
  'face': ?face,
};

Map<String, Object?> _rolled({
  required int seat,
  int value = 3,
  required List<int> legal,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
  bool? release,
  int k = 5,
  int deadlineMs = 45000,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
  'release': ?release,
  'deadline_ms': deadlineMs,
  'k': k,
  'reveal': 'b' * 64,
};

/// The fields of a turn but `release`, as a list, so `expect` compares them
/// deeply.
List<Object?> _turnFields(TurnState t) => <Object?>[
  t.seat,
  t.phase,
  t.value,
  t.legal,
  t.queue,
  t.legalByFace?.map((FaceLegal f) => '${f.face}:${f.tokens}').toList(),
  t.k,
  t.deadlineMs,
  t.segmentMs,
  t.sixes,
];

// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // N1. The snapshot fields.
  // =========================================================================
  group('N1 snapshot fields', () {
    test('N1-ruleset-present: rules.ruleset "2026-11" is read', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(ruleset: '2026-11'),
      );
      expect(
        s.rules.ruleset,
        '2026-11',
        reason: _r('N1-ruleset-present', 'rules.ruleset == "2026-11"'),
      );
    });

    test('N1-ruleset-absent: no ruleset key reads as null', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(_roomJson());
      expect(
        s.rules.ruleset,
        isNull,
        reason: _r('N1-ruleset-absent', 'rules.ruleset == null'),
      );
    });

    test('N1-ruleset-2026-10: an explicit "2026-10" is kept as sent', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(ruleset: '2026-10'),
      );
      expect(
        s.rules.ruleset,
        '2026-10',
        reason: _r('N1-ruleset-2026-10', 'the value as sent, not normalised'),
      );
    });

    test(
      'N1-drought-present: seat drought 0 and 9 are read, 0 is not null',
      () {
        final RoomSnapshot s = RoomSnapshot.fromJson(
          _roomJson(
            ruleset: '2026-11',
            seats: <Map<String, Object?>>[
              _seatJson(0, drought: 0),
              _seatJson(1, drought: 9),
              _seatJson(2, drought: 4),
            ],
          ),
        );
        expect(s.seats.map((SeatState x) => x.drought).toList(), <int?>[
          0,
          9,
          4,
        ], reason: _r('N1-drought-present', 'drought per seat [0, 9, 4]'));
      },
    );

    test('N1-drought-absent: seats without the key read null', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(_roomJson());
      expect(s.seats.map((SeatState x) => x.drought).toList(), <int?>[
        null,
        null,
        null,
      ], reason: _r('N1-drought-absent', 'null for every seat'));
    });

    test('N1-release-present: snapshot turn release true and false', () {
      final RoomSnapshot yes = RoomSnapshot.fromJson(
        _roomJson(
          turn: _turnJson(
            phase: 'await_move',
            legal: <int>[0, 1],
            queue: <int>[3],
            release: true,
          ),
        ),
      );
      final RoomSnapshot no = RoomSnapshot.fromJson(
        _roomJson(turn: _turnJson(release: false)),
      );
      expect(
        yes.turn!.release,
        isTrue,
        reason: _r('N1-release-present', 'turn.release == true when sent true'),
      );
      expect(
        no.turn!.release,
        isFalse,
        reason: _r(
          'N1-release-present',
          'turn.release == false when sent false',
        ),
      );
    });

    test('N1-release-absent: a snapshot turn without release is false', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(_roomJson());
      expect(
        s.turn!.release,
        isFalse,
        reason: _r('N1-release-absent', 'turn.release == false, never null'),
      );
    });

    test('N1-grace-present: snapshot turn grace_ms is read as graceMs', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(turn: _turnJson(graceMs: 660)),
      );
      expect(
        s.turn!.graceMs,
        660,
        reason: _r('N1-grace-present', 'turn.graceMs == 660'),
      );
      expect(
        s.turn!.deadlineMs,
        45000,
        reason: _r(
          'N1-grace-present',
          'deadlineMs stays the full budget 45000',
        ),
      );
    });

    test('N1-grace-absent: no grace_ms reads null, not 0', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(_roomJson());
      expect(
        s.turn!.graceMs,
        isNull,
        reason: _r('N1-grace-absent', 'turn.graceMs == null'),
      );
    });

    test('N1-placings-retired-present: both lists are read in wire order', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(
          ruleset: '2026-11',
          placings: <int>[2, 0],
          retired: <int>[3, 1],
          players: 4,
        ),
      );
      expect(s.placings, <int>[
        2,
        0,
      ], reason: _r('N1-placings-retired-present', 'placings == [2, 0]'));
      expect(s.retired, <int>[
        3,
        1,
      ], reason: _r('N1-placings-retired-present', 'retired == [3, 1]'));
    });

    test('N1-placings-retired-empty: empty lists stay empty', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(ruleset: '2026-11', placings: <int>[], retired: <int>[]),
      );
      expect(
        s.placings,
        isEmpty,
        reason: _r('N1-placings-retired-empty', 'placings == []'),
      );
      expect(
        s.retired,
        isEmpty,
        reason: _r('N1-placings-retired-empty', 'retired == []'),
      );
    });

    test('N1-placings-retired-absent: missing keys read as empty lists', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(_roomJson());
      expect(
        s.placings,
        isEmpty,
        reason: _r('N1-placings-retired-absent', 'placings == [] not null'),
      );
      expect(
        s.retired,
        isEmpty,
        reason: _r('N1-placings-retired-absent', 'retired == [] not null'),
      );
    });

    test('N1-host-minus-one: host_seat -1 decodes, hostSeat is -1', () {
      final RoomSnapshot s = RoomSnapshot.fromJson(
        _roomJson(hostSeat: -1, ruleset: '2026-11'),
      );
      expect(
        s.hostSeat,
        -1,
        reason: _r('N1-host-minus-one', 'a snapshot with host_seat -1 decodes'),
      );
    });

    test('N1-host-bounds: host_seat -2 and 4 still throw', () {
      for (final int bad in <int>[-2, 4, 99]) {
        expect(
          () => RoomSnapshot.fromJson(_roomJson(hostSeat: bad)),
          throwsA(isA<SnapshotFormatException>()),
          reason: _r(
            'N1-host-bounds',
            'host_seat $bad rejected with SnapshotFormatException, only -1 is new',
          ),
        );
      }
    });

    test('N1-host-minus-one-via-controller: a room frame with host_seat -1 '
        'is accepted, hostSeat -1, phase connected', () async {
      final (RoomController c, FakeTransport t) = await _hand(hostSeat: -1);
      expect(
        c.phase,
        RoomPhase.connected,
        reason: _r('N1-host-minus-one-via-controller', 'phase connected'),
      );
      expect(
        c.room!.hostSeat,
        -1,
        reason: _r('N1-host-minus-one-via-controller', 'room.hostSeat == -1'),
      );
      expect(_resumeCount(t), 0);
    });

    test('N1-copywith-room: placings and retired round-trip through copyWith '
        'and survive an unrelated copyWith', () {
      final RoomSnapshot base = RoomSnapshot.fromJson(_roomJson());
      final RoomSnapshot set = base.copyWith(
        placings: <int>[1, 2],
        retired: <int>[0],
      );
      expect(set.placings, <int>[
        1,
        2,
      ], reason: _r('N1-copywith-room', 'copyWith(placings: [1, 2]) sets it'));
      expect(set.retired, <int>[
        0,
      ], reason: _r('N1-copywith-room', 'copyWith(retired: [0]) sets it'));
      final RoomSnapshot kept = set.copyWith(seq: 99);
      expect(
        kept.placings,
        <int>[1, 2],
        reason: _r('N1-copywith-room', 'an unrelated copyWith keeps placings'),
      );
      expect(kept.retired, <int>[
        0,
      ], reason: _r('N1-copywith-room', 'an unrelated copyWith keeps retired'));
      expect(base.placings, isEmpty, reason: 'copyWith must not mutate base');
    });

    test(
      'N1-copywith-seat: drought round-trips through SeatState.copyWith',
      () {
        final SeatState seat = SeatState.fromJson(_seatJson(1, drought: 3));
        expect(
          seat.copyWith(name: 'Zed').drought,
          3,
          reason: _r(
            'N1-copywith-seat',
            'an unrelated copyWith keeps drought 3',
          ),
        );
        expect(
          seat.copyWith(drought: 7).drought,
          7,
          reason: _r('N1-copywith-seat', 'copyWith(drought: 7) sets it'),
        );
        expect(
          SeatState.fromJson(_seatJson(1)).copyWith(connected: false).drought,
          isNull,
          reason: _r('N1-copywith-seat', 'null stays null'),
        );
      },
    );

    test('N1-controller-snapshot: a createRoom reply carrying every new field '
        'lands whole in controller.room', () async {
      final (RoomController c, _, _) = await _connected(
        _roomJson(
          ruleset: '2026-11',
          placings: <int>[1],
          retired: <int>[2],
          seats: <Map<String, Object?>>[
            _seatJson(0, drought: 2),
            _seatJson(1, drought: 0),
            _seatJson(2, drought: 9),
          ],
          turn: _turnJson(
            phase: 'await_move',
            legal: <int>[0],
            queue: <int>[4],
            release: true,
            graceMs: 500,
          ),
        ),
      );
      addTearDown(c.dispose);
      final RoomSnapshot room = c.room!;
      expect(
        room.rules.ruleset,
        '2026-11',
        reason: _r('N1-controller-snapshot', 'ruleset'),
      );
      expect(room.placings, <int>[
        1,
      ], reason: _r('N1-controller-snapshot', 'placings'));
      expect(room.retired, <int>[
        2,
      ], reason: _r('N1-controller-snapshot', 'retired'));
      expect(room.seats.map((SeatState s) => s.drought).toList(), <int?>[
        2,
        0,
        9,
      ], reason: _r('N1-controller-snapshot', 'drought per seat'));
      expect(
        room.turn!.release,
        isTrue,
        reason: _r('N1-controller-snapshot', 'release'),
      );
      expect(
        room.turn!.graceMs,
        500,
        reason: _r('N1-controller-snapshot', 'graceMs'),
      );
    });
  });

  // =========================================================================
  // N2. The seq chain.
  // =========================================================================
  group('N2 seat_finished', () {
    test('N2-finished-chain: moved (n), seat_finished (n+1), turn (n+2) '
        'resyncs nothing, seq follows, placings == [1]', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        turn: _turnJson(
          seat: 1,
          phase: 'await_move',
          legal: <int>[0],
          value: 3,
          queue: <int>[3],
        ),
        seats: <Map<String, Object?>>[
          _seatJson(0),
          _seatJson(1, tokens: const <int>[57, 57, 57, 54]),
          _seatJson(2),
        ],
      );
      await _push(t, 'moved', <String, Object?>{
        ..._moved(seat: 1, token: 3, from: 54, to: 57, face: 3),
        'seq': 11,
      });
      expect(
        c.room!.seq,
        11,
        reason: _r('N2-finished-chain', 'seq 11 after moved'),
      );
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
        'seq': 12,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N2-finished-chain', 'no desync after seat_finished at n+1'),
      );
      expect(
        c.room!.seq,
        12,
        reason: _r(
          'N2-finished-chain',
          'seat_finished advances room.seq by one',
        ),
      );
      expect(
        c.room!.placings,
        <int>[1],
        reason: _r('N2-finished-chain', 'placings == [1] after seat_finished'),
      );
      await _push(t, 'turn', <String, Object?>{
        'seat': 2,
        'deadline_ms': 45000,
        'seq': 13,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r(
          'N2-finished-chain',
          'the turn after seat_finished at n+2 is contiguous, not a gap',
        ),
      );
      expect(
        _resumeCount(t),
        0,
        reason: _r('N2-finished-chain', 'no resume sent'),
      );
      expect(
        c.room!.seq,
        13,
        reason: _r('N2-finished-chain', 'seq 13 after turn'),
      );
      expect(
        c.room!.turn!.seat,
        2,
        reason: _r('N2-finished-chain', 'turn passed to seat 2'),
      );
      expect(c.room!.seats.map((SeatState s) => s.seat).toList(), <int>[
        0,
        1,
        2,
      ], reason: _r('N2-finished-chain', 'a finished seat stays in seats'));
    });

    test(
      'N2-finished-second: a second finish appends place 2 after place 1',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(
          seq: 20,
          placings: <int>[1],
        );
        await _pushNext(c, t, 'seat_finished', <String, Object?>{
          'seat': 2,
          'place': 2,
        });
        expect(
          c.room!.placings,
          <int>[1, 2],
          reason: _r(
            'N2-finished-second',
            'placings == [1, 2], in finish order',
          ),
        );
        expect(c.hasDesynced, isFalse);
        expect(c.room!.seq, 21);
      },
    );

    test(
      'N2-finished-notifies: a reduced seat_finished notifies listeners',
      () async {
        final (RoomController c, FakeTransport t) = await _hand();
        int notified = 0;
        c.addListener(() => notified++);
        await _pushNext(c, t, 'seat_finished', <String, Object?>{
          'seat': 1,
          'place': 1,
        });
        expect(
          notified,
          greaterThanOrEqualTo(1),
          reason: _r(
            'N2-finished-notifies',
            'listeners told that the room changed',
          ),
        );
      },
    );

    test('N2-finished-wrong-place: a place other than placings.length + 1 '
        'resyncs and applies nothing', () async {
      for (final int place in <int>[0, 2, 3, 4, -1]) {
        final (RoomController c, FakeTransport t) = await _hand(seq: 30);
        await _push(t, 'seat_finished', <String, Object?>{
          'seat': 1,
          'place': place,
          'seq': 31,
        });
        final String scenario =
            'N2-finished-wrong-place (place $place, empty placings)';
        expect(c.hasDesynced, isTrue, reason: _r(scenario, 'hasDesynced true'));
        expect(
          _resumeCount(t),
          1,
          reason: _r(scenario, 'exactly one resume sent'),
        );
        expect(
          c.room!.placings,
          isEmpty,
          reason: _r(scenario, 'placings untouched'),
        );
        expect(c.room!.seq, 30, reason: _r(scenario, 'seq not advanced'));
      }
    });

    test('N2-finished-wrong-place-after-one: with placings [1] only place 2 is '
        'accepted; a repeated place 1 resyncs', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 30,
        placings: <int>[1],
      );
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 2,
        'place': 1,
        'seq': 31,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N2-finished-wrong-place-after-one', 'hasDesynced true'),
      );
      expect(c.room!.placings, <int>[
        1,
      ], reason: _r('N2-finished-wrong-place-after-one', 'placings still [1]'));
      expect(_resumeCount(t), 1);
    });

    test(
      'N2-finished-gap: a seat_finished past seq + 1 resyncs, not applied',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 40);
        await _push(t, 'seat_finished', <String, Object?>{
          'seat': 1,
          'place': 1,
          'seq': 43,
        });
        expect(
          c.hasDesynced,
          isTrue,
          reason: _r('N2-finished-gap', 'hasDesynced true'),
        );
        expect(_resumeCount(t), 1, reason: _r('N2-finished-gap', 'one resume'));
        expect(
          c.room!.placings,
          isEmpty,
          reason: _r('N2-finished-gap', 'not applied'),
        );
        expect(c.room!.seq, 40, reason: _r('N2-finished-gap', 'seq unchanged'));
      },
    );

    test('N2-finished-replay: the same seat_finished delivered twice resyncs '
        'on the second and never doubles the place', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 50);
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
        'seq': 51,
      });
      expect(c.room!.placings, <int>[1]);
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
        'seq': 51,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N2-finished-replay', 'a replayed seq is a gap and resyncs'),
      );
      expect(c.room!.placings, <int>[
        1,
      ], reason: _r('N2-finished-replay', 'placings still [1], not [1, 1]'));
      expect(c.room!.seq, 51);
    });

    test('N2-finished-during-resync: while a resync is in flight a valid '
        'seat_finished changes nothing', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 60);
      await _push(t, 'presence', <String, Object?>{
        'seat': 1,
        'connected': false,
        'seq': 99,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: 'precondition: a gap must start a resync',
      );
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
        'seq': 61,
      });
      expect(
        c.room!.placings,
        isEmpty,
        reason: _r(
          'N2-finished-during-resync',
          'frame inert while resync in flight',
        ),
      );
      expect(c.room!.seq, 60);
      expect(
        _resumeCount(t),
        1,
        reason: _r('N2-finished-during-resync', 'no second resume'),
      );
    });

    test('N2-finished-malformed: a seat_finished without seat or place is '
        'dropped like every malformed delta: no resync, no change', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 70);
      await _push(t, 'seat_finished', <String, Object?>{'place': 1, 'seq': 71});
      await _push(t, 'seat_finished', <String, Object?>{'seat': 1, 'seq': 71});
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N2-finished-malformed', 'no resync'),
      );
      expect(
        c.room!.placings,
        isEmpty,
        reason: _r('N2-finished-malformed', 'nothing applied'),
      );
      expect(
        c.room!.seq,
        70,
        reason: _r('N2-finished-malformed', 'seq unchanged'),
      );
    });

    test('N2-finished-reaches-frames: the frame reaches controller.frames '
        'whether or not it is reduced', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 80);
      final List<String> seen = <String>[];
      c.frames.listen((Frame f) => seen.add(f.type));
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
        'seq': 81,
      });
      await _push(t, 'seat_finished', <String, Object?>{
        'seat': 2,
        'place': 7,
        'seq': 82,
      });
      expect(
        seen.where((String x) => x == 'seat_finished').length,
        2,
        reason: _r('N2-finished-reaches-frames', 'both frames on frames'),
      );
    });
  });

  group('N2 seat_retired', () {
    test(
      'N2-retired-chain: seat_retired (n+1) then turn (n+2) resyncs nothing; '
      'retired, hostSeat and lastRetirement are set',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(
          seq: 100,
          hostSeat: 0,
          turn: _turnJson(seat: 0),
        );
        expect(
          c.lastRetirement,
          isNull,
          reason: _r(
            'N2-retired-chain',
            'lastRetirement null before any retirement',
          ),
        );
        await _push(t, 'seat_retired', <String, Object?>{
          'seat': 0,
          'reason': 'absent',
          'host_seat': 1,
          'seq': 101,
        });
        expect(
          c.hasDesynced,
          isFalse,
          reason: _r('N2-retired-chain', 'no desync'),
        );
        expect(
          c.room!.seq,
          101,
          reason: _r('N2-retired-chain', 'seq advanced by one'),
        );
        expect(c.room!.retired, <int>[
          0,
        ], reason: _r('N2-retired-chain', 'retired == [0]'));
        expect(
          c.room!.hostSeat,
          1,
          reason: _r('N2-retired-chain', 'hostSeat from host_seat'),
        );
        expect(
          c.lastRetirement?.seat,
          0,
          reason: _r('N2-retired-chain', 'lastRetirement.seat == 0'),
        );
        expect(
          c.lastRetirement?.reason,
          'absent',
          reason: _r('N2-retired-chain', 'lastRetirement.reason == "absent"'),
        );
        await _push(t, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'grace_ms': 500,
          'seq': 102,
        });
        expect(
          c.hasDesynced,
          isFalse,
          reason: _r(
            'N2-retired-chain',
            'the turn after seat_retired is contiguous',
          ),
        );
        expect(
          _resumeCount(t),
          0,
          reason: _r('N2-retired-chain', 'no resume sent'),
        );
        expect(c.room!.seq, 102);
        expect(c.room!.turn!.seat, 1);
        expect(c.room!.seats.map((SeatState s) => s.seat).toList(), <int>[
          0,
          1,
          2,
        ], reason: _r('N2-retired-chain', 'a retired seat stays in seats'));
      },
    );

    test('N2-retired-reasons: left, absent and kicked are all carried to '
        'lastRetirement verbatim', () async {
      for (final String reason in <String>['left', 'absent', 'kicked']) {
        final (RoomController c, FakeTransport t) = await _hand(seq: 5);
        await _push(t, 'seat_retired', <String, Object?>{
          'seat': 2,
          'reason': reason,
          'host_seat': 0,
          'seq': 6,
        });
        expect(
          c.lastRetirement,
          (seat: 2, reason: reason),
          reason: _r(
            'N2-retired-reasons ($reason)',
            'lastRetirement == (seat 2, $reason)',
          ),
        );
      }
    });

    test(
      'N2-retired-host-minus-one: host_seat -1 is accepted and stored',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 5);
        await _push(t, 'seat_retired', <String, Object?>{
          'seat': 0,
          'reason': 'left',
          'host_seat': -1,
          'seq': 6,
        });
        expect(
          c.hasDesynced,
          isFalse,
          reason: _r('N2-retired-host-minus-one', 'no resync'),
        );
        expect(
          c.room!.hostSeat,
          -1,
          reason: _r('N2-retired-host-minus-one', 'hostSeat == -1'),
        );
        expect(c.room!.retired, <int>[0]);
      },
    );

    test('N2-retired-host-unchanged: host_seat equal to the current host '
        'leaves hostSeat there', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 5,
        hostSeat: 0,
      );
      await _push(t, 'seat_retired', <String, Object?>{
        'seat': 2,
        'reason': 'kicked',
        'host_seat': 0,
        'seq': 6,
      });
      expect(
        c.room!.hostSeat,
        0,
        reason: _r('N2-retired-host-unchanged', 'hostSeat 0'),
      );
      expect(c.room!.retired, <int>[
        2,
      ], reason: _r('N2-retired-host-unchanged', 'retired == [2]'));
      expect(c.room!.seq, 6, reason: _r('N2-retired-host-unchanged', 'seq 6'));
    });

    test('N2-retired-accumulates: two retirements append in order and '
        'lastRetirement is the latest', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 5);
      await _pushNext(c, t, 'seat_retired', <String, Object?>{
        'seat': 2,
        'reason': 'absent',
        'host_seat': 0,
      });
      await _pushNext(c, t, 'seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'left',
        'host_seat': 0,
      });
      expect(
        c.room!.retired,
        <int>[2, 1],
        reason: _r(
          'N2-retired-accumulates',
          'retired == [2, 1], retirement order',
        ),
      );
      expect(c.lastRetirement, (
        seat: 1,
        reason: 'left',
      ), reason: _r('N2-retired-accumulates', 'lastRetirement is the second'));
      expect(c.room!.seq, 7);
      expect(c.hasDesynced, isFalse);
    });

    test(
      'N2-retired-nothing-else: only retired, hostSeat and seq change; '
      'seats, tokens, connection flags, turn and state are untouched',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(
          seq: 5,
          turn: _turnJson(
            seat: 1,
            phase: 'await_move',
            value: 4,
            legal: <int>[2],
            queue: <int>[4],
            deadlineMs: 31000,
            k: 9,
          ),
          seats: <Map<String, Object?>>[
            _seatJson(0, tokens: const <int>[0, -1, -1, -1]),
            _seatJson(1, tokens: const <int>[10, 20, -1, -1]),
            _seatJson(2, connected: false, tokens: const <int>[57, 3, -1, -1]),
          ],
        );
        final RoomSnapshot before = c.room!;
        await _pushNext(c, t, 'seat_retired', <String, Object?>{
          'seat': 2,
          'reason': 'absent',
          'host_seat': 0,
        });
        final RoomSnapshot after = c.room!;
        expect(
          after.seats
              .map(
                (SeatState s) =>
                    (s.seat, s.connected, s.tokens.join(','), s.name),
              )
              .toList(),
          before.seats
              .map(
                (SeatState s) =>
                    (s.seat, s.connected, s.tokens.join(','), s.name),
              )
              .toList(),
          reason: _r(
            'N2-retired-nothing-else',
            'seats identical in seat, connected, tokens, name',
          ),
        );
        expect(
          after.state,
          before.state,
          reason: _r('N2-retired-nothing-else', 'state'),
        );
        expect(
          after.winner,
          before.winner,
          reason: _r('N2-retired-nothing-else', 'winner'),
        );
        expect(
          after.placings,
          before.placings,
          reason: _r('N2-retired-nothing-else', 'placings'),
        );
        expect(after.retired, <int>[
          2,
        ], reason: _r('N2-retired-nothing-else', 'retired == [2]'));
        expect(
          after.seq,
          before.seq + 1,
          reason: _r('N2-retired-nothing-else', 'seq advanced by one'),
        );
        final TurnState bt = before.turn!;
        final TurnState at = after.turn!;
        expect(
          _turnFields(at),
          _turnFields(bt),
          reason: _r(
            'N2-retired-nothing-else',
            'turn untouched: the turn or game_over that follows does the rest',
          ),
        );
        expect(
          at.release,
          bt.release,
          reason: _r('N2-retired-nothing-else', 'release untouched'),
        );
      },
    );

    test(
      'N2-retired-gap: a seat_retired past seq + 1 resyncs and applies nothing',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 5);
        await _push(t, 'seat_retired', <String, Object?>{
          'seat': 2,
          'reason': 'kicked',
          'host_seat': 1,
          'seq': 9,
        });
        expect(
          c.hasDesynced,
          isTrue,
          reason: _r('N2-retired-gap', 'hasDesynced'),
        );
        expect(_resumeCount(t), 1, reason: _r('N2-retired-gap', 'one resume'));
        expect(
          c.room!.retired,
          isEmpty,
          reason: _r('N2-retired-gap', 'retired untouched'),
        );
        expect(
          c.room!.hostSeat,
          0,
          reason: _r('N2-retired-gap', 'hostSeat untouched'),
        );
        expect(
          c.lastRetirement,
          isNull,
          reason: _r('N2-retired-gap', 'lastRetirement untouched'),
        );
        expect(c.room!.seq, 5);
      },
    );

    test('N2-retired-replay: a replayed seat_retired resyncs and never '
        'doubles the seat in retired', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 5);
      final Map<String, Object?> data = <String, Object?>{
        'seat': 2,
        'reason': 'left',
        'host_seat': 0,
        'seq': 6,
      };
      await _push(t, 'seat_retired', data);
      await _push(t, 'seat_retired', data);
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N2-retired-replay', 'the replay is a gap'),
      );
      expect(c.room!.retired, <int>[
        2,
      ], reason: _r('N2-retired-replay', 'retired == [2], not [2, 2]'));
      expect(c.room!.seq, 6);
    });

    test('N2-retired-malformed: a seat_retired with no seat is dropped: no '
        'resync, no change, lastRetirement null', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 5);
      await _push(t, 'seat_retired', <String, Object?>{
        'reason': 'left',
        'host_seat': 0,
        'seq': 6,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N2-retired-malformed', 'no resync'),
      );
      expect(
        c.room!.retired,
        isEmpty,
        reason: _r('N2-retired-malformed', 'nothing applied'),
      );
      expect(c.lastRetirement, isNull);
      expect(c.room!.seq, 5);
    });

    test(
      'N2-retired-cleared-on-new-game: game_started clears lastRetirement',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 5);
        await _pushNext(c, t, 'seat_retired', <String, Object?>{
          'seat': 2,
          'reason': 'kicked',
          'host_seat': 0,
        });
        expect(
          c.lastRetirement,
          isNotNull,
          reason: 'precondition: seat_retired reduced into lastRetirement (N2)',
        );
        await _pushNext(c, t, 'game_started', <String, Object?>{
          'turn': 0,
          'game_id': 'game-2',
          'client_seeds': 'cs2',
        });
        expect(
          c.lastRetirement,
          isNull,
          reason: _r(
            'N2-retired-cleared-on-new-game',
            'lastRetirement null after game_started',
          ),
        );
        expect(c.hasDesynced, isFalse);
      },
    );

    test('N2-retired-then-game-over: seat_retired then game_over with no turn '
        'between resyncs nothing', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 5,
        seats: <Map<String, Object?>>[_seatJson(0), _seatJson(1)],
        turn: _turnJson(seat: 1),
      );
      await _pushNext(c, t, 'seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'left',
        'host_seat': 0,
      });
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://provefair.app/v/x',
        'placings': <int>[0, 1],
        'retired': <int>[1],
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N2-retired-then-game-over', 'no resync'),
      );
      expect(c.room!.state, RoomState.finished);
      expect(c.room!.seq, 7);
    });
  });

  // =========================================================================
  // N3. The release.
  // =========================================================================
  group('N3 release', () {
    test('N3-release-rolled: release true with a non-empty legal is '
        'awaitMove, release, legal and queue from the frame, value null, '
        'legalByFace null', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 3,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[3],
          release: true,
          k: 5,
        ),
      );
      final TurnState turn = c.room!.turn!;
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N3-release-rolled', 'no resync'),
      );
      expect(
        turn.phase,
        TurnPhase.awaitMove,
        reason: _r(
          'N3-release-rolled',
          'phase awaitMove (a queue with no legal_by_face is NOT awaitRoll here)',
        ),
      );
      expect(
        turn.release,
        isTrue,
        reason: _r('N3-release-rolled', 'release true'),
      );
      expect(turn.legal, <int>[
        0,
        1,
        2,
        3,
      ], reason: _r('N3-release-rolled', 'legal from the frame'));
      expect(turn.queue, <int>[
        3,
      ], reason: _r('N3-release-rolled', 'queue from the frame'));
      expect(turn.value, isNull, reason: _r('N3-release-rolled', 'value null'));
      expect(
        turn.legalByFace,
        isNull,
        reason: _r('N3-release-rolled', 'legalByFace null'),
      );
      expect(turn.seat, 0);
      expect(turn.k, 5, reason: _r('N3-release-rolled', 'k from the frame'));
      expect(c.room!.seq, 11);
    });

    test('N3-release-rolled-two-legal: the legal list is exactly the frame\'s, '
        'not widened to every token', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          legal: <int>[1, 3],
          queue: <int>[2],
          value: 2,
          release: true,
        ),
      );
      expect(c.room!.turn!.legal, <int>[
        1,
        3,
      ], reason: _r('N3-release-rolled-two-legal', 'legal == [1, 3]'));
      expect(c.room!.turn!.queue, <int>[2]);
      expect(
        c.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason: _r('N3-release-rolled-two-legal', 'phase awaitMove'),
      );
      expect(
        c.room!.turn!.release,
        isTrue,
        reason: _r('N3-release-rolled-two-legal', 'release true'),
      );
      expect(
        c.room!.turn!.value,
        isNull,
        reason: _r('N3-release-rolled-two-legal', 'value null'),
      );
    });

    test('N3-release-rolled-on-another-seat: a release rolled by seat 1 '
        'while the controller sits on seat 0 reduces the same way', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        turn: _turnJson(seat: 1),
      );
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 1,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[5],
          value: 5,
          release: true,
        ),
      );
      expect(c.room!.turn!.seat, 1);
      expect(c.room!.turn!.phase, TurnPhase.awaitMove);
      expect(c.room!.turn!.release, isTrue);
      expect(c.hasDesynced, isFalse);
    });

    test('N3-release-explicit-false: release false behaves as an ordinary '
        'roll-queue rolled: a queue with no legal_by_face is awaitRoll, '
        'release false', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 6,
          legal: <int>[],
          queue: <int>[6],
          release: false,
        ),
      );
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r('N3-release-explicit-false', 'release false'),
      );
      expect(
        c.room!.turn!.phase,
        TurnPhase.awaitRoll,
        reason: _r('N3-release-explicit-false', 'awaitRoll as today'),
      );
    });

    test('N3-release-absent-ordinary: an ordinary rolled with legal_by_face is '
        'awaitMove with release false', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 4,
          legal: <int>[1],
          queue: <int>[4],
          legalByFace: <Map<String, Object?>>[
            <String, Object?>{
              'face': 4,
              'tokens': <int>[1],
            },
          ],
        ),
      );
      final TurnState turn = c.room!.turn!;
      expect(
        turn.release,
        isFalse,
        reason: _r('N3-release-absent-ordinary', 'release false'),
      );
      expect(turn.phase, TurnPhase.awaitMove);
      expect(
        turn.value,
        4,
        reason: _r('N3-release-absent-ordinary', 'value kept as today'),
      );
      expect(turn.legalByFace, hasLength(1));
    });

    test('N3-release-lapse: release true with legal [] reduces as a roll-queue '
        'rolled with no legal move does today (awaitRoll, legal [], empty '
        'queue) plus release true', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 4,
          legal: <int>[],
          queue: <int>[],
          release: true,
        ),
      );
      final TurnState turn = c.room!.turn!;
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N3-release-lapse', 'no resync'),
      );
      expect(
        turn.release,
        isTrue,
        reason: _r('N3-release-lapse', 'release true on the lapse'),
      );
      expect(
        turn.phase,
        TurnPhase.awaitRoll,
        reason: _r(
          'N3-release-lapse',
          'awaitRoll as an ordinary no-legal-move roll',
        ),
      );
      expect(turn.legal, isEmpty, reason: _r('N3-release-lapse', 'legal []'));
      expect(turn.queue, isEmpty, reason: _r('N3-release-lapse', 'queue []'));
      expect(
        turn.value,
        4,
        reason: _r('N3-release-lapse', 'value stored as it arrived, as today'),
      );
      expect(
        c.room!.recentRolls.last,
        (5, 4),
        reason: _r('N3-release-lapse', 'recentRolls records the face as today'),
      );
    });

    test('N3-release-lapse-matches-ordinary: the lapse turn equals the '
        'ordinary no-legal-move turn in every field but release', () async {
      final (RoomController a, FakeTransport ta) = await _hand(seq: 10);
      final (RoomController b, FakeTransport tb) = await _hand(seq: 10);
      await _pushNext(
        a,
        ta,
        'rolled',
        _rolled(
          seat: 0,
          value: 4,
          legal: <int>[],
          queue: <int>[],
          release: true,
        ),
      );
      await _pushNext(
        b,
        tb,
        'rolled',
        _rolled(seat: 0, value: 4, legal: <int>[], queue: <int>[]),
      );
      final TurnState x = a.room!.turn!;
      final TurnState y = b.room!.turn!;
      expect(
        _turnFields(x),
        _turnFields(y),
        reason: _r(
          'N3-release-lapse-matches-ordinary',
          'identical but for release',
        ),
      );
      expect(
        x.release,
        isTrue,
        reason: _r('N3-release-lapse-matches-ordinary', 'lapse release true'),
      );
      expect(y.release, isFalse);
    });

    test('N3-release-lapse-chain: rolled (lapse), turn_passed, turn for the '
        'next seat is one unbroken chain; release is true until the '
        'turn_passed and false after it', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 2,
          legal: <int>[],
          queue: <int>[],
          release: true,
        ),
      );
      expect(c.room!.turn!.release, isTrue);
      await _pushNext(c, t, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r(
          'N3-release-lapse-chain',
          'release false once the turn_passed has been reduced',
        ),
      );
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 1500,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r(
          'N3-release-lapse-chain',
          'no resync across the three frames',
        ),
      );
      expect(c.room!.turn!.seat, 1);
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r(
          'N3-release-lapse-chain',
          'release false on the next seat turn',
        ),
      );
      expect(c.room!.seq, 13);
      expect(_resumeCount(t), 0);
    });

    test('N3-release-moved: moved with release true (from -1, no face) puts '
        'the token on 0, clears release, and chains into the turn', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[3],
          release: true,
        ),
      );
      expect(
        c.room!.turn!.release,
        isTrue,
        reason: 'precondition: a release rolled sets turn.release (N3)',
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 2, from: -1, to: 0, release: true),
      );
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N3-release-moved', 'no resync'),
      );
      expect(
        c.room!.seats.firstWhere((SeatState s) => s.seat == 0).tokens,
        <int>[-1, -1, 0, -1],
        reason: _r(
          'N3-release-moved',
          'token 2 of seat 0 on square 0, others still in the yard',
        ),
      );
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r('N3-release-moved', 'release false after the moved'),
      );
      expect(c.room!.seq, 12);
      expect(
        c.room!.lastSpentFace,
        isNull,
        reason: _r(
          'N3-release-moved',
          'no face on the frame, lastSpentFace not set',
        ),
      );
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': 44000,
        'value': 3,
        'legal': <int>[2],
        'queue': <int>[3],
        'legal_by_face': <Map<String, Object?>>[
          <String, Object?>{
            'face': 3,
            'tokens': <int>[2],
          },
        ],
      });
      expect(c.hasDesynced, isFalse);
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r(
          'N3-release-moved',
          'the follow-up turn does not set release',
        ),
      );
      expect(c.room!.turn!.phase, TurnPhase.awaitMove);
    });

    test('N3-release-moved-captures-nothing: captured [] and extra_roll false '
        'leave every other seat\'s tokens alone', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        seats: <Map<String, Object?>>[
          _seatJson(0),
          _seatJson(1, tokens: const <int>[0, 5, -1, -1]),
          _seatJson(2, tokens: const <int>[12, -1, -1, -1]),
        ],
      );
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[3],
          release: true,
        ),
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 0, from: -1, to: 0, release: true),
      );
      expect(
        c.room!.seats.firstWhere((SeatState s) => s.seat == 1).tokens,
        <int>[0, 5, -1, -1],
        reason: _r('N3-release-moved-captures-nothing', 'seat 1 untouched'),
      );
      expect(
        c.room!.seats.firstWhere((SeatState s) => s.seat == 2).tokens,
        <int>[12, -1, -1, -1],
        reason: _r('N3-release-moved-captures-nothing', 'seat 2 untouched'),
      );
    });

    test('N3-release-moved-then-pass: moved (release), turn_passed, turn is '
        'one chain', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[3],
          release: true,
        ),
      );
      expect(
        c.room!.turn!.release,
        isTrue,
        reason: _r(
          'N3-release-moved-then-pass',
          'release true after the rolled',
        ),
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 0, from: -1, to: 0, release: true),
      );
      await _pushNext(c, t, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 1500,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N3-release-moved-then-pass', 'no resync'),
      );
      expect(c.room!.turn!.seat, 1);
      expect(c.room!.turn!.release, isFalse);
      expect(c.room!.seq, 14);
    });

    test('N3-moved-ordinary-clears-release: an ordinary moved after a '
        'release-carrying turn also leaves release false', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        turn: _turnJson(
          phase: 'await_move',
          legal: <int>[0],
          queue: <int>[3],
          release: true,
        ),
      );
      expect(
        c.room!.turn!.release,
        isTrue,
        reason:
            'precondition: a snapshot turn carrying release true is read (N1)',
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 0, from: -1, to: 0),
      );
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r(
          'N3-moved-ordinary-clears-release',
          'release false after any moved',
        ),
      );
    });

    test('N3-turn-never-sets-release: a turn frame without release leaves '
        'release false even straight after a release rolled', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(seat: 0, legal: <int>[0, 1], queue: <int>[3], release: true),
      );
      expect(
        c.room!.turn!.release,
        isTrue,
        reason: 'precondition: a release rolled sets turn.release (N3)',
      );
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': 40000,
        'value': 3,
        'legal': <int>[0, 1],
        'queue': <int>[3],
      });
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r(
          'N3-turn-never-sets-release',
          'a turn frame that does not carry release gives release false',
        ),
      );
    });

    test('N3-turn-carrying-release: a turn frame that carries release true '
        'sets it', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': 45000,
        'value': 3,
        'legal': <int>[0, 1],
        'queue': <int>[3],
        'release': true,
      });
      expect(
        c.room!.turn!.release,
        isTrue,
        reason: _r(
          'N3-turn-carrying-release',
          'a turn frame that carries release true sets it',
        ),
      );
    });

    test('N3-release-gap: a release rolled past seq + 1 resyncs and is not '
        'applied', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _push(t, 'rolled', <String, Object?>{
        ..._rolled(seat: 0, legal: <int>[0, 1], queue: <int>[3], release: true),
        'seq': 14,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N3-release-gap', 'hasDesynced'),
      );
      expect(
        c.room!.turn!.release,
        isFalse,
        reason: _r('N3-release-gap', 'release not applied'),
      );
      expect(c.room!.turn!.phase, TurnPhase.awaitRoll);
      expect(_resumeCount(t), 1);
    });

    test('N3-release-moved-gap: a release moved past seq + 1 resyncs and '
        'leaves the tokens in the yard', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _push(t, 'moved', <String, Object?>{
        ..._moved(seat: 0, token: 0, from: -1, to: 0, release: true),
        'seq': 15,
      });
      expect(c.hasDesynced, isTrue);
      expect(
        c.room!.seats.firstWhere((SeatState s) => s.seat == 0).tokens,
        <int>[-1, -1, -1, -1],
        reason: _r('N3-release-moved-gap', 'tokens untouched'),
      );
    });

    test(
      'N3-snapshot-release-turn: a resume snapshot whose turn carries '
      'release true is awaitMove with release, legal, queue, no value',
      () async {
        final (RoomController c, FakeTransport t, _) = await _connected(
          _roomJson(
            ruleset: '2026-11',
            turn: _turnJson(
              phase: 'await_move',
              legal: <int>[0, 3],
              queue: <int>[2],
              release: true,
            ),
          ),
        );
        addTearDown(c.dispose);
        final TurnState turn = c.room!.turn!;
        expect(
          turn.release,
          isTrue,
          reason: _r('N3-snapshot-release-turn', 'release true'),
        );
        expect(turn.phase, TurnPhase.awaitMove);
        expect(turn.legal, <int>[0, 3]);
        expect(turn.queue, <int>[2]);
        expect(
          turn.value,
          isNull,
          reason: _r('N3-snapshot-release-turn', 'no value'),
        );
        expect(turn.legalByFace, isNull);
        expect(_resumeCount(t), 0);
      },
    );
  });

  // =========================================================================
  // N4. game_over.
  // =========================================================================
  group('N4 game_over', () {
    test('N4-game-over-stores: placings and retired are stored from the '
        'frame, winner and state as today', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        placings: <int>[1],
        retired: <int>[2],
        turn: _turnJson(seat: 0),
      );
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'https://provefair.app/v/x',
        'placings': <int>[1, 0],
        'retired': <int>[2],
      });
      expect(c.hasDesynced, isFalse);
      expect(
        c.room!.state,
        RoomState.finished,
        reason: _r('N4-game-over-stores', 'state finished'),
      );
      expect(
        c.room!.winner,
        1,
        reason: _r('N4-game-over-stores', 'winner as today'),
      );
      expect(
        c.room!.placings,
        <int>[1, 0],
        reason: _r(
          'N4-game-over-stores',
          'placings from the frame, last seat standing included',
        ),
      );
      expect(c.room!.retired, <int>[
        2,
      ], reason: _r('N4-game-over-stores', 'retired from the frame'));
      expect(
        c.room!.turn!.phase,
        TurnPhase.finished,
        reason: _r('N4-game-over-stores', 'turn finished as today'),
      );
    });

    test('N4-game-over-replaces: the frame\'s lists replace what the deltas '
        'accumulated, they are not appended to it', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        placings: <int>[2],
        retired: <int>[1],
      );
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 2,
        'verify_url': '',
        'placings': <int>[2, 0, 1],
        'retired': <int>[1],
      });
      expect(
        c.room!.placings,
        <int>[2, 0, 1],
        reason: _r(
          'N4-game-over-replaces',
          'placings == the frame, not [2, 2, 0, 1]',
        ),
      );
      expect(
        c.room!.retired,
        <int>[1],
        reason: _r('N4-game-over-replaces', 'retired == the frame, not [1, 1]'),
      );
    });

    test('N4-game-over-absent: a 2026-10 game_over with neither key leaves '
        'both lists empty', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        ruleset: null,
        seq: 10,
      );
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://provefair.app/v/x',
      });
      expect(
        c.room!.placings,
        isEmpty,
        reason: _r('N4-game-over-absent', 'placings []'),
      );
      expect(
        c.room!.retired,
        isEmpty,
        reason: _r('N4-game-over-absent', 'retired []'),
      );
      expect(c.room!.winner, 0);
    });

    test(
      'N4-game-over-empty-retired: retired [] with placings of three',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        await _pushNext(c, t, 'game_over', <String, Object?>{
          'winner': 2,
          'verify_url': 'u',
          'placings': <int>[2, 1, 0],
          'retired': <int>[],
        });
        expect(c.room!.placings, <int>[2, 1, 0]);
        expect(c.room!.retired, isEmpty);
      },
    );

    test('N4-last-finished: lastFinished keeps placings and retired', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'u',
        'placings': <int>[0, 1],
        'retired': <int>[2],
      });
      expect(
        c.lastFinished,
        isNotNull,
        reason: _r('N4-last-finished', 'lastFinished recorded'),
      );
      expect(c.lastFinished!.placings, <int>[
        0,
        1,
      ], reason: _r('N4-last-finished', 'lastFinished.placings'));
      expect(c.lastFinished!.retired, <int>[
        2,
      ], reason: _r('N4-last-finished', 'lastFinished.retired'));
      expect(c.lastFinished!.winner, 0);
    });

    test('N4-last-finished-after-freeing: after game_over, one player_left '
        'per retired seat (their own seq) resyncs nothing and lastFinished '
        'keeps placings, retired and the retired seat in seats', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        retired: <int>[1, 2],
      );
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'u',
        'placings': <int>[0],
        'retired': <int>[1, 2],
      });
      await _pushNext(c, t, 'player_left', <String, Object?>{
        'seat': 1,
        'host_seat': 0,
      });
      await _pushNext(c, t, 'player_left', <String, Object?>{
        'seat': 2,
        'host_seat': 0,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r(
          'N4-last-finished-after-freeing',
          'no resync across game_over and two player_left',
        ),
      );
      expect(c.room!.seq, 13);
      expect(c.room!.seats.map((SeatState s) => s.seat).toList(), <int>[0]);
      expect(
        c.lastFinished!.placings,
        <int>[0],
        reason: _r(
          'N4-last-finished-after-freeing',
          'lastFinished.placings kept',
        ),
      );
      expect(
        c.lastFinished!.retired,
        <int>[1, 2],
        reason: _r(
          'N4-last-finished-after-freeing',
          'lastFinished.retired kept',
        ),
      );
      expect(
        c.lastFinished!.seats.map((SeatState s) => s.seat).toList(),
        <int>[0, 1, 2],
        reason: _r(
          'N4-last-finished-after-freeing',
          'lastFinished keeps the finished seat list as before',
        ),
      );
    });

    test('N4-last-finished-cleared-on-new-game: game_started drops '
        'lastFinished as today', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'u',
        'placings': <int>[0, 1, 2],
        'retired': <int>[],
      });
      await _pushNext(c, t, 'game_started', <String, Object?>{
        'turn': 1,
        'game_id': 'game-2',
        'client_seeds': 'x',
      });
      expect(
        c.lastFinished,
        isNull,
        reason: _r('N4-last-finished-cleared-on-new-game', 'lastFinished null'),
      );
    });

    test('N4-game-over-gap: a game_over past seq + 1 resyncs and stores no '
        'placings', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _push(t, 'game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'u',
        'placings': <int>[0, 1, 2],
        'retired': <int>[],
        'seq': 15,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N4-game-over-gap', 'hasDesynced'),
      );
      expect(
        c.room!.placings,
        isEmpty,
        reason: _r('N4-game-over-gap', 'placings not stored'),
      );
      expect(c.room!.state, RoomState.playing);
      expect(c.lastFinished, isNull);
    });

    test('N4-no-seat-finished-at-end: the winning move ends in game_over '
        'with no seat_finished, one chain moved, game_over', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 10,
        turn: _turnJson(
          seat: 2,
          phase: 'await_move',
          legal: <int>[3],
          value: 3,
          queue: <int>[3],
        ),
        seats: <Map<String, Object?>>[
          _seatJson(0),
          _seatJson(1),
          _seatJson(2, tokens: const <int>[57, 57, 57, 54]),
        ],
        placings: <int>[1],
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 2, token: 3, from: 54, to: 57, face: 3),
      );
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'u',
        'placings': <int>[1, 2, 0],
        'retired': <int>[],
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N4-no-seat-finished-at-end', 'no resync'),
      );
      expect(c.room!.placings, <int>[1, 2, 0]);
      expect(c.room!.seq, 12);
    });
  });

  // =========================================================================
  // N5. The grace.
  // =========================================================================
  group('N5 grace', () {
    test('N5-turn-grace: a turn frame with grace_ms carries it as graceMs and '
        'leaves deadlineMs and segmentMs at the full budget', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 1060,
      });
      final TurnState turn = c.room!.turn!;
      expect(
        turn.graceMs,
        1060,
        reason: _r('N5-turn-grace', 'graceMs == 1060'),
      );
      expect(
        turn.deadlineMs,
        45000,
        reason: _r(
          'N5-turn-grace',
          'deadlineMs is the full budget, the grace is not subtracted',
        ),
      );
      expect(
        turn.segmentMs,
        45000,
        reason: _r('N5-turn-grace', 'segmentMs unchanged by the grace'),
      );
      expect(turn.seat, 1);
    });

    test(
      'N5-turn-no-grace: a turn frame without grace_ms gives null, not 0',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        await _pushNext(c, t, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
        });
        expect(
          c.room!.turn!.graceMs,
          isNull,
          reason: _r('N5-turn-no-grace', 'graceMs null'),
        );
      },
    );

    test('N5-turn-grace-not-sticky: a later turn without grace_ms clears an '
        'earlier graceMs', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 500,
      });
      expect(
        c.room!.turn!.graceMs,
        500,
        reason: 'precondition: a turn frame with grace_ms sets graceMs (N5)',
      );
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
      });
      expect(
        c.room!.turn!.graceMs,
        isNull,
        reason: _r('N5-turn-grace-not-sticky', 'graceMs back to null'),
      );
    });

    test('N5-turn-grace-await-move: grace_ms on an await_move turn is read '
        'too', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'phase': 'await_move',
        'deadline_ms': 10000,
        'value': 2,
        'legal': <int>[0],
        'queue': <int>[2],
        'grace_ms': 1700,
      });
      expect(c.room!.turn!.graceMs, 1700);
      expect(
        c.room!.turn!.deadlineMs,
        10000,
        reason: _r(
          'N5-turn-grace-await-move',
          'away seat budget 10000 untouched',
        ),
      );
    });

    test('N5-snapshot-grace: a snapshot turn mid-grace carries graceMs 660 '
        'and the full deadline; one after the grace carries null', () async {
      final (RoomController mid, _, _) = await _connected(
        _roomJson(
          ruleset: '2026-11',
          turn: _turnJson(deadlineMs: 45000, graceMs: 660),
        ),
      );
      addTearDown(mid.dispose);
      expect(
        mid.room!.turn!.graceMs,
        660,
        reason: _r('N5-snapshot-grace', 'graceMs 660'),
      );
      expect(
        mid.room!.turn!.deadlineMs,
        45000,
        reason: _r('N5-snapshot-grace', 'deadlineMs the full budget'),
      );
      final (RoomController after, _, _) = await _connected(
        _roomJson(ruleset: '2026-11', turn: _turnJson(deadlineMs: 43000)),
      );
      addTearDown(after.dispose);
      expect(
        after.room!.turn!.graceMs,
        isNull,
        reason: _r('N5-snapshot-grace', 'graceMs null after the grace'),
      );
      expect(after.room!.turn!.deadlineMs, 43000);
    });

    test(
      'N5-no-other-reader: the frame stays a plain turn, so the grace does '
      'not change seq handling: a gap on a turn with grace resyncs',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        await _push(t, 'turn', <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'grace_ms': 1060,
          'seq': 20,
        });
        expect(
          c.hasDesynced,
          isTrue,
          reason: _r('N5-no-other-reader', 'gap still resyncs'),
        );
        expect(c.room!.turn!.seat, 0);
        expect(c.room!.turn!.graceMs, isNull);
      },
    );
  });

  // =========================================================================
  // N6. kick.
  // =========================================================================
  group('N6 kick on the connection', () {
    Future<(RoomConnection, FakeTransport)> open() async {
      final FakeTransport transport = FakeTransport();
      final RoomConnection connection = RoomConnection(
        url: Uri.parse(_testUrl),
        connect: (Uri url) async => transport,
      );
      await connection.open();
      addTearDown(connection.close);
      return (connection, transport);
    }

    test('N6-conn-envelope: kick(2) sends t "kick" with d {"seat": 2} and '
        'nothing else', () async {
      final (RoomConnection conn, FakeTransport t) = await open();
      final Future<Frame> future = conn.kick(2);
      await pumpEventQueue();
      final Map<String, Object?> sent = _decode(t.sentRaw.last);
      expect(sent['t'], 'kick', reason: _r('N6-conn-envelope', 't == "kick"'));
      expect(sent['d'], <String, Object?>{
        'seat': 2,
      }, reason: _r('N6-conn-envelope', 'd == {"seat": 2}'));
      t.pushText(
        _frame(
          type: 'seat_retired',
          re: sent['id']! as String,
          data: <String, Object?>{
            'seat': 2,
            'reason': 'kicked',
            'host_seat': 0,
            'seq': 3,
          },
        ),
      );
      await future;
    });

    test('N6-conn-completes-with-reply: the future completes with the reply '
        'frame itself', () async {
      final (RoomConnection conn, FakeTransport t) = await open();
      final Future<Frame> future = conn.kick(1);
      await pumpEventQueue();
      final String id = _idOf(t.sentRaw.last);
      t.pushText(
        _frame(
          type: 'seat_retired',
          re: id,
          data: <String, Object?>{
            'seat': 1,
            'reason': 'kicked',
            'host_seat': 0,
            'seq': 9,
          },
        ),
      );
      final Frame reply = await future;
      expect(
        reply.type,
        'seat_retired',
        reason: _r('N6-conn-completes-with-reply', 'reply.type'),
      );
      expect(
        reply.re,
        id,
        reason: _r(
          'N6-conn-completes-with-reply',
          'reply.re is the request id',
        ),
      );
      expect(reply.data['seat'], 1);
      expect(reply.data['reason'], 'kicked');
    });

    test('N6-conn-error: an error reply completes with ProtocolErrorException '
        'carrying the code, for each of the five codes', () async {
      for (final String code in <String>[
        'NOT_HOST',
        'WRONG_PHASE',
        'BAD_FIELD',
        'ILLEGAL_MOVE',
        'NOT_ABSENT',
      ]) {
        final (RoomConnection conn, FakeTransport t) = await open();
        final Future<Frame> future = conn.kick(3);
        await pumpEventQueue();
        t.pushText(
          _frame(
            type: 'error',
            re: _idOf(t.sentRaw.last),
            data: <String, Object?>{'code': code, 'message': 'no'},
          ),
        );
        await expectLater(
          future,
          throwsA(
            isA<ProtocolErrorException>().having(
              (ProtocolErrorException e) => e.code,
              'code',
              code,
            ),
          ),
          reason: _r(
            'N6-conn-error ($code)',
            'ProtocolErrorException with code $code',
          ),
        );
      }
    });

    test('N6-conn-closed: kick on a connection that is not open throws '
        'ConnectionClosedException, as every request does', () async {
      final RoomConnection conn = RoomConnection(
        url: Uri.parse(_testUrl),
        connect: (Uri url) async => FakeTransport(),
      );
      addTearDown(conn.close);
      await expectLater(
        conn.kick(1),
        throwsA(isA<ConnectionClosedException>()),
        reason: _r('N6-conn-closed', 'ConnectionClosedException before open()'),
      );
    });
  });

  group('N6 kick on the controller', () {
    Map<String, Object?> retiredReply(int seat, int seq, {int host = 0}) =>
        <String, Object?>{
          'seat': seat,
          'reason': 'kicked',
          'host_seat': host,
          'seq': seq,
        };

    test('N6-ctl-accepted: the envelope is sent, a seat_retired reply with re '
        'returns null, and the frame is reduced exactly once', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      final Future<String?> future = c.kick(2);
      await pumpEventQueue();
      final List<Map<String, Object?>> kicks = _sentOfType(t, 'kick');
      expect(
        kicks,
        hasLength(1),
        reason: _r('N6-ctl-accepted', 'exactly one kick frame sent'),
      );
      expect(kicks.single['d'], <String, Object?>{
        'seat': 2,
      }, reason: _r('N6-ctl-accepted', 'd == {"seat": 2}'));
      t.pushText(
        _frame(
          type: 'seat_retired',
          re: kicks.single['id']! as String,
          data: retiredReply(2, 11),
        ),
      );
      expect(
        await future,
        isNull,
        reason: _r(
          'N6-ctl-accepted',
          'null when the server answered seat_retired',
        ),
      );
      await pumpEventQueue();
      expect(
        c.phase,
        RoomPhase.connected,
        reason: _r('N6-ctl-accepted', 'phase connected'),
      );
      expect(c.hasDesynced, isFalse);
      expect(
        c.room!.retired,
        <int>[2],
        reason: _r(
          'N6-ctl-accepted',
          'the reply seat_retired is reduced: retired == [2] (once, not [2, 2])',
        ),
      );
      expect(
        c.room!.seq,
        11,
        reason: _r('N6-ctl-accepted', 'seq advanced exactly once'),
      );
      expect(c.lastRetirement, (
        seat: 2,
        reason: 'kicked',
      ), reason: _r('N6-ctl-accepted', 'lastRetirement set from the reply'));
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 500,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('N6-ctl-accepted', 'the turn after the reply is contiguous'),
      );
    });

    for (final String code in <String>[
      'NOT_HOST',
      'WRONG_PHASE',
      'BAD_FIELD',
      'ILLEGAL_MOVE',
      'NOT_ABSENT',
    ]) {
      test('N6-ctl-refused-$code: the code is returned and the connection '
          'stays up, state untouched, later frames still reduced', () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        final RoomSnapshot before = c.room!;
        final int sentBefore = t.sentRaw.length;
        final Future<String?> future = c.kick(1);
        await pumpEventQueue();
        final Map<String, Object?> sent = _decode(t.sentRaw.last);
        expect(
          sent['t'],
          'kick',
          reason: 'precondition: kick sent a kick frame (N6)',
        );
        t.pushText(
          _frame(
            type: 'error',
            re: sent['id']! as String,
            data: <String, Object?>{'code': code, 'message': 'refused'},
          ),
        );
        final String scenario = 'N6-ctl-refused-$code';
        expect(
          await future,
          code,
          reason: _r(scenario, 'the refusal code "$code" returned'),
        );
        await pumpEventQueue();
        expect(
          c.phase,
          RoomPhase.connected,
          reason: _r(scenario, 'phase still connected'),
        );
        expect(c.errorCode, isNull, reason: _r(scenario, 'no errorCode set'));
        expect(
          t.isClosed,
          isFalse,
          reason: _r(scenario, 'transport not closed'),
        );
        expect(
          t.closeCalls,
          isEmpty,
          reason: _r(scenario, 'close never called'),
        );
        expect(
          t.sentRaw.length,
          sentBefore + 1,
          reason: _r(
            scenario,
            'only the kick was sent: no resume, no reconnect',
          ),
        );
        expect(
          identical(c.room, before),
          isTrue,
          reason: _r(scenario, 'room untouched'),
        );
        await _pushNext(c, t, 'presence', <String, Object?>{
          'seat': 1,
          'connected': false,
        });
        expect(
          c.room!.seats.firstWhere((SeatState s) => s.seat == 1).connected,
          isFalse,
          reason: _r(
            scenario,
            'a later frame on the same connection is still reduced',
          ),
        );
      });
    }

    for (final String code in <String>[
      'NOT_YOUR_TURN',
      'GAME_OVER',
      'RATE_LIMITED',
      'ROOM_NOT_FOUND',
      'SOMETHING_NEW',
    ]) {
      test('N6-ctl-other-$code: a code outside the five fails as an in-room '
          'request does today: phase failed, errorCode verbatim, connection '
          'closed', () async {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        final Future<String?> future = c.kick(1);
        await pumpEventQueue();
        t.pushText(
          _frame(
            type: 'error',
            re: _idOf(t.sentRaw.last),
            data: <String, Object?>{'code': code, 'message': 'x'},
          ),
        );
        await future;
        await pumpEventQueue();
        final String scenario = 'N6-ctl-other-$code';
        expect(c.phase, RoomPhase.failed, reason: _r(scenario, 'phase failed'));
        expect(c.errorCode, code, reason: _r(scenario, 'errorCode == "$code"'));
        expect(t.isClosed, isTrue, reason: _r(scenario, 'transport closed'));
      });
    }

    test('N6-ctl-lowercase-code: a refused code that differs only in case is '
        'not one of the five', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      final Future<String?> future = c.kick(1);
      await pumpEventQueue();
      t.pushText(
        _frame(
          type: 'error',
          re: _idOf(t.sentRaw.last),
          data: <String, Object?>{'code': 'not_absent', 'message': 'x'},
        ),
      );
      await future;
      await pumpEventQueue();
      expect(
        c.phase,
        RoomPhase.failed,
        reason: _r('N6-ctl-lowercase-code', 'exact-match codes only'),
      );
    });

    test('N6-ctl-seat-is-not-filtered: kick(9) and kick(-1) are sent as '
        'given; the server owns BAD_FIELD', () async {
      for (final int seat in <int>[9, -1, 0]) {
        final (RoomController c, FakeTransport t) = await _hand(seq: 10);
        final Future<String?> future = c.kick(seat);
        await pumpEventQueue();
        final Map<String, Object?> sent = _decode(t.sentRaw.last);
        expect(
          sent['t'],
          'kick',
          reason: _r(
            'N6-ctl-seat-is-not-filtered (seat $seat)',
            'a kick frame sent',
          ),
        );
        expect(
          sent['d'],
          <String, Object?>{'seat': seat},
          reason: _r(
            'N6-ctl-seat-is-not-filtered (seat $seat)',
            'd == {"seat": $seat}',
          ),
        );
        t.pushText(
          _frame(
            type: 'error',
            re: sent['id']! as String,
            data: <String, Object?>{'code': 'BAD_FIELD', 'message': 'seat'},
          ),
        );
        expect(await future, 'BAD_FIELD');
      }
    });

    test('N6-ctl-not-connected: idle, closed and failed phases return null '
        'and send nothing, open nothing, notify nothing', () async {
      // idle
      final _Connector idleConnector = _Connector();
      final RoomController idle = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: idleConnector.call,
      );
      addTearDown(idle.dispose);
      int notified = 0;
      idle.addListener(() => notified++);
      expect(
        await idle.kick(1),
        isNull,
        reason: _r('N6-ctl-not-connected (idle)', 'null'),
      );
      expect(
        idleConnector.calls,
        isEmpty,
        reason: _r('N6-ctl-not-connected (idle)', 'no connection attempt'),
      );
      expect(idle.phase, RoomPhase.idle);
      expect(
        notified,
        0,
        reason: _r('N6-ctl-not-connected (idle)', 'no notification'),
      );

      // closed
      final (RoomController closed, FakeTransport ct, _Connector cc) =
          await _connected(_roomJson());
      addTearDown(closed.dispose);
      ct.endFromFarSide();
      await pumpEventQueue();
      expect(
        closed.phase,
        RoomPhase.closed,
        reason: 'precondition: the far side ending the stream closes the controller',
      );
      final int sentClosed = ct.sentRaw.length;
      final int callsClosed = cc.calls.length;
      expect(
        await closed.kick(1),
        isNull,
        reason: _r('N6-ctl-not-connected (closed)', 'null'),
      );
      expect(
        ct.sentRaw.length,
        sentClosed,
        reason: _r('N6-ctl-not-connected (closed)', 'nothing sent'),
      );
      expect(
        cc.calls.length,
        callsClosed,
        reason: _r('N6-ctl-not-connected (closed)', 'no new connection'),
      );
      expect(closed.phase, RoomPhase.closed);

      // failed
      final (RoomController failed, FakeTransport ft) = await _hand(seq: 10);
      final Future<String?> first = failed.kick(1);
      await pumpEventQueue();
      ft.pushText(
        _frame(
          type: 'error',
          re: _idOf(ft.sentRaw.last),
          data: <String, Object?>{'code': 'NOT_YOUR_TURN', 'message': 'x'},
        ),
      );
      await first;
      await pumpEventQueue();
      expect(
        failed.phase,
        RoomPhase.failed,
        reason: 'precondition: a refusal outside the five fails the controller (N6)',
      );
      final int sentFailed = ft.sentRaw.length;
      expect(
        await failed.kick(1),
        isNull,
        reason: _r('N6-ctl-not-connected (failed)', 'null'),
      );
      expect(
        ft.sentRaw.length,
        sentFailed,
        reason: _r('N6-ctl-not-connected (failed)', 'nothing sent'),
      );
      expect(failed.phase, RoomPhase.failed);
    });

    test('N6-ctl-after-dispose: kick on a disposed controller returns null '
        'and sends nothing', () async {
      final (RoomController c, FakeTransport t, _) = await _connected(
        _roomJson(),
      );
      c.dispose();
      final int sent = t.sentRaw.length;
      expect(
        await c.kick(1),
        isNull,
        reason: _r('N6-ctl-after-dispose', 'null'),
      );
      expect(
        t.sentRaw.length,
        sent,
        reason: _r('N6-ctl-after-dispose', 'nothing sent'),
      );
    });
  });

  // =========================================================================
  // N7. Everything else unchanged.
  // =========================================================================
  group('N7 unchanged', () {
    test('N7-cues-new-types: cuesForFrame answers [] for seat_finished and '
        'seat_retired, for my seat, another seat and no seat', () {
      for (final String type in <String>['seat_finished', 'seat_retired']) {
        for (final int? mySeat in <int?>[0, 1, 3, null]) {
          for (final int seat in <int>[0, 1, 2]) {
            final Frame frame = Frame(
              type: type,
              id: 'AAAAAAAA',
              data: <String, Object?>{
                'seat': seat,
                'place': 1,
                'reason': 'kicked',
                'host_seat': 0,
                'seq': 5,
              },
            );
            expect(
              cuesForFrame(frame, mySeat: mySeat),
              isEmpty,
              reason: _r(
                'N7-cues-new-types ($type seat $seat mySeat $mySeat)',
                'no cue',
              ),
            );
          }
        }
      }
    });

    test('N7-2026-10-hand: a complete 2026-10 hand (rolled with queue, moved, '
        'turn, turn_passed, game_over) reduces as before and no new field is '
        'ever set', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        ruleset: null,
        seq: 10,
        turn: _turnJson(seat: 0, queue: <int>[]),
      );
      void expectNeutral(String step) {
        final RoomSnapshot r = c.room!;
        expect(
          r.rules.ruleset,
          isNull,
          reason: _r('N7-2026-10-hand ($step)', 'rules.ruleset null'),
        );
        expect(
          r.placings,
          isEmpty,
          reason: _r('N7-2026-10-hand ($step)', 'placings []'),
        );
        expect(
          r.retired,
          isEmpty,
          reason: _r('N7-2026-10-hand ($step)', 'retired []'),
        );
        expect(
          r.seats.map((SeatState s) => s.drought).toList(),
          everyElement(isNull),
          reason: _r('N7-2026-10-hand ($step)', 'drought null on every seat'),
        );
        expect(
          r.turn!.release,
          isFalse,
          reason: _r('N7-2026-10-hand ($step)', 'release false'),
        );
        expect(
          r.turn!.graceMs,
          isNull,
          reason: _r('N7-2026-10-hand ($step)', 'graceMs null'),
        );
        expect(
          c.lastRetirement,
          isNull,
          reason: _r('N7-2026-10-hand ($step)', 'lastRetirement null'),
        );
        expect(
          c.hasDesynced,
          isFalse,
          reason: _r('N7-2026-10-hand ($step)', 'no resync'),
        );
      }

      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(seat: 0, value: 6, legal: <int>[], queue: <int>[6]),
      );
      expect(
        c.room!.turn!.phase,
        TurnPhase.awaitRoll,
        reason: _r(
          'N7-2026-10-hand (rolled 6)',
          'awaitRoll, a six owes a roll',
        ),
      );
      expectNeutral('rolled 6');
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 0,
        'deadline_ms': 45000,
        'phase': 'await_roll',
        'queue': <int>[6],
      });
      expectNeutral('turn same seat');
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          value: 2,
          legal: <int>[0],
          queue: <int>[6, 2],
          legalByFace: <Map<String, Object?>>[
            <String, Object?>{
              'face': 6,
              'tokens': <int>[0],
            },
            <String, Object?>{
              'face': 2,
              'tokens': <int>[0],
            },
          ],
        ),
      );
      expect(
        c.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason: _r(
          'N7-2026-10-hand (rolled 2)',
          'awaitMove with legal_by_face',
        ),
      );
      expect(c.room!.turn!.legalByFace, hasLength(2));
      expect(
        c.room!.turn!.value,
        2,
        reason: _r('N7-2026-10-hand (rolled 2)', 'value kept'),
      );
      expectNeutral('rolled 2');
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 0, from: 10, to: 12, face: 2),
      );
      expect(c.room!.lastSpentFace, 2);
      expectNeutral('moved');
      await _pushNext(c, t, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      expectNeutral('turn_passed');
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
      });
      expect(c.room!.turn!.seat, 1);
      expectNeutral('turn next seat');
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'u',
      });
      expect(c.room!.state, RoomState.finished);
      expect(c.room!.winner, 1);
      expect(c.room!.turn!.phase, TurnPhase.finished);
      expectNeutral('game_over');
      expect(c.lastFinished, isNotNull);
      expect(
        c.lastFinished!.placings,
        isEmpty,
        reason: _r('N7-2026-10-hand (game_over)', 'lastFinished.placings []'),
      );
      expect(c.lastFinished!.retired, isEmpty);
      expect(c.room!.seq, 17);
      expect(_resumeCount(t), 0);
    });

    test('N7-gap-2026-10: a moved then a turn that skips one seq still '
        'resyncs', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        ruleset: null,
        seq: 10,
      );
      await _push(t, 'moved', <String, Object?>{
        ..._moved(seat: 0, token: 0, from: 10, to: 12),
        'seq': 11,
      });
      await _push(t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'seq': 13,
      });
      expect(
        c.hasDesynced,
        isTrue,
        reason: _r('N7-gap-2026-10', 'a real gap still resyncs'),
      );
    });

    test(
      'N7-ordinary-moved-capture: a capturing moved reduces as before',
      () async {
        final (RoomController c, FakeTransport t) = await _hand(
          ruleset: null,
          seq: 10,
          seats: <Map<String, Object?>>[
            _seatJson(0, tokens: const <int>[10, -1, -1, -1]),
            _seatJson(1, tokens: const <int>[14, -1, -1, -1]),
            _seatJson(2),
          ],
        );
        await _pushNext(
          c,
          t,
          'moved',
          _moved(
            seat: 0,
            token: 0,
            from: 10,
            to: 14,
            captured: <Map<String, Object?>>[
              <String, Object?>{'seat': 1, 'token': 0},
            ],
            extraRoll: true,
            face: 4,
          ),
        );
        expect(
          c.room!.seats.firstWhere((SeatState s) => s.seat == 0).tokens,
          <int>[14, -1, -1, -1],
        );
        expect(
          c.room!.seats.firstWhere((SeatState s) => s.seat == 1).tokens,
          <int>[-1, -1, -1, -1],
        );
        expect(
          c.room!.turn!.settling,
          isTrue,
          reason: _r(
            'N7-ordinary-moved-capture',
            'settling placeholder as today',
          ),
        );
        expect(c.room!.turn!.release, isFalse);
      },
    );

    test('N7-unknown-type-still-inert: a frame type the reducer does not know '
        'neither advances seq nor resyncs', () async {
      final (RoomController c, FakeTransport t) = await _hand(seq: 10);
      await _push(t, 'seat_unknown_type', <String, Object?>{
        'seat': 1,
        'seq': 11,
      });
      expect(
        c.room!.seq,
        10,
        reason: _r('N7-unknown-type-still-inert', 'seq unchanged'),
      );
      expect(c.hasDesynced, isFalse);
    });
  });

  // =========================================================================
  // The whole 2026-11 hand, one chain.
  // =========================================================================
  group('N2-N6 together', () {
    test('NX-full-hand: release rolled, release moved, move, finish, retire, '
        'game_over, freeing: 12 frames, one chain, no resync', () async {
      final (RoomController c, FakeTransport t) = await _hand(
        seq: 200,
        seats: <Map<String, Object?>>[
          _seatJson(0),
          _seatJson(1, tokens: const <int>[57, 57, 57, 55]),
          _seatJson(2),
        ],
      );
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 0,
          legal: <int>[0, 1, 2, 3],
          queue: <int>[2],
          value: 2,
          release: true,
        ),
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 0, token: 0, from: -1, to: 0, release: true),
      );
      await _pushNext(c, t, 'turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 1,
        'deadline_ms': 45000,
        'grace_ms': 1500,
      });
      await _pushNext(
        c,
        t,
        'rolled',
        _rolled(
          seat: 1,
          value: 2,
          legal: <int>[3],
          queue: <int>[2],
          legalByFace: <Map<String, Object?>>[
            <String, Object?>{
              'face': 2,
              'tokens': <int>[3],
            },
          ],
        ),
      );
      await _pushNext(
        c,
        t,
        'moved',
        _moved(seat: 1, token: 3, from: 55, to: 57, face: 2),
      );
      await _pushNext(c, t, 'seat_finished', <String, Object?>{
        'seat': 1,
        'place': 1,
      });
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 2,
        'deadline_ms': 45000,
        'grace_ms': 1280,
      });
      await _pushNext(c, t, 'seat_retired', <String, Object?>{
        'seat': 2,
        'reason': 'absent',
        'host_seat': 0,
      });
      await _pushNext(c, t, 'turn', <String, Object?>{
        'seat': 0,
        'deadline_ms': 45000,
        'grace_ms': 500,
      });
      await _pushNext(c, t, 'game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'u',
        'placings': <int>[1, 0],
        'retired': <int>[2],
      });
      await _pushNext(c, t, 'player_left', <String, Object?>{
        'seat': 2,
        'host_seat': 0,
      });
      expect(
        c.hasDesynced,
        isFalse,
        reason: _r('NX-full-hand', 'no resync anywhere in the chain'),
      );
      expect(_resumeCount(t), 0, reason: _r('NX-full-hand', 'no resume sent'));
      expect(
        c.room!.seq,
        212,
        reason: _r('NX-full-hand', 'seq 200 + 12 frames'),
      );
      expect(c.room!.state, RoomState.finished);
      expect(c.room!.placings, <int>[1, 0]);
      expect(c.lastFinished!.retired, <int>[2]);
      expect(c.lastRetirement, (seat: 2, reason: 'absent'));
    });
  });
}

void unawaitedFuture(Future<void> future) {}
