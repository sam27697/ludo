// Spike C1-T05: always auto-play every forced chain. Drives a fixture match
// through GameScreen, counts await-move turns whose legal list has length 1,
// and logs how many of those the screen auto-resolved by calling move with
// no tap, hold, or undo.

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

const String _testUrl = 'wss://forced-chain-spike.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'spike-t05-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  int? sixes,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'sixes': ?sixes,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
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
      ],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport queued',
      );
    }
    return _queue.removeAt(0);
  }
}

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) async {
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
      data: _roomJson(seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child) {
  return MaterialApp(
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

List<String> _newOfType(FakeTransport transport, int sentBefore, String type) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((String s) => _typeOf(s) == type)
      .toList();
}

void main() {
  testWidgets(
    'fixture match auto-plays every legal==1 await-move and logs the fraction',
    (tester) async {
      final seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[4, -1, 12, -1]),
        _seatJson(1, name: 'Bob', tokens: const <int>[-1, 8, -1, -1]),
      ];
      final (controller, transport) = await _connectPlaying(
        tester,
        seats: seats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 8000, k: 0),
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.state,
        RoomState.playing,
        reason: 'fixture broken',
      );

      await _mount(tester, controller);

      int seq = 1;
      int k = 0;
      int from0 = 4;
      int legal1Turns = 0;
      int autoResolved = 0;
      int choiceTurns = 0;
      int emptyLegalTurns = 0;
      int opponentLegal1Ignored = 0;
      int ourAwaitMoveTurns = 0;

      Future<String> tapRoll() async {
        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('game-screen-roll-button')));
        await tester.pump();
        final List<String> rolls = _newOfType(transport, sentBefore, 'roll');
        expect(rolls, hasLength(1), reason: 'roll tap must send one roll');
        return _idOf(rolls.single);
      }

      Future<void> pushRolled({
        required String rollId,
        required int seat,
        required int value,
        required List<int> legal,
      }) async {
        k += 1;
        seq += 1;
        transport.pushText(
          _frame(
            type: 'rolled',
            re: seat == 0 ? rollId : null,
            data: <String, Object?>{
              'seat': seat,
              'value': value,
              'legal': legal,
              'deadline_ms': 8000,
              'k': k,
              'reveal': 'b' * 64,
              'seq': seq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      Future<void> answerMoved({
        required String moveId,
        required int seat,
        required int token,
        required int from,
        required int to,
        required bool extraRoll,
      }) async {
        seq += 1;
        transport.pushText(
          _frame(
            type: 'moved',
            re: seat == 0 ? moveId : null,
            data: <String, Object?>{
              'seat': seat,
              'token': token,
              'from': from,
              'to': to,
              'captured': <Object?>[],
              'extra_roll': extraRoll,
              'seq': seq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      Future<void> pushTurn(int seat) async {
        seq += 1;
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': seat,
              'deadline_ms': 8000,
              'seq': seq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      // --- Forced chain: two extra-roll unique-legal moves, no taps. ---
      ourAwaitMoveTurns += 1;
      legal1Turns += 1;
      final String rollId1 = await tapRoll();
      final int sentBeforeAuto1 = transport.sentRaw.length;
      await pushRolled(
        rollId: rollId1,
        seat: 0,
        value: 6,
        legal: const <int>[0],
      );
      final List<String> auto1 = _newOfType(transport, sentBeforeAuto1, 'move');
      expect(
        auto1,
        hasLength(1),
        reason: 'legal==1 after roll 1 must auto-send move with no tap',
      );
      expect(_dataOf(auto1.single), <String, Object?>{'token': 0});
      autoResolved += 1;
      await answerMoved(
        moveId: _idOf(auto1.single),
        seat: 0,
        token: 0,
        from: from0,
        to: from0 + 6,
        extraRoll: true,
      );
      from0 += 6;

      ourAwaitMoveTurns += 1;
      legal1Turns += 1;
      final String rollId2 = await tapRoll();
      final int sentBeforeAuto2 = transport.sentRaw.length;
      await pushRolled(
        rollId: rollId2,
        seat: 0,
        value: 2,
        legal: const <int>[2],
      );
      final List<String> auto2 = _newOfType(transport, sentBeforeAuto2, 'move');
      expect(
        auto2,
        hasLength(1),
        reason: 'legal==1 extra-roll chain step must auto-send move',
      );
      expect(_dataOf(auto2.single), <String, Object?>{'token': 2});
      autoResolved += 1;
      await answerMoved(
        moveId: _idOf(auto2.single),
        seat: 0,
        token: 2,
        from: 12,
        to: 14,
        extraRoll: false,
      );

      await pushTurn(1);

      // Opponent unique-legal: this client must not send a move.
      opponentLegal1Ignored += 1;
      seq += 1;
      k += 1;
      final int sentBeforeOpp = transport.sentRaw.length;
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 1,
            'value': 3,
            'legal': <int>[1],
            'deadline_ms': 8000,
            'k': k,
            'reveal': 'c' * 64,
            'seq': seq,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        _newOfType(transport, sentBeforeOpp, 'move'),
        isEmpty,
        reason: 'opponent legal==1 must not auto-move on this client',
      );
      await answerMoved(
        moveId: 'unused',
        seat: 1,
        token: 1,
        from: 8,
        to: 11,
        extraRoll: false,
      );
      await pushTurn(0);

      // --- Choice turn: legal length 2, player must tap. ---
      ourAwaitMoveTurns += 1;
      choiceTurns += 1;
      final String rollId3 = await tapRoll();
      final int sentBeforeChoice = transport.sentRaw.length;
      await pushRolled(
        rollId: rollId3,
        seat: 0,
        value: 4,
        legal: const <int>[0, 2],
      );
      expect(
        _newOfType(transport, sentBeforeChoice, 'move'),
        isEmpty,
        reason: 'legal length 2 must not auto-move',
      );
      await tester.tap(find.byKey(const Key('game-screen-token-0')));
      await tester.pump();
      final List<String> choiceMove = _newOfType(
        transport,
        sentBeforeChoice,
        'move',
      );
      expect(choiceMove, hasLength(1));
      expect(_dataOf(choiceMove.single), <String, Object?>{'token': 0});
      await answerMoved(
        moveId: _idOf(choiceMove.single),
        seat: 0,
        token: 0,
        from: from0,
        to: from0 + 4,
        extraRoll: false,
      );
      from0 += 4;
      await pushTurn(0);

      // --- Another unique-legal after the choice. ---
      ourAwaitMoveTurns += 1;
      legal1Turns += 1;
      final String rollId4 = await tapRoll();
      final int sentBeforeAuto3 = transport.sentRaw.length;
      await pushRolled(
        rollId: rollId4,
        seat: 0,
        value: 1,
        legal: const <int>[0],
      );
      final List<String> auto3 = _newOfType(transport, sentBeforeAuto3, 'move');
      expect(
        auto3,
        hasLength(1),
        reason: 'later legal==1 turn must still auto-send',
      );
      expect(_dataOf(auto3.single), <String, Object?>{'token': 0});
      autoResolved += 1;
      await answerMoved(
        moveId: _idOf(auto3.single),
        seat: 0,
        token: 0,
        from: from0,
        to: from0 + 1,
        extraRoll: false,
      );
      await pushTurn(0);

      // --- Empty legal: no auto-move. ---
      ourAwaitMoveTurns += 1;
      emptyLegalTurns += 1;
      final String rollId5 = await tapRoll();
      final int sentBeforeEmpty = transport.sentRaw.length;
      await pushRolled(
        rollId: rollId5,
        seat: 0,
        value: 5,
        legal: const <int>[],
      );
      expect(
        _newOfType(transport, sentBeforeEmpty, 'move'),
        isEmpty,
        reason: 'empty legal list must not auto-move',
      );

      expect(autoResolved, legal1Turns);
      expect(legal1Turns, 3);
      expect(choiceTurns, 1);
      expect(emptyLegalTurns, 1);
      expect(opponentLegal1Ignored, 1);
      expect(ourAwaitMoveTurns, 5);

      final double fractionLegal1Auto = legal1Turns == 0
          ? 0
          : autoResolved / legal1Turns;
      final double fractionOfOurTurns = autoResolved / ourAwaitMoveTurns;
      debugPrint(
        'SPIKE_MEASURE auto_resolved=$autoResolved '
        'legal1_turns=$legal1Turns '
        'our_await_move_turns=$ourAwaitMoveTurns '
        'choice_turns=$choiceTurns '
        'empty_legal_turns=$emptyLegalTurns '
        'opponent_legal1_ignored=$opponentLegal1Ignored '
        'fraction_legal1_auto=${fractionLegal1Auto.toStringAsFixed(2)} '
        'fraction_of_our_turns=${fractionOfOurTurns.toStringAsFixed(2)}',
      );
    },
  );
}
