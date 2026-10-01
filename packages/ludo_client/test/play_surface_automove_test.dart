// Conformance tests for the unique-legal auto-move on GameScreen's new play
// surface, written from work/ludo/orders/C-223-play-surface.md (the master,
// run 65) alone. Order 223 (lib/src/game_screen.dart, lib/src/board.dart) is
// being built in parallel by a different worker; this file was written
// without opening either of those files' new content, so it is expected to
// fail to compile or run red against a branch that still carries
// `game-automove-undo` and a 3-second hold.
//
// The Undo chip is gone by the contract's own text ("There is no Undo: with
// one legal token, waiting and the turn timer lead to that same move, so
// Undo cancelled nothing real"), so this file replaces
// test/unique_legal_automove_test.dart's Undo-specific cases rather than
// migrating them; see that file's own header comment for exactly what moved
// here and what was dropped outright.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real RoomController sits over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here). The 1500ms
// hold is advanced on flutter_test's fake clock via tester.pump, never a
// real Timer or a real delay.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://play-surface-automove-test.invalid/ws';
const Key _dieKey = Key('game-die');
const int _uniqueToken = 2;

Key _glowKey(int seat, int index) => Key('board-automove-glow-$seat-$index');
Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'automove2-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Future<(RoomController, FakeTransport)> _connectAwaitingRoll(
  WidgetTester tester,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
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
      data: _roomJson(
        seats: _twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

/// Taps game-die, answers with a rolled frame whose legal list is [legal],
/// at turn [k]. Returns the sentRaw length once the screen has processed
/// that frame.
Future<int> _rollWithLegal(
  WidgetTester tester,
  FakeTransport transport, {
  required List<int> legal,
  required int k,
}) async {
  final int sentBeforeRoll = transport.sentRaw.length;
  await tester.tap(find.byKey(_dieKey));
  await tester.pump();
  final List<String> rollMessages = transport.sentRaw
      .skip(sentBeforeRoll)
      .where((s) => _typeOf(s) == 'roll')
      .toList();
  expect(
    rollMessages,
    hasLength(1),
    reason: 'fixture is broken: tapping game-die must send exactly one roll',
  );
  transport.pushText(
    _frame(
      type: 'rolled',
      re: _idOf(rollMessages.single),
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': legal,
        'deadline_ms': 45000,
        'k': k,
        'reveal': 'b' * 64,
        'seq': k + 1,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  return transport.sentRaw.length;
}

List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((s) => _typeOf(s) == 'move')
      .toList();
}

Future<void> _completeMove(
  WidgetTester tester,
  FakeTransport transport,
  String moveText, {
  required int token,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      re: _idOf(moveText),
      data: <String, Object?>{
        'seat': 0,
        'token': token,
        'from': -1,
        'to': 5,
        'captured': <Object?>[],
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // ==========================================================================
  // No Undo control anywhere.
  // ==========================================================================
  group('no Undo control', () {
    testWidgets(
      'game-automove-undo does not exist during the pending hold, after it '
      'commits, or at any other time',
      (tester) async {
        final (controller, transport) = await _connectAwaitingRoll(tester);
        await _mount(tester, controller);

        expect(find.byKey(const Key('game-automove-undo')), findsNothing);

        final int sentAfterRolled = await _rollWithLegal(
          tester,
          transport,
          legal: const <int>[_uniqueToken],
          k: 1,
        );
        expect(
          find.byKey(const Key('game-automove-undo')),
          findsNothing,
          reason:
              'game-automove-undo must not exist while the auto-move hold '
              'is pending; there is no Undo in the new contract',
        );

        await tester.pump(const Duration(milliseconds: 1500));
        expect(_movesSince(transport, sentAfterRolled), hasLength(1));
        expect(
          find.byKey(const Key('game-automove-undo')),
          findsNothing,
          reason: 'game-automove-undo must not exist after the move commits',
        );

        final String moveText = _movesSince(transport, sentAfterRolled).single;
        await _completeMove(
          tester,
          transport,
          moveText,
          token: _uniqueToken,
          seq: 3,
        );
      },
    );
  });

  // ==========================================================================
  // The glow: present exactly for the pending unique-legal token.
  // ==========================================================================
  group('board-automove-glow', () {
    testWidgets(
      'appears on the unique legal token once its roll lands, and is gone '
      'once the move commits',
      (tester) async {
        final (controller, transport) = await _connectAwaitingRoll(tester);
        await _mount(tester, controller);

        expect(find.byKey(_glowKey(0, _uniqueToken)), findsNothing);

        final int sentAfterRolled = await _rollWithLegal(
          tester,
          transport,
          legal: const <int>[_uniqueToken],
          k: 1,
        );

        expect(
          find.byKey(_glowKey(0, _uniqueToken)),
          findsOneWidget,
          reason:
              'board-automove-glow-0-$_uniqueToken must appear once the '
              'unique-legal roll lands',
        );

        await tester.pump(const Duration(milliseconds: 1500));
        expect(_movesSince(transport, sentAfterRolled), hasLength(1));
        expect(
          find.byKey(_glowKey(0, _uniqueToken)),
          findsNothing,
          reason: 'the glow must be gone once the auto-move has committed',
        );

        final String moveText = _movesSince(transport, sentAfterRolled).single;
        await _completeMove(
          tester,
          transport,
          moveText,
          token: _uniqueToken,
          seq: 3,
        );
      },
    );

    testWidgets('does not appear when two tokens are legal', (tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[0, _uniqueToken],
        k: 1,
      );

      expect(find.byKey(_glowKey(0, 0)), findsNothing);
      expect(find.byKey(_glowKey(0, _uniqueToken)), findsNothing);
    });
  });

  // ==========================================================================
  // Manual tap during the hold: sends once, at once, and the timer sends
  // nothing more.
  // ==========================================================================
  group('tapping the glowing token before the hold elapses', () {
    testWidgets(
      'sends exactly one move immediately, and the 1500ms timer sends '
      'nothing further',
      (tester) async {
        final (controller, transport) = await _connectAwaitingRoll(tester);
        await _mount(tester, controller);

        final int sentAfterRolled = await _rollWithLegal(
          tester,
          transport,
          legal: const <int>[_uniqueToken],
          k: 1,
        );

        await tester.pump(const Duration(milliseconds: 200));
        expect(
          _movesSince(transport, sentAfterRolled),
          isEmpty,
          reason: 'fixture is broken: no move must exist yet at 200ms',
        );

        await tester.tap(find.byKey(_hitKey(0, _uniqueToken)));
        await tester.pump();

        final List<String> movesRightAfterTap = _movesSince(
          transport,
          sentAfterRolled,
        );
        expect(
          movesRightAfterTap,
          hasLength(1),
          reason:
              'tapping the glowing token before the hold elapses must send '
              'exactly one move at once',
        );
        expect(_dataOf(movesRightAfterTap.single), <String, Object?>{
          'token': _uniqueToken,
        });
        await _completeMove(
          tester,
          transport,
          movesRightAfterTap.single,
          token: _uniqueToken,
          seq: 3,
        );

        // Let the original 1500ms window run out; the manual tap must have
        // disarmed the timer, so nothing further is sent.
        await tester.pump(const Duration(milliseconds: 1500));
        expect(
          _movesSince(transport, sentAfterRolled),
          hasLength(1),
          reason:
              'after the manual tap already sent the move, the original '
              '1500ms timer must not send a second one',
        );
      },
    );
  });

  // ==========================================================================
  // Re-arming: a new turn.k re-arms the hold.
  // ==========================================================================
  group('a new turn.k re-arms the hold', () {
    testWidgets('a second unique-legal roll, at a new k, glows and commits '
        'independently of the first', (tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      final int sentAfterFirstRolled = await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[_uniqueToken],
        k: 1,
      );
      await tester.pump(const Duration(milliseconds: 1500));
      final List<String> firstMoves = _movesSince(
        transport,
        sentAfterFirstRolled,
      );
      expect(firstMoves, hasLength(1));
      await _completeMove(
        tester,
        transport,
        firstMoves.single,
        token: _uniqueToken,
        seq: 3,
      );

      // A further turn hands play back to seat 0 with a new k and a new
      // unique-legal roll, this time on a different token.
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 4},
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        controller.room!.turn!.phase,
        TurnPhase.awaitRoll,
        reason: 'fixture is broken: the fresh turn frame must be awaitRoll',
      );

      const int secondUniqueToken = 0;
      final int sentAfterSecondRolled = await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[secondUniqueToken],
        k: 3,
      );

      expect(
        find.byKey(_glowKey(0, secondUniqueToken)),
        findsOneWidget,
        reason:
            'a fresh unique-legal roll at a new k must arm the hold '
            'again and glow the (possibly different) unique token',
      );

      await tester.pump(const Duration(milliseconds: 1500));
      final List<String> secondMoves = _movesSince(
        transport,
        sentAfterSecondRolled,
      );
      expect(
        secondMoves,
        hasLength(1),
        reason:
            'the re-armed hold at the new k must independently commit '
            'exactly one further move',
      );
      expect(_dataOf(secondMoves.single), <String, Object?>{
        'token': secondUniqueToken,
      });
      await _completeMove(
        tester,
        transport,
        secondMoves.single,
        token: secondUniqueToken,
        seq: 5,
      );
    });
  });
}
