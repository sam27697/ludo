// Old-client survival for docs/PROTOCOL.md section 37 item 3: `room_closed`
// is a type a client that predates it does not know, and must ignore with no
// effect on its state. This feeds the frame to the RoomController as it
// exists and asserts that phase, room, error and takeover state are
// unchanged, nothing is sent back, and the next ordinary push still applies.
//
// A real RoomController sits over FakeTransport (test/net/fake_transport.dart)
// behind a connector double, as test/c547_controller_test.dart does. No
// random input. Replay one case with:
//   flutter test test/c725_room_closed_ignored_test.dart --plain-name '<name>'

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _code = 'K7M2QP';
const String _token = 'tok-c725-001';

int _idSeq = 0;
String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c725-srv-id-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _roomJson({int seq = 1}) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    for (final int seat in <int>[0, 1])
      <String, Object?>{
        'seat': seat,
        'name': seat == 0 ? 'Sam' : 'Bob',
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

void main() {
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  testWidgets('a room_closed frame leaves phase, room, error and takeover '
      'state untouched and sends nothing', (WidgetTester tester) async {
    const String name = 'room_closed leaves state untouched, sends nothing';
    final FakeTransport transport = FakeTransport();
    final List<Uri> calls = <Uri>[];
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c725.invalid/ws'),
      connect: (Uri url) async {
        calls.add(url);
        return transport;
      },
      autoReconnectDelays: const <Duration>[],
    );
    addTearDown(controller.dispose);

    final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re:
            (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
                as String,
        data: _roomJson(),
      ),
    );
    await created;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: '$name: fixture: create reply must land connected',
    );

    final RoomSnapshot? roomBefore = controller.room;
    final RoomPhase phaseBefore = controller.phase;
    final String? errorBefore = controller.errorCode;
    final bool takenBefore = controller.seatTakenOver;
    final int sentBefore = transport.sentRaw.length;
    final int callsBefore = calls.length;
    expect(roomBefore, isNotNull, reason: '$name: fixture: a room is held');

    transport.pushText(
      _frame(
        type: 'room_closed',
        data: <String, Object?>{'reason': 'lobby_timeout'},
      ),
    );
    await tester.pump();
    await tester.pump();

    String seen() =>
        'phase=${controller.phase} errorCode='
        '${controller.errorCode} seatTakenOver=${controller.seatTakenOver} '
        'room.seq=${controller.room?.seq}';
    expect(
      controller.phase,
      phaseBefore,
      reason: '$name: phase must not change; saw ${seen()}',
    );
    expect(
      controller.errorCode,
      errorBefore,
      reason: '$name: errorCode must not change; saw ${seen()}',
    );
    expect(
      controller.seatTakenOver,
      takenBefore,
      reason: '$name: seatTakenOver must not change; saw ${seen()}',
    );
    expect(
      controller.room,
      same(roomBefore),
      reason:
          '$name: the held room snapshot must be the same object; '
          'saw ${seen()}',
    );
    expect(
      transport.sentRaw.length,
      sentBefore,
      reason:
          '$name: the client must send nothing in answer (no resync); '
          'sent ${transport.sentRaw.sublist(sentBefore)}',
    );
    expect(
      calls.length,
      callsBefore,
      reason: '$name: no reconnect may be opened',
    );
    expect(
      transport.isClosed,
      isFalse,
      reason: '$name: the client must not close the transport',
    );

    // Still working: the next ordinary push applies.
    transport.pushText(_frame(type: 'room', data: _roomJson(seq: 2)));
    await tester.pump();
    expect(
      controller.room?.seq,
      2,
      reason:
          '$name: a room push after room_closed must still apply; '
          'saw ${seen()}',
    );
  });
}
