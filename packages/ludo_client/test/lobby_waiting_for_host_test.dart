// Order 188 introduced the guest's host-starts-it line for a full room;
// C-666 D3 widened it: a guest in an ordinary lobby always reads
// lobbyWaitingForHost on lobby-waiting, whatever the seat count, and the
// "Waiting for players (n of m)" line is no longer shown. The cases that
// pinned the count for a room short of full (WH-PART, the first half of
// WH-FILL) now pin the host line for the same situation.
//
// This file pins the contract with the literal strings rather than with the
// generated getters, so it compiles whether or not lobbyWaitingForPlayers is
// still generated. The old count line is matched by its literal text.
//
// Driven the same way test/lobby_screen_test.dart drives LobbyScreen: a
// real RoomController built over a FakeTransport (test/net/fake_transport.
// dart, read-only, not edited here), never a mock of RoomController. The
// connector double, the frame builder and the JSON fixtures below are
// copied from lobby_screen_test.dart's own idiom rather than imported --
// every one of them is file-private there (leading underscore).
//
// WH-FILL's "server pushes the frame that seats a fourth player" is the
// presence-gap-then-resume path lobby_screen_test.dart already exercises
// (its "rule 5" group and its Locale(ar) connected-body case): a `presence`
// push whose seq is not room.seq + 1 makes RoomController's own
// `_beginResync` send a `resume` on the transport already open, without any
// tap and without a second transport; answering that `resume` with a `room`
// frame is the one place in that file a connected room's snapshot is ever
// replaced wholesale after the initial connect. There is no other frame in
// that file that grows a room's seats after connection.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// The host-starts-it literals, the en and ar texts of lobbyWaitingForHost.
const String _kWaitingForHostEn = 'Waiting for the host to start the game';
const String _kWaitingForHostAr = 'بانتظار المضيف لبدء اللعبة';
const String _kOldCountEn = 'Waiting for players';
const String _kOldCountAr = 'بانتظار اللاعبين';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/net/room_controller_test.dart and
// --- test/lobby_screen_test.dart --------------------------------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
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
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from lobby_screen_test.dart's
// --- own idiom rather than imported: it is not exported by that file, and
// --- that file is not on this order's file list to modify. -----------------

/// Hands out queued [FakeTransport]s, one per call, in order.
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
        'rig: expected LobbyScreen.initState to have sent exactly one '
        'request to the transport by now (createRoom or joinRoom); '
        'sentRaw is empty',
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
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // Section 32 item 6: a typed-code join waits for the install id. A launched
  // app has read or made it already, so the fixtures do the same once, and
  // every test starts from a store that holds only that id (a record one test
  // saves must not turn the next test's join into a resume).
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

  group('order 188, widened by C-666 D3: a guest always sees '
      'lobbyWaitingForHost', () {
    testWidgets(
      'WH-EN: guest, room full (4 of 4), Locale(en): lobby-waiting reads '
      'the host-starts-it literal, not the players count',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          4,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

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
          seats: seats,
        );

        expect(
          controller.isHost,
          isFalse,
          reason: 'WH-EN fixture: this scenario must mount as a guest',
        );
        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason: 'WH-EN fixture: needs a full room, 4 of 4',
        );

        final waitingFinder = find.byKey(const Key('lobby-waiting'));
        expect(
          waitingFinder,
          findsOneWidget,
          reason:
              'WH-EN: a guest must still show lobby-waiting when the room '
              'is full',
        );
        final waitingText = tester.widget<Text>(waitingFinder);
        expect(
          waitingText.data,
          _kWaitingForHostEn,
          reason:
              'WH-EN: with a full room, lobby-waiting must read the '
              'literal "$_kWaitingForHostEn" (the host is who this guest '
              'is now waiting on); got "${waitingText.data}"',
        );
        expect(
          find.textContaining(_kOldCountEn),
          findsNothing,
          reason:
              'WH-EN: the "$_kOldCountEn (n of m)" line must not be shown '
              'in a full room; nobody else is coming, so a players count is '
              'not what a guest is waiting for',
        );
      },
    );

    testWidgets(
      'WH-AR: guest, room full (4 of 4), Locale(ar): lobby-waiting reads '
      'the Arabic host-starts-it literal, not the players count',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          4,
          (i) => _seatJson(i, name: 'لاعب $i', connected: true),
        );

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.join,
            code: 'ABC234',
            playerName: 'لاعب 1',
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
          seats: seats,
        );

        expect(
          controller.isHost,
          isFalse,
          reason: 'WH-AR fixture: this scenario must mount as a guest',
        );
        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason: 'WH-AR fixture: needs a full room, 4 of 4',
        );

        final waitingFinder = find.byKey(const Key('lobby-waiting'));
        expect(
          waitingFinder,
          findsOneWidget,
          reason:
              'WH-AR: a guest must still show lobby-waiting when the room '
              'is full',
        );
        final waitingText = tester.widget<Text>(waitingFinder);
        expect(
          waitingText.data,
          _kWaitingForHostAr,
          reason:
              'WH-AR: with a full room, lobby-waiting must read the '
              'literal "$_kWaitingForHostAr" (the host is who this guest '
              'is now waiting on); got "${waitingText.data}"',
        );
        expect(
          find.textContaining(_kOldCountAr),
          findsNothing,
          reason:
              'WH-AR: the "$_kOldCountAr (n of m)" line must not be shown '
              'in a full room',
        );
      },
    );

    testWidgets(
      'WH-3: guest in a 3-player room, 3 of 3: lobby-waiting reads the '
      'host-starts-it literal, catching an implementation that only '
      'checks seated == 4',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          3,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

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
          players: 3,
          seats: seats,
        );

        expect(
          controller.isHost,
          isFalse,
          reason: 'WH-3 fixture: this scenario must mount as a guest',
        );
        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason: 'WH-3 fixture: needs a full 3-player room, 3 of 3',
        );
        expect(
          controller.room!.players,
          3,
          reason: 'WH-3 fixture: needs a 3-player room, not the default 4',
        );

        final waitingFinder = find.byKey(const Key('lobby-waiting'));
        expect(
          waitingFinder,
          findsOneWidget,
          reason:
              'WH-3: a guest must still show lobby-waiting when the room '
              'is full',
        );
        final waitingText = tester.widget<Text>(waitingFinder);
        expect(
          waitingText.data,
          _kWaitingForHostEn,
          reason:
              'WH-3: with a full 3-player room, lobby-waiting must read '
              'the literal "$_kWaitingForHostEn" too; "full" is seated == '
              'players, not seated == 4, and a room capped at 3 must not '
              'be exempted; got "${waitingText.data}"',
        );
      },
    );

    testWidgets('WH-PART: guest, 3 of 4: lobby-waiting reads the host line, '
        'not the players count (C-666 D3)', (tester) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final seats = List<Map<String, Object?>>.generate(
        3,
        (i) => _seatJson(i, name: 'p$i', connected: true),
      );

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
        seats: seats,
      );

      expect(
        controller.isHost,
        isFalse,
        reason: 'WH-PART fixture: this scenario must mount as a guest',
      );
      expect(
        controller.room!.seats.length,
        3,
        reason: 'WH-PART fixture: needs a room short of full, 3 of 4',
      );
      expect(
        controller.room!.players,
        4,
        reason: 'WH-PART fixture: needs a room short of full, 3 of 4',
      );

      final waitingFinder = find.byKey(const Key('lobby-waiting'));
      expect(
        waitingFinder,
        findsOneWidget,
        reason: 'WH-PART: a guest must still show lobby-waiting',
      );
      final waitingText = tester.widget<Text>(waitingFinder);
      expect(
        waitingText.data,
        _kWaitingForHostEn,
        reason:
            'WH-PART: with the room short of full, lobby-waiting must read '
            '"$_kWaitingForHostEn" all the same (C-666 D3: the host decides '
            'when to start); got "${waitingText.data}"',
      );
      expect(
        find.textContaining(_kOldCountEn),
        findsNothing,
        reason: 'WH-PART: the "$_kOldCountEn (n of m)" line is gone',
      );
    });

    testWidgets(
      'WH-FILL: guest mounted at 3 of 4 reading the host line; once the '
      'server pushes the frame that seats the fourth player, the same '
      'lobby-waiting still reads the host-starts-it literal',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final threeSeats = List<Map<String, Object?>>.generate(
          3,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

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
          seats: threeSeats,
        );

        expect(
          controller.isHost,
          isFalse,
          reason: 'WH-FILL fixture: this scenario must mount as a guest',
        );
        expect(
          controller.room!.seats.length,
          3,
          reason: 'WH-FILL fixture: must mount short of full, 3 of 4',
        );
        expect(
          controller.room!.players,
          4,
          reason: 'WH-FILL fixture: must mount short of full, 3 of 4',
        );

        final waitingFinder = find.byKey(const Key('lobby-waiting'));
        final beforeText = tester.widget<Text>(waitingFinder);
        expect(
          beforeText.data,
          _kWaitingForHostEn,
          reason:
              'WH-FILL: before the fourth seat arrives, lobby-waiting must '
              'already read "$_kWaitingForHostEn" (C-666 D3); '
              'got "${beforeText.data}"',
        );

        // Grow the room to 4 of 4 the way lobby_screen_test.dart already
        // does: a presence push whose seq is not room.seq + 1 (here, room.
        // seq is 1, so anything but 2) makes RoomController's own
        // _beginResync send a resume on this same transport; answering it
        // with a room frame replaces the whole snapshot. seat 0 (the host)
        // is already seated, so the gap check is reached.
        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': true, 'seq': 9},
          ),
        );
        await tester.pump();
        await tester.pump();

        final resumeId = _idOf(transport.sentRaw.last);
        expect(
          _typeOf(transport.sentRaw.last),
          'resume',
          reason:
              'WH-FILL fixture: the gapped presence above must have made '
              'the controller send its own background resume as the last '
              'request on this transport',
        );

        final fourSeats = List<Map<String, Object?>>.generate(
          4,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: resumeId,
            data: _roomJson(players: 4, hostSeat: 0, seats: fourSeats, seq: 9),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason:
              'WH-FILL fixture: the pushed room frame must have grown the '
              'room to 4 of 4 before this test can claim anything about '
              'the text it shows now',
        );

        final afterText = tester.widget<Text>(
          find.byKey(const Key('lobby-waiting')),
        );
        expect(
          afterText.data,
          _kWaitingForHostEn,
          reason:
              'WH-FILL: once the fourth seat fills the room in place, the '
              'same lobby-waiting (one mount, no remount) must read the '
              'literal "$_kWaitingForHostEn"; got "${afterText.data}"',
        );
      },
    );
  });
}
