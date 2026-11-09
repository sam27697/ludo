// C-607 (order 607t): a seat that leaves the rematch table stops counting as
// ready on the phone. Written from work/ludo/orders/607-left-seat-drops-ready.md
// (D1, D2) alone, never from the implementation.
//
// A real RoomController over a FakeTransport, driven the way the server drives
// it: a PLAYING room, `game_over`, then a `room` push carrying the section 16.2
// `rematch {by, ready}` block (the road test/c606_rematch_live_names_test.dart
// takes), then a `player_left` (PROTOCOL 16.9 item 4). The server removes a
// departing seat from `rematch.ready` and sends only `player_left`, so the
// phone must drop the mark itself; `by` stays exactly as it was.
//
// What the cases pin, by the order's letters:
//   a  seats 0,1,2, ready [0,1], by 0; seat 1 leaves: seats lose 1, ready is
//      [0], by is 0
//   b  the same with by 1 (the asker leaves): ready loses 1, by stays 1
//   c  a seat that is not ready leaves (seat 2): rematch is unchanged
//   d  no rematch (a plain LOBBY): the leave works as today, rematch is null
//   e  a seq gap on the player_left: nothing applied, a resync begins, ready
//      unchanged
//   f  a leave and then a player_joined for the same seat: the joiner is not
//      in ready
// plus the ugly neighbours: order of the other ready seats kept, the last
// ready seat leaving, a replayed player_left, two leaves in a row, the old
// snapshot left untouched, and a later `room` push that readies the joiner.
//
// Every wait is a drain of the event queue, never a sleep. Every failure
// reason names the scenario and carries the frames pushed so far (Rig.why),
// which is the whole recipe to replay it. Nothing here is random.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c607-left-seat-ready-test.invalid/ws';
const String _roomCode = 'K7M2QP';
const String _verifyUrl = 'https://provefair.app/v/c607-left-seat-ready';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c607-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

typedef _Seats = List<(int seat, String name)>;

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

/// A PLAYING room, a plain LOBBY (neither [playing] nor [rematchBy]), or the
/// section 16.2 rematch LOBBY that follows a game's end: a new chain, no game,
/// no turn, `rematch {by, ready}`.
Map<String, Object?> _roomJson({
  required _Seats seats,
  required int seq,
  bool playing = false,
  int? rematchBy,
  List<int>? ready,
}) {
  final bool rematch = rematchBy != null;
  return <String, Object?>{
    'code': _roomCode,
    'state': playing ? 'PLAYING' : 'LOBBY',
    'host_seat': 0,
    'players': 4,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': (rematch ? 'b' : 'a') * 64,
    'chain_index': rematch ? 1 : 0,
    'game_id': playing ? '7f3a9c1e5b2d4068' : null,
    'client_seeds': playing ? '0:sam-seed|2:friend-seed' : null,
    'seats': <Map<String, Object?>>[
      for (final (int seat, String name) in seats) _seatJson(seat, name),
    ],
    'turn': playing
        ? <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          }
        : null,
    'winner': null,
    'seq': seq,
    if (rematch)
      'rematch': <String, Object?>{
        'by': rematchBy,
        'ready': ready ?? <int>[rematchBy],
      },
  };
}

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

int _resumeCount(FakeTransport transport) => transport.sentRaw
    .where((String raw) => _decode(raw)['t'] == 'resume')
    .length;

const _Seats _three = <(int, String)>[(0, 'Sam'), (1, 'Karim'), (2, 'Lina')];

/// One scenario: a controller seated at seat 0 (host Sam) holding a lobby of
/// [_three], plain or in rematch with the `ready` and `by` the server told it.
class _Rig {
  _Rig._(this.name, this.controller, this.transport, this.seq);

  final String name;
  final RoomController controller;
  final FakeTransport transport;
  final List<String> steps = <String>[];

  /// The room seq the controller holds; the next state change carries +1.
  int seq;

  /// The replay recipe: scenario name and every frame pushed so far.
  String get why => 'scenario "$name"; frames so far: ${steps.join(' | ')}';

  RoomSnapshot get room => controller.room!;

  /// Mounts a plain LOBBY of [_three] with no rematch block at all.
  static Future<_Rig> plainLobby(String name) =>
      _open(name, _three, playing: false);

  /// Plays a first game to `game_over`, then pushes the rematch lobby `room`
  /// for [_three] with [ready] and [by].
  static Future<_Rig> rematchLobby(
    String name, {
    required int by,
    required List<int> ready,
  }) async {
    final _Rig rig = await _open(name, _three, playing: true);
    await rig.push('game_over', <String, Object?>{
      'winner': 2,
      'verify_url': _verifyUrl,
    });
    rig.seq += 1;
    final Map<String, Object?> data = _roomJson(
      seats: _three,
      seq: rig.seq,
      rematchBy: by,
      ready: ready,
    );
    rig.steps.add('push room (rematch lobby, by $by, ready $ready) $data');
    rig.transport.pushText(_frame(type: 'room', data: data));
    await pumpEventQueue();
    expect(
      rig.room.state,
      RoomState.lobby,
      reason: 'fixture: the rematch lobby is the live room; ${rig.why}',
    );
    expect(
      rig.room.rematch?.ready,
      ready,
      reason:
          'fixture: the room push must land with ready $ready; got '
          '${rig.room.rematch?.ready}; ${rig.why}',
    );
    expect(
      rig.room.rematch?.by,
      by,
      reason:
          'fixture: the room push must land with by $by; got '
          '${rig.room.rematch?.by}; ${rig.why}',
    );
    return rig;
  }

  static Future<_Rig> _open(
    String name,
    _Seats seats, {
    required bool playing,
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    addTearDown(controller.dispose);
    final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
    await pumpEventQueue();
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
        data: _roomJson(seats: seats, seq: 1, playing: playing),
      ),
    );
    await created;
    final _Rig rig = _Rig._(name, controller, transport, 1);
    rig.steps.add('mounted ${playing ? 'PLAYING' : 'LOBBY'} room seq 1');
    return rig;
  }

  /// One server push with the next seq (or [atSeq] when given), then a drain.
  Future<void> push(
    String type,
    Map<String, Object?> data, {
    int? atSeq,
  }) async {
    final int at = atSeq ?? seq + 1;
    if (atSeq == null) {
      seq = at;
    }
    final Map<String, Object?> full = <String, Object?>{...data, 'seq': at};
    steps.add('push $type $full');
    transport.pushText(_frame(type: type, data: full));
    await pumpEventQueue();
  }

  Future<void> left(int seat, {int? atSeq}) => push(
    'player_left',
    <String, Object?>{'seat': seat, 'host_seat': 0},
    atSeq: atSeq,
  );

  Future<void> joined(int seat, String name) =>
      push('player_joined', <String, Object?>{'seat': seat, 'name': name});

  List<int> get seatNumbers => <int>[
    for (final SeatState s in room.seats) s.seat,
  ];
}

void main() {
  // --- a: a ready seat leaves ------------------------------------------------
  group('(a) a ready seat leaves the rematch table', () {
    test('seats 0,1,2, ready [0,1], by 0; seat 1 leaves: seats lose 1, ready '
        'is [0], by is 0', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'a-ready-seat-leaves',
        by: 0,
        ready: <int>[0, 1],
      );
      await rig.left(1);
      expect(
        rig.seatNumbers,
        <int>[0, 2],
        reason:
            'C-607 D1: seat 1 is gone from seats; got ${rig.seatNumbers}; '
            '${rig.why}',
      );
      expect(
        rig.room.rematch,
        isNotNull,
        reason:
            'C-607 D1: the rematch block survives the leave; got null; '
            '${rig.why}',
      );
      expect(
        rig.room.rematch!.ready,
        <int>[0],
        reason:
            'C-607 D1: the server dropped seat 1 from rematch.ready, so the '
            'phone must too; expected [0], got ${rig.room.rematch!.ready}; '
            '${rig.why}',
      );
      expect(
        rig.room.rematch!.by,
        0,
        reason:
            'C-607 D1: by is kept exactly as it was (section 16.6); expected '
            '0, got ${rig.room.rematch!.by}; ${rig.why}',
      );
      expect(
        rig.room.seq,
        rig.seq,
        reason:
            'C-607 D2: the accepted frame advances seq to ${rig.seq}; got '
            '${rig.room.seq}; ${rig.why}',
      );
      expect(
        rig.controller.hasDesynced,
        isFalse,
        reason: 'C-607 D2: an in-turn leave is no desync; ${rig.why}',
      );
    });

    test('the other ready seats keep their order: ready [2,0,1] minus 1 is '
        '[2,0]', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'a-order-kept',
        by: 2,
        ready: <int>[2, 0, 1],
      );
      await rig.left(1);
      expect(
        rig.room.rematch?.ready,
        <int>[2, 0],
        reason:
            'C-607 D1: ready minus the departing seat, the order of the '
            'others kept; expected [2, 0], got ${rig.room.rematch?.ready}; '
            '${rig.why}',
      );
      expect(
        rig.room.rematch?.by,
        2,
        reason: 'C-607 D1: by stays 2; got ${rig.room.rematch?.by}; ${rig.why}',
      );
    });

    test('the only ready seat leaves: ready is empty, by is kept, the block '
        'is still there', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'a-last-ready-leaves',
        by: 1,
        ready: <int>[1],
      );
      await rig.left(1);
      expect(
        rig.room.rematch,
        isNotNull,
        reason:
            'C-607 D1: an empty ready list is still a rematch block (the '
            'leave does not close the ask); got null; ${rig.why}',
      );
      expect(
        rig.room.rematch!.ready,
        isEmpty,
        reason:
            'C-607 D1: nobody is ready any more; got '
            '${rig.room.rematch!.ready}; ${rig.why}',
      );
      expect(
        rig.room.rematch!.by,
        1,
        reason: 'C-607 D1: by stays 1; got ${rig.room.rematch!.by}; ${rig.why}',
      );
    });

    test('the snapshot held before the leave is not edited in place', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'a-old-snapshot-untouched',
        by: 0,
        ready: <int>[0, 1],
      );
      final RoomSnapshot before = rig.room;
      final RematchState? beforeRematch = before.rematch;
      await rig.left(1);
      expect(
        identical(rig.room, before),
        isFalse,
        reason: 'C-607 D1: a leave builds a new room; ${rig.why}',
      );
      expect(
        beforeRematch?.ready,
        <int>[0, 1],
        reason:
            'C-607 D1: the earlier RematchState still reads [0, 1] (a '
            'listener may hold it); got ${beforeRematch?.ready}; ${rig.why}',
      );
      expect(
        before.seats.length,
        3,
        reason:
            'C-607 D1: the earlier room still has 3 seats; got '
            '${before.seats.length}; ${rig.why}',
      );
    });

    test('two leaves in a row: ready [0,1,2] loses 1 then 2, one at a '
        'time', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'a-two-leaves',
        by: 0,
        ready: <int>[0, 1, 2],
      );
      await rig.left(1);
      expect(
        rig.room.rematch?.ready,
        <int>[0, 2],
        reason:
            'C-607 D1: after seat 1 left, expected [0, 2]; got '
            '${rig.room.rematch?.ready}; ${rig.why}',
      );
      await rig.left(2);
      expect(
        rig.room.rematch?.ready,
        <int>[0],
        reason:
            'C-607 D1: after seat 2 left, expected [0]; got '
            '${rig.room.rematch?.ready}; ${rig.why}',
      );
      expect(rig.seatNumbers, <int>[
        0,
      ], reason: 'only the host sits; got ${rig.seatNumbers}; ${rig.why}');
    });
  });

  // --- b: the asker leaves ---------------------------------------------------
  group('(b) the seat that asked for the rematch leaves', () {
    test(
      'by 1, ready [0,1]; seat 1 leaves: ready loses 1, by stays 1',
      () async {
        final _Rig rig = await _Rig.rematchLobby(
          'b-asker-leaves',
          by: 1,
          ready: <int>[0, 1],
        );
        await rig.left(1);
        expect(
          rig.room.rematch,
          isNotNull,
          reason: 'C-607 D1: the rematch block survives; got null; ${rig.why}',
        );
        expect(
          rig.room.rematch!.ready,
          <int>[0],
          reason:
              'C-607 D1: the asker is out of ready once gone; expected [0], '
              'got ${rig.room.rematch!.ready}; ${rig.why}',
        );
        expect(
          rig.room.rematch!.by,
          1,
          reason:
              'C-607 D1: by is kept exactly as it was even though seat 1 is '
              'gone (section 16.6); expected 1, got ${rig.room.rematch!.by}; '
              '${rig.why}',
        );
        expect(rig.seatNumbers, <int>[
          0,
          2,
        ], reason: 'seat 1 left; got ${rig.seatNumbers}; ${rig.why}');
      },
    );
  });

  // --- c: a seat that is not ready leaves ------------------------------------
  group('(c) a seat that is not ready leaves', () {
    test('ready [0,1], by 0; seat 2 leaves: rematch is unchanged', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'c-not-ready-leaves',
        by: 0,
        ready: <int>[0, 1],
      );
      await rig.left(2);
      expect(rig.seatNumbers, <int>[
        0,
        1,
      ], reason: 'seat 2 left; got ${rig.seatNumbers}; ${rig.why}');
      expect(
        rig.room.rematch,
        isNotNull,
        reason: 'C-607 D1: the rematch block is kept; got null; ${rig.why}',
      );
      expect(
        rig.room.rematch!.ready,
        <int>[0, 1],
        reason:
            'C-607 D1: seat 2 was not ready, so ready is untouched; '
            'expected [0, 1], got ${rig.room.rematch!.ready}; ${rig.why}',
      );
      expect(
        rig.room.rematch!.by,
        0,
        reason: 'C-607 D1: by stays 0; got ${rig.room.rematch!.by}; ${rig.why}',
      );
    });
  });

  // --- d: no rematch ---------------------------------------------------------
  group('(d) a plain lobby, no rematch', () {
    test('a leave works as today and rematch stays null', () async {
      final _Rig rig = await _Rig.plainLobby('d-plain-lobby-leave');
      expect(
        rig.room.rematch,
        isNull,
        reason: 'fixture: a plain LOBBY has no rematch; ${rig.why}',
      );
      await rig.left(1);
      expect(rig.seatNumbers, <int>[
        0,
        2,
      ], reason: 'seat 1 left the lobby; got ${rig.seatNumbers}; ${rig.why}');
      expect(
        rig.room.rematch,
        isNull,
        reason:
            'C-607 D1: no rematch before, none after; got '
            '${rig.room.rematch}; ${rig.why}',
      );
      expect(
        rig.room.seq,
        rig.seq,
        reason: 'the frame is applied at seq ${rig.seq}; ${rig.why}',
      );
      expect(
        rig.room.state,
        RoomState.lobby,
        reason: 'the room stays a lobby; ${rig.why}',
      );
    });
  });

  // --- e: seq gap and replay -------------------------------------------------
  group('(e) a player_left that skips a seq or repeats one', () {
    test(
      'a gap: nothing is applied, a resync begins, ready is unchanged',
      () async {
        final _Rig rig = await _Rig.rematchLobby(
          'e-seq-gap',
          by: 0,
          ready: <int>[0, 1],
        );
        final int held = rig.room.seq;
        final int resumesBefore = _resumeCount(rig.transport);
        await rig.left(1, atSeq: held + 5);
        expect(
          rig.controller.hasDesynced,
          isTrue,
          reason:
              'a gap (held seq $held, frame at ${held + 5}) must flag a '
              'desync; ${rig.why}',
        );
        expect(
          _resumeCount(rig.transport),
          resumesBefore + 1,
          reason:
              'a gap begins exactly one resync (a resume request); resumes '
              'before $resumesBefore, now ${_resumeCount(rig.transport)}; '
              '${rig.why}',
        );
        expect(
          rig.seatNumbers,
          <int>[0, 1, 2],
          reason:
              'a gapped player_left is not applied; got ${rig.seatNumbers}; '
              '${rig.why}',
        );
        expect(
          rig.room.seq,
          held,
          reason:
              'seq must not advance on a gap; held $held, got '
              '${rig.room.seq}; ${rig.why}',
        );
        expect(
          rig.room.rematch?.ready,
          <int>[0, 1],
          reason:
              'C-607 D1: ready changes only once the frame is accepted; '
              'expected [0, 1], got ${rig.room.rematch?.ready}; ${rig.why}',
        );
        expect(
          rig.room.rematch?.by,
          0,
          reason: 'by unchanged; got ${rig.room.rematch?.by}; ${rig.why}',
        );
      },
    );

    test('a replayed player_left (same seq twice) is applied once; the '
        'second changes nothing', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'e-replayed-leave',
        by: 0,
        ready: <int>[0, 1, 2],
      );
      await rig.left(1);
      final int seqAfterFirst = rig.room.seq;
      final int resumesBefore = _resumeCount(rig.transport);
      await rig.left(1, atSeq: rig.seq);
      expect(
        rig.room.rematch?.ready,
        <int>[0, 2],
        reason:
            'C-607 D1: a replay must not drop another seat or restore one; '
            'expected [0, 2], got ${rig.room.rematch?.ready}; ${rig.why}',
      );
      expect(rig.seatNumbers, <int>[
        0,
        2,
      ], reason: 'got ${rig.seatNumbers} after the replay; ${rig.why}');
      expect(
        rig.room.seq,
        seqAfterFirst,
        reason:
            'a replay does not advance seq; expected $seqAfterFirst, got '
            '${rig.room.seq}; ${rig.why}',
      );
      expect(
        _resumeCount(rig.transport),
        resumesBefore,
        reason: 'a replay starts no resync; ${rig.why}',
      );
    });
  });

  // --- f: a seat changes hands -----------------------------------------------
  group('(f) a seat is left and then taken by someone else', () {
    test('leave then player_joined for the same seat: the joiner is not in '
        'ready', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'f-changes-hands',
        by: 0,
        ready: <int>[0, 1],
      );
      await rig.left(1);
      await rig.joined(1, 'Maya');
      expect(rig.seatNumbers, <int>[
        0,
        1,
        2,
      ], reason: 'Maya sits at seat 1; got ${rig.seatNumbers}; ${rig.why}');
      expect(
        rig.room.seats.firstWhere((SeatState s) => s.seat == 1).name,
        'Maya',
        reason: 'seat 1 is Maya\'s now; ${rig.why}',
      );
      expect(
        rig.room.rematch?.ready,
        isNot(contains(1)),
        reason:
            'C-607 D1: Maya never accepted; the server dropped seat 1 when '
            'Karim left, so she must not read as ready; ready is '
            '${rig.room.rematch?.ready}; ${rig.why}',
      );
      expect(
        rig.room.rematch?.ready,
        <int>[0],
        reason:
            'C-607 D1: only the host is ready; got '
            '${rig.room.rematch?.ready}; ${rig.why}',
      );
      expect(
        rig.room.rematch?.by,
        0,
        reason: 'by stays 0; got ${rig.room.rematch?.by}; ${rig.why}',
      );
    });

    test('the joiner readies by a later room push: then, and only then, she '
        'is in ready', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'f-joiner-readies-later',
        by: 0,
        ready: <int>[0, 1],
      );
      await rig.left(1);
      await rig.joined(1, 'Maya');
      expect(
        rig.room.rematch?.ready,
        isNot(contains(1)),
        reason: 'C-607 D1: before she accepts; ${rig.why}',
      );
      rig.seq += 1;
      final Map<String, Object?> data = _roomJson(
        seats: const <(int, String)>[(0, 'Sam'), (1, 'Maya'), (2, 'Lina')],
        seq: rig.seq,
        rematchBy: 0,
        ready: <int>[0, 1],
      );
      rig.steps.add('push room (Maya readies) $data');
      rig.transport.pushText(_frame(type: 'room', data: data));
      await pumpEventQueue();
      expect(
        rig.room.rematch?.ready,
        <int>[0, 1],
        reason:
            'C-607 D2: a server `room` push is taken as it comes; expected '
            '[0, 1], got ${rig.room.rematch?.ready}; ${rig.why}',
      );
    });

    test('a ready neighbour is not disturbed when a seat changes hands: '
        'ready [0,2,1], seat 1 leaves and Maya joins', () async {
      final _Rig rig = await _Rig.rematchLobby(
        'f-neighbour-undisturbed',
        by: 0,
        ready: <int>[0, 2, 1],
      );
      await rig.left(1);
      await rig.joined(1, 'Maya');
      expect(
        rig.room.rematch?.ready,
        <int>[0, 2],
        reason:
            'C-607 D1: Lina (seat 2) stays ready, Maya is not; expected '
            '[0, 2], got ${rig.room.rematch?.ready}; ${rig.why}',
      );
    });
  });
}
