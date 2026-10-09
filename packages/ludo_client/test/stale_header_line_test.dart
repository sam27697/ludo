// Proof of C-286 rule 1 and rule 2. GameScreen is driven the same way
// test/game_stale_table_test.dart drives it: a real RoomController over
// FakeTransport (test/net/fake_transport.dart, read-only here), one
// GameScreen mount per case. No pumpAndSettle (the countdown timer
// reschedules) and no bare pumpEventQueue() inside a testWidgets body.
//
// Own-turn cases are red on this tree: the stale header is still the live
// line ("Your turn. Roll the die." / "Your turn. Choose a token to move." /
// "دورك. ارمِ النرد."), so the exact short line is absent and the
// instruction is still on screen. The other-seat case and the reconnect
// case are green here: another seat's waiting line is unchanged, and a
// resumed awaitRoll shows the live line with the stale table gone.
//
// awaitMove is the room snapshot after a roll that left legal moves
// (phase await_move, a value, a non-empty legal list), the same shape
// test/game_stale_table_test.dart mounts. The header is read off that
// snapshot.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const List<Duration> _oneDelay = <Duration>[Duration(seconds: 1)];

const Key _staleTableKey = Key('game-screen-stale-table');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'stale-header-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) {
    _queue.add(transport);
  }

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued',
      );
    }
    return _queue.removeAt(0);
  }
}

Future<(RoomController, FakeTransport, _Connector)> _connectPlaying(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
  List<Duration> autoReconnectDelays = const <Duration>[],
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
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
      data: _roomJson(seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport, connector);
}

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
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

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

List<Map<String, Object?>> _twoSeats({
  List<int>? seat0Tokens,
}) => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: seat0Tokens ?? const <int>[-1, -1, -1, -1]),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _awaitRollTurn({int seat = 0}) =>
    _turnJson(seat: seat, phase: 'await_roll', deadlineMs: 45000, k: 0);

Map<String, Object?> _awaitMoveTurn() => _turnJson(
  seat: 0,
  phase: 'await_move',
  deadlineMs: 45000,
  k: 1,
  value: 4,
  legal: const <int>[1, 3],
);

Future<void> _drop(WidgetTester tester, FakeTransport transport) async {
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
}

void main() {
  final List<Map<String, Object?>> rollSeats = _twoSeats();
  final List<Map<String, Object?>> moveSeats = _twoSeats(
    seat0Tokens: const <int>[3, 10, 20, 30],
  );

  testWidgets(
    'own turn, awaitRoll, socket dropped: the stale table reads exactly '
    '"Your turn" and the screen has nothing containing "Roll the die"',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        seats: rollSeats,
        turn: _awaitRollTurn(),
        autoReconnectDelays: _oneDelay,
      );
      try {
        await _mount(tester, controller);
        await _drop(tester, transport);

        expect(controller.phase, RoomPhase.closed);
        expect(controller.room, isNotNull);
        final Finder stale = find.byKey(_staleTableKey);
        expect(
          stale,
          findsOneWidget,
          reason:
              'fixture: a dropped socket with a room in hand keeps '
              'game-screen-stale-table',
        );
        expect(
          find.descendant(of: stale, matching: find.text('Your turn')),
          findsOneWidget,
          reason:
              'own turn, awaitRoll, socket dropped: the header inside '
              'game-screen-stale-table must be exactly "Your turn"',
        );
        expect(
          find.textContaining('Roll the die'),
          findsNothing,
          reason:
              'own turn, awaitRoll, socket dropped: nothing on the screen '
              'may contain "Roll the die"',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets(
    'own turn, awaitMove after a roll with legal moves, socket dropped: '
    'the stale table reads exactly "Your turn" and the screen has nothing '
    'containing "Choose a token"',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        seats: moveSeats,
        turn: _awaitMoveTurn(),
        autoReconnectDelays: _oneDelay,
      );
      try {
        await _mount(tester, controller);
        await _drop(tester, transport);

        expect(controller.phase, RoomPhase.closed);
        expect(controller.room, isNotNull);
        final Finder stale = find.byKey(_staleTableKey);
        expect(
          stale,
          findsOneWidget,
          reason:
              'fixture: a dropped socket with a room in hand keeps '
              'game-screen-stale-table',
        );
        expect(
          find.descendant(of: stale, matching: find.text('Your turn')),
          findsOneWidget,
          reason:
              'own turn, awaitMove, socket dropped: the header inside '
              'game-screen-stale-table must be exactly "Your turn"',
        );
        expect(
          find.textContaining('Choose a token'),
          findsNothing,
          reason:
              'own turn, awaitMove, socket dropped: nothing on the screen '
              'may contain "Choose a token"',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('ar: own turn, awaitRoll, socket dropped: the stale table reads '
      'exactly "دورك" and the screen has nothing containing "ارمِ النرد"', (
    tester,
  ) async {
    final (controller, transport, _) = await _connectPlaying(
      tester,
      seats: rollSeats,
      turn: _awaitRollTurn(),
      autoReconnectDelays: _oneDelay,
    );
    try {
      await _mount(tester, controller, locale: const Locale('ar'));
      await _drop(tester, transport);

      expect(controller.phase, RoomPhase.closed);
      expect(controller.room, isNotNull);
      final Finder stale = find.byKey(_staleTableKey);
      expect(
        stale,
        findsOneWidget,
        reason:
            'fixture: a dropped socket with a room in hand keeps '
            'game-screen-stale-table',
      );
      expect(
        find.descendant(of: stale, matching: find.text('دورك')),
        findsOneWidget,
        reason:
            'ar, own turn, awaitRoll, socket dropped: the header inside '
            'game-screen-stale-table must be exactly "دورك"',
      );
      expect(
        find.textContaining('ارمِ النرد'),
        findsNothing,
        reason:
            'ar, own turn, awaitRoll, socket dropped: nothing on the '
            'screen may contain "ارمِ النرد"',
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    'another seat\'s turn, socket dropped: the stale table still shows '
    'the waiting line naming that seat',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        seats: rollSeats,
        turn: _awaitRollTurn(seat: 1),
        autoReconnectDelays: _oneDelay,
      );
      try {
        await _mount(tester, controller);
        await _drop(tester, transport);

        expect(controller.phase, RoomPhase.closed);
        expect(controller.room, isNotNull);
        final Finder stale = find.byKey(_staleTableKey);
        expect(
          stale,
          findsOneWidget,
          reason:
              'fixture: a dropped socket with a room in hand keeps '
              'game-screen-stale-table',
        );
        expect(
          find.descendant(of: stale, matching: find.text('Waiting for Bob')),
          findsOneWidget,
          reason:
              'another seat\'s turn, socket dropped: the waiting line '
              'inside game-screen-stale-table still names that seat',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('own turn, socket dropped, then reconnected to a live awaitRoll: '
      '"Your turn. Roll the die." is back and the stale table is gone', (
    tester,
  ) async {
    final (controller, transport, connector) = await _connectPlaying(
      tester,
      seats: rollSeats,
      turn: _awaitRollTurn(),
      autoReconnectDelays: _oneDelay,
    );
    final FakeTransport resumeTransport = FakeTransport();
    connector.enqueue(resumeTransport);
    try {
      await _mount(tester, controller);
      await _drop(tester, transport);
      expect(controller.phase, RoomPhase.closed);
      expect(
        find.byKey(_staleTableKey),
        findsOneWidget,
        reason:
            'fixture: the resume below returns from '
            'game-screen-stale-table',
      );

      await tester.pump(_oneDelay[0]);
      await tester.pump();
      await tester.pump();
      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason: 'fixture: the automatic attempt must send resume',
      );
      expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: _idOf(resumeTransport.sentRaw.last),
          data: _roomJson(seats: rollSeats, turn: _awaitRollTurn(), seq: 1),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.phase, RoomPhase.connected);
      expect(
        find.text('Your turn. Roll the die.'),
        findsOneWidget,
        reason:
            'after reconnect on awaitRoll the live header '
            '"Your turn. Roll the die." is back',
      );
      expect(
        find.byKey(_staleTableKey),
        findsNothing,
        reason: 'after reconnect the game-screen-stale-table key is gone',
      );
    } finally {
      controller.dispose();
    }
  });
}
