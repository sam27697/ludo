// Proof for order 206's goal 1 ("start with who is here") and goal 4 (the
// rules lines), written from work/ludo/orders/206-lobby-start-with-present.md
// and docs/PROTOCOL.md section 15, against no implementation of either: on
// this branch lib/src/lobby_screen.dart has neither the extra button nor the
// rules lines, and the ARB getters order 206 introduces
// (lobbyStartWithPresent, lobbyRuleBlocksOn, lobbyRuleBlocksOff,
// lobbyRuleCaptureBonusOn, lobbyRuleCaptureBonusOff) do not exist. Every one
// of those five is referenced below, each in the exact place order 206's own
// spec says the widget will use it, so this file cannot compile until that
// order lands, and an `analyze` run against it names only those five
// identifiers and nothing else -- that is the acceptance criterion this file
// is written to, not a defect in this file.
//
// Driven the same way test/lobby_screen_test.dart and
// test/lobby_waiting_for_host_test.dart drive LobbyScreen: a real
// RoomController over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here), never a mock of RoomController. The connector
// double, the frame builder and the JSON fixtures below are copied from
// those two files' own idiom rather than imported -- every one of them is
// file-private there.
//
// Ids at the start of each group/test name are order 205's own (L1..L9).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/lobby_screen_test.dart -------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

/// A server push or reply, encoded exactly as Frame.decode expects.
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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot --------------

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

/// [occupied] consecutive seats starting at 0, seat 0 always the host.
List<Map<String, Object?>> _seats(int occupied) =>
    List<Map<String, Object?>>.generate(
      occupied,
      (i) => _seatJson(i, name: 'p$i', connected: true),
    );

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  bool blocks = true,
  bool captureBonus = true,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': blocks,
    'capture_bonus': captureBonus,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

// --- a TransportConnector test double, copied from lobby_screen_test.dart's
// --- own idiom rather than imported: it is not exported by that file, and
// --- that file is not on this order's file list to modify. -----------------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

// --- widget harness ----------------------------------------------------

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

// --- scenario driving ----------------------------------------------------

/// Mounts [screen], waits for the request rule 1 (order 081) says initState
/// must issue, and returns the raw sent message's id so a reply can target
/// it with `re`. Fails loudly, naming what was expected, if no message ever
/// reaches the transport.
Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_harness(screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'expected LobbyScreen.initState to have sent exactly one request '
        'to the transport by now (createRoom or joinRoom); sentRaw is '
        'empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = 'ABC234',
  int players = 4,
  int hostSeat = 0,
  List<Map<String, Object?>>? seats,
  bool blocks = true,
  bool captureBonus = true,
  int seq = 1,
}) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': seatForThisClient,
        'seat_token': 'tok-$seatForThisClient',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        code: code,
        players: players,
        hostSeat: hostSeat,
        seats: seats,
        blocks: blocks,
        captureBonus: captureBonus,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // --- L1 -------------------------------------------------------------
  group('L1: host, 4 seats, 3 occupied', () {
    testWidgets(
      'lobby-start-with-present-button is present and its label reads '
      'loc.lobbyStartWithPresent(3), the en "other" plural form '
      '"Start with 3 players"',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _seats(3),
        );

        expect(
          controller.isHost,
          isTrue,
          reason: 'L1 fixture: this scenario must mount as the host',
        );
        expect(controller.room!.seats.length, 3);
        expect(controller.room!.players, 4);

        final finder = find.byKey(const Key('lobby-start-with-present-button'));
        expect(
          finder,
          findsOneWidget,
          reason:
              'L1: host, room not full (3 of 4), and at least two seats '
              'occupied must show lobby-start-with-present-button',
        );

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        final expected = loc.lobbyStartWithPresent(3);
        expect(
          expected,
          'Start with 3 players',
          reason:
              'L1 pins the exact en string from order 206\'s ARB table for '
              'the "other" plural form with count=3; got "$expected"',
        );
        expect(
          find.descendant(of: finder, matching: find.text(expected)),
          findsOneWidget,
          reason:
              'L1: the button must contain a Text reading exactly '
              'loc.lobbyStartWithPresent(3) == "$expected"',
        );
      },
    );
  });

  // --- L2 -------------------------------------------------------------
  group('L2: lobby-start-with-present-button is absent', () {
    testWidgets(
      'L2a: a guest in the same room (3 of 4) sees no button, even though '
      'the room is not full and two or more seats are occupied',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.join,
            code: 'ABC234',
            playerName: 'p1',
          ),
          transport,
        );
        // Seat 1, host seat 0: this client is not the host.
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 1,
          hostSeat: 0,
          players: 4,
          seats: _seats(3),
        );

        expect(
          controller.isHost,
          isFalse,
          reason: 'L2a fixture: this scenario must mount as a guest',
        );
        expect(controller.room!.seats.length, 3);
        expect(controller.room!.players, 4);

        expect(
          find.byKey(const Key('lobby-start-with-present-button')),
          findsNothing,
          reason:
              'L2a: a guest must never see lobby-start-with-present-button, '
              'whatever the seat count',
        );
      },
    );

    testWidgets('L2b: the host sees no button once the room is full (4 of 4)', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'p0',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _seats(4),
      );

      expect(controller.isHost, isTrue);
      expect(
        controller.room!.seats.length,
        controller.room!.players,
        reason: 'L2b fixture: needs a full room, 4 of 4',
      );

      expect(
        find.byKey(const Key('lobby-start-with-present-button')),
        findsNothing,
        reason:
            'L2b: a full room has nobody left to start with fewer than '
            'were configured, so the button must not show, even to the '
            'host',
      );
    });

    testWidgets(
      'L2c: the host sees no button when only the host is seated (one seat)',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'p0',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _seats(1),
        );

        expect(controller.isHost, isTrue);
        expect(
          controller.room!.seats.length,
          1,
          reason: 'L2c fixture: needs only the host seated',
        );

        expect(
          find.byKey(const Key('lobby-start-with-present-button')),
          findsNothing,
          reason:
              'L2c: with one seat occupied there is nobody to start with; '
              'the button must not show even to the host',
        );
      },
    );
  });

  // --- L3 -------------------------------------------------------------
  group(
    'L3: tapping sends set_players then start_game, exactly one of each',
    () {
      testWidgets(
        'the first frame sent after the tap is set_players {players: 3}; '
        'answering it with a full 3-seat room sends start_game next, and '
        'only once',
        (tester) async {
          final connector = _Connector();
          final transport = FakeTransport();
          connector.enqueue(transport);
          final controller = _newController(connector);
          addTearDown(controller.dispose);

          final id = await _mountAndCaptureRequest(
            tester,
            LobbyScreen(
              controller: controller,
              action: LobbyAction.create,
              playerName: 'p0',
              players: 4,
            ),
            transport,
          );
          await _resolveConnected(
            tester,
            transport,
            id,
            seatForThisClient: 0,
            hostSeat: 0,
            players: 4,
            seats: _seats(3),
          );

          final finder = find.byKey(
            const Key('lobby-start-with-present-button'),
          );
          expect(finder, findsOneWidget);

          final beforeCount = transport.sentRaw.length;
          await tester.tap(finder);
          await tester.pump();

          final sentAfterTap = transport.sentRaw.skip(beforeCount).toList();
          expect(
            sentAfterTap,
            hasLength(1),
            reason:
                'L3: tapping must send exactly one frame before any reply '
                'arrives; got $sentAfterTap',
          );
          expect(_typeOf(sentAfterTap.single), 'set_players');
          expect(
            _dataOf(sentAfterTap.single),
            <String, Object?>{'players': 3},
            reason:
                'L3: the set_players request must carry count == '
                'room.seats.length == 3',
          );

          final setPlayersId = _idOf(sentAfterTap.single);
          transport.pushText(
            _frame(
              type: 'room',
              re: setPlayersId,
              data: _roomJson(
                players: 3,
                hostSeat: 0,
                seats: _seats(3),
                seq: 2,
              ),
            ),
          );
          await tester.pump();
          await tester.pump();

          final sentAfterReply = transport.sentRaw
              .skip(beforeCount + 1)
              .toList();
          expect(
            sentAfterReply,
            hasLength(1),
            reason:
                'L3: once set_players answers with a now-full room, exactly '
                'one further frame must be sent (start_game); got '
                '$sentAfterReply',
          );
          expect(_typeOf(sentAfterReply.single), 'start_game');

          final setPlayersFrames = transport.sentRaw
              .where((s) => _typeOf(s) == 'set_players')
              .toList();
          final startGameFrames = transport.sentRaw
              .where((s) => _typeOf(s) == 'start_game')
              .toList();
          expect(
            setPlayersFrames,
            hasLength(1),
            reason: 'L3: exactly one set_players must ever be sent',
          );
          expect(
            startGameFrames,
            hasLength(1),
            reason: 'L3: exactly one start_game must ever be sent',
          );

          // Resolve start_game so addTearDown's dispose does not race
          // flutter_test's pending-timer invariant against a request the
          // assertions above already exercised.
          final startId = _idOf(sentAfterReply.single);
          transport.pushText(
            _frame(
              type: 'game_started',
              re: startId,
              data: <String, Object?>{
                'turn': 0,
                'game_id': 'a' * 16,
                'client_seeds': '0:seed',
                'seq': 3,
              },
            ),
          );
          await tester.pump();
        },
      );
    },
  );

  // --- L4 -------------------------------------------------------------
  group('L4: a refused set_players does not wreck the lobby', () {
    testWidgets(
      'answered NOT_ENOUGH_PLAYERS: the lobby stays in its connected body '
      '(lobby-room-code still found, no lobby-error), and no start_game is '
      'sent',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'p0',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _seats(3),
        );

        final finder = find.byKey(const Key('lobby-start-with-present-button'));
        await tester.tap(finder);
        await tester.pump();

        expect(_typeOf(transport.sentRaw.last), 'set_players');
        final setPlayersId = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'error',
            re: setPlayersId,
            data: <String, Object?>{
              'code': 'NOT_ENOUGH_PLAYERS',
              'message':
                  'a friend left between the tap and the server '
                  'reading it',
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('lobby-room-code')),
          findsOneWidget,
          reason:
              'L4: the lobby must stay in its connected body after a '
              'refused set_players',
        );
        expect(
          find.byKey(const Key('lobby-error')),
          findsNothing,
          reason:
              'L4: a refused set_players must not send the lobby into its '
              'error body',
        );

        final startGameFrames = transport.sentRaw
            .where((s) => _typeOf(s) == 'start_game')
            .toList();
        expect(
          startGameFrames,
          isEmpty,
          reason:
              'L4: a refused set_players must never be followed by '
              'start_game',
        );
      },
    );
  });

  // --- L5 -------------------------------------------------------------
  group('L5: tapping twice before the reply sends exactly one set_players', () {
    testWidgets('a second tap while the first request is still in flight sends '
        'nothing more', (tester) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'p0',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _seats(3),
      );

      final finder = find.byKey(const Key('lobby-start-with-present-button'));

      await tester.tap(finder);
      await tester.pump();
      final afterFirstTap = transport.sentRaw
          .where((s) => _typeOf(s) == 'set_players')
          .toList();
      expect(
        afterFirstTap,
        hasLength(1),
        reason:
            'L5 fixture: the first tap must have sent set_players before '
            'the second tap is attempted; got $afterFirstTap',
      );

      await tester.tap(finder);
      await tester.pump();
      final afterSecondTap = transport.sentRaw
          .where((s) => _typeOf(s) == 'set_players')
          .toList();
      expect(
        afterSecondTap,
        hasLength(1),
        reason:
            'L5: a second tap before the reply must send nothing more; the '
            'button must be disabled while the first set_players request '
            'is in flight, got ${afterSecondTap.length} set_players frames',
      );

      // Answer with a room that leaves the seat count unchanged (still 3
      // of 4), so no start_game follows and this test stays about the tap
      // count alone; resolved so addTearDown's dispose does not race
      // flutter_test's pending-timer invariant.
      final setPlayersId = _idOf(afterSecondTap.single);
      transport.pushText(
        _frame(
          type: 'room',
          re: setPlayersId,
          data: _roomJson(players: 4, hostSeat: 0, seats: _seats(3), seq: 2),
        ),
      );
      await tester.pump();
    });
  });

  // --- L6 -------------------------------------------------------------
  group('L6: ar locale, 2 occupied of 4', () {
    testWidgets(
      'the label is the =2 plural form "ابدأ بلاعبَين", under Directionality '
      'rtl',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'سام',
            players: 4,
          ),
          transport,
          locale: const Locale('ar'),
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _seats(2),
        );

        final context = tester.element(find.byType(LobbyScreen));
        expect(
          Directionality.of(context),
          TextDirection.rtl,
          reason:
              'L6: pumping LobbyScreen in Locale(ar) must resolve '
              'Directionality to rtl',
        );

        final loc = AppLocalizations.of(context);
        final expected = loc.lobbyStartWithPresent(2);
        expect(
          expected,
          'ابدأ بلاعبَين',
          reason:
              'L6 pins the exact ar =2 string from order 206\'s ARB table; '
              'got "$expected"',
        );

        final finder = find.byKey(const Key('lobby-start-with-present-button'));
        expect(finder, findsOneWidget);
        expect(
          find.descendant(of: finder, matching: find.text(expected)),
          findsOneWidget,
          reason:
              'L6: the button must contain a Text reading exactly the ar '
              '=2 form "$expected", not the "other" form',
        );
      },
    );
  });

  // --- L7/L8/L9 ---------------------------------------------------------
  group('L7/L8/L9: the rules lines under the seat list', () {
    testWidgets('L7: guest view, blocks off / capture bonus on, en', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'p1',
        ),
        transport,
      );
      // Seat 1, host seat 0: this client is not the host.
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: _seats(2),
        blocks: false,
        captureBonus: true,
      );

      expect(controller.isHost, isFalse, reason: 'L7 fixture: guest view');
      expect(controller.room!.rules.blocks, isFalse);
      expect(controller.room!.rules.captureBonus, isTrue);

      final context = tester.element(find.byType(LobbyScreen));
      final loc = AppLocalizations.of(context);
      expect(
        loc.lobbyRuleBlocksOff,
        'Blocks: off',
        reason:
            'L7 pins the exact en string from order 206\'s ARB table for '
            'lobbyRuleBlocksOff',
      );
      expect(
        loc.lobbyRuleCaptureBonusOn,
        'Capture bonus: on',
        reason:
            'L7 pins the exact en string from order 206\'s ARB table for '
            'lobbyRuleCaptureBonusOn',
      );

      final blocksText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-blocks')),
      );
      expect(
        blocksText.data,
        'Blocks: off',
        reason:
            'L7: lobby-rule-blocks must read "Blocks: off" for '
            'rules.blocks == false; got "${blocksText.data}"',
      );
      final captureText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-capture-bonus')),
      );
      expect(
        captureText.data,
        'Capture bonus: on',
        reason:
            'L7: lobby-rule-capture-bonus must read "Capture bonus: on" '
            'for rules.captureBonus == true; got "${captureText.data}"',
      );
    });

    testWidgets('L8: the same room in ar reads the ar strings', (tester) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'سام',
        ),
        transport,
        locale: const Locale('ar'),
      );
      // Seat 1, host seat 0: this client is not the host.
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: _seats(2),
        blocks: false,
        captureBonus: true,
      );

      final context = tester.element(find.byType(LobbyScreen));
      final loc = AppLocalizations.of(context);
      expect(
        loc.lobbyRuleBlocksOff,
        'الحواجز: معطّلة',
        reason:
            'L8 pins the exact ar string from order 206\'s ARB table for '
            'lobbyRuleBlocksOff',
      );
      expect(
        loc.lobbyRuleCaptureBonusOn,
        'مكافأة الأكل: مفعّلة',
        reason:
            'L8 pins the exact ar string from order 206\'s ARB table for '
            'lobbyRuleCaptureBonusOn',
      );

      final blocksText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-blocks')),
      );
      expect(
        blocksText.data,
        'الحواجز: معطّلة',
        reason:
            'L8: lobby-rule-blocks must read the ar string for blocks '
            'off; got "${blocksText.data}"',
      );
      final captureText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-capture-bonus')),
      );
      expect(
        captureText.data,
        'مكافأة الأكل: مفعّلة',
        reason:
            'L8: lobby-rule-capture-bonus must read the ar string for '
            'capture bonus on; got "${captureText.data}"',
      );
    });

    testWidgets('L9: defaults (both on) for the host view, en', (tester) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'p0',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _seats(1),
      );

      expect(controller.isHost, isTrue, reason: 'L9 fixture: host view');
      expect(controller.room!.rules.blocks, isTrue);
      expect(controller.room!.rules.captureBonus, isTrue);

      final context = tester.element(find.byType(LobbyScreen));
      final loc = AppLocalizations.of(context);
      expect(loc.lobbyRuleBlocksOn, 'Blocks: on');
      expect(loc.lobbyRuleCaptureBonusOn, 'Capture bonus: on');

      final blocksText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-blocks')),
      );
      expect(
        blocksText.data,
        'Blocks: on',
        reason:
            'L9: lobby-rule-blocks must read "Blocks: on" for the '
            'default rules, for the host too; got "${blocksText.data}"',
      );
      final captureText = tester.widget<Text>(
        find.byKey(const Key('lobby-rule-capture-bonus')),
      );
      expect(
        captureText.data,
        'Capture bonus: on',
        reason:
            'L9: lobby-rule-capture-bonus must read "Capture bonus: on" '
            'for the default rules, for the host too; got '
            '"${captureText.data}"',
      );
    });
  });
}
