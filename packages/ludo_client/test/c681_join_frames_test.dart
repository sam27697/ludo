// C-681t: what the client sends to join a room and how it reads the section 31
// snapshot additions (order 681, docs/PROTOCOL.md section 31 items 1 to 3).
//
// Written from the order and the spec alone. Names that do not exist until
// order 681's lib lands (`RoomController.joinByLink`, `RoomSnapshot.linkId`,
// `guestApproval`, `knocks`, `SeatState.via`, `SeatVia`, `KnockPhase`,
// `knockState`) are unresolved on a tree without it: this file does not
// compile there, by design.
//
// A real RoomController over FakeTransport (test/net/fake_transport.dart).
// What is pinned:
//   - `joinByLink` sends `join_room` {name, link}; `joinRoom` sends
//     {name, code}; both also send `install`; `code` and `link` are never
//     both present (the server answers BAD_FIELD to both)
//   - `install` is the stored install id, the same on every join, and is
//     made and stored when there is none yet
//   - the snapshot reads `link_id`, `guest_approval`, `knocks`, seat `via`,
//     and reads their absence (an old server) as empty/false/unknown
//   - a join answered by `knock_pending` leaves the caller out of the room
//   - error codes of a refused join land on errorCode
//
// Replay: flutter test test/c681_join_frames_test.dart --plain-name '<id>'
// Nothing is random; every reason carries the scenario id and the frames sent.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c681-join-frames.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _installA = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';
final RegExp _installShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c681-jf-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seat(int seat, String name, {String? via}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
      'via': ?via,
    };

Map<String, Object?> _roomJson({
  int seq = 1,
  Object? linkId = _linkId,
  Object? guestApproval = false,
  Object? knocks = const <Object?>[],
  List<Map<String, Object?>>? seats,
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
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seat(0, 'Sam', via: 'host'),
        _seat(1, 'Bob', via: 'link'),
      ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': ?linkId,
  'guest_approval': ?guestApproval,
  'knocks': ?knocks,
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

  static _Scn open(WidgetTester tester, String id) {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    addTearDown(controller.dispose);
    return _Scn(id, tester, controller, transport, connector);
  }

  String get why =>
      '$id: sent so far: ${transport.sentRaw}. reproduce: flutter test '
      "test/c681_join_frames_test.dart --plain-name '$id'";

  Future<void> settle() async {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  Map<String, Object?> sent(String type) {
    final List<String> hits = transport.sentRaw
        .where((String raw) => _typeOf(raw) == type)
        .toList();
    expect(
      hits,
      hasLength(1),
      reason: 'expected exactly one `$type` frame sent. $why',
    );
    return _decode(hits.single);
  }

  Map<String, Object?> sentData(String type) =>
      sent(type)['d']! as Map<String, Object?>;

  void answerSeated(int seat, Map<String, Object?> room) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': seat, 'seat_token': 'tok-c681-$seat'},
      ),
    );
    transport.pushText(
      _frame(type: 'room', re: _idOf(transport.sentRaw.last), data: room),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': _installA,
    });
  });

  group('join frames', () {
    testWidgets('joinRoom by code sends name, code and install, no link', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'jf.code');
      unawaited(s.controller.joinRoom(code: _code, name: 'Bob'));
      await s.settle();
      final Map<String, Object?> d = s.sentData('join_room');
      expect(d['code'], _code, reason: 'expected code $_code in d. ${s.why}');
      expect(d['name'], 'Bob', reason: 'expected name Bob in d. ${s.why}');
      expect(
        d['install'],
        _installA,
        reason: 'expected the stored install id in d. ${s.why}',
      );
      expect(
        d.containsKey('link'),
        isFalse,
        reason: 'a typed-code join must not carry a link key. ${s.why}',
      );
    });

    testWidgets('joinByLink sends name, link and install, no code', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'jf.link');
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      await s.settle();
      final Map<String, Object?> d = s.sentData('join_room');
      expect(d['link'], _linkId, reason: 'expected link $_linkId. ${s.why}');
      expect(d['name'], 'Bob', reason: 'expected name Bob. ${s.why}');
      expect(
        d['install'],
        _installA,
        reason: 'expected the stored install id. ${s.why}',
      );
      expect(
        d.containsKey('code'),
        isFalse,
        reason: 'a link join must not carry a code key. ${s.why}',
      );
    });

    testWidgets('no join_room frame ever carries both link and code', (
      tester,
    ) async {
      for (final bool byLink in <bool>[true, false]) {
        final _Scn s = _Scn.open(tester, 'jf.never_both.$byLink');
        unawaited(
          byLink
              ? s.controller.joinByLink(link: _linkId, name: 'Bob')
              : s.controller.joinRoom(code: _code, name: 'Bob'),
        );
        await s.settle();
        final Map<String, Object?> d = s.sentData('join_room');
        expect(
          d.containsKey('link') && d.containsKey('code'),
          isFalse,
          reason:
              'both keys on one join_room (BAD_FIELD on the server): $d. ${s.why}',
        );
        expect(
          d.containsKey('link') || d.containsKey('code'),
          isTrue,
          reason: 'neither key on a join_room (BAD_FIELD): $d. ${s.why}',
        );
      }
    });

    testWidgets('the install on the wire has the section 31 shape', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _Scn s = _Scn.open(tester, 'jf.install_made');
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      await s.settle();
      final Object? install = s.sentData('join_room')['install'];
      expect(
        install is String && _installShape.hasMatch(install),
        isTrue,
        reason:
            'expected install of 16..64 chars [A-Za-z0-9_-] made on first '
            'use; saw $install. ${s.why}',
      );
      final SharedPreferences prefs = await tester.runAsync(
        SharedPreferences.getInstance,
      ) as SharedPreferences;
      expect(
        prefs.getString('install_id'),
        install,
        reason: 'the install sent must be the one stored. ${s.why}',
      );
    });

    testWidgets('the same install rides on every join, link or code', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final List<Object?> seen = <Object?>[];
      for (final bool byLink in <bool>[true, false, true]) {
        final _Scn s = _Scn.open(
          tester,
          'jf.install_stable.$byLink.${seen.length}',
        );
        unawaited(
          byLink
              ? s.controller.joinByLink(link: _linkId, name: 'Bob')
              : s.controller.joinRoom(code: _code, name: 'Bob'),
        );
        await s.settle();
        seen.add(s.sentData('join_room')['install']);
      }
      expect(
        seen.toSet().length,
        1,
        reason:
            'expected one install id across three joins; saw $seen. '
            'reproduce: flutter test test/c681_join_frames_test.dart '
            "--plain-name 'the same install rides on every join'",
      );
    });

    testWidgets('a join made while one is in flight sends one frame only', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'jf.double_join');
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      unawaited(s.controller.joinByLink(link: _linkId, name: 'Bob'));
      unawaited(s.controller.joinRoom(code: _code, name: 'Bob'));
      await s.settle();
      final int joins = s.transport.sentRaw
          .where((String raw) => _typeOf(raw) == 'join_room')
          .length;
      expect(
        joins,
        1,
        reason:
            'expected 1 join_room for 3 calls while connecting; saw $joins. ${s.why}',
      );
      expect(
        s.connector.calls,
        hasLength(1),
        reason:
            'expected 1 connection; saw ${s.connector.calls.length}. ${s.why}',
      );
    });
  });

  group('join results', () {
    testWidgets('a link join answered by seat_assigned and room is seated', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'jr.link_seated');
      final Future<void> joined = s.controller.joinByLink(
        link: _linkId,
        name: 'Bob',
      );
      await s.settle();
      s.answerSeated(1, _roomJson());
      await joined;
      expect(
        s.controller.phase,
        RoomPhase.connected,
        reason: 'expected connected. ${s.why}',
      );
      expect(s.controller.seat, 1, reason: 'expected seat 1. ${s.why}');
      expect(
        s.controller.seatToken,
        'tok-c681-1',
        reason: 'expected the token. ${s.why}',
      );
      expect(
        s.controller.room?.linkId,
        _linkId,
        reason: 'expected linkId. ${s.why}',
      );
      expect(
        s.controller.room?.code,
        _code,
        reason: 'expected the code too. ${s.why}',
      );
      expect(
        s.controller.room?.seats[1].via,
        SeatVia.link,
        reason: 'expected seat 1 via link. ${s.why}',
      );
      expect(
        s.controller.knockState.phase,
        KnockPhase.none,
        reason: 'a seated join is not a knock. ${s.why}',
      );
    });

    testWidgets('a code join answered by knock_pending holds no seat', (
      tester,
    ) async {
      final _Scn s = _Scn.open(tester, 'jr.code_knock');
      unawaited(s.controller.joinRoom(code: _code, name: 'Bob'));
      await s.settle();
      s.transport.pushText(
        _frame(
          type: 'knock_pending',
          re: _idOf(s.transport.sentRaw.last),
          data: <String, Object?>{
            'knock_id': 'kn-c681-0001',
            'expires_ms': 60000,
          },
        ),
      );
      await s.settle();
      expect(
        s.controller.knockState.phase,
        KnockPhase.pending,
        reason: 'expected pending. ${s.why}',
      );
      expect(
        s.controller.knockState.knockId,
        'kn-c681-0001',
        reason: 'expected the knock id. ${s.why}',
      );
      expect(
        s.controller.seat,
        isNull,
        reason: 'a pending knock holds no seat. ${s.why}',
      );
      expect(
        s.controller.seatToken,
        isNull,
        reason: 'a pending knock holds no token. ${s.why}',
      );
      expect(
        s.controller.room,
        isNull,
        reason: 'a pending knock holds no room. ${s.why}',
      );
    });

    testWidgets('a refused join puts the server code on errorCode', (
      tester,
    ) async {
      for (final String code in <String>[
        'NO_SUCH_ROOM',
        'KICKED',
        'KNOCK_REFUSED',
        'TOO_MANY_KNOCKS',
        'NO_SUCH_KNOCK',
      ]) {
        for (final bool byLink in <bool>[true, false]) {
          final _Scn s = _Scn.open(tester, 'jr.refused.$code.$byLink');
          unawaited(
            byLink
                ? s.controller.joinByLink(link: _linkId, name: 'Bob')
                : s.controller.joinRoom(code: _code, name: 'Bob'),
          );
          await s.settle();
          s.transport.pushText(
            _frame(
              type: 'error',
              re: _idOf(s.transport.sentRaw.last),
              data: <String, Object?>{'code': code, 'message': 'refused'},
            ),
          );
          await s.settle();
          expect(
            s.controller.errorCode,
            code,
            reason: 'expected errorCode $code. ${s.why}',
          );
          expect(
            s.controller.seat,
            isNull,
            reason: 'a refused join holds no seat. ${s.why}',
          );
          expect(
            s.controller.room,
            isNull,
            reason: 'a refused join holds no room. ${s.why}',
          );
          expect(
            s.controller.knockState.phase,
            isNot(KnockPhase.pending),
            reason: 'a refused join is not a pending knock. ${s.why}',
          );
        }
      }
    });
  });

  group('snapshot additions', () {
    test('link_id, guest_approval, knocks and via are read', () {
      final RoomSnapshot room = RoomSnapshot.fromJson(
        _roomJson(
          guestApproval: true,
          knocks: <Object?>[
            <String, Object?>{
              'knock_id': 'kn-1',
              'name': 'Ann',
              'expires_ms': 59000,
            },
            <String, Object?>{
              'knock_id': 'kn-2',
              'name': 'Zed',
              'expires_ms': 1,
            },
          ],
          seats: <Map<String, Object?>>[
            _seat(0, 'Sam', via: 'host'),
            _seat(1, 'Bob', via: 'link'),
            _seat(2, 'Cy', via: 'code'),
            _seat(3, 'Dee', via: 'approved'),
          ],
        ),
      );
      expect(
        room.linkId,
        _linkId,
        reason: 'link id. code: ${jsonEncode(_roomJson())}',
      );
      expect(
        room.guestApproval,
        isTrue,
        reason: 'guest_approval true must be read',
      );
      expect(
        room.knocks.map((Knock k) => (k.id, k.name, k.expiresMs)).toList(),
        <(String, String, int)>[('kn-1', 'Ann', 59000), ('kn-2', 'Zed', 1)],
        reason: 'knocks must be read in order with id, name and expiresMs',
      );
      expect(room.seats.map((SeatState s) => s.via).toList(), <SeatVia>[
        SeatVia.host,
        SeatVia.link,
        SeatVia.code,
        SeatVia.approved,
      ], reason: 'via per seat');
    });

    test(
      'an old server (no link_id, guest_approval, knocks, via) reads empty',
      () {
        final RoomSnapshot room = RoomSnapshot.fromJson(
          _roomJson(
            linkId: null,
            guestApproval: null,
            knocks: null,
            seats: <Map<String, Object?>>[_seat(0, 'Sam'), _seat(1, 'Bob')],
          ),
        );
        expect(
          room.linkId,
          '',
          reason: 'linkId must be the empty string without link_id',
        );
        expect(
          room.guestApproval,
          isFalse,
          reason: 'guestApproval must default to false',
        );
        expect(room.knocks, isEmpty, reason: 'knocks must default to empty');
        expect(room.seats.map((SeatState s) => s.via).toList(), <SeatVia>[
          SeatVia.unknown,
          SeatVia.unknown,
        ], reason: 'a seat with no via is SeatVia.unknown');
      },
    );

    test('an unrecognised via is unknown, not an error', () {
      final RoomSnapshot room = RoomSnapshot.fromJson(
        _roomJson(
          seats: <Map<String, Object?>>[
            _seat(0, 'Sam', via: 'host'),
            _seat(1, 'Bob', via: 'teleport'),
            _seat(2, 'Cy', via: ''),
          ],
        ),
      );
      expect(room.seats.map((SeatState s) => s.via).toList(), <SeatVia>[
        SeatVia.host,
        SeatVia.unknown,
        SeatVia.unknown,
      ], reason: 'unrecognised via strings are SeatVia.unknown');
    });

    test('a non-host snapshot has empty knocks', () {
      final RoomSnapshot room = RoomSnapshot.fromJson(
        _roomJson(guestApproval: true),
      );
      expect(room.knocks, isEmpty, reason: 'knocks: [] reads as empty');
      expect(
        room.guestApproval,
        isTrue,
        reason: 'approval survives an empty knocks list',
      );
    });

    test(
      'a snapshot round trips linkId and guestApproval through copyWith',
      () {
        final RoomSnapshot room = RoomSnapshot.fromJson(
          _roomJson(guestApproval: true),
        );
        final RoomSnapshot next = room.copyWith(seq: room.seq + 1);
        expect(next.linkId, _linkId, reason: 'copyWith must keep linkId');
        expect(
          next.guestApproval,
          isTrue,
          reason: 'copyWith must keep guestApproval',
        );
        expect(next.knocks, isEmpty, reason: 'copyWith must keep knocks');
      },
    );
  });
}
