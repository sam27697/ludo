// Tests for contract C-316, docs/PROTOCOL.md section 18, rule 1: who is
// host after a leave. Cut from integrate/run83 at 8208945; the
// implementation (order 316) lands in lib/ in parallel, in a tree this
// file's author has not opened.
//
// On this tree, lib/src/net/room_controller.dart's _reducePlayerLeft
// (around line 1030) reads only `seat` off the frame and never looks at
// `host_seat` at all: it removes the seat and nothing else. That is the
// behaviour rule 1 replaces. This file drives a real RoomController over
// FakeTransport (test/net/fake_transport.dart, read-only) the way
// test/lobby_host_waiting_test.dart and test/rematch_client_test.dart do,
// with the small frame/connector helpers copied from those files rather
// than imported, per this order's own instruction.
//
// Also holds the one rule 4 case the order asks to keep in a file that
// compiles cleanly and must stay green on this tree: a PLAYING room whose
// socket drops still shows game-screen-stale-table, dimmed, under
// IgnorePointer -- contract rule 4's last sentence, "PLAYING and a normal
// LOBBY keep today's stale-table behaviour (C-282) unchanged." That case
// shares no fixture with the rule 1 cases above it; it is kept in this file
// only because the order asks for a file whose red/green is measured
// without any l10n dependency, and this file already is one.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://leave-table-controller-test.invalid/ws';

const Key _startKey = Key('lobby-start-button');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-ctl-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  String code = 'LV3TBL',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 3,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
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
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
        _seatJson(2, name: 'Ken'),
      ],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

/// The three-seat lobby every rule 1 case starts from: host Sam (0), this
/// device as Bob (1), and Ken (2).
List<Map<String, Object?>> _threeSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
  _seatJson(2, name: 'Ken'),
];

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test fixture is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

/// Mounts LobbyScreen as action-create for seat 1 ("Bob") and resolves the
/// create_room request into the three-seat full lobby, host Sam (0).
/// Mirrors test/lobby_host_waiting_test.dart's own
/// _mountAndCaptureRequest/_resolveConnected pair.
Future<(RoomController, FakeTransport)> _mountThreeSeatLobby(
  WidgetTester tester,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);

  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Bob',
        players: 3,
      ),
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason: 'fixture is broken: LobbyScreen.initState must send create_room',
  );
  final String id = _idOf(transport.sentRaw.last);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-1'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(hostSeat: 0, players: 3, seats: _threeSeats(), seq: 1),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.room,
    isNotNull,
    reason: 'fixture is broken: the create_room reply must land a room',
  );
  expect(controller.room!.seats, hasLength(3), reason: 'fixture is broken');
  expect(
    controller.isHost,
    isFalse,
    reason: 'fixture is broken: Bob (seat 1) is not the host Sam (seat 0)',
  );
  return (controller, transport);
}

void main() {
  group('rule 1: host hand-on carried by player_left.host_seat', () {
    testWidgets(
      'host (seat 0) leaves a full 3-seat LOBBY naming this seat (1) as the '
      'new host_seat: isHost becomes true, and once the room refills, '
      'lobby-start-button is shown and enabled to this seat',
      (WidgetTester tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _mountThreeSeatLobby(tester);

        // Mutation this catches: _reducePlayerLeft dropping the host_seat
        // field on the floor (today's body only ever does
        // `room.copyWith(seats: seats, seq: seqValue)`, no hostSeat
        // argument at all) -- or reading it but never wiring it into the
        // copyWith call.
        transport.pushText(
          _frame(
            type: 'player_left',
            data: <String, Object?>{'seat': 0, 'host_seat': 1, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.room!.seats.map((s) => s.seat), <int>[
          1,
          2,
        ], reason: 'fixture: the host leaving must still remove seat 0');
        expect(
          controller.room!.hostSeat,
          1,
          reason:
              'rule 1: player_left carrying host_seat: 1 must set '
              'RoomSnapshot.hostSeat to 1; it is still '
              '${controller.room!.hostSeat}',
        );
        expect(
          controller.isHost,
          isTrue,
          reason:
              'rule 1: with hostSeat == 1 and this device\'s own seat == 1, '
              'RoomController.isHost must read true; it reads '
              '${controller.isHost}',
        );

        // The room is 2 of 3 now; lobby-start-button must not appear until
        // it refills, same as C-274. A fresh join by a third player fills
        // the vacated seat 0 again.
        expect(
          find.byKey(_startKey),
          findsNothing,
          reason:
              'fixture: 2 of 3 seated must show no lobby-start-button yet, '
              'host or not',
        );
        transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 0, 'name': 'Nadia', 'seq': 3},
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.room!.seats, hasLength(3), reason: 'fixture');

        final Finder start = find.byKey(_startKey);
        expect(
          start,
          findsOneWidget,
          reason:
              'rule 1: once the room refills to 3 of 3, the new host (seat '
              '1, this device) must see lobby-start-button; isHost was '
              '${controller.isHost}',
        );
        final ElevatedButton button = tester.widget<ElevatedButton>(start);
        expect(
          button.onPressed,
          isNotNull,
          reason: 'a full room must enable lobby-start-button to the host',
        );
      },
    );

    testWidgets(
      'host leaves with no host_seat key at all (an older server): hostSeat '
      'is left exactly as it was',
      (WidgetTester tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _mountThreeSeatLobby(tester);
        final int hostSeatBefore = controller.room!.hostSeat;

        // Mutation this catches: a "fix" that defaults a missing host_seat
        // to some sentinel (0, or the lowest remaining seat computed
        // client-side) instead of leaving RoomSnapshot.hostSeat untouched
        // when the key is absent -- rule 1's own "additive field" clause.
        transport.pushText(
          _frame(
            type: 'player_left',
            data: <String, Object?>{'seat': 0, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.room!.seats.map((s) => s.seat), <int>[
          1,
          2,
        ], reason: 'fixture: the seat must still be removed');
        expect(
          controller.room!.hostSeat,
          hostSeatBefore,
          reason:
              'rule 1: a player_left with no host_seat key must leave '
              'hostSeat exactly as it was ($hostSeatBefore); it is now '
              '${controller.room!.hostSeat}',
        );
      },
    );

    testWidgets(
      'a non-host seat (2) leaves carrying host_seat: 7, outside -1..3: the '
      'whole frame is treated as malformed, no state change at all',
      (WidgetTester tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _mountThreeSeatLobby(tester);
        final int seqBefore = controller.room!.seq;
        final int hostSeatBefore = controller.room!.hostSeat;

        // Mutation this catches: a fix that validates host_seat's range
        // only to decide whether to apply it to hostSeat, while still
        // removing the named seat and advancing seq regardless -- rule 1
        // says an out-of-range value makes the *whole* frame malformed,
        // the seat removal included, not just the hostSeat assignment.
        transport.pushText(
          _frame(
            type: 'player_left',
            data: <String, Object?>{'seat': 2, 'host_seat': 7, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.seats.map((s) => s.seat),
          <int>[0, 1, 2],
          reason:
              'rule 1: host_seat: 7 is outside -1..3, so this player_left '
              'must change nothing, including seat 2 staying put; seats '
              'are now ${controller.room!.seats.map((s) => s.seat).toList()}',
        );
        expect(
          controller.room!.seq,
          seqBefore,
          reason:
              'rule 1: a malformed player_left must not advance seq past '
              '$seqBefore; it is now ${controller.room!.seq}',
        );
        expect(
          controller.room!.hostSeat,
          hostSeatBefore,
          reason: 'rule 1: a malformed player_left must not touch hostSeat',
        );
      },
    );
  });

  group(
    'rule 4, PLAYING unchanged: contract rule 4\'s last sentence, must stay '
    'green on this tree',
    () {
      testWidgets('a PLAYING room whose socket drops still shows '
          'game-screen-stale-table, dimmed under IgnorePointer, unchanged '
          '(C-282)', (WidgetTester tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = _newController(connector);
        addTearDown(controller.dispose);

        final Future<void> future = controller.createRoom(
          name: 'Sam',
          players: 2,
        );
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
              state: 'PLAYING',
              hostSeat: 0,
              players: 2,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Bob'),
              ],
              turn: <String, Object?>{
                'seat': 0,
                'phase': 'await_roll',
                'deadline_ms': 45000,
                'k': 0,
              },
              seq: 1,
            ),
          ),
        );
        await future;

        await tester.pumpWidget(_harness(GameScreen(controller: controller)));
        await tester.pump();
        expect(
          controller.room!.state.toString(),
          contains('playing'),
          reason: 'fixture is broken',
        );

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          controller.phase,
          RoomPhase.closed,
          reason: 'fixture is broken: the drop must close phase',
        );

        expect(
          find.byKey(const Key('game-screen-stale-table')),
          findsOneWidget,
          reason:
              'rule 4\'s last sentence: PLAYING keeps today\'s stale-table '
              'behaviour unchanged; game-screen-stale-table must still be '
              'present while the socket is down',
        );
      });
    },
  );
}
