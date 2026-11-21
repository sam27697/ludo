// C-681t: the knock frames, the host's controls and the lobby kick on the
// client (order 681, docs/PROTOCOL.md section 31 items 3 to 6 and rulings
// 11d, 11e3).
//
// Written from the order and the spec alone; the names `answerKnock`,
// `setGuestApproval`, `knockState`, `KnockPhase`, `wasKicked`, `Knock`,
// `RoomSnapshot.knocks` do not exist until order 681's lib lands, so this
// file does not compile on a tree without it, by design.
//
// A real RoomController over FakeTransport, frames pushed one by one. Groups:
//   seq      `knock` and `knock_closed` carry seq: in order they apply, with
//            a gap they resume (one `resume` frame, hasDesynced), replayed
//            they do not apply twice. `knock_pending`, `knock_failed` and
//            `kicked` carry none and never start a resume.
//   knocker  knock_pending then knock_failed outcomes, then acceptance.
//   host     answer_knock, set_guest_approval and lobby kick frames.
//   kicked   the `kicked` frame: seat and token cleared, wasKicked, no
//            resume, no session-memory offer.
//
// Replay: flutter test test/c681_knock_kick_test.dart --plain-name '<id>'
// Every reason names the scenario and the frames sent. No random input.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c681-knock-kick.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _token = 'tok-c681-kk-001';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c681-kk-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _knockJson(String id, String name, int expiresMs) =>
    <String, Object?>{'knock_id': id, 'name': name, 'expires_ms': expiresMs};

Map<String, Object?> _roomJson({
  int seq = 10,
  bool approval = true,
  List<Map<String, Object?>> knocks = const <Map<String, Object?>>[],
  int seats = 2,
}) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
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
    for (int i = 0; i < seats; i += 1)
      <String, Object?>{
        'seat': i,
        'name': i == 0 ? 'Sam' : 'P$i',
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
        'via': i == 0 ? 'host' : 'link',
      },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': _linkId,
  'guest_approval': approval,
  'knocks': knocks,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];
  void enqueue(FakeTransport transport) => _queue.add(transport);
  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError('_Connector: nothing queued for call #${calls.length}');
    }
    return _queue.removeAt(0);
  }
}

class _Scn {
  _Scn(this.id, this.tester, this.controller, this.transport, this.connector);

  final String id;
  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;
  final List<String> pushed = <String>[];

  static _Scn open(
    WidgetTester tester,
    String id, {
    List<Duration> delays = const <Duration>[],
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: delays,
    );
    addTearDown(controller.dispose);
    return _Scn(id, tester, controller, transport, connector);
  }

  String get why =>
      '$id: pushed ${pushed.join(' | ')}; sent '
      '${transport.sentRaw.map(_typeOf).toList()}. reproduce: flutter test '
      "test/c681_knock_kick_test.dart --plain-name '$id'";

  Future<void> settle() async {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  /// A connected LOBBY at [seq] as the host (seat 0, create) or a guest
  /// (seat 1, typed-code join, approval off so it is seated at once).
  Future<void> seat({required bool host, int seq = 10}) async {
    final Future<void> pending = host
        ? controller.createRoom(name: 'Sam', players: 4)
        : controller.joinRoom(code: _code, name: 'Bob');
    await settle();
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': host ? 0 : 1, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(transport.sentRaw.last),
        data: _roomJson(seq: seq, approval: host),
      ),
    );
    await pending;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected connected after the seat reply. $why',
    );
  }

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    String? re,
  }) async {
    pushed.add('$type${jsonEncode(data)}');
    transport.pushText(_frame(type: type, re: re, data: data));
    await settle();
  }

  List<String> sentOf(String type) =>
      transport.sentRaw.where((String raw) => _typeOf(raw) == type).toList();

  List<(String, String, int)> get knocks => controller.room!.knocks
      .map((Knock k) => (k.id, k.name, k.expiresMs))
      .toList();

  void expectNoResume(String when) {
    expect(
      sentOf('resume'),
      isEmpty,
      reason: 'expected no `resume` $when. $why',
    );
    expect(
      controller.hasDesynced,
      isFalse,
      reason: 'expected hasDesynced false $when. $why',
    );
  }
}

void main() {
  group('seq: knock and knock_closed carry it', () {
    testWidgets('an in-order knock applies: added, seq advances, no resume', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.knock_in_order');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      expect(
        s.knocks,
        <(String, String, int)>[('kn-0001', 'Ann', 60000)],
        reason:
            'expected one knock (kn-0001, Ann, 60000). saw ${s.knocks}. ${s.why}',
      );
      expect(s.controller.room!.seq, 11, reason: 'expected seq 11. ${s.why}');
      s.expectNoResume('after an in-order knock');
    });

    testWidgets('two knocks keep arrival order', (tester) async {
      final _Scn s = _Scn.open(tester, 'seq.two_knocks');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0002', 'Zed', 60000),
        'seq': 12,
      });
      expect(s.knocks.map(((String, String, int) k) => k.$1).toList(), <String>[
        'kn-0001',
        'kn-0002',
      ], reason: 'expected arrival order. saw ${s.knocks}. ${s.why}');
      expect(s.controller.room!.seq, 12, reason: 'expected seq 12. ${s.why}');
    });

    testWidgets('knock_closed removes that knock only and advances seq', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.closed');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0002', 'Zed', 60000),
        'seq': 12,
      });
      await s.push('knock_closed', <String, Object?>{
        'knock_id': 'kn-0001',
        'outcome': 'rejected',
        'seq': 13,
      });
      expect(s.knocks.map(((String, String, int) k) => k.$1).toList(), <String>[
        'kn-0002',
      ], reason: 'expected only kn-0002 left. saw ${s.knocks}. ${s.why}');
      expect(s.controller.room!.seq, 13, reason: 'expected seq 13. ${s.why}');
      s.expectNoResume('after an in-order knock_closed');
    });

    testWidgets('every outcome of knock_closed closes the knock', (
      tester,
    ) async {
      for (final String outcome in <String>[
        'accepted',
        'rejected',
        'timeout',
        'full',
        'withdrawn',
        'switched_off',
      ]) {
        final _Scn s = _Scn.open(tester, 'seq.closed.$outcome');
        await s.seat(host: true, seq: 10);
        await s.push('knock', <String, Object?>{
          ..._knockJson('kn-0001', 'Ann', 60000),
          'seq': 11,
        });
        await s.push('knock_closed', <String, Object?>{
          'knock_id': 'kn-0001',
          'outcome': outcome,
          'seq': 12,
        });
        expect(
          s.knocks,
          isEmpty,
          reason: 'expected no knock after outcome $outcome. ${s.why}',
        );
        expect(
          s.controller.room!.seq,
          12,
          reason: 'expected seq 12 after $outcome. ${s.why}',
        );
      }
    });

    testWidgets('knock_closed for an unknown id changes no knock, no crash', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.closed_unknown');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      await s.push('knock_closed', <String, Object?>{
        'knock_id': 'kn-ghost',
        'outcome': 'timeout',
        'seq': 12,
      });
      expect(s.knocks.map(((String, String, int) k) => k.$1).toList(), <String>[
        'kn-0001',
      ], reason: 'a close for another id must leave kn-0001. ${s.why}');
      expect(
        s.controller.room!.seq,
        12,
        reason: 'in-order seq still advances. ${s.why}',
      );
    });

    testWidgets(
      'a knock with a seq gap triggers one resume and is not applied',
      (tester) async {
        final _Scn s = _Scn.open(tester, 'seq.knock_gap');
        await s.seat(host: true, seq: 10);
        await s.push('knock', <String, Object?>{
          ..._knockJson('kn-0001', 'Ann', 60000),
          'seq': 13,
        });
        expect(
          s.sentOf('resume'),
          hasLength(1),
          reason: 'expected exactly one resume. ${s.why}',
        );
        final Map<String, Object?> d =
            _decode(s.sentOf('resume').single)['d']! as Map<String, Object?>;
        expect(
          d['code'],
          _code,
          reason: 'resume must name the room code. ${s.why}',
        );
        expect(
          d['seat_token'],
          _token,
          reason: 'resume must carry the seat token. ${s.why}',
        );
        expect(
          s.controller.hasDesynced,
          isTrue,
          reason: 'expected hasDesynced. ${s.why}',
        );
        expect(
          s.knocks,
          isEmpty,
          reason: 'a gapped knock must not be applied. ${s.why}',
        );
        expect(
          s.controller.room!.seq,
          10,
          reason: 'seq must stay 10 until the resume. ${s.why}',
        );
      },
    );

    testWidgets('a knock_closed with a seq gap triggers a resume', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.closed_gap');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      await s.push('knock_closed', <String, Object?>{
        'knock_id': 'kn-0001',
        'outcome': 'rejected',
        'seq': 14,
      });
      expect(
        s.sentOf('resume'),
        hasLength(1),
        reason: 'expected exactly one resume. ${s.why}',
      );
      expect(
        s.controller.hasDesynced,
        isTrue,
        reason: 'expected hasDesynced. ${s.why}',
      );
      expect(s.knocks.map(((String, String, int) k) => k.$1).toList(), <String>[
        'kn-0001',
      ], reason: 'a gapped close must not be applied. ${s.why}');
    });

    testWidgets('the resume reply re-bases the knocks from the snapshot', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.resume_rebases');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 13,
      });
      final String resumeId = _idOf(s.sentOf('resume').single);
      await s.push(
        'room',
        _roomJson(
          seq: 13,
          knocks: <Map<String, Object?>>[_knockJson('kn-0001', 'Ann', 41000)],
        ),
        re: resumeId,
      );
      expect(
        s.controller.hasDesynced,
        isFalse,
        reason: 'resume reply must clear hasDesynced. ${s.why}',
      );
      expect(s.knocks, <(String, String, int)>[
        ('kn-0001', 'Ann', 41000),
      ], reason: 'knocks must come from the resume snapshot. ${s.why}');
    });

    testWidgets('a replayed knock is not applied twice', (tester) async {
      final _Scn s = _Scn.open(tester, 'seq.knock_replay');
      await s.seat(host: true, seq: 10);
      final Map<String, Object?> knock = <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      };
      await s.push('knock', knock);
      await s.push('knock', knock);
      expect(
        s.knocks.length,
        1,
        reason:
            'a replayed knock must not duplicate it. saw ${s.knocks}. ${s.why}',
      );
      expect(s.controller.room!.seq, 11, reason: 'seq must stay 11. ${s.why}');
    });

    testWidgets('a room snapshot replaces the knocks wholesale', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.room_replaces');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        ..._knockJson('kn-0001', 'Ann', 60000),
        'seq': 11,
      });
      await s.push('room', _roomJson(seq: 12));
      expect(
        s.knocks,
        isEmpty,
        reason: 'room with knocks [] must clear them. ${s.why}',
      );
      await s.push(
        'room',
        _roomJson(
          seq: 13,
          knocks: <Map<String, Object?>>[_knockJson('kn-0007', 'Eve', 30000)],
        ),
      );
      expect(s.knocks, <(String, String, int)>[
        ('kn-0007', 'Eve', 30000),
      ], reason: 'room knocks must be shown as sent. ${s.why}');
    });

    testWidgets('a knock with no knock_id is ignored without throwing', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'seq.knock_malformed');
      await s.seat(host: true, seq: 10);
      await s.push('knock', <String, Object?>{
        'name': 'Ann',
        'expires_ms': 60000,
        'seq': 11,
      });
      await s.push('knock', <String, Object?>{
        'knock_id': 7,
        'name': 'Ann',
        'expires_ms': 'x',
        'seq': 12,
      });
      expect(
        s.knocks,
        isEmpty,
        reason: 'a malformed knock must not be added. ${s.why}',
      );
      expect(
        s.controller.phase,
        RoomPhase.connected,
        reason: 'the connection must survive. ${s.why}',
      );
    });
  });

  group('seq: frames that carry none', () {
    testWidgets('knock_pending and knock_failed never start a resume', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'noseq.pending_failed_seated');
      await s.seat(host: false, seq: 10);
      await s.push('knock_pending', <String, Object?>{
        'knock_id': 'kn-0001',
        'expires_ms': 60000,
      });
      await s.push('knock_failed', <String, Object?>{
        'knock_id': 'kn-0001',
        'outcome': 'rejected',
      });
      s.expectNoResume(
        'after knock_pending and knock_failed, which carry no seq',
      );
      expect(
        s.controller.room!.seq,
        10,
        reason: 'those frames must not move seq. ${s.why}',
      );
    });

    testWidgets('kicked never starts a resume and does not move seq', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'noseq.kicked');
      await s.seat(host: false, seq: 10);
      await s.push('kicked', <String, Object?>{});
      s.expectNoResume('after kicked');
    });

    testWidgets('a room frame after knock_pending still obeys seq', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'noseq.room_after_pending');
      await s.seat(host: false, seq: 10);
      await s.push('knock_pending', <String, Object?>{
        'knock_id': 'kn-0001',
        'expires_ms': 60000,
      });
      await s.push('room', _roomJson(seq: 11));
      expect(
        s.controller.room!.seq,
        11,
        reason: 'next seq must apply. ${s.why}',
      );
      s.expectNoResume('when the next room frame is seq + 1');
    });
  });

  group('knocker', () {
    Future<_Scn> knocking(
      WidgetTester tester,
      String id, {
      int expiresMs = 60000,
    }) async {
      final _Scn s = _Scn.open(tester, id);
      unawaited(s.controller.joinRoom(code: _code, name: 'Bob'));
      await s.settle();
      expect(
        s.controller.knockState.phase,
        KnockPhase.none,
        reason: 'fixture: no knock state before knock_pending. ${s.why}',
      );
      final int before = DateTime.now().millisecondsSinceEpoch;
      await s.push('knock_pending', <String, Object?>{
        'knock_id': 'kn-0001',
        'expires_ms': expiresMs,
      }, re: _idOf(s.transport.sentRaw.last));
      final int after = DateTime.now().millisecondsSinceEpoch;
      final KnockState k = s.controller.knockState;
      expect(k.phase, KnockPhase.pending, reason: 'expected pending. ${s.why}');
      expect(
        k.knockId,
        'kn-0001',
        reason: 'expected knockId kn-0001. ${s.why}',
      );
      expect(
        k.expiresAtMs,
        inInclusiveRange(before + expiresMs, after + expiresMs),
        reason:
            'expected expiresAtMs = device clock at knock_pending + '
            '$expiresMs, between ${before + expiresMs} and '
            '${after + expiresMs}; saw ${k.expiresAtMs}. ${s.why}',
      );
      return s;
    }

    testWidgets(
      'knock_pending: pending with an id and a deadline on the device clock',
      (tester) async {
        await knocking(tester, 'knocker.pending');
      },
    );

    testWidgets('knock_pending takes its deadline from expires_ms', (
      tester,
    ) async {
      await knocking(tester, 'knocker.pending_45s', expiresMs: 45000);
    });

    testWidgets('knock_failed outcomes map to the knock phases', (
      tester,
    ) async {
      final Map<String, KnockPhase> wanted = <String, KnockPhase>{
        'rejected': KnockPhase.rejected,
        'timeout': KnockPhase.timedOut,
        'full': KnockPhase.full,
        'withdrawn': KnockPhase.withdrawn,
        'switched_off': KnockPhase.switchedOff,
      };
      for (final MapEntry<String, KnockPhase> e in wanted.entries) {
        final _Scn s = await knocking(tester, 'knocker.failed.${e.key}');
        await s.push('knock_failed', <String, Object?>{
          'knock_id': 'kn-0001',
          'outcome': e.key,
        });
        expect(
          s.controller.knockState.phase,
          e.value,
          reason:
              'expected ${e.value} for outcome ${e.key}; saw ${s.controller.knockState.phase}. ${s.why}',
        );
        expect(
          s.controller.seat,
          isNull,
          reason: 'a failed knock holds no seat. ${s.why}',
        );
        expect(
          s.controller.seatToken,
          isNull,
          reason: 'a failed knock holds no token. ${s.why}',
        );
        expect(
          s.controller.room,
          isNull,
          reason: 'a failed knock holds no room. ${s.why}',
        );
      }
    });

    testWidgets(
      'knock_failed with an unknown outcome or no outcome leaves pending',
      (tester) async {
        final _Scn s = await knocking(tester, 'knocker.failed_malformed');
        await s.push('knock_failed', <String, Object?>{
          'knock_id': 'kn-0001',
          'outcome': 'exploded',
        });
        await s.push('knock_failed', <String, Object?>{'knock_id': 'kn-0001'});
        await s.push('knock_failed', <String, Object?>{'outcome': 42});
        expect(
          s.controller.knockState.phase,
          KnockPhase.pending,
          reason:
              'a malformed knock_failed must not change the phase. ${s.why}',
        );
      },
    );

    testWidgets('an accepted knock is a seat: seat_assigned then room', (
      tester,
    ) async {
      final _Scn s = await knocking(tester, 'knocker.accepted');
      await s.push('seat_assigned', <String, Object?>{
        'seat': 2,
        'seat_token': 'tok-acc-2',
      });
      await s.push('room', <String, Object?>{
        ..._roomJson(seq: 20, seats: 3, approval: true),
        'seats': <Map<String, Object?>>[
          for (int i = 0; i < 3; i += 1)
            <String, Object?>{
              'seat': i,
              'name': 'P$i',
              'connected': true,
              'tokens': const <int>[-1, -1, -1, -1],
              'client_seed': null,
              'seed_origin': null,
              'via': <String>['host', 'link', 'approved'][i],
            },
        ],
      });
      expect(s.controller.seat, 2, reason: 'expected seat 2. ${s.why}');
      expect(
        s.controller.seatToken,
        'tok-acc-2',
        reason: 'expected the new token. ${s.why}',
      );
      expect(
        s.controller.room?.seats[2].via,
        SeatVia.approved,
        reason: 'expected via approved. ${s.why}',
      );
      expect(
        s.controller.knockState.phase,
        KnockPhase.accepted,
        reason: 'expected knock phase accepted once seated. ${s.why}',
      );
    });

    testWidgets('a knock that was never made leaves the state at none', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'knocker.none');
      await s.seat(host: false);
      final KnockState k = s.controller.knockState;
      expect(k.phase, KnockPhase.none, reason: 'expected none. ${s.why}');
      expect(
        k.knockId == null || k.knockId!.isEmpty,
        isTrue,
        reason: 'expected no knock id; saw ${k.knockId}. ${s.why}',
      );
    });
  });

  group('host controls', () {
    testWidgets(
      'answerKnock accept sends answer_knock {knock_id, accept: true}',
      (tester) async {
        final _Scn s = _Scn.open(tester, 'host.accept');
        await s.seat(host: true);
        unawaited(s.controller.answerKnock('kn-0001', accept: true));
        await s.settle();
        expect(
          s.sentOf('answer_knock'),
          hasLength(1),
          reason: 'expected one answer_knock. ${s.why}',
        );
        expect(_decode(s.sentOf('answer_knock').single)['d'], <String, Object?>{
          'knock_id': 'kn-0001',
          'accept': true,
        }, reason: 'expected exactly {knock_id, accept: true}. ${s.why}');
      },
    );

    testWidgets('answerKnock reject sends accept: false', (tester) async {
      final _Scn s = _Scn.open(tester, 'host.reject');
      await s.seat(host: true);
      unawaited(s.controller.answerKnock('kn-0002', accept: false));
      await s.settle();
      expect(_decode(s.sentOf('answer_knock').single)['d'], <String, Object?>{
        'knock_id': 'kn-0002',
        'accept': false,
      }, reason: 'expected exactly {knock_id, accept: false}. ${s.why}');
    });

    testWidgets('answerKnock refused with NO_SUCH_KNOCK lands on errorCode', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'host.no_such_knock');
      await s.seat(host: true);
      final Future<void> answered = s.controller.answerKnock(
        'kn-gone',
        accept: true,
      );
      await s.settle();
      await s.push('error', <String, Object?>{
        'code': 'NO_SUCH_KNOCK',
        'message': 'closed',
      }, re: _idOf(s.sentOf('answer_knock').single));
      await answered;
      expect(
        s.controller.errorCode,
        'NO_SUCH_KNOCK',
        reason: 'expected errorCode NO_SUCH_KNOCK. ${s.why}',
      );
      expect(
        s.controller.room,
        isNotNull,
        reason: 'the held room must survive a refused answer. ${s.why}',
      );
    });

    testWidgets(
      'answerKnock with nothing connected sends nothing and does not throw',
      (tester) async {
        final _Scn s = _Scn.open(tester, 'host.answer_idle');
        await s.controller.answerKnock('kn-0001', accept: true);
        await s.controller.setGuestApproval(true);
        await s.settle();
        expect(
          s.transport.sentRaw,
          isEmpty,
          reason: 'idle controller must send nothing. ${s.why}',
        );
        expect(
          s.connector.calls,
          isEmpty,
          reason: 'idle controller must open nothing. ${s.why}',
        );
      },
    );

    testWidgets('setGuestApproval sends set_guest_approval {enabled}', (
      tester,
    ) async {
      for (final bool on in <bool>[true, false]) {
        final _Scn s = _Scn.open(tester, 'host.approval.$on');
        await s.seat(host: true);
        unawaited(s.controller.setGuestApproval(on));
        await s.settle();
        expect(
          s.sentOf('set_guest_approval'),
          hasLength(1),
          reason: 'expected one frame. ${s.why}',
        );
        expect(
          _decode(s.sentOf('set_guest_approval').single)['d'],
          <String, Object?>{'enabled': on},
          reason: 'expected exactly {enabled: $on}. ${s.why}',
        );
      }
    });

    testWidgets('the room reply to set_guest_approval updates guestApproval', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'host.approval_reply');
      await s.seat(host: true);
      expect(
        s.controller.room!.guestApproval,
        isTrue,
        reason: 'fixture: approval on. ${s.why}',
      );
      final Future<void> done = s.controller.setGuestApproval(false);
      await s.settle();
      await s.push(
        'room',
        _roomJson(seq: 11, approval: false),
        re: _idOf(s.sentOf('set_guest_approval').single),
      );
      await done;
      expect(
        s.controller.room!.guestApproval,
        isFalse,
        reason: 'expected approval off after the reply. ${s.why}',
      );
      expect(s.controller.room!.seq, 11, reason: 'expected seq 11. ${s.why}');
    });

    testWidgets('kick in LOBBY sends kick {seat} and returns null on success', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'host.lobby_kick');
      await s.seat(host: true);
      final Future<String?> result = s.controller.kick(1);
      await s.settle();
      expect(
        s.sentOf('kick'),
        hasLength(1),
        reason: 'expected one kick. ${s.why}',
      );
      expect(_decode(s.sentOf('kick').single)['d'], <String, Object?>{
        'seat': 1,
      }, reason: 'expected exactly {seat: 1}. ${s.why}');
      await s.push('player_left', <String, Object?>{
        'seat': 1,
        'seq': 11,
      }, re: _idOf(s.sentOf('kick').single));
      expect(
        await result,
        isNull,
        reason: 'a kick the server accepted returns null. ${s.why}',
      );
    });

    testWidgets('a refused lobby kick returns the server code', (tester) async {
      for (final String code in <String>[
        'ILLEGAL_MOVE',
        'NOT_HOST',
        'BAD_FIELD',
      ]) {
        final _Scn s = _Scn.open(tester, 'host.lobby_kick_refused.$code');
        await s.seat(host: true);
        final Future<String?> result = s.controller.kick(0);
        await s.settle();
        await s.push('error', <String, Object?>{
          'code': code,
          'message': 'no',
        }, re: _idOf(s.sentOf('kick').single));
        expect(
          await result,
          code,
          reason: 'expected the code $code back. ${s.why}',
        );
        expect(
          s.controller.phase,
          RoomPhase.connected,
          reason: 'a refused kick keeps the connection. ${s.why}',
        );
      }
    });
  });

  group('kicked', () {
    testWidgets('kicked clears the seat and the token and sets wasKicked', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'kicked.clears');
      await s.seat(host: false);
      expect(s.controller.seat, 1, reason: 'fixture: seat 1. ${s.why}');
      expect(
        s.controller.seatToken,
        _token,
        reason: 'fixture: token. ${s.why}',
      );
      expect(
        s.controller.wasKicked,
        isFalse,
        reason: 'fixture: not kicked yet. ${s.why}',
      );
      await s.push('kicked', <String, Object?>{});
      expect(
        s.controller.seat,
        isNull,
        reason: 'expected the seat cleared. ${s.why}',
      );
      expect(
        s.controller.seatToken,
        isNull,
        reason: 'expected the token cleared. ${s.why}',
      );
      expect(
        s.controller.wasKicked,
        isTrue,
        reason: 'expected wasKicked. ${s.why}',
      );
    });

    testWidgets('kicked notifies listeners once it is applied', (tester) async {
      final _Scn s = _Scn.open(tester, 'kicked.notifies');
      await s.seat(host: false);
      final List<bool> seen = <bool>[];
      s.controller.addListener(() => seen.add(s.controller.wasKicked));
      await s.push('kicked', <String, Object?>{});
      expect(
        seen,
        contains(true),
        reason: 'a listener must see wasKicked true. saw $seen. ${s.why}',
      );
    });

    testWidgets('kicked is not a takeover and not an error', (tester) async {
      final _Scn s = _Scn.open(tester, 'kicked.not_takeover');
      await s.seat(host: false);
      await s.push('kicked', <String, Object?>{});
      expect(
        s.controller.seatTakenOver,
        isFalse,
        reason: 'kicked is not seatTakenOver. ${s.why}',
      );
      expect(
        s.controller.hasDesynced,
        isFalse,
        reason: 'kicked is not a desync. ${s.why}',
      );
    });

    testWidgets('no resume follows kicked, even through the close that follows', (
      tester,
    ) async {
      final _Scn s = _Scn.open(
        tester,
        'kicked.no_resume',
        delays: const <Duration>[Duration(seconds: 1), Duration(seconds: 2)],
      );
      final FakeTransport spare = FakeTransport();
      s.connector.enqueue(spare);
      await s.seat(host: false);
      await s.push('kicked', <String, Object?>{});
      s.transport.endFromFarSide();
      await s.settle();
      await tester.pump(const Duration(seconds: 10));
      await s.settle();
      s.expectNoResume('after kicked and the socket closing');
      expect(
        s.connector.calls,
        hasLength(1),
        reason:
            'no reconnect may be opened for a kicked seat; calls ${s.connector.calls.length}. ${s.why}',
      );
      expect(
        spare.sentRaw,
        isEmpty,
        reason: 'nothing may be sent on a second socket. ${s.why}',
      );
      expect(
        s.controller.autoReconnectPending,
        isFalse,
        reason: 'no reconnect timer for a kicked seat. ${s.why}',
      );
      expect(
        s.controller.seatToken,
        isNull,
        reason: 'the token must stay cleared. ${s.why}',
      );
    });

    testWidgets('reconnect() after kicked opens nothing', (tester) async {
      final _Scn s = _Scn.open(tester, 'kicked.reconnect');
      await s.seat(host: false);
      await s.push('kicked', <String, Object?>{});
      s.transport.endFromFarSide();
      await s.settle();
      await s.controller.reconnect();
      await s.settle();
      expect(
        s.connector.calls,
        hasLength(1),
        reason: 'reconnect() must not open a socket. ${s.why}',
      );
    });

    testWidgets('kicked twice is the same as once', (tester) async {
      final _Scn s = _Scn.open(tester, 'kicked.twice');
      await s.seat(host: false);
      await s.push('kicked', <String, Object?>{});
      await s.push('kicked', <String, Object?>{});
      expect(s.controller.wasKicked, isTrue, reason: 'still kicked. ${s.why}');
      expect(s.controller.seat, isNull, reason: 'still no seat. ${s.why}');
    });

    testWidgets('kicked with no room held (a knocker) does not throw', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'kicked.no_room');
      unawaited(s.controller.joinRoom(code: _code, name: 'Bob'));
      await s.settle();
      await s.push('kicked', <String, Object?>{});
      expect(s.controller.seat, isNull, reason: 'no seat. ${s.why}');
      expect(s.controller.seatToken, isNull, reason: 'no token. ${s.why}');
    });

    testWidgets('session memory offers no resume for a kicked seat', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'kicked.session_memory');
      await s.seat(host: false);
      // The record a seated phone keeps (what the home screen stores for a
      // seat it holds).
      await tester.runAsync(
        () => SessionMemory.recordSeat(
          const SeatRecord(code: _code, seat: 1, seatToken: _token),
        ),
      );
      final SessionMemory before = (await tester.runAsync(SessionMemory.load))!;
      expect(
        before.seatRecord,
        isNotNull,
        reason: 'fixture: the record is stored. ${s.why}',
      );
      await s.push('kicked', <String, Object?>{});
      await s.settle();
      final SessionMemory after = (await tester.runAsync(SessionMemory.load))!;
      expect(
        after.seatRecord,
        isNull,
        reason:
            'expected no seat record to resume after kicked; saw ${after.seatRecord?.code}. ${s.why}',
      );
    });

    testWidgets('wasKicked is cleared by the next join', (tester) async {
      final _Scn s = _Scn.open(tester, 'kicked.cleared_by_join');
      await s.seat(host: false);
      await s.push('kicked', <String, Object?>{});
      s.transport.endFromFarSide();
      await s.settle();
      expect(
        s.controller.wasKicked,
        isTrue,
        reason: 'fixture: kicked. ${s.why}',
      );
      final FakeTransport next = FakeTransport();
      s.connector.enqueue(next);
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      await s.settle();
      expect(
        s.connector.calls,
        hasLength(2),
        reason: 'expected the join to open a new connection. ${s.why}',
      );
      next.pushText(
        _frame(
          type: 'error',
          re: _idOf(next.sentRaw.last),
          data: <String, Object?>{'code': 'KICKED', 'message': 'barred'},
        ),
      );
      await s.settle();
      expect(
        s.controller.errorCode,
        'KICKED',
        reason: 'a barred rejoin answers KICKED. ${s.why}',
      );
      expect(
        s.controller.wasKicked,
        isFalse,
        reason:
            'wasKicked is cleared by the next join, whatever it answers. ${s.why}',
      );
    });
  });
}
