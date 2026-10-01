// Widget tests for GameScreen unique-legal auto-move: after a roll whose
// legal list has exactly one token, the screen must hold for 1500ms before
// calling controller.move, and never send that move before the hold
// elapses. Nothing here edits the protocol.
//
// Order 224 (work/ludo/orders/C-223-play-surface.md, run 65) rewrote this
// feature: the hold shortened from 3s to 1500ms, the trigger moved from the
// Roll button to the die (`game-die`), and the Undo chip
// (`game-automove-undo`) is gone outright -- the contract's own words are
// "There is no Undo: with one legal token, waiting and the turn timer lead
// to that same move, so Undo cancelled nothing real." This file's original
// three Undo-specific cases ("game-automove-undo cancels a pending
// unique-legal move...", "Semantics announce fires ... when ... undone")
// and its two Semantics-announce cases have no successor and are dropped,
// not migrated, for that reason: there is no control left to cancel, and
// C-223's own accessibility section asks only for the token's Semantics
// button state (covered by test/play_surface_tokens_test.dart), never a
// live-region announcement on the hold's start or commit, so asserting one
// here would be testing an implementation detail the contract does not
// require. What survives below -- no early send, exactly one send once the
// hold elapses, and no send at all with two legal tokens -- is retested
// against the new mechanics. The manual-tap-cancels-and-sends-once case, the
// glow's own presence, the no-automove-undo-anywhere case and the new-k
// re-arm case now live in test/play_surface_automove_test.dart, so they are
// not repeated here.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real controller sits over FakeTransport, and every
// claim about what the screen sent is checked by decoding sentRaw. The
// 1500ms hold is advanced on flutter_test's fake clock via tester.pump, not
// wall time.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://unique-legal-automove-test.invalid/ws';
const Key _dieKey = Key('game-die');
const int _uniqueToken = 2;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'automove-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
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

/// Taps the die, answers with a `rolled` frame whose legal list is [legal],
/// and returns the sentRaw length after the screen has processed that
/// frame. Further `move` frames are counted from that index.
Future<int> _rollWithLegal(
  WidgetTester tester,
  FakeTransport transport, {
  required List<int> legal,
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
    reason: 'fixture is broken: tapping the die must send exactly one roll',
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
        'k': 1,
        'reveal': 'b' * 64,
        'seq': 2,
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

/// Completes the outstanding `move` request so RoomConnection's own reply
/// timer is not still pending when flutter_test verifies invariants.
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
  testWidgets(
    'after a unique-legal roll, no move is sent before 1500ms then exactly '
    'one move is sent',
    (tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      final int sentAfterRolled = await _rollWithLegal(
        tester,
        transport,
        legal: const <int>[_uniqueToken],
      );

      expect(
        controller.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason:
            'fixture is broken: a unique-legal rolled frame must leave '
            'the turn in awaitMove',
      );
      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'a unique-legal roll must enter a pending hold: no move '
            'frame on the transport before the 1500ms window elapses',
      );

      await tester.pump(const Duration(milliseconds: 1499));
      expect(
        _movesSince(transport, sentAfterRolled),
        isEmpty,
        reason:
            'controller.move must not run before the 1500ms hold elapses; '
            'got ${_movesSince(transport, sentAfterRolled).length} move '
            'frame(s) at 1499ms',
      );

      await tester.pump(const Duration(milliseconds: 1));
      final List<String> moves = _movesSince(transport, sentAfterRolled);
      expect(
        moves,
        hasLength(1),
        reason:
            'waiting out the 1500ms hold must put exactly one move on the '
            'transport; got ${moves.length}',
      );
      expect(_typeOf(moves.single), 'move');
      expect(
        _dataOf(moves.single),
        <String, Object?>{'token': _uniqueToken},
        reason:
            'the auto-move must name the unique legal token '
            '$_uniqueToken; got ${_dataOf(moves.single)}',
      );
      await _completeMove(
        tester,
        transport,
        moves.single,
        token: _uniqueToken,
        seq: 3,
      );
    },
  );

  testWidgets('a roll with two legal tokens sends no move after 1500ms', (
    tester,
  ) async {
    final (controller, transport) = await _connectAwaitingRoll(tester);
    await _mount(tester, controller);

    final int sentAfterRolled = await _rollWithLegal(
      tester,
      transport,
      legal: const <int>[0, _uniqueToken],
    );

    await tester.pump(const Duration(milliseconds: 1500));
    expect(
      _movesSince(transport, sentAfterRolled),
      isEmpty,
      reason:
          'auto-move is only for a unique legal token; two legal '
          'tokens must not put a move on the transport after 1500ms',
    );
  });
}
